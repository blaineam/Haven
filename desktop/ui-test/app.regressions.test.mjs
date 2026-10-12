// desktop/ui-test/app.regressions.test.mjs — bugs the DOM harness found in app.js. Each test failed
// against the app.js that shipped in 2.0.x and passes with its fix; the fix commit carries them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { boot, post, NOW, HEX, J, click, tab, lastCall, BO, DM, withDm, BO_POST, menuBtn } from './uiharness.mjs';

test('leaving the Circle tab and coming back restores the composer (an unchanged feed must not skip it)', async () => {
  const { app } = await boot();
  assert.ok(app.q('#composer-slot').children.length > 0);
  await tab(app, 'messages');
  assert.equal(app.q('#composer-slot').children.length, 0, 'the composer belongs to the Circle feed only');
  await tab(app, 'circle');
  assert.ok(app.q('#composer-slot').children.length > 0, 'the composer comes back with the feed');
  await tab(app, 'you');
  await tab(app, 'circle');
  assert.ok(app.q('textarea.composer-field'), 'and still works after a second round trip');
});

test('activity: a group-DM row reads "messaged the group", not "sent you a message" (rows are snake_case)', async () => {
  const group = `dm:${HEX('a')}-${HEX('b')}-${HEX('c')}`;
  const rows = [
    { id: 'g', kind: 'dm', circle_id: group, actor_name: 'Cy', snippet: 'hello team', created_at: NOW - 2000, emoji: null, link: null },
    { id: 'o', kind: 'dm', circle_id: DM, actor_name: 'Bo', snippet: 'psst', created_at: NOW - 3000, emoji: null, link: null },
  ];
  const { app } = await boot({ ...withDm(), be: { activity: { rows, seen_at: 0 } } });
  await click(app, '#bell-btn');
  const names = app.qa('#modal-root .thread-item .name').map((n) => n.textContent);
  assert.ok(names.some((n) => /Cy · messaged the group/i.test(n)), names.join(' | '));
  assert.ok(names.some((n) => /Bo · sent you a message/i.test(n)), names.join(' | '));
});

test('reaching the end of the feed asks the authors for the page before it (lazy history)', async () => {
  const feed = [post({ id: 'n', created_at: NOW - 1_000 }), post({ id: 'm', created_at: NOW - 50_000 }), post({ id: 'o', created_at: NOW - 900_000 })];
  const { app } = await boot({ state: { feeds: { default: feed } } });
  const ask = lastCall(app, 'request_older_history');
  assert.ok(ask, 'the end of the list triggers a history request');
  assert.equal(ask.args.circleId, 'default');
  assert.equal(ask.args.oldestCreatedAt, NOW - 900_000, 'the cursor is the OLDEST post held');
});


test("feed: if the DM can't be opened the user is told instead of the handler crashing", async () => {
  const errors = [];
  const onRej = (e) => errors.push(e);
  process.on('unhandledRejection', onRej);
  const { app } = await boot({ state: { ...withDm().state, feeds: { default: [BO_POST()] } }, be: { message_author: () => null } });
  await click(app, '.card[data-post="bp1"] .kebab');
  await click(app, menuBtn(app, /Message Bo/i));
  await app.settle();
  process.off('unhandledRejection', onRej);
  assert.deepEqual(errors.map(String), [], 'the failure path must not throw');
  assert.match(app.q('#toast').textContent, /open/i, 'a toast explains it');
});


test('deep links: haven://m/<dm> opens the thread, or says it is not on this device', async () => {
  const { app } = await boot(withDm());
  assert.equal(await app.ev(`routeDeepLink("haven://m/${encodeURIComponent(DM)}")`), 'dm');
  await app.settle();
  assert.ok(app.q('.thread-wrap'));
  const errors = []; const on = (e) => errors.push(String(e)); process.on('unhandledRejection', on);
  await app.ev('routeDeepLink("haven://m/dm%3Aunknown")');
  await app.settle(); process.off('unhandledRejection', on);
  assert.deepEqual(errors, [], 'the not-on-this-device path must not throw');
  assert.ok(app.q('#toast').textContent.length > 0);
});


test('story captions: a caption anchored at the left or top edge stays there', async () => {
  const { app } = await boot();
  const d = J(app.ev('StoryCaptions.decode("\\u00010,0,1,0.000,0.000,1.000,1.000,0.0000,0.0000,0.0000\\u0001edge")'));
  assert.equal(d.spec.x, 0, 'x = 0 is a valid position, not "missing"');
  assert.equal(d.spec.y, 0);
});

