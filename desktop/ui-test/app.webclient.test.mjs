// desktop/ui-test/app.webclient.test.mjs — what the page does in a browser, where it matters what
// it asks for and when: low-bandwidth loading, the profile's media, redraws, songs, swipes and the
// media viewer. The same things in real browsers with real bytes: web-client/smoke/media.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { boot, post, NOW, J, tab } from './uiharness.mjs';

const WEB = { web: true, site: 'example.test' };
const story = (id, over = {}) => post({ id, story: true, media: [`img_${id}`], created_at: NOW - 1000, ...over });
const wants = (app) => app.calls.filter((c) => c.cmd === 'media_want').flatMap((c) => J(c.args.references));

/** An IntersectionObserver the test drives: `show(el, visible)` tells every watcher of `el`. */
function observers(app) {
  const all = [];
  app.ctx.IntersectionObserver = class {
    constructor(cb, opts) { this.cb = cb; this.opts = opts; this.seen = new Set(); all.push(this); }
    observe(el) { this.seen.add(el); }
    unobserve(el) { this.seen.delete(el); }
    disconnect() { this.seen.clear(); }
  };
  return (el, visible = true) => {
    for (const o of all) if (o.seen.has(el)) o.cb([{ target: el, isIntersecting: visible }]);
  };
}

/** A browser on the You tab, holding `thumb:` but not the full photo of one post. */
async function lowBandwidth() {
  const { app, s } = await boot({
    host: WEB,
    state: { feeds: { default: [] } },
    be: { media_data_url: ({ reference }) => (reference === 'img_small' ? 'data:image/jpeg;base64,AA' : null) },
  });
  const show = observers(app); // before the first placeholder makes its watcher
  s.feeds.default = [post({ media: ['img_full', 'thumb:img_full:img_small'] })];
  await tab(app, 'you');
  await app.settle();
  return { app, show, box: () => app.q('#view-you .media-evicted') };
}

test('web: the small picture is asked for at once, the full one only after the reader stays on it', async () => {
  const { app, show, box } = await lowBandwidth();
  const tile = box();
  assert.ok(tile, 'a placeholder stands in');
  assert.deepEqual(wants(app), [], 'nothing before it is on screen');
  show(tile);
  await app.settle();
  assert.deepEqual(wants(app), ['img_small'], 'on screen: the small picture only');
  await app.timers.advance(500);
  assert.ok(!wants(app).includes('img_full'), 'half a second is a reader passing by');
  await app.timers.advance(400);
  assert.ok(wants(app).includes('img_full'), 'staying asks for the full photo');
  assert.ok(box().querySelector('img'), 'and the small picture is what shows meanwhile');
});

test('web: scrolling past before the pause never asks for the full photo', async () => {
  const { app, show, box } = await lowBandwidth();
  const tile = box();
  show(tile);
  await app.timers.advance(300);
  show(tile, false);
  await app.timers.advance(5000);
  assert.ok(!wants(app).includes('img_full'), J(wants(app)).join());
});

test('web: a tile still on screen and still missing is asked for again', async () => {
  const { app, show, box } = await lowBandwidth();
  const tile = box();
  tile.getBoundingClientRect = () => ({ top: 10, bottom: 200, left: 10, right: 300, width: 290, height: 190 });
  show(tile);
  await app.timers.advance(1000);
  const before = wants(app).filter((r) => r === 'img_full').length;
  await app.timers.advance(30_000);
  assert.ok(wants(app).filter((r) => r === 'img_full').length > before, 'a kept story gets no other retry');
});

test("the profile asks each post's and story's own circle for its media", async () => {
  const { app } = await boot({
    state: {
      circles: [{ id: 'default', name: 'My Circle', member_count: 1 }, { id: 'fam', name: 'Family', member_count: 2 }],
      feeds: { default: [post({ id: 'a', media: ['img_a'] })], fam: [post({ id: 'b', media: ['img_b'] }), story('c')] },
    },
    be: { media_data_url: 'data:image/jpeg;base64,AA' },
  });
  app.calls.length = 0;
  await tab(app, 'you');
  await app.settle();
  const asked = (ref) => [...new Set(app.calls.filter((c) => c.cmd === 'media_data_url' && c.args.reference === ref).map((c) => c.args.circleId))];
  assert.deepEqual(asked('img_a'), ['default']);
  assert.deepEqual(asked('img_b'), ['fam'], 'the first circle used to claim every tile');
  assert.deepEqual(asked('img_c'), ['fam']);
});

test('the profile is not rebuilt by a sync update that changes nothing, and is by one that does', async () => {
  const { app, s } = await boot({ state: { feeds: { default: [post({ media: ['img_1', 'img_2'] })] } }, be: { media_data_url: 'data:image/jpeg;base64,AA' } });
  await tab(app, 'you');
  await app.settle();
  const card = app.q('#view-you .card[data-post="p1"]');
  await app.ev('renderYou()');
  await app.settle();
  assert.equal(app.q('#view-you .card[data-post="p1"]'), card, 'same node: the carousel keeps its place');
  s.feeds.default = [post({ body: 'edited', media: ['img_1', 'img_2'] })];
  await app.ev('renderYou()');
  await app.settle();
  assert.notEqual(app.q('#view-you .card[data-post="p1"]'), card);
});

test('a carousel has previous and next buttons, hidden at its ends', async () => {
  const { app } = await boot({ state: { feeds: { default: [post({ media: ['img_1', 'img_2'] })] } } });
  const media = app.q('.card[data-post="p1"] .post-media.carousel');
  assert.equal(media.querySelector('.carousel-arrow.prev').style.display, 'none');
  assert.notEqual(media.querySelector('.carousel-arrow.next').style.display, 'none');
});

async function gridPost() {
  const refs = Array.from({ length: 12 }, (_, i) => `img_${i}`);
  const { app } = await boot({ state: { feeds: { default: [post({ media: refs })] } }, be: { media_data_url: 'data:image/jpeg;base64,AA' } });
  const tile = app.qa('.card[data-post="p1"] .post-media.masonry img')[4];
  return { app, tile };
}

test('clicking a grid tile opens the viewer on that photo', async () => {
  const { app, tile } = await gridPost();
  tile.click();
  await app.timers.advance(400);
  assert.ok(app.q('#modal-root .media-viewer'), 'the viewer is open');
  assert.equal(app.q('.viewer-count').textContent, '5 / 12');
  const filled = app.qa('.viewer-slide').filter((sl) => sl.children.length).length;
  assert.equal(filled, 3, 'only the photo and its neighbors are loaded');
});

test('a double click is still the heart, not the viewer', async () => {
  const { app, tile } = await gridPost();
  tile.click();
  tile.dispatchEvent(new app.ctx.Event('dblclick', { bubbles: true }));
  await app.timers.advance(400);
  assert.equal(app.q('#modal-root .media-viewer'), null);
});

test("with one person's stories on show, a sideways swipe moves one story", async () => {
  const { app } = await boot();
  const list = ['s1', 's2', 's3'].map((id) => story(id));
  app.ev(`viewStories(${JSON.stringify(list)}, 0)`);
  await app.settle();
  const on = () => app.qa('.story-progress .seg.on').length;
  const stage = app.q('.story-stage');
  const swipe = async (deltaX) => {
    stage.dispatchEvent(Object.assign(new app.ctx.Event('wheel', { bubbles: true, cancelable: true }), { deltaX, deltaY: 0 }));
    await app.settle();
  };
  assert.equal(on(), 1);
  await swipe(200);
  assert.equal(on(), 2, 'it used to skip the whole person, which closed the viewer');
  await swipe(200);
  assert.equal(on(), 2, "the same gesture's momentum does nothing");
  await app.timers.advance(300);
  await swipe(-200);
  assert.equal(on(), 1);
});

test('web: a song waits for the sound switch; the desktop app plays it either way', async () => {
  const web = await boot({ host: WEB });
  const desktop = await boot();
  assert.equal(web.app.ev('deviceLikelySilent()'), true);
  assert.equal(desktop.app.ev('deviceLikelySilent()'), false);
});

test('both places the web policy is written allow blob: and Apple preview audio, and no data: media', () => {
  const read = (p) => readFileSync(new URL(`../../${p}`, import.meta.url), 'utf8');
  const media = (text) => /media-src ([^;"]+);/.exec(text)[1].trim();
  const relay = media(read('core/haven-net/src/webbundle.rs'));
  assert.equal(media(read('web-client/build.sh')), relay, 'a relay and a web site serve the same policy');
  assert.deepEqual(relay.split(' '), ["'self'", 'blob:', 'https://*.itunes.apple.com', 'https://*.mzstatic.com']);
});
