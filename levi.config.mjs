// levi.config.mjs — localization surfaces for Haven.
//
// Levi auto-discovers the .xcstrings catalog, appstore-metadata.md and the
// Android res/values-* trees, so those are deliberately NOT declared here.
// Only the web dictionaries need declaring — the layout varies per project and
// cannot be guessed, which is why `levi status Haven` reported
// "web/JSON — not configured" and every site string stayed unmanaged.
//
//   node ../_shared/levi/levi.mjs status Haven
//   node ../_shared/levi/levi.mjs translate Haven --surface web
export default {
  name: 'Haven',

  // web/i18n/<page>.<lang>.json — English is baked into each page's HTML as the
  // no-JS + SEO baseline, and `<page>.en.json` mirrors it as the translation
  // source. Elements bind by stable key via data-i18n / data-i18n-html, so
  // editing English copy means editing the HTML *and* the matching value in
  // <page>.en.json; the other locales then read as stale and Levi refills them.
  web: { dir: 'web/i18n', pattern: '{page}.{lang}.json', source: 'en' },
};
