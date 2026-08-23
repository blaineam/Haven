// Rocket — parse a per-app appstore-metadata.md into ASC field maps.
//
// Format: a markdown file with `## <field>` sections. Recognised fields map to
// App Store Connect attributes. ASC enforces length limits (commented below).
import { readFile } from 'node:fs/promises';

// field -> { target, attr, max }
//   target 'version' → appStoreVersionLocalization
//   target 'appInfo' → appInfoLocalization (app-level)
//   target 'review'  → appStoreReviewDetail (reviewer notes / contact / demo)
export const FIELDS = {
  name:               { target: 'appInfo', attr: 'name', max: 30 },
  subtitle:           { target: 'appInfo', attr: 'subtitle', max: 30 },
  privacy_policy_url: { target: 'appInfo', attr: 'privacyPolicyUrl', max: 255 },
  description:        { target: 'version', attr: 'description', max: 4000 },
  keywords:          { target: 'version', attr: 'keywords', max: 100 },
  promotional_text:  { target: 'version', attr: 'promotionalText', max: 170 },
  whats_new:         { target: 'version', attr: 'whatsNew', max: 4000 },
  marketing_url:     { target: 'version', attr: 'marketingUrl', max: 255 },
  support_url:       { target: 'version', attr: 'supportUrl', max: 255 },
  review_notes:      { target: 'review', attr: 'notes', max: 4000 },
  review_first_name: { target: 'review', attr: 'contactFirstName', max: 50 },
  review_last_name:  { target: 'review', attr: 'contactLastName', max: 50 },
  review_phone:      { target: 'review', attr: 'contactPhone', max: 50 },
  review_email:      { target: 'review', attr: 'contactEmail', max: 100 },
  demo_account_name:     { target: 'review', attr: 'demoAccountName', max: 100 },
  demo_account_password: { target: 'review', attr: 'demoAccountPassword', max: 100 },
};

// Store POLICY sections — not listing copy, never pushed by `meta`, never
// localized. They drive `rocket territories` / `rocket price` / `rocket
// compliance` (see docs/compliance.md) and are preserved by `meta-pull`.
//   ## availability      exclude: eu, france, china   new_territories: yes|no
//   ## price             free | 4.99                  (base-territory customer price)
export const POLICY_FIELDS = ['availability', 'price'];

// Every `## key` section in the markdown → { key: body }. Keys are lower-cased.
export function sectionsOf(md) {
  const out = {};
  const re = /^##\s+([a-z0-9_]+)\s*$/gim;
  const parts = [];
  let m, last = null;
  while ((m = re.exec(md))) {
    if (last) parts.push({ key: last.key, start: last.end, end: m.index });
    last = { key: m[1].toLowerCase(), end: re.lastIndex };
  }
  if (last) parts.push({ key: last.key, start: last.end, end: md.length });
  for (const p of parts) out[p.key] = md.slice(p.start, p.end).trim();
  return out;
}

export function parseMetadata(md) {
  const out = {};
  for (const [key, body] of Object.entries(sectionsOf(md))) if (FIELDS[key]) out[key] = body;
  return out;
}

// The policy sections only (raw bodies; the commands parse them further).
export function parsePolicy(md) {
  const out = {};
  for (const [key, body] of Object.entries(sectionsOf(md))) if (POLICY_FIELDS.includes(key)) out[key] = body;
  return out;
}

export async function loadMetadata(path) {
  const md = await readFile(path, 'utf8');
  return parseMetadata(md);
}

// Fields ASC actually stores per-locale. Everything with target 'review' is on
// appStoreReviewDetail, which is ONE record per version — not localized. Pushing
// a translated review note would overwrite the reviewer's English instructions
// with, say, German, so non-source locales drop those fields entirely.
export const LOCALIZED_TARGETS = new Set(['version', 'appInfo']);

// Split parsed fields into ASC version-localization + appInfo-localization attr maps.
// Returns { version: {...}, appInfo: {...}, review: {...}, warnings: [...] }.
// `locale` only changes which fields are eligible — see LOCALIZED_TARGETS.
export function toAscAttrs(fields, { locale = 'en-US' } = {}) {
  const out = { version: {}, appInfo: {}, review: {} };
  const warnings = [];
  const localizedOnly = locale !== 'en-US';
  const skippedReview = [];
  for (const [key, value] of Object.entries(fields)) {
    const def = FIELDS[key];
    if (!def) continue;
    if (localizedOnly && !LOCALIZED_TARGETS.has(def.target)) { skippedReview.push(key); continue; }
    let v = value;
    if (def.max && v.length > def.max) {
      warnings.push(`${localizedOnly ? `${locale} ` : ''}${key} is ${v.length} chars, ASC max ${def.max} — truncating`);
      v = v.slice(0, def.max);
    }
    (out[def.target] ?? out.version)[def.attr] = v;
  }
  if (skippedReview.length) {
    warnings.push(`${locale}: ${skippedReview.join(', ')} skipped — App Review details aren't localized (they live on the version, once)`);
  }
  return { ...out, warnings };
}

// ── Google Play listing mapping ────────────────────────────────────────────
// The same appstore-metadata.md drives Play. Play's field set + limits differ
// from ASC, so map the shared fields and truncate to Play's caps. Returns
// { listing: { title, shortDescription, fullDescription }, whatsNew, warnings }.
//   title             ≤ 50   ← name
//   shortDescription  ≤ 80   ← subtitle (falls back to promotional_text)
//   fullDescription   ≤ 4000 ← description
//   whatsNew (notes)  ≤ 500  ← whats_new  (per-track release notes, not listing)
export const PLAY_LIMITS = { title: 50, shortDescription: 80, fullDescription: 4000, whatsNew: 500 };
export function toPlayListing(fields) {
  const warnings = [];
  const cap = (key, val) => {
    if (val == null) return undefined;
    const max = PLAY_LIMITS[key];
    if (max && val.length > max) { warnings.push(`play ${key} is ${val.length} chars, Play max ${max} — truncating`); return val.slice(0, max); }
    return val;
  };
  const listing = {};
  const title = cap('title', fields.name);
  const shortDescription = cap('shortDescription', fields.subtitle || fields.promotional_text);
  const fullDescription = cap('fullDescription', fields.description);
  if (title != null) listing.title = title;
  if (shortDescription != null) listing.shortDescription = shortDescription;
  if (fullDescription != null) listing.fullDescription = fullDescription;
  const whatsNew = cap('whatsNew', fields.whats_new);
  return { listing, whatsNew, warnings };
}

// ── Microsoft Store listing mapping ────────────────────────────────────────
// Returns { listing: { title, description, shortDescription }, warnings }.
//   title            ≤ 256  ← name
//   description      ≤ 10000 ← description
//   shortDescription ≤ 200  ← subtitle (stashed as the first "feature")
export const MS_LIMITS = { title: 256, description: 10000, shortDescription: 200, releaseNotes: 1500 };
export function toMsListing(fields) {
  const warnings = [];
  const cap = (key, val) => {
    if (val == null) return undefined;
    const max = MS_LIMITS[key];
    if (max && val.length > max) { warnings.push(`ms ${key} is ${val.length} chars, MS max ${max} — truncating`); return val.slice(0, max); }
    return val;
  };
  const listing = {};
  const title = cap('title', fields.name);
  const description = cap('description', fields.description);
  const shortDescription = cap('shortDescription', fields.subtitle || fields.promotional_text);
  if (title != null) listing.title = title;
  if (description != null) listing.description = description;
  if (shortDescription != null) listing.shortDescription = shortDescription;
  // VENDORED ADDITION (upstream: rocket lib/metadata.mjs): the MS listing carries release notes
  // too — rocket's copy dropped whats_new for MS, so the Store never showed per-version notes.
  const releaseNotes = cap('releaseNotes', fields.whats_new);
  if (releaseNotes != null) listing.releaseNotes = releaseNotes;
  return { listing, warnings };
}

export const TEMPLATE = `# {{APP}} — App Store metadata

<!-- Edited here, synced to the App Store Connect draft by: rocket meta {{APP}} -->
<!-- Lengths are enforced by ASC. Keep within the limits noted. -->

## name
{{APP}}

## subtitle
A short, punchy tagline (≤30 chars)

## description
What the app does and why someone wants it. Up to 4000 chars.

## keywords
comma,separated,keywords,≤100,chars,total

## promotional_text
Optional 170-char line you can change anytime without a new build.

## whats_new
What changed in this version.

## marketing_url
https://example.com

## support_url
https://example.com/support

## privacy_policy_url
https://example.com/privacy

## review_notes
Notes for the App Review team: how to exercise the app, any test data, and what
to expect. Up to 4000 chars.

## review_first_name
First

## review_last_name
Last

## review_phone
+10000000000

## review_email
you@example.com

## availability
<!-- Store policy, applied by: rocket territories {{APP}} --apply   (docs/compliance.md)
     exclude: named sets (eu, eea, france, china, uk, switzerland) and/or ISO codes -->
exclude: france, china
new_territories: yes

## price
<!-- Base-territory customer price, applied by: rocket price {{APP}} --apply -->
free
`;
