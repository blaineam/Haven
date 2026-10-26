// desktop/ui-test/app.palette.test.mjs — palettes (docs/PALETTES.md) and the multi-circle post picker,
// against the REAL app.js + styles.css + strings.js.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { boot, post, click, tab, lastCall, DM, withDm } from './uiharness.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const ui = (f) => readFileSync(join(root, 'desktop/ui', f), 'utf8');
const css = ui('styles.css');
const spec = readFileSync(join(root, 'docs/PALETTES.md'), 'utf8');
const IDS = ['sunset', 'ocean', 'forest', 'rose', 'ember', 'sky', 'grape', 'neutral'];

// ── the pure palette functions, lifted from the shipped app.js ──────────────────────────────────
const appSrc = ui('app.js');
const pal = (() => {
  const a = appSrc.indexOf('const PALETTE_KEY');
  const b = appSrc.indexOf('function currentPalette');
  assert.ok(a > 0 && b > a, 'palette block moved in app.js');
  const ctx = vm.createContext({});
  vm.runInContext(appSrc.slice(a, b) + '\nglobalThis.o = { PALETTES, DEFAULT_PALETTE, paletteVars, normalizePaletteId, contrastRatio, inkFor };', ctx);
  return ctx.o;
})();

test('palettes: the table in docs/PALETTES.md and PALETTES in app.js are identical', () => {
  const rows = [...spec.matchAll(/^\| `(\w+)` \| [^|]+ \| (#[0-9A-Fa-f]{6}) \| (#[0-9A-Fa-f]{6}) \| (#[0-9A-Fa-f]{6}) \|$/gm)];
  assert.deepEqual(rows.map((r) => r[1]), IDS);
  for (const [, id, a, b, c] of rows) assert.equal(pal.PALETTES[id].join(',').toLowerCase(), [a, b, c].join(',').toLowerCase(), id);
});

test('palettes: unknown / missing / hostile ids fall back to sunset', () => {
  for (const bad of [undefined, null, '', 'nope', 42, '__proto__', 'constructor', 'toString']) assert.equal(pal.normalizePaletteId(bad), 'sunset', String(bad));
  for (const id of IDS) assert.equal(pal.normalizePaletteId(id), id);
});

test('palettes: text ink clears WCAG AA (4.5:1) in light and dark for every palette', () => {
  for (const id of IDS) {
    const v = pal.paletteVars(id);
    assert.ok(pal.contrastRatio(v['--p2-ink-dark'], '#1c1828') >= 4.5, `${id} dark`);
    assert.ok(pal.contrastRatio(v['--p2-ink-light'], '#f6f4fb') >= 4.5, `${id} light`);
  }
});

test('palettes: sunset equals the CSS defaults (first paint is right before any script runs)', () => {
  const v = pal.paletteVars('sunset');
  const def = (name) => css.match(new RegExp(`--${name}:\\s*([^;]+);`))[1].trim();
  assert.equal(def('p1').toLowerCase(), v['--p1'].toLowerCase());
  assert.equal(def('p2').toLowerCase(), v['--p2'].toLowerCase());
  assert.equal(def('p3').toLowerCase(), v['--p3'].toLowerCase());
  assert.equal(def('p2-ink-dark'), v['--p2-ink-dark']);
  assert.equal(def('p2-ink-light'), v['--p2-ink-light']);
  assert.match(css, /--p2-rgb: 236, 72, 153/);
});

test('palettes: no hard-coded violet/pink/amber colour left in the stylesheet or app.js', () => {
  assert.doesNotMatch(css, /var\(--(violet|pink|amber)\)/);
  const body = css.replace(/^:root \{[\s\S]*?\n\}/m, '');   // the :root defaults legitimately hold sunset
  assert.doesNotMatch(body.replace(/--p[123]-rgb:[^;]+;/g, ''), /236,\s*72,\s*153|124,\s*58,\s*237|#(ec4899|7c3aed)\b/i);
  assert.doesNotMatch(appSrc, /236,\s*72,\s*153|var\(--pink\)/);
});

test('palettes: every palette has a runtime icon PNG and a translated name in all six languages', () => {
  for (const id of IDS) assert.ok(existsSync(join(root, 'desktop/ui/palette-icons', id + '.png')), id);
  const strings = ui('strings.js');
  for (const k of ['palette_title', 'palette_foot', 'post_to_n_circles', 'post_to_circles_title', 'multipost_hint', 'multipost_media_note', ...IDS.map((i) => 'palette_' + i)]) {
    assert.equal(strings.split(`"${k}":`).length - 1, 7, `${k} present in en + 6 languages`);
  }
});

test('palettes: packaged icons are untouched by the runtime icon (MSIX/Flatpak/tauri.conf keep the fixed icon)', () => {
  const conf = JSON.parse(readFileSync(join(root, 'desktop/src-tauri/tauri.conf.json'), 'utf8'));
  assert.ok(conf.bundle.icon.every((p) => p.startsWith('icons/')), 'bundle icons stay the fixed set');
  assert.match(readFileSync(join(root, 'desktop/src-tauri/capabilities/default.json'), 'utf8'), /core:window:allow-set-icon/);
});

// ── DOM: applying, persisting, falling back ─────────────────────────────────────────────────────
const rootStyle = (app) => app.document.documentElement.style;

test('boot applies the default palette to <html>', async () => {
  const { app } = await boot();
  assert.equal(rootStyle(app)['--p2'], '#EC4899');
  assert.equal(app.document.documentElement.dataset.palette, 'sunset');
});

test('boot applies a saved palette, and a corrupt saved value falls back to sunset', async () => {
  const { app } = await boot({ local: { 'haven-palette': 'ocean' } });
  assert.equal(rootStyle(app)['--p2'], '#06B6D4');
  assert.equal(rootStyle(app)['--p2-rgb'], '6, 182, 212');
  const bad = await boot({ local: { 'haven-palette': 'chartreuse' } });
  assert.equal(rootStyle(bad.app)['--p2'], '#EC4899');
});

test('Settings has a swatch per palette; picking one re-themes live, persists, and retints the window icon', async () => {
  const { app } = await boot();
  const icons = [];
  app.ctx.__TAURI__.window = { getCurrentWindow: () => ({ setIcon: async (b) => { icons.push(b.length); } }) };
  app.ctx.fetch = async (url) => ({ ok: true, url, arrayBuffer: async () => new ArrayBuffer(8) });
  await tab(app, 'you');
  await click(app, '#tb-right button.icon-btn');
  const swatches = app.qa('#modal-root .swatch');
  assert.deepEqual(swatches.map((s) => s.getAttribute('data-palette')), IDS);
  assert.equal(app.q('#modal-root .swatch.on').getAttribute('data-palette'), 'sunset');
  await click(app, swatches.find((s) => s.getAttribute('data-palette') === 'forest'));
  assert.equal(app.localStorage.getItem('haven-palette'), 'forest');
  assert.equal(rootStyle(app)['--p2'], '#10B981');
  assert.equal(app.q('#modal-root .swatch.on').getAttribute('data-palette'), 'forest');
  assert.equal(app.q('#modal-root .swatch.on').getAttribute('aria-checked'), 'true');
  assert.deepEqual(icons, [8], 'setIcon was handed the palette PNG');
  assert.match(app.q('#modal-root').textContent, /installed app icon/);
});

test('neutral strips colour: every stop is a grey', async () => {
  const v = pal.paletteVars('neutral');
  for (const k of ['--p1', '--p2', '--p3']) {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(v[k].slice(i, i + 2), 16));
    assert.ok(Math.abs(r - g) < 20 && Math.abs(g - b) < 24, `${k} ${v[k]} is grey`);
  }
});

// ── DOM: multi-circle post ──────────────────────────────────────────────────────────────────────
const circles = [{ id: 'default', name: 'My Circle', member_count: 1 }, { id: 'fam', name: 'Family', member_count: 4 }, { id: DM, name: 'Bo', member_count: 2 }];
const twoCircles = (extra = {}) => ({ ...withDm(), state: { ...withDm().state, circles, feeds: { default: [post()], fam: [] } }, ...extra });
const type = (app, v) => { const f = app.q('textarea.composer-field'); f.value = v; f.dispatchEvent(new app.ctx.Event('input', { bubbles: true })); };
const rightClickPost = async (app) => { app.q('.composer-send').dispatchEvent(new app.ctx.Event('contextmenu', { bubbles: true, cancelable: true })); await app.settle(); };

test('plain click on Post is unchanged: this circle only, no picker, no confirm', async () => {
  const { app } = await boot(twoCircles());
  type(app, 'solo');
  await click(app, '.composer-send');
  const posts = app.calls.filter((c) => c.cmd === 'post');
  assert.equal(posts.length, 1);
  assert.equal(posts[0].args.circleId, 'default');
  assert.equal(app.qa('#menu-root .circle-pick').length, 0);
  assert.deepEqual(app.dialogs, []);
});

test('right-click on Post lists the circles (current pre-checked, DMs excluded) and posts once per ticked circle', async () => {
  const { app } = await boot(twoCircles());
  type(app, 'to both');
  await rightClickPost(app);
  const boxes = app.qa('#menu-root .circle-pick input[type="checkbox"]');
  assert.deepEqual(boxes.map((b) => b.getAttribute('data-circle')), ['default', 'fam'], 'DM excluded, current first');
  assert.deepEqual(boxes.map((b) => b.checked), [true, false]);
  assert.equal(app.q('#menu-root .circle-pick .btn').textContent, 'Post', 'one circle ticked = plain Post');
  boxes[1].checked = true; boxes[1].dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  assert.equal(app.q('#menu-root .circle-pick .btn').textContent, 'Post to 2 circles');
  await click(app, '#menu-root .circle-pick .btn');
  const posts = app.calls.filter((c) => c.cmd === 'post');
  assert.deepEqual(posts.map((c) => c.args.circleId), ['default', 'fam']);
  assert.ok(posts.every((c) => c.args.body === 'to both'));
  assert.equal(app.qa('#menu-root .circle-pick').length, 0, 'popover closes');
  assert.equal(app.q('textarea.composer-field').value, '', 'composer cleared once');
});

test('unticking the current circle posts only to the other one', async () => {
  const { app } = await boot(twoCircles());
  type(app, 'only family');
  await rightClickPost(app);
  const [cur, fam] = app.qa('#menu-root .circle-pick input[type="checkbox"]');
  cur.checked = false; cur.dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  fam.checked = true; fam.dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  await click(app, '#menu-root .circle-pick .btn');
  assert.deepEqual(app.calls.filter((c) => c.cmd === 'post').map((c) => c.args.circleId), ['fam']);
});

test('with a single circle the gesture does nothing (no picker to show)', async () => {
  const { app } = await boot();
  type(app, 'hi');
  await rightClickPost(app);
  assert.equal(app.qa('#menu-root .circle-pick').length, 0);
  assert.equal(app.calls.filter((c) => c.cmd === 'post').length, 0, 'right-click never posts by itself');
});

test('long-press on Post opens the picker and the trailing click does not also post', async () => {
  const { app } = await boot(twoCircles());
  type(app, 'held');
  const btn = app.q('.composer-send');
  btn.dispatchEvent(new app.ctx.Event('pointerdown', { bubbles: true }));
  await app.timers.advance(600);
  await app.settle();
  assert.equal(app.qa('#menu-root .circle-pick').length, 1);
  btn.click(); await app.settle();
  assert.equal(app.calls.filter((c) => c.cmd === 'post').length, 0);
});

test('the one-time multi-circle hint shows only for 2+ circles, only once', async () => {
  const one = await boot();
  for (let i = 0; i < 4; i++) { type(one.app, 'p' + i); await click(one.app, '.composer-send'); }
  assert.notEqual(one.app.localStorage.getItem('haven-multipost-hint'), 'done', 'single circle: never shown');
  const two = await boot(twoCircles());
  const seen = [];
  for (let i = 0; i < 5; i++) { type(two.app, 'p' + i); await click(two.app, '.composer-send'); if (/right-click/.test(two.app.q('#toast').textContent)) seen.push(i); two.app.q('#toast').textContent = ''; }
  assert.equal(two.app.localStorage.getItem('haven-multipost-hint'), 'done');
  assert.equal(seen.length, 1, 'shown exactly once');
});

test('with an attachment only the current circle is selectable; without one every circle is', async () => {
  const { app } = await boot(twoCircles());
  type(app, 'with photo');
  app.ev('state.attachments.push({ ref: "r1", url: null, isVideo: false })');
  await rightClickPost(app);
  const [cur, fam] = app.qa('#menu-root .circle-pick input[type="checkbox"]');
  assert.equal(cur.disabled, false);
  assert.equal(fam.disabled, true, 'other circles are disabled while media is attached');
  assert.equal(fam.checked, false);
  assert.match(app.q('#menu-root .circle-pick').textContent, /current circle for now/);
  await click(app, '#menu-root .circle-pick .btn');
  assert.deepEqual(app.calls.filter((c) => c.cmd === 'post').map((c) => c.args.circleId), ['default']);
  const free = await boot(twoCircles());
  type(free.app, 'text only');
  await rightClickPost(free.app);
  assert.ok(free.app.qa('#menu-root .circle-pick input[type="checkbox"]').every((b) => !b.disabled));
  assert.equal(free.app.qa('#menu-root .cp-note').length, 0);
});
