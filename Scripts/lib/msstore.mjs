// Rocket — Microsoft Store submission API (Partner Center) helpers.
//
// Mirrors asc.mjs / play.mjs: an auth helper (`makeMsToken`), a thin request
// client (`msstore(...)`), then the app-submission endpoints Rocket drives.
// Zero dependencies — Node's built-in fetch.
//
// AUTH — Azure AD (Entra) client-credentials. An Entra app registered under the
// Partner Center account (tenant id + client id + client secret) requests a
// bearer for the Dev Center management resource. Same three secrets the Haven
// docs call STORE_TENANT_ID / STORE_CLIENT_ID / STORE_CLIENT_SECRET.
//
// ── WHAT MUST BE DONE ONCE, BY HAND, IN PARTNER CENTER (cannot be API-driven) ──
//   1. Register as a Microsoft developer + pay the one-time fee.
//   2. RESERVE the app's display name (e.g. "Haven 〇"). The reserved name is
//      what the package identity binds to — the API can't create it.
//   3. Complete TAX + PAYOUT profiles. Submissions are blocked until these exist.
//   4. Create + COMMIT the app's VERY FIRST submission by hand: age rating,
//      category, screenshots, description, pricing/markets, and the first
//      package. The Store enrolls package signing on this first pass.
//   Only AFTER the app is live can this client open follow-up submissions. Every
//   package update carries the listing forward unchanged unless you patch it
//   (see updateSubmission). Partner Center allows exactly ONE open submission at
//   a time, so a metadata edit and a package update can't both be pending.

import { readFile } from 'node:fs/promises';

const MGMT = 'https://manage.devcenter.microsoft.com/v1.0/my';
const RESOURCE = 'https://manage.devcenter.microsoft.com';

// Azure AD client-credentials → management-API bearer.
export async function makeMsToken({ tenantId, clientId, clientSecret } = {}) {
  if (!tenantId || !clientId || !clientSecret) {
    throw new Error('Microsoft Store auth needs tenantId + clientId + clientSecret (set MS_TENANT_ID / MS_CLIENT_ID / MS_CLIENT_SECRET)');
  }
  const url = `https://login.microsoftonline.com/${encodeURIComponent(tenantId)}/oauth2/token`;
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: clientId,
      client_secret: clientSecret,
      resource: RESOURCE,
    }),
  });
  const json = await r.json().catch(() => ({}));
  if (!r.ok || !json.access_token) {
    const detail = json.error_description || json.error || r.statusText;
    throw new Error(`Microsoft Store token exchange failed → ${r.status} ${detail}`);
  }
  return json.access_token;
}

// Thin request client. get/post/put/del mirror asc().
export function msstore(token) {
  const call = async (method, path, body) => {
    const r = await fetch(MGMT + path, {
      method,
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (r.status === 204) return {};
    const json = await r.json().catch(() => ({}));
    if (!r.ok) {
      const detail = json?.message
        || json?.errors?.map((e) => e.message || e.code).join('; ')
        || r.statusText;
      const err = new Error(`MS ${method} ${path} → ${r.status} ${detail}`);
      err.body = json;   // Partner Center 400s hide per-field ModelState here — keep it
      throw err;
    }
    return json;
  };
  return {
    token,
    get: (p) => call('GET', p),
    post: (p, b) => call('POST', p, b),
    put: (p, b) => call('PUT', p, b),
    del: (p) => call('DELETE', p),
  };
}

const enc = encodeURIComponent;

// ---- app + submissions ----------------------------------------------------

// The app record: includes pendingApplicationSubmission (an open one, if any)
// and lastPublishedApplicationSubmission.
export async function getApp(api, appId) {
  return api.get(`/applications/${enc(appId)}`);
}

// Delete an open (pending) submission — the Store allows only one at a time, so
// creating a new submission first requires clearing any stuck pending one.
export async function deletePendingSubmission(api, appId, submissionId) {
  return api.del(`/applications/${enc(appId)}/submissions/${enc(submissionId)}`);
}

// Create a new submission (clones the last published one as the starting point).
// Throws if a pending submission already exists — clear it first (see above).
export async function createSubmission(api, appId) {
  return api.post(`/applications/${enc(appId)}/submissions`, {});
}

export async function getSubmission(api, appId, submissionId) {
  return api.get(`/applications/${enc(appId)}/submissions/${enc(submissionId)}`);
}

// PUT the full submission object back after mutating listings/packages/etc.
// (the Store's update is a whole-object replace, not a patch).
export async function updateSubmission(api, appId, submissionId, submission) {
  return api.put(`/applications/${enc(appId)}/submissions/${enc(submissionId)}`, submission);
}

// Commit a submission → sends it to certification.
export async function commitSubmission(api, appId, submissionId) {
  return api.post(`/applications/${enc(appId)}/submissions/${enc(submissionId)}/commit`, {});
}

// Poll a submission's status: { status, statusDetails }.
// status ∈ None|CommitStarted|CommitFailed|PreProcessing|Certification|Release|Published|…
export async function getSubmissionStatus(api, appId, submissionId) {
  return api.get(`/applications/${enc(appId)}/submissions/${enc(submissionId)}/status`);
}

// ---- package upload (Azure blob SAS) --------------------------------------

// The submission response carries `fileUploadUrl` — a pre-authorized Azure blob
// SAS URL. You upload a ZIP whose contents are the package(s) named in the
// submission's applicationPackages[].fileName. This does a single BlockBlob PUT,
// which is fine for the modest MSIX sizes here; a multi-hundred-MB package would
// need block-list chunking (x-ms-blob-type stays BlockBlob, but split + commit
// blocks) — noted so nobody is surprised by a size ceiling.
export async function uploadPackageZip(fileUploadUrl, zipPath) {
  if (!fileUploadUrl) throw new Error('submission has no fileUploadUrl — recreate the submission');
  const bytes = await readFile(zipPath);
  const r = await fetch(fileUploadUrl.replace('+', '%2B'), {
    method: 'PUT',
    headers: { 'x-ms-blob-type': 'BlockBlob', 'content-type': 'application/zip' },
    body: bytes,
  });
  if (!r.ok) {
    const text = await r.text().catch(() => r.statusText);
    throw new Error(`MS package upload → ${r.status} ${text.slice(0, 200)}`);
  }
  return true;
}

// ---- listing helpers ------------------------------------------------------

// Patch the base (default-language, or given index) listing's text fields on a
// submission object IN PLACE, then hand it back for updateSubmission. The Store
// nests listings under listings[lang].baseListing.{title,description,...}.
export function patchListing(submission, lang, { title, description, shortDescription, releaseNotes } = {}) {
  submission.listings = submission.listings || {};
  const entry = submission.listings[lang] = submission.listings[lang] || { baseListing: {} };
  entry.baseListing = entry.baseListing || {};
  if (title != null) entry.baseListing.title = title;
  if (description != null) entry.baseListing.description = description;
  // MS Store has no dedicated "short description"; the closest is the listing's
  // features/first description line. We stash it as the first feature so nothing
  // is silently dropped.
  if (shortDescription != null) {
    entry.baseListing.features = entry.baseListing.features || [];
    entry.baseListing.features[0] = shortDescription;
  }
  if (releaseNotes != null) entry.baseListing.releaseNotes = releaseNotes;   // vendored addition
  return submission;
}

// A compact status read for `rocket status <app> --store ms`: the app's pending
// + last-published submission ids/states, without opening anything.
export async function msStatus(api, appId) {
  const app = await getApp(api, appId);
  const pending = app.pendingApplicationSubmission || null;
  const last = app.lastPublishedApplicationSubmission || null;
  const out = { appId, primaryName: app.primaryName, pending: null, lastPublished: null };
  if (pending) {
    const s = await getSubmissionStatus(api, appId, pending.id).catch(() => ({}));
    out.pending = { id: pending.id, status: s.status || 'Pending' };
  }
  if (last) out.lastPublished = { id: last.id };
  return out;
}

// ── NEW Store Submission API (api.partner.microsoft.com "ingestion") ─────────────────
// The pipeline behind msstore-cli and the new Partner Center UI. Exists here because the
// legacy devcenter API's submission-clone went inconsistent after a dashboard-flow publish
// (clone claims zero listings while GET shows them) — the new pipeline is the writable one.
// The `/my/` segment resolves the seller context for the AAD app (msstore-cli's base);
// without it every product 404s (ICH50404) even with a valid token — probed empirically.
const INGESTION = 'https://api.partner.microsoft.com/v1.0/my/ingestion';

export async function makeIngestionToken({ tenantId, clientId, clientSecret } = {}) {
  const r = await fetch(`https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: clientId,
      client_secret: clientSecret,
      scope: 'https://api.partner.microsoft.com/.default',
    }),
  });
  const json = await r.json().catch(() => ({}));
  if (!r.ok || !json.access_token) {
    throw new Error(`ingestion token exchange failed → ${r.status} ${json.error_description || json.error || r.statusText}`);
  }
  return json.access_token;
}

export function ingestion(token) {
  const call = async (method, path, body) => {
    const r = await fetch(INGESTION + path, {
      method,
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await r.text();
    let json = null; try { json = text ? JSON.parse(text) : null; } catch { /* */ }
    if (!r.ok) {
      const err = new Error(`ING ${method} ${path} → ${r.status} ${(json?.message || text || r.statusText).slice(0, 300)}`);
      err.status = r.status; err.body = json ?? text;
      throw err;
    }
    return json;
  };
  return { token, get: (p) => call('GET', p), post: (p, b) => call('POST', p, b), put: (p, b) => call('PUT', p, b) };
}
