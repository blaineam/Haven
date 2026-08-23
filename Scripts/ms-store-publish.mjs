#!/usr/bin/env node
// Microsoft Store publish — listing (all locales) + package in ONE submission, pure Ingestion API.
//
// Why this exists (2026-08-23, the night 1.7.0 shipped):
//   * msstore-cli refused the publish twice: first because a DASHBOARD-created submission occupied
//     the slot ("Ingestion API can only update…"), then because "App updates are supported only
//     for Free products" — a CLI-side gate; the raw Ingestion API serves paid apps fine.
//   * The CLI also submits the PACKAGE ONLY — listing text and what's-new never rode CI, and the
//     user's requirement is explicit: "I want ms store listing info to be updated on ci".
//
// The MS client + metadata parser are VENDORED from the private blaineam/rocket repo
// (lib/msstore.mjs, lib/metadata.mjs, lib/locales.mjs) — CI cannot check that repo out without a
// cross-repo token this repo does not have. Improvements here (releaseNotes mapping, the
// applicationPackages patch) should be upstreamed to rocket when convenient.
//
// Flow: token → app → reuse-or-create the pending API submission → patch every locale's listing
// from appstore-metadata[.<locale>].md → declare the new package (old ones PendingDelete) →
// update → upload the package zip → commit → poll certification.
//
// Env: STORE_TENANT_ID, STORE_CLIENT_ID, STORE_CLIENT_SECRET, STORE_APP_ID
// Usage: node Scripts/ms-store-publish.mjs --version 1.7.0 --msix path/to/Haven-1.7.0.msix
//        [--dry-run]  parse + map + print, no network
//        [--no-wait]  commit and exit without polling certification

import { existsSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { basename, join } from 'node:path';
import {
  makeMsToken, msstore, getApp, getSubmission, createSubmission, updateSubmission,
  commitSubmission, getSubmissionStatus, uploadPackageZip, patchListing,
  deletePendingSubmission,
} from './lib/msstore.mjs';
import { loadMetadata, toMsListing } from './lib/metadata.mjs';
import { makeIngestionToken, ingestion } from './lib/msstore.mjs';
import { msCode } from './lib/locales.mjs';

const arg = (name, dflt = null) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? dflt : (process.argv[i + 1] ?? true);
};
const has = (name) => process.argv.includes(`--${name}`);
const die = (m) => { console.error(`✗ ${m}`); process.exit(1); };
const log = (m) => console.log(`• ${m}`);
const ok = (m) => console.log(`✓ ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── probe mode: map the NEW ingestion API's view of this product (no writes) ──
if (has('probe-ingestion')) {
  const storeId = arg('store-id') || die('--store-id required for the probe');
  const tok = await makeIngestionToken({
    tenantId: process.env.STORE_TENANT_ID, clientId: process.env.STORE_CLIENT_ID,
    clientSecret: process.env.STORE_CLIENT_SECRET,
  });
  console.log('• ingestion token OK');
  const ing = ingestion(tok);
  // Also learn the legacy GUID for this app — the ingestion surface may key products by
  // it rather than the Store big-ID.
  let guid = null;
  try {
    const legacyTok = await makeMsToken({ tenantId: process.env.STORE_TENANT_ID, clientId: process.env.STORE_CLIENT_ID, clientSecret: process.env.STORE_CLIENT_SECRET });
    const legacy = msstore(legacyTok);
    const app = await getApp(legacy, process.env.STORE_APP_ID);
    guid = app?.id || null;
    console.log(`• legacy app.id = ${guid} (primaryName=${app?.primaryName})`);
  } catch (e) { console.log(`• legacy lookup failed: ${String(e.message).slice(0, 120)}`); }
  const probes = [
    '/products',
    `/products/${storeId}`,
    ...(guid && guid !== storeId ? [`/products/${guid}`] : []),
  ];
  for (const p of probes) {
    try {
      const r = await ing.get(p);
      console.log(`✓ GET ${p} → ${JSON.stringify(r).slice(0, 1400)}`);
    } catch (e) {
      console.log(`✗ GET ${p} → ${e.status ?? '?'} ${String(e.message).slice(0, 260)}`);
    }
  }
  process.exit(0);
}

const version = arg('version') || die('--version required');
const msixPath = arg('msix');
const dryRun = has('dry-run');
const wait = !has('no-wait');
if (!dryRun && !msixPath) die('--msix required (or use --dry-run)');
if (msixPath && !existsSync(msixPath)) die(`no such file: ${msixPath}`);

// Every appstore-metadata[.<locale>].md in the repo root drives one MS listing language.
const root = process.cwd();
const metaFiles = readdirSync(root).filter((f) => /^appstore-metadata(\.[A-Za-z-]+)?\.md$/.test(f));
if (!metaFiles.length) die('no appstore-metadata*.md in the working directory');

const listings = [];
for (const f of metaFiles) {
  const m = f.match(/^appstore-metadata(?:\.([A-Za-z-]+))?\.md$/);
  const locale = m[1] || 'en-US';
  const fields = await loadMetadata(join(root, f));
  const { listing, warnings } = toMsListing(fields);
  warnings.forEach((w) => log(`⚠ ${w}`));
  if (!Object.keys(listing).length) { log(`⚠ ${f}: nothing to push — skipped`); continue; }
  if (fields.whats_new && !fields.whats_new.startsWith(version)) {
    die(`${f} whats_new starts with "${fields.whats_new.split('\n')[0].slice(0, 50)}" — must start with "${version}" (stale notes would ship)`);
  }
  listings.push({ lang: msCode(locale), listing, file: f });
}
ok(`listings prepared for ${listings.length} language(s): ${listings.map((l) => l.lang).join(', ')}`);

if (dryRun) {
  for (const { lang, listing } of listings) {
    log(`${lang}: ${Object.keys(listing).map((k) => `${k}(${String(listing[k]).length})`).join(' ')}`);
  }
  ok('dry-run complete (no network)');
  process.exit(0);
}

const tenantId = process.env.STORE_TENANT_ID || die('STORE_TENANT_ID unset');
const clientId = process.env.STORE_CLIENT_ID || die('STORE_CLIENT_ID unset');
const clientSecret = process.env.STORE_CLIENT_SECRET || die('STORE_CLIENT_SECRET unset');
const appId = process.env.STORE_APP_ID || die('STORE_APP_ID unset');

const token = await makeMsToken({ tenantId, clientId, clientSecret });
const api = msstore(token);
const app = await getApp(api, appId);
log(`app: ${app.primaryName || appId}`);

let sub;
if (app.pendingApplicationSubmission) {
  const id = app.pendingApplicationSubmission.id;
  const status = (await getSubmissionStatus(api, appId, id).catch(() => ({}))).status || 'unknown';
  // Only 'PendingCommit' is editable. An IN-FLIGHT submission (e.g. a dashboard-committed price
  // change in certification) occupies the one-per-app slot and nothing can be created until it
  // publishes — that's a WAIT, not a failure: exit 3 so a dispatcher can retry later. Anything
  // else pending ('None' msstore-cli corpses, 'CommitFailed') rejects every PUT with 409
  // delete-and-recreate — honor that.
  const IN_FLIGHT = ['CommitStarted', 'PreProcessing', 'Certification', 'Publishing', 'Release', 'PendingPublication'];
  if (status === 'PendingCommit') {
    log(`reusing pending submission ${id} (${status})`);
    sub = await getSubmission(api, appId, id);
    log(`draft body status=${sub.status ?? 'absent'} listings=[${Object.keys(sub.listings || {}).join(',')}] packages=${(sub.applicationPackages || []).length}`);
  } else if (IN_FLIGHT.includes(status)) {
    log(`slot occupied: submission ${id} is ${status} — retry after it publishes`);
    process.exit(3);
  } else {
    log(`pending submission ${id} is '${status}' — deleting the corpse`);
    await deletePendingSubmission(api, appId, id);
    sub = await createSubmission(api, appId);
    log(`created submission ${sub.id}`);
  }
} else {
  try {
    sub = await createSubmission(api, appId);
  } catch (e) {
    // Field case: after the dashboard price-flip published, POST /submissions started
    // 400ing "The size of Listings must be 1 or more" — the clone-base (last published
    // submission) fails validation. Dump Microsoft's actual state so the failure is
    // diagnosable from the run log, then rethrow.
    log(`create failed: ${e.message}`);
    if (e.body) log(`full error body: ${JSON.stringify(e.body).slice(0, 1500)}`);
    const fresh = await getApp(api, appId).catch(() => null);
    log(`diagnostics: pending=${JSON.stringify(fresh?.pendingApplicationSubmission || null)} lastPublished=${JSON.stringify(fresh?.lastPublishedApplicationSubmission || null)} advancedListings=${JSON.stringify(fresh?.hasAdvancedListingPermission ?? 'absent')}`);
    const pubId = fresh?.lastPublishedApplicationSubmission?.id;
    if (pubId) {
      const pub = await getSubmission(api, appId, pubId).catch((err) => ({ error: String(err) }));
      log(`published submission ${pubId}: status=${pub.status || '?'} listings=[${Object.keys(pub.listings || {}).join(',') || 'NONE'}] packages=${(pub.applicationPackages || []).length} pricing=${JSON.stringify(pub.pricing?.priceId || pub.pricing || null).slice(0, 120)}`);
      for (const [lang, l] of Object.entries(pub.listings || {})) {
        const base = l?.baseListing || {};
        log(`  listing ${lang}: baseListing keys=[${Object.keys(base).join(',') || 'EMPTY'}] title=${JSON.stringify(base.title ?? null)} descLen=${(base.description || '').length} overrides=[${Object.keys(l?.platformOverrides || {}).join(',') || 'none'}]`);
      }
    }
    throw e;
  }
  log(`created submission ${sub.id}`);
}

for (const { lang, listing } of listings) patchListing(sub, lang, listing);

// Declare the new package; carried-forward packages leave with it. fileName must match the
// entry inside the uploaded zip exactly — the zip is built flat (-j) from the msix below.
const fileName = basename(msixPath);
sub.applicationPackages = (sub.applicationPackages || []).map((p) => ({ ...p, fileStatus: 'PendingDelete' }));
sub.applicationPackages.push({ fileName, fileStatus: 'PendingUpload', minimumDirectXVersion: 'None', minimumSystemRam: 'None' });

await updateSubmission(api, appId, sub.id, sub);
ok(`submission ${sub.id}: ${listings.length} listing(s) + package ${fileName} staged`);

const zip = join(process.env.RUNNER_TEMP || '/tmp', 'ms-store-package.zip');
execFileSync('rm', ['-f', zip]);
execFileSync('zip', ['-j', '-q', zip, msixPath]);
log('uploading package zip…');
await uploadPackageZip(sub.fileUploadUrl, zip);
ok('package uploaded');

await commitSubmission(api, appId, sub.id);
ok(`committed submission ${sub.id} → certification`);
if (!wait) { log('--no-wait: not polling; Partner Center finishes certification.'); process.exit(0); }

const deadline = Date.now() + 30 * 60_000;
for (;;) {
  await sleep(30_000);
  let s;
  try { s = await getSubmissionStatus(api, appId, sub.id); } catch (e) { log(`poll hiccup: ${e.message.split('\n')[0]}`); continue; }
  log(`status: ${s.status}`);
  if (['Published', 'Release', 'CertificationCompleted', 'PreProcessing', 'Certification'].includes(s.status)) {
    // PreProcessing/Certification are healthy in-flight states; only wait out the terminal ones.
    if (['Published', 'Release', 'CertificationCompleted'].includes(s.status)) { ok(`Microsoft Store: ${s.status}`); process.exit(0); }
  }
  if (['CommitFailed', 'CertificationFailed', 'Canceled', 'InvalidState'].includes(s.status)) {
    const errs = (s.statusDetails?.errors || []).map((e) => e.details || e.code).join('; ');
    die(`Microsoft Store: ${s.status} — ${errs || 'see Partner Center'}`);
  }
  if (Date.now() > deadline) { log('still in certification after 30min — Partner Center will finish it.'); process.exit(0); }
}
