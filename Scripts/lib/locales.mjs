// Rocket — the locale registry shared by every store.
//
// One list, three storefronts. App Store Connect, Google Play, and the
// Microsoft Store all spell the same language differently (ASC `zh-Hans`,
// Play `zh-CN`, MS `zh-cn`), and Xcode String Catalogs use a fourth spelling
// for the in-app strings. Keeping the mapping in one table is what stops a
// listing from being pushed to a locale that silently doesn't exist.
//
// `asc` is the canonical key everywhere in Rocket: file names
// (`appstore-metadata.<asc>.md`), CLI flags (`--locale zh-Hans`), and the
// coverage matrix all use it.

// The suite's committed language set. Everything else in LOCALES is supported
// but not swept by `--locale all` / `rocket loc` unless it has a file on disk.
export const BIG8 = ['zh-Hans', 'ja', 'de-DE', 'fr-FR', 'es-ES', 'ko', 'pt-BR', 'it'];

// The source of truth every translation derives from.
export const SOURCE_LOCALE = 'en-US';

// asc → { name, endonym, play, ms, xcode }
//   name    English name, for CLI output
//   endonym native name, used in the translation prompt (models respond better
//           to "translate into 日本語" than "translate into Japanese")
//   play    Google Play listing language code
//   ms      Microsoft Store listing language code
//   xcode   the language code an Xcode String Catalog / .lproj uses
export const LOCALES = {
  'en-US':   { name: 'English (U.S.)',        endonym: 'English',    play: 'en-US', ms: 'en-us', xcode: 'en' },
  'zh-Hans': { name: 'Chinese (Simplified)',  endonym: '简体中文',    play: 'zh-CN', ms: 'zh-cn', xcode: 'zh-Hans' },
  'zh-Hant': { name: 'Chinese (Traditional)', endonym: '繁體中文',    play: 'zh-TW', ms: 'zh-tw', xcode: 'zh-Hant' },
  'ja':      { name: 'Japanese',              endonym: '日本語',      play: 'ja-JP', ms: 'ja',    xcode: 'ja' },
  'ko':      { name: 'Korean',                endonym: '한국어',      play: 'ko-KR', ms: 'ko',    xcode: 'ko' },
  'de-DE':   { name: 'German',                endonym: 'Deutsch',    play: 'de-DE', ms: 'de',    xcode: 'de' },
  'fr-FR':   { name: 'French',                endonym: 'Français',   play: 'fr-FR', ms: 'fr',    xcode: 'fr' },
  'es-ES':   { name: 'Spanish (Spain)',       endonym: 'Español',    play: 'es-ES', ms: 'es',    xcode: 'es' },
  'es-MX':   { name: 'Spanish (Mexico)',      endonym: 'Español (México)', play: 'es-419', ms: 'es-mx', xcode: 'es-MX' },
  'pt-BR':   { name: 'Portuguese (Brazil)',   endonym: 'Português (Brasil)', play: 'pt-BR', ms: 'pt-br', xcode: 'pt-BR' },
  'it':      { name: 'Italian',               endonym: 'Italiano',   play: 'it-IT', ms: 'it',    xcode: 'it' },
  'nl-NL':   { name: 'Dutch',                 endonym: 'Nederlands', play: 'nl-NL', ms: 'nl',    xcode: 'nl' },
  'ru':      { name: 'Russian',               endonym: 'Русский',    play: 'ru-RU', ms: 'ru',    xcode: 'ru' },
  'tr':      { name: 'Turkish',               endonym: 'Türkçe',     play: 'tr-TR', ms: 'tr',    xcode: 'tr' },
  'pl':      { name: 'Polish',                endonym: 'Polski',     play: 'pl-PL', ms: 'pl',    xcode: 'pl' },
  'sv':      { name: 'Swedish',               endonym: 'Svenska',    play: 'sv-SE', ms: 'sv',    xcode: 'sv' },
  'id':      { name: 'Indonesian',            endonym: 'Bahasa Indonesia', play: 'id', ms: 'id', xcode: 'id' },
  'th':      { name: 'Thai',                  endonym: 'ไทย',        play: 'th',    ms: 'th',    xcode: 'th' },
  'vi':      { name: 'Vietnamese',            endonym: 'Tiếng Việt', play: 'vi',    ms: 'vi',    xcode: 'vi' },
  'ar-SA':   { name: 'Arabic',                endonym: 'العربية',    play: 'ar',    ms: 'ar',    xcode: 'ar' },
  'hi':      { name: 'Hindi',                 endonym: 'हिन्दी',      play: 'hi-IN', ms: 'hi',    xcode: 'hi' },
};

export const isKnownLocale = (l) => Object.hasOwn(LOCALES, l);
export const localeName = (l) => LOCALES[l]?.name || l;
export const localeEndonym = (l) => LOCALES[l]?.endonym || l;
export const playCode = (l) => LOCALES[l]?.play || l;
export const msCode = (l) => LOCALES[l]?.ms || l.toLowerCase();
export const xcodeCode = (l) => LOCALES[l]?.xcode || l;

// Languages that run notably longer than English and therefore break layouts
// and blow ASC's tighter caps (subtitle 30, promotional_text 170) first.
// `loc lint` weights its warnings by this.
export const EXPANSION = { 'de-DE': 1.35, 'fr-FR': 1.25, 'es-ES': 1.25, 'es-MX': 1.25, 'pt-BR': 1.25, 'it': 1.2, 'ru': 1.2, 'nl-NL': 1.2 };

// Resolve a `--locale` value: a single locale, a comma list, `big8`, or `all`.
// `all` means "every locale that has a metadata file on disk" — the caller
// passes those in as `present`, because sweeping all 21 known locales would
// create empty listings nobody asked for.
export function resolveLocales(value, { present = [] } = {}) {
  if (!value || value === SOURCE_LOCALE) return [SOURCE_LOCALE];
  if (value === 'big8') return [...BIG8];
  if (value === 'all') return [SOURCE_LOCALE, ...present.filter((l) => l !== SOURCE_LOCALE)];
  const out = value.split(',').map((s) => s.trim()).filter(Boolean);
  const bad = out.filter((l) => !isKnownLocale(l));
  if (bad.length) throw new Error(`unknown locale(s): ${bad.join(', ')} — known: ${Object.keys(LOCALES).join(', ')}`);
  return out;
}
