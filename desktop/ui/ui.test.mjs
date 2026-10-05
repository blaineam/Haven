// desktop/ui/ui.test.mjs — tests for the desktop web UI's pure logic, run with `node --test`.
//
// app.js and strings.js are plain browser scripts (no modules, no build step), so this file loads
// the REAL source text and evaluates it in a node:vm sandbox with the few browser globals they
// touch stubbed. Individual pure functions are lifted out of app.js by name (brace-matched), so the
// code under test is byte-for-byte what ships — nothing is re-implemented here.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const appSrc = readFileSync(join(here, 'app.js'), 'utf8');
const stringsSrc = readFileSync(join(here, 'strings.js'), 'utf8');
const indexHtml = readFileSync(join(here, 'index.html'), 'utf8');

// ── strings.js ───────────────────────────────────────────────────────────────────────────────────

/** Evaluate strings.js as the given browser language; returns its window globals (+ T, test-only). */
function loadStrings(lang = 'en-US') {
  const win = {};
  const ctx = vm.createContext({
    window: win,
    navigator: { language: lang },
    document: { readyState: 'complete', querySelectorAll: () => [] },
  });
  // Expose the per-language tables to the test (the shipped file only exports EN).
  const src = stringsSrc.replace('window.HAVEN_STRINGS_EN = EN;', 'window.HAVEN_STRINGS_EN = EN; window.__T = T;');
  assert.notEqual(src, stringsSrc, 'strings.js export line moved — update this test');
  vm.runInContext(src, ctx);
  return win;
}

const LANGS = { ja: 'ja-JP', de: 'de-DE', es: 'es-ES', ko: 'ko-KR', 'pt-BR': 'pt-BR', it: 'it-IT' };
const placeholders = (s) => [...String(s).matchAll(/\{(\d+)\}/g)].map((m) => m[1]).sort().join(',');

test('strings: exactly the six export-compliant languages ship (never fr / zh)', () => {
  const T = loadStrings().__T;
  assert.deepEqual(Object.keys(T).sort(), Object.keys(LANGS).sort());
  for (const [code, nav] of [['fr', 'fr-FR'], ['zh', 'zh-CN'], ['pt', 'pt-PT']]) {
    assert.equal(loadStrings(nav).HAVEN_LANG, 'en', `${code} must fall back to English`);
  }
  for (const [code, nav] of Object.entries(LANGS)) assert.equal(loadStrings(nav).HAVEN_LANG, code);
});

test('strings: t() substitutes positional args and falls back EN → key', () => {
  const w = loadStrings('en-US');
  assert.equal(w.t('post_to_everyone_in', 'Family'), 'Post to everyone in Family');
  assert.equal(w.t('definitely_not_a_key_xyz'), 'definitely_not_a_key_xyz');
  assert.equal(w.t('post_to_everyone_in'), 'Post to everyone in {0}', 'missing args leave the slot visible, not "undefined"');
  const ja = loadStrings('ja-JP');
  assert.notEqual(ja.t('cancel'), 'Cancel', 'Japanese table is active');
  assert.equal(ja.tEn('cancel'), 'Cancel', 'tEn is always English (wire values)');
});

test('strings: every translation keeps exactly the placeholders of its English source', () => {
  const w = loadStrings();
  const EN = w.HAVEN_STRINGS_EN;
  const bad = [];
  for (const [lang, table] of Object.entries(w.__T)) {
    for (const [k, v] of Object.entries(table)) {
      if (!(k in EN)) continue;   // orphans are reported by the next test
      if (placeholders(v) !== placeholders(EN[k])) bad.push(`${lang}:${k} has {${placeholders(v)}} vs en {${placeholders(EN[k])}}`);
    }
  }
  assert.deepEqual(bad, [], 'a dropped {0} silently loses a name/count in that language');
});

test('strings: translation tables carry no keys the English source lacks', () => {
  const w = loadStrings();
  const EN = w.HAVEN_STRINGS_EN;
  const orphans = [];
  for (const [lang, table] of Object.entries(w.__T)) {
    for (const k of Object.keys(table)) if (!(k in EN)) orphans.push(`${lang}:${k}`);
  }
  assert.deepEqual(orphans, []);
});

// Keys app.js uses that the string tables do not define (a real bug each — see the todo test below).
// `friend`: the story viewer's reply placeholder for an author with no display name
// (`t("friend")` in viewStories) renders the raw key and is never translated.
const KNOWN_MISSING_KEYS = ['friend'];

function usedKeys() {
  const used = new Set();
  for (const m of appSrc.matchAll(/\bt(?:En)?\(\s*"([a-z0-9_]+)"/g)) used.add(m[1]);
  for (const m of indexHtml.matchAll(/data-i18n(?:-title|-aria|-placeholder)?="([a-z0-9_]+)"/g)) used.add(m[1]);
  return used;
}

test('strings: every literal t("key") in app.js and data-i18n key in index.html exists in English', () => {
  const EN = loadStrings().HAVEN_STRINGS_EN;
  const used = usedKeys();
  assert.ok(used.size > 100, `expected to find many keys, found ${used.size}`);
  const missing = [...used].filter((k) => !(k in EN) && !KNOWN_MISSING_KEYS.includes(k)).sort();
  assert.deepEqual(missing, [], 'a missing key renders as its raw identifier in the UI');
});

test('strings: known-missing keys are defined (KNOWN BUG — expected to fail until strings.js gains them)',
  { todo: 'add "friend" to strings.js EN + the six translations (Levi), then delete KNOWN_MISSING_KEYS' }, () => {
    const EN = loadStrings().HAVEN_STRINGS_EN;
    assert.deepEqual(KNOWN_MISSING_KEYS.filter((k) => usedKeys().has(k) && !(k in EN)), []);
  });

// ── app.js pure helpers ─────────────────────────────────────────────────────────────────────────

/** Source text of a top-level `function name(...) { ... }` in app.js (brace-matched). */
function fnSource(name) {
  const start = appSrc.search(new RegExp(`^function ${name}\\(`, 'm'));
  assert.ok(start >= 0, `function ${name} not found in app.js`);
  let depth = 0;
  for (let i = appSrc.indexOf('{', start); i < appSrc.length; i++) {
    const c = appSrc[i];
    if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return appSrc.slice(start, i + 1);
  }
  throw new Error(`unbalanced braces in ${name}`);
}

/** Source text of a top-level `const name = ...;` one-liner in app.js. */
function constSource(name) {
  const m = appSrc.match(new RegExp(`^const ${name} = .*;$`, 'm'));
  assert.ok(m, `const ${name} not found in app.js`);
  return m[0];
}

function lift(names, consts = [], extra = {}) {
  const ctx = vm.createContext({ t: (k) => (k === 'just_now' ? 'just now' : k), ...extra });
  vm.runInContext([...consts.map(constSource), ...names.map(fnSource)].join('\n') +
    `\n;({ ${[...names, ...consts].join(', ')} })`, ctx);
  return vm.runInContext(`({ ${[...names, ...consts].join(', ')} })`, ctx);
}

test('app: esc() neutralises HTML in user-controlled text', () => {
  const { esc } = lift([], ['esc']);
  assert.equal(esc('<img src=x onerror="alert(1)">&'), '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;&amp;');
  assert.equal(esc(null), '');
});

test('app: secret-message marker is STX, wire-compatible with iOS/Android', () => {
  const ctx = vm.createContext({});
  const marker = appSrc.match(/^const SECRET_MARKER = (.*);$/m);
  assert.ok(marker, 'SECRET_MARKER not found');
  vm.runInContext(`const SECRET_MARKER = ${marker[1]};\n${constSource('isSecret')}\n${constSource('secretText')}\n` +
    'globalThis.r = { SECRET_MARKER, isSecret, secretText };', ctx);
  const { SECRET_MARKER, isSecret, secretText } = ctx.r;
  assert.equal(SECRET_MARKER, '\u0002');
  assert.ok(isSecret('\u0002psst'));
  assert.equal(secretText('\u0002psst'), 'psst');
  assert.equal(secretText('plain'), 'plain');
  assert.ok(!isSecret(undefined));
});

test('app: parseGeo reads location refs and rejects junk', () => {
  const { parseGeo } = lift(['parseGeo']);
  assert.deepEqual({ ...parseGeo('geo:37.5,-122.25,Golden Gate, SF') }, { lat: 37.5, lon: -122.25, label: 'Golden Gate, SF' });
  assert.deepEqual({ ...parseGeo('geo:1,2') }, { lat: 1, lon: 2, label: '' });
  for (const bad of ['geo:', 'geo:abc,def', 'geo:12', 'img_123', null, 42]) assert.equal(parseGeo(bad), null, String(bad));
});

test('app: cappedReactions keeps the top N but never hides my own reaction', () => {
  const { cappedReactions } = lift(['cappedReactions']);
  const rs = [
    { emoji: 'a', count: 5 }, { emoji: 'b', count: 4 }, { emoji: 'c', count: 3 }, { emoji: 'mine', count: 1, mine: true },
  ];
  const emojis = (xs) => JSON.parse(JSON.stringify(xs.map((r) => r.emoji)));   // vm arrays are cross-realm
  assert.deepEqual(emojis(cappedReactions(rs, 3)), ['a', 'b', 'mine']);
  assert.deepEqual(emojis(cappedReactions(rs, 10)), ['a', 'b', 'c', 'mine']);
  assert.equal(cappedReactions(undefined, 3).length, 0);
});

test('app: hostLooksPrivate classifies turn:/stun: hosts for the Haven-first ICE policy', () => {
  const { hostLooksPrivate } = lift(['hostLooksPrivate']);
  for (const u of ['turn:10.0.0.1:3478', 'turn:192.168.1.5:3478?transport=udp', 'stun:127.0.0.1:3478',
                   'turn:169.254.1.1', 'turn:172.16.0.1:3478', 'turn:172.31.9.9']) {
    assert.ok(hostLooksPrivate(u), u);
  }
  for (const u of ['turn:turn.example.com:3478', 'stun:1.1.1.1:3478', 'turn:172.32.0.1:3478', 'turn:172.15.0.1']) {
    assert.ok(!hostLooksPrivate(u), u);
  }
});

test('app: fmtBytes / base64ByteLength', () => {
  const { fmtBytes, base64ByteLength } = lift(['fmtBytes', 'base64ByteLength']);
  assert.equal(fmtBytes(0), '0 B');
  assert.equal(fmtBytes(512), '512 B');
  assert.equal(fmtBytes(1536), '1.5 KB');
  assert.equal(fmtBytes(20 * 1024 * 1024), '20 MB');
  assert.equal(fmtBytes(3 * 1024 ** 4), '3.0 TB');
  for (const s of ['', 'a', 'ab', 'abc', 'abcd', 'hello world!!']) {
    assert.equal(base64ByteLength(Buffer.from(s).toString('base64')), Buffer.byteLength(s), s);
  }
  assert.equal(base64ByteLength(null), 0);
});

test('app: relTime buckets and initials', () => {
  const { relTime, initials } = lift(['relTime', 'initials']);
  const now = Date.now();
  assert.equal(relTime(0), '');
  assert.equal(relTime(now - 5_000), 'just now');
  assert.equal(relTime(now - 5 * 60_000), '5m');
  assert.equal(relTime(now - 3 * 3_600_000), '3h');
  assert.equal(relTime(now - 2 * 86_400_000), '2d');
  assert.equal(relTime(now - 14 * 86_400_000), '2w');
  assert.equal(relTime(now - 60 * 86_400_000), '2mo');
  assert.equal(relTime(now - 800 * 86_400_000), '2y');
  assert.equal(initials('ada lovelace'), 'AL');
  assert.equal(initials('  cher '), 'C');
  assert.equal(initials(''), '·');
});

test('app: carouselAspect is uniform only once every item reported, else clamped', () => {
  const limits = appSrc.match(/^const PAGE_ASPECT_MIN = .*, PAGE_ASPECT_MAX = .*;$/m);
  assert.ok(limits, 'PAGE_ASPECT_MIN/MAX not found');
  const ctx = vm.createContext({});
  vm.runInContext(`${limits[0]}\n${fnSource('carouselAspect')}\nglobalThis.r = { carouselAspect, PAGE_ASPECT_MIN, PAGE_ASPECT_MAX };`, ctx);
  const { carouselAspect, PAGE_ASPECT_MIN, PAGE_ASPECT_MAX } = ctx.r;
  assert.equal(carouselAspect([]), 4 / 3);
  assert.equal(carouselAspect([0, 0]), 4 / 3);
  // All square: uniform → exactly 1 even if outside the clamp.
  assert.equal(carouselAspect([1, 1, 1]), 1);
  // Mixed: tallest (smallest w/h), clamped into the page range.
  const mixed = carouselAspect([1.5, 0.2]);
  assert.equal(mixed, Math.min(PAGE_ASPECT_MAX, Math.max(PAGE_ASPECT_MIN, 0.2)));
  // One still decoding (0): not yet known to be uniform → clamped path.
  assert.equal(carouselAspect([3, 0]), Math.min(PAGE_ASPECT_MAX, Math.max(PAGE_ASPECT_MIN, 3)));
});

test('app: stories older than 24h are past their window', () => {
  const ctx = vm.createContext({});
  vm.runInContext(`${constSource('STORY_LIFETIME_MS')}\n${fnSource('isPastStoryWindow')}\nglobalThis.r = isPastStoryWindow;`, ctx);
  const past = ctx.r;
  const now = Date.now();
  assert.equal(past(now - 23 * 3_600_000), false);
  assert.equal(past(now - 25 * 3_600_000), true);
  assert.equal(past(String(now - 1000)), false, 'engine timestamps arrive as strings/u64');
});

test('app: story tray groups by author, oldest-first within, most recent author first', () => {
  const { groupStoriesFlat } = lift(['groupStoriesFlat']);
  const s = (author_name, created_at) => ({ author_name, created_at, id: `${author_name}${created_at}` });
  const { flat, starts } = groupStoriesFlat([s('ann', 5), s('bob', 9), s('ann', 1), s('bob', 3), s('cy', 7)]);
  assert.deepEqual(JSON.parse(JSON.stringify(flat.map((x) => x.id))), ['bob3', 'bob9', 'cy7', 'ann1', 'ann5']);
  assert.equal(starts.get('bob'), 0);
  assert.equal(starts.get('cy'), 2);
  assert.equal(starts.get('ann'), 3);
});

test('app: composer audience names the circle only when it fits (Apple ComposerAudience parity)', () => {
  const start = appSrc.indexOf('const Audience = {');
  assert.ok(start >= 0, 'Audience not found');
  let depth = 0, end = -1;
  for (let i = appSrc.indexOf('{', start); i < appSrc.length; i++) {
    if (appSrc[i] === '{') depth++;
    else if (appSrc[i] === '}' && --depth === 0) { end = i + 1; break; }
  }
  const w = loadStrings('en-US');
  const ctx = vm.createContext({ t: w.t });
  vm.runInContext(`${appSrc.slice(start, end)};\nglobalThis.r = Audience;`, ctx);
  const A = ctx.r;
  assert.equal(A.placeholder('Family'), 'Post to everyone in Family');
  assert.equal(A.placeholder('a'.repeat(14)), `Post to everyone in ${'a'.repeat(14)}`);
  assert.equal(A.placeholder('a'.repeat(15)), 'Post to everyone…');
  assert.equal(A.placeholder(''), 'Post to everyone…');
  assert.equal(A.placeholder(undefined), 'Post to everyone…');
});
