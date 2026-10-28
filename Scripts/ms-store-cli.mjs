#!/usr/bin/env node
// Microsoft Store release through Microsoft's own `msstore` CLI (v0.4.x): package + the nine-language listing,
// in one submission. Replaces the hand-rolled Ingestion-API lane (Scripts/ms-store-publish.mjs), which
// the Store's packaged-app backend broke in 2026-08; the CLI's `submission get/update/publish` path works again.
//
// Standalone on purpose — CI (release.yml `msix-submit`, ms-store.yml) and rocket can both call it:
//
//   node Scripts/ms-store-cli.mjs --version 2.1.0 --msix out/Haven-2.1.0.msixbundle
//        [--no-commit]   leave the submission as a draft (you press Submit in Partner Center)
//        [--no-wait]     commit and exit without polling certification
//        [--dry-run]     map + print the listing patch from the CURRENT submission; change nothing
//
// Needs `msstore` on PATH, already configured (`msstore reconfigure …`), and STORE_APP_ID. On Linux the CLI's
// credential store needs libsecret + an unlocked keyring (see .github/workflows/ms-store.yml). Linux matters:
// `submission update` takes the whole submission as ONE argument (~55 KB with nine languages), over Windows' 32,767-char cap.
//
// Flow (the CLI docs' own order — `publish` RECREATES the draft, so it must run before any metadata edit):
//   1. msstore publish <msixbundle> -id <app> --noCommit           package into a fresh draft
//   2. msstore submission get <app>                                the draft as JSON
//   3. patch each locale's Description/ShortDescription/ReleaseNotes (not Title: names are reserved) from appstore-metadata[.<locale>].md
//      (a language the draft lacks is cloned from en-us, so it keeps the screenshots)
//   4. msstore submission update <app> <json>                      listings + package, together
//   5. msstore submission publish <app> ; msstore submission poll <app>

import { existsSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { loadMetadata, toMsListing } from './lib/metadata.mjs';
import { msCode } from './lib/locales.mjs';

const arg = (name, dflt = null) => { const i = process.argv.indexOf(`--${name}`); return i === -1 ? dflt : (process.argv[i + 1] ?? true); };
const has = (name) => process.argv.includes(`--${name}`);
const die = (m) => { console.error(`✗ ${m}`); process.exit(1); };
const log = (m) => console.log(`• ${m}`);
const ok = (m) => console.log(`✓ ${m}`);

const version = arg('version') || die('--version X.Y.Z required');
const msix = arg('msix');
const dryRun = has('dry-run');
const appId = process.env.STORE_APP_ID || die('STORE_APP_ID unset');
if (!dryRun && !msix) die('--msix required (or --dry-run)');
if (msix && !existsSync(msix)) die(`no such file: ${msix}`);

const ms = (args, { allowFail = false, quiet = false } = {}) => {
  const r = spawnSync('msstore', args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (!quiet) process.stderr.write(`$ msstore ${args.map((a) => (a.length > 80 ? `<${a.length} chars>` : a)).join(' ')}\n`);
  if (r.stderr && !quiet) process.stderr.write(r.stderr.split('\n').slice(-12).join('\n') + '\n');
  if (r.status !== 0 && !allowFail) die(`msstore ${args[0]} ${args[1] ?? ''} failed (exit ${r.status})\n${(r.stdout || '').slice(-1500)}`);
  return r;
};
const getSubmission = () => {
  const r = ms(['submission', 'get', appId], { quiet: true });
  const text = r.stdout;
  const start = text.indexOf('{');
  if (start < 0) die(`submission get returned no JSON:\n${text.slice(0, 500)}`);
  return JSON.parse(text.slice(start));
};

// ── the listing text, per language, from appstore-metadata[.<locale>].md ──
const root = process.cwd();
const metaFiles = readdirSync(root).filter((f) => /^appstore-metadata(\.[A-Za-z-]+)?\.md$/.test(f));
if (!metaFiles.length) die('no appstore-metadata*.md in the working directory');
const wanted = [];
for (const f of metaFiles) {
  const m = f.match(/^appstore-metadata(?:\.([A-Za-z-]+))?\.md$/);
  const locale = m[1] || 'en-US';
  const fields = await loadMetadata(join(root, f));
  const { listing, warnings } = toMsListing(fields);
  warnings.forEach((w) => log(`⚠ ${w}`));
  if (!Object.keys(listing).length) { log(`⚠ ${f}: nothing to push — skipped`); continue; }
  if (!has('bare') && fields.whats_new && !fields.whats_new.startsWith(version)) {
    die(`${f} whats_new starts with "${fields.whats_new.split('\n')[0].slice(0, 50)}" — must start with "${version}" (stale notes would ship)`);
  }
  wanted.push({ lang: msCode(locale), listing });
}
ok(`listing text ready for ${wanted.length} language(s): ${wanted.map((w) => w.lang).join(', ')}`);

const pascal = (k) => k[0].toUpperCase() + k.slice(1);
const patch = (sub) => {
  sub.Listings ??= {};
  const en = sub.Listings['en-us']?.BaseListing;
  for (const { lang, listing } of wanted) {
    let entry = sub.Listings[lang];
    if (!entry) {
      if (!en) { log(`⚠ ${lang}: not in the submission and no en-us listing to clone — skipped`); continue; }
      entry = sub.Listings[lang] = { BaseListing: structuredClone(en) };   // keeps screenshots/keywords; text is replaced below
      log(`${lang}: new language, cloned from en-us`);
    }
    entry.BaseListing ??= {};
    // NEVER the title: the Store only accepts RESERVED app names per language ("Invalid listing title(s) … Please use
    // reserved name(s)"), and a translated title is not one. The draft keeps whatever name was reserved.
    for (const [k, v] of Object.entries(listing)) if (k !== 'title') entry.BaseListing[pascal(k)] = v;
  }
  return sub;
};

if (dryRun) {
  const sub = patch(getSubmission());
  for (const { lang } of wanted) {
    const b = sub.Listings?.[lang]?.BaseListing || {};
    log(`${lang}: title=${JSON.stringify(b.Title ?? null)} descLen=${(b.Description || '').length} notes=${JSON.stringify((b.ReleaseNotes || '').slice(0, 40))}`);
  }
  ok('dry run — nothing changed');
  process.exit(0);
}

// 1. package → fresh draft (recreates the draft from the last published submission)
// The package FILE is the positional argument (the CLI's loose-MSIX publisher takes .msix/.msixbundle/.msixupload
// there; its `-i` is an input DIRECTORY, whatever the docs say). Absolute, because the CLI's cwd is not ours.
ms(['publish', resolve(msix), '-id', appId, '--noCommit', '-v']);
// EXPERIMENT (--bare): commit the package-only draft untouched — no `submission update`, so no pricing is re-sent.
if (has('bare')) { ms(['submission', 'publish', appId]); ok('bare draft (package only, no update) committed'); process.exit(0); }
// 2-4. listing text onto that draft, together with the package it now holds
const sub = patch(getSubmission());
// Pricing and availability: the Store's API REQUIRES a Pricing object on every update (the CLI: "The JSON you provided
// has no 'Pricing' object"; the REST API: "Pricing data was not provided"), so it cannot be left out. What we can do is
// send back EXACTLY what the draft already holds — never edit it — and make sure the draft is a clean clone of the last
// PUBLISHED submission: a draft cloned from a previously FAILED one (CommitFailed) inherits its broken pricing
// (a phantom 235-market "sale" → InvalidPricingAvailabilitySettings), so a failed submission must be deleted first
// (`msstore submission delete`; ms-store-cli-probe.yml delete_pending) before the next attempt.
const price = sub.Pricing?.PriceId;
log(`Pricing sent back unchanged: PriceId=${JSON.stringify(price ?? null)}, markets overridden: ${Object.keys(sub.Pricing?.MarketSpecificPricings || {}).join(',') || 'none'}`);
if (!price || price === 'Base') { sub.Pricing ??= {}; sub.Pricing.PriceId = 'Free'; log('⚠ PriceId was missing/Base — set to "Free"'); }
const upd = ms(['submission', 'update', appId, JSON.stringify(sub), '-v'], { allowFail: true });
if (upd.status !== 0) die(`msstore submission update failed (exit ${upd.status})\n--- stdout ---\n${(upd.stdout || '').slice(-3500)}\n--- stderr ---\n${(upd.stderr || '').slice(-1500)}`);
ok(`draft updated: ${wanted.length} language(s) + ${msix}`);
if (has('no-commit')) { ok('left as a DRAFT (--no-commit): review and Submit in Partner Center'); process.exit(0); }
// 5. commit + certification
ms(['submission', 'publish', appId]);
ok(`submitted ${version} for certification`);
if (!has('no-wait')) ms(['submission', 'poll', appId], { allowFail: true });
