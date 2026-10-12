// desktop/ui-test/app.dom.test.mjs — runs the WHOLE app.js against a stub DOM and a fake Tauri backend
// (see domstub.mjs / uiharness.mjs) and asserts on what actually renders: boot paths, the three
// tabs, the feed, DMs, settings, onboarding and the terms gate. app.js is evaluated under its real
// file URL, so `node --test --experimental-test-coverage` attributes executed lines to it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { boot, post, fakeBackend, ME, HEX, NOW, J, click, tab, lastCall, BO, DM, withDm, BO_POST, menuBtn } from './uiharness.mjs';
import { loadApp, Element as StubElement } from './domstub.mjs';

test('boot renders the circle feed from the backend', async () => {
  const { app } = await boot();
  const cmds = app.commands();
  for (const c of ['needs_onboarding', 'seedless_status', 'bootstrap', 'circles', 'feed']) assert.ok(cmds.includes(c), `${c} was invoked`);
  assert.match(app.q('#view-circle').textContent, /hello world/);
});

const typeInto = (app, sel, v) => { const n = app.q(sel); n.value = v; n.dispatchEvent(new (app.ctx.Event)('input', { bubbles: true })); return n; };

test('the tab bar switches views and the active class follows', async () => {
  const { app } = await boot();
  assert.ok(app.q('.tab[data-view="circle"]').classList.contains('active'));
  await tab(app, 'messages');
  assert.ok(app.q('#view-messages').classList.contains('active'));
  assert.ok(!app.q('#view-circle').classList.contains('active'));
  assert.equal(app.q('#composer-slot').children.length, 0, 'the composer belongs to the Circle feed only');
  await tab(app, 'you');
  assert.match(app.q('#view-you').textContent, /Ada/);
});

test('posting from the composer calls the backend with the body and clears the field', async () => {
  const { app, s } = await boot();
  const field = app.q('textarea.composer-field');
  field.value = 'a brand new post';
  field.dispatchEvent(new (app.ctx.Event)('input', { bubbles: true }));
  s.feeds.default = [post({ id: 'p2', body: 'a brand new post' }), ...s.feeds.default];
  await click(app, '.composer-send');
  const c = lastCall(app, 'post');
  assert.ok(c, 'post was invoked');
  assert.equal(c.args.body, 'a brand new post');
  assert.equal(c.args.circleId, 'default');
  assert.equal(app.q('textarea.composer-field')?.value ?? '', '', 'the field is cleared once sent');
  // The engine announces the change; the debounced listener re-reads the feed.
  await app.emit('haven:changed');
  await app.timers.advance(500);
  await app.settle();
  assert.match(app.q('#view-circle').textContent, /a brand new post/);
});

test('an empty composer does not post', async () => {
  const { app } = await boot();
  await click(app, '.composer-send');
  assert.equal(lastCall(app, 'post'), undefined);
});

test('the activity bell opens a panel and marks it seen', async () => {
  const { app } = await boot({ be: { activity: { rows: [{ id: 'a1', kind: 'comment', circle_id: 'default', actor_name: 'Bo', snippet: 'nice one', created_at: NOW - 1000, emoji: null, link: 'haven://x' }], seen_at: 0 } } });
  await click(app, '#bell-btn');
  assert.match(app.q('#modal-root').textContent + app.q('#menu-root').textContent + app.q('body').textContent, /nice one/);
  assert.ok(app.commands().includes('activity'));
});

test('settings sheet lists every area and each row opens its own sheet', async () => {
  const { app } = await boot();
  await tab(app, 'you');
  await click(app, '#tb-right button.icon-btn');
  const rows = () => app.qa('#modal-root .set-row').filter((r) => r.tagName === 'BUTTON');
  const expected = { 0: /Relays/, 1: /Blocked/, 2: /Identities/, 3: /Devices/, 4: /Scheduled/, 5: /Privacy/, 11: /Instagram/, 12: /Advanced/ };
  for (const [i, re] of Object.entries(expected)) {
    await click(app, '#tb-right button.icon-btn');
    await click(app, rows()[Number(i)]);
    assert.match(app.q('#modal-root .modal-head h2').textContent, re, `row ${i}`);
  }
});

test('the appearance row flips the theme and remembers it', async () => {
  const { app } = await boot();
  await tab(app, 'you');
  await click(app, '#tb-right button.icon-btn');
  const row = app.qa('#modal-root .set-row').find((r) => /Appearance/.test(r.textContent));
  await click(app, row);
  assert.equal(app.localStorage.getItem('haven-theme'), 'light');
  assert.equal(app.document.documentElement.dataset.theme, 'light');
});

test('messages: the thread list shows name, preview, relative time and the unread badge', async () => {
  const { app } = await boot(withDm());
  await tab(app, 'messages');
  const row = app.q('.thread-item');
  assert.equal(row.querySelector('.name').textContent, 'Bo');
  assert.ok(row.querySelector('.name').classList.contains('unread'), 'unread threads are bold');
  assert.equal(row.querySelector('.preview').textContent, 'hey there');
  assert.equal(row.querySelector('.unread-pill').textContent, '2');
  assert.equal(app.text('#badge-messages'), '1', 'the tab badge counts unread threads');
});

test('messages: an empty inbox says so', async () => {
  const { app } = await boot();
  await tab(app, 'messages');
  assert.match(app.q('#view-messages').textContent, /No messages yet/);
});

test('messages: opening a thread renders both sides and marks it read', async () => {
  const { app } = await boot(withDm());
  await tab(app, 'messages');
  await click(app, '.thread-item');
  const rows = app.qa('.bubble-row');
  assert.equal(rows.length, 2);
  assert.ok(rows[1].classList.contains('me') && !rows[0].classList.contains('me'));
  assert.match(app.q('.chat').textContent, /hey there/);
  assert.match(app.q('.chat').textContent, /hi bo/);
  assert.ok(lastCall(app, 'mark_dm_read'), 'viewing a thread advances its read watermark');
  assert.equal(lastCall(app, 'mark_dm_read').args.circleId, DM);
  assert.ok(app.q('#view-messages').classList.contains('thread-mode'));
});

test('messages: Enter sends the DM; Shift+Enter does not; an empty box sends nothing', async () => {
  const { app } = await boot(withDm());
  await tab(app, 'messages');
  await click(app, '.thread-item');
  const ta = app.q('.dm-composer textarea');
  const key = (k, extra = {}) => ta.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: k, ...extra }));
  key('Enter');
  await app.settle();
  assert.equal(lastCall(app, 'send_dm'), undefined, 'nothing typed, nothing sent');
  ta.value = 'line one';
  key('Enter', { shiftKey: true });
  await app.settle();
  assert.equal(lastCall(app, 'send_dm'), undefined, 'Shift+Enter is a newline');
  key('Enter');
  await app.settle();
  const sent = lastCall(app, 'send_dm');
  assert.ok(sent);
  assert.equal(sent.args.circleId, DM);
  assert.equal(sent.args.body, 'line one');
  assert.equal(ta.value, '', 'the box clears after sending');
});

test('messages: the thread menu pins, and delete asks first', async () => {
  const { app } = await boot(withDm());
  await tab(app, 'messages');
  await click(app, '.thread-item .kebab');
  const items = () => app.qa('#menu-root button, #menu-root .menu-item, #menu-root [role="menuitem"]');
  assert.ok(items().length >= 2, 'pin + delete are offered');
  const pin = items().find((b) => /^Pin/.test(b.textContent.trim()));
  await click(app, pin);
  assert.deepEqual(JSON.parse(JSON.stringify(lastCall(app, 'set_pinned_dms').args.ids)), [DM]);
  assert.ok(app.q('.pin-grid'), 'a pinned thread rides the top grid');

  await tab(app, 'circle'); await tab(app, 'messages');
  await click(app, '.pin-tile');
  assert.ok(app.q('.thread-wrap'), 'a pinned tile opens the thread');
});

test('messages: deleting a conversation is confirmed, and declining keeps it', async () => {
  const { app } = await boot(withDm());
  await tab(app, 'messages');
  app.ctx.__confirm = false;
  await click(app, '.thread-item .kebab');
  const del = app.qa('#menu-root button').find((b) => /Delete/i.test(b.textContent));
  await click(app, del);
  assert.equal(lastCall(app, 'delete_conversation'), undefined);
  assert.equal(app.dialogs.at(-1)[0], 'confirm');
  app.ctx.__confirm = true;
  await click(app, '.thread-item .kebab');
  await click(app, app.qa('#menu-root button').find((b) => /Delete/i.test(b.textContent)));
  assert.equal(lastCall(app, 'delete_conversation').args.circleId, DM);
});

test('messages: the compose chip starts a DM with the picked contact', async () => {
  const { app } = await boot(withDm());
  await tab(app, 'messages');
  await click(app, '#tb-right button');
  assert.match(app.q('#modal-root').textContent, /New Message/i);
  const start = () => app.qa('#modal-root button').find((b) => b.classList.contains('primary'));
  assert.ok(start().disabled, 'Start is disabled until someone is picked');
  await click(app, app.qa('#modal-root .list-item')[0]);
  assert.ok(!start().disabled);
  await click(app, start());
  assert.equal(lastCall(app, 'start_dm').args.contactIdHex, BO);
  assert.ok(app.q('#view-messages').classList.contains('thread-mode'));
});

const social = () => boot({ state: { contacts: withDm().state.contacts, feeds: { default: [BO_POST(), post()] } } });

test('feed: a post card shows author, body, reaction pills and comments', async () => {
  const { app } = await social();
  const card = app.q('.card.post[data-post="bp1"]');
  assert.ok(card);
  assert.equal(card.querySelector('.name').textContent, 'Bo');
  assert.equal(card.querySelector('.post-body').textContent, 'bo says hi');
  const pills = card.querySelectorAll('.react-pill');
  assert.equal(pills.length, 2);
  assert.ok(pills[1].classList.contains('mine'), 'my own reaction is highlighted');
  assert.match(card.querySelector('.comment-list').textContent, /first!/);
  assert.match(card.querySelector('.quick button:last-child').textContent, /1/, 'comment count on the toggle');
});

test('feed: tapping a reaction pill toggles it through the backend', async () => {
  const { app } = await social();
  const pills = app.qa('.card[data-post="bp1"] .react-pill');
  await click(app, pills[0]);          // not mine → react
  assert.equal(lastCall(app, 'react')?.args.emoji, '❤️');
  assert.equal(lastCall(app, 'react').args.target, 'bp1');
  await click(app, pills[1]);          // mine → take it back
  assert.equal(lastCall(app, 'unreact')?.args.emoji, '😂');
});

test('feed: the comment field posts a trimmed comment on Enter and via the send button', async () => {
  const { app } = await social();
  const card = app.q('.card[data-post="bp1"]');
  const input = card.querySelector('.reply-row input');
  input.value = '   ';
  await click(app, card.querySelector('.send-sm'));
  assert.equal(lastCall(app, 'comment'), undefined, 'blank comments are not sent');
  input.value = '  nice  ';
  input.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  assert.equal(lastCall(app, 'comment').args.body, 'nice');
  assert.equal(input.value, '');
  input.value = 'again';
  await click(app, card.querySelector('.send-sm'));
  assert.equal(app.calls.filter((c) => c.cmd === 'comment').length, 2);
});

test('feed: the 💬 button reveals the comment thread', async () => {
  const { app } = await social();
  const card = app.q('.card[data-post="bp1"]');
  assert.ok(!card.querySelector('.comments').classList.contains('show'));
  await click(app, card.querySelector('.quick button:last-child'));
  assert.ok(card.querySelector('.comments').classList.contains('show'));
});

test("feed: someone else's post offers message / report / hide, and mine offers edit / unsend", async () => {
  const { app } = await social();
  await click(app, '.card[data-post="bp1"] .kebab');
  assert.ok(menuBtn(app, /Share/i));
  assert.ok(menuBtn(app, /Message Bo/i), 'a contact can be messaged from their post');
  assert.ok(menuBtn(app, /Report/i));
  assert.ok(!menuBtn(app, /^Edit/i) && !menuBtn(app, /Unsend/i));
  await click(app, '.card[data-post="p1"] .kebab');
  assert.ok(menuBtn(app, /^Edit/i) && menuBtn(app, /Unsend/i));
  assert.ok(!menuBtn(app, /Report/i) && !menuBtn(app, /Message/i));
});

test('feed: Message <author> opens the DM thread with a staged draft and sends nothing', async () => {
  const { app } = await boot({ state: { ...withDm().state, feeds: { default: [BO_POST()] } }, be: { message_author: () => ({ dm: DM, name: 'Bo', draft: 'haven://post/x' }) } });
  await click(app, '.card[data-post="bp1"] .kebab');
  await click(app, menuBtn(app, /Message Bo/i));
  assert.ok(app.q('.thread-wrap'), 'the thread is open');
  assert.equal(app.q('.dm-composer textarea').value, 'haven://post/x', 'the post link is waiting, unsent');
  assert.equal(lastCall(app, 'send_dm'), undefined);
});

test('feed: hiding a post removes it from the list and the circle menu can show it again', async () => {
  const { app } = await social();
  await click(app, '.card[data-post="bp1"] .kebab');
  await click(app, menuBtn(app, /^Hide/i));
  assert.ok(!app.q('.card[data-post="bp1"]'));
  assert.ok(app.q('.card[data-post="p1"]'), 'other posts stay');
  assert.match(app.localStorage.getItem('haven-hidden') ?? '', /bp1/);
});

test('feed: unsend calls the backend for my own post only', async () => {
  const { app } = await social();
  await click(app, '.card[data-post="p1"] .kebab');
  await click(app, menuBtn(app, /Unsend/i));
  const c = lastCall(app, 'unsend_post');
  assert.deepEqual(JSON.parse(JSON.stringify(c.args)), { circleId: 'default', target: 'p1' });
});

test('feed: editing a post saves the new text with its media and song untouched', async () => {
  const { app } = await social();
  await click(app, '.card[data-post="p1"] .kebab');
  await click(app, menuBtn(app, /^Edit/i));
  const ta = app.q('#modal-root textarea');
  assert.equal(ta.value, 'hello world');
  ta.value = '  hello edited  ';
  await click(app, app.qa('#modal-root .btn.primary').at(-1));
  const c = lastCall(app, 'edit_post');
  assert.equal(c.args.body, 'hello edited');
  assert.equal(c.args.target, 'p1');
  assert.deepEqual(JSON.parse(JSON.stringify(c.args.media)), []);
  assert.equal(app.q('#modal-root').children.length, 0, 'the dialog closes on success');
});

test('feed: a failed edit keeps the dialog open with the text intact', async () => {
  const { app } = await boot({ be: { edit_post: () => { throw new Error('engine busy'); } } });
  await click(app, '.card[data-post="p1"] .kebab');
  await click(app, menuBtn(app, /^Edit/i));
  app.q('#modal-root textarea').value = 'keep me';
  await click(app, app.qa('#modal-root .btn.primary').at(-1));
  assert.ok(app.q('#modal-root textarea'), 'dialog stays');
  assert.equal(app.q('#modal-root textarea').value, 'keep me');
  assert.ok(!app.qa('#modal-root .btn.primary').at(-1).disabled, 'Save is usable again');
});

test('feed: reporting picks a reason, hides the post, and can block the author', async () => {
  const { app } = await boot({ state: { ...withDm().state, feeds: { default: [BO_POST()] } }, be: { report: () => BO } });
  await click(app, '.card[data-post="bp1"] .kebab');
  await click(app, menuBtn(app, /Report/i));
  const submit = () => app.qa('#modal-root .btn.primary').at(-1);
  assert.ok(submit().disabled, 'a reason is required first');
  await click(app, app.qa('#modal-root .btn.reason')[0]);
  assert.ok(!submit().disabled);
  await click(app, submit());
  const r = lastCall(app, 'report');
  assert.equal(r.args.target, 'bp1');
  assert.ok(r.args.reason);
  assert.ok(!app.q('.card[data-post="bp1"]'), 'the reporter never sees it again');
});

test('feed: double-clicking a photo hearts it once', async () => {
  const { app } = await boot({ state: { feeds: { default: [BO_POST({ media: ['img_abc'], reactions: [] })] } } });
  const media = app.q('.card[data-post="bp1"] .post-media');
  assert.ok(media, 'a single photo renders a media block');
  media.dispatchEvent(new app.ctx.Event('dblclick', { bubbles: true }));
  await app.settle();
  assert.equal(lastCall(app, 'react').args.emoji, '❤️');
});

test('feed: an unsent post is dropped from the list, and stories only appear in the tray', async () => {
  const feed = [post({ id: 'gone', unsent: true, body: 'x' }), post({ id: 's1', story: true, body: 'story caption', media: ['img_s'] }), post({ id: 'keep', body: 'normal' })];
  const { app } = await boot({ state: { feeds: { default: feed } } });
  assert.ok(!app.q('.card[data-post="gone"]'));
  assert.ok(!app.q('.card[data-post="s1"]'), 'a story is not a feed card');
  assert.ok(app.q('.card[data-post="keep"]'));
  assert.equal(app.qa('.story-ring.cover').length, 1, 'one ring for the author with stories');
  assert.ok(app.q('.story-ring.add'));
});

test('feed: the sound toggle persists the choice', async () => {
  const { app } = await boot();
  await click(app, '[data-sound-toggle]');
  assert.equal(lastCall(app, 'set_video_sound').args.on, true);
});

test('feed: an empty circle shows the empty state', async () => {
  const { app } = await boot({ state: { feeds: { default: [] } } });
  assert.match(app.q('#view-circle').textContent, /Nothing here yet/i);
});

// ── deep links ──────────────────────────────────────────────────────────────────────────────────

test('deep links: post and story links round-trip through the one emitted form', async () => {
  const { app } = await boot();
  const link = app.ev('DeepLink.postLink("dm:aa-bb", "p.1/x")');
  assert.match(link, /^https:\/\/wemiller\.com\/apps\/haven\/open\/#p\//);
  assert.ok(!link.includes('/p/dm'), 'the payload rides in the #fragment, never the path');
  assert.deepEqual(J(app.ev(`DeepLink.post(${JSON.stringify(link)})`)), { circleId: 'dm:aa-bb', postId: 'p.1/x' });
  const s = app.ev('DeepLink.storyLink("default", "s1")');
  assert.deepEqual(J(app.ev(`DeepLink.story(${JSON.stringify(s)})`)), { circleId: 'default', postId: 's1' });
  assert.equal(app.ev(`DeepLink.post(${JSON.stringify(s)})`), null, 'a story link is not a post link');
  assert.equal(app.ev(`DeepLink.story(${JSON.stringify(link)})`), null);
});

test('deep links: the legacy haven:// forms parse, and look-alikes are refused', async () => {
  const { app } = await boot();
  const P = (u) => app.ev(`DeepLink.post(${JSON.stringify(u)})`);
  assert.deepEqual(J(P('haven://p/default/abc')), { circleId: 'default', postId: 'abc' });
  assert.equal(P('haven://p/onlyone'), null);
  assert.equal(P('haven://x/default/abc'), null);
  assert.equal(P('https://evil.example/apps/haven/open/#p/default.abc'), null, 'other hosts never route');
  assert.equal(P('http://wemiller.com/apps/haven/#p/default.abc'), null, 'plain http is refused');
  assert.equal(P('https://wemiller.com/apps/haven/#abc.def'), null, 'an invite is not a post');
  assert.equal(P('https://wemiller.com/apps/haven/#p/nodot'), null);
  assert.equal(P('https://wemiller.com/apps/haven/#p/%E0%A4%A.x'), null, 'malformed percent-escapes do not throw');
  assert.equal(P('not a url'), null);
  assert.equal(P(null), null);
  assert.deepEqual(J(app.ev('DeepLink.story("haven://s/c/p")')), { circleId: 'c', postId: 'p' });
  assert.equal(app.ev('DeepLink.story("haven://s/c")'), null);
  assert.deepEqual(J(app.ev('DeepLink.message("haven://m/dm%3Aa-b/m1")')), { circleId: 'dm:a-b', messageId: 'm1' });
  assert.deepEqual(J(app.ev('DeepLink.message("haven://m/dm%3Aa-b")')), { circleId: 'dm:a-b', messageId: null });
  assert.equal(app.ev('DeepLink.message("haven://m/")'), null);
  assert.equal(app.ev('DeepLink.message("haven://p/x/y")'), null);
  assert.deepEqual(J(app.ev('DeepLink.circle("haven://c/work")')), { circleId: 'work' });
  assert.equal(app.ev('DeepLink.circle("https://x")'), null);
});

test('deep links: a story pointer is found inside free-form message text', async () => {
  const { app } = await boot();
  const link = app.ev('DeepLink.storyLink("default", "s9")');
  const hit = J(app.ev(`DeepLink.firstStoryIn(${JSON.stringify('look at this ' + link + ' wow')})`));
  assert.equal(hit.postId, 's9');
  assert.equal(hit.raw, link);
  assert.equal(app.ev('DeepLink.firstStoryIn("no links here")'), null);
  assert.equal(app.ev('DeepLink.firstStoryIn(null)'), null);
  const embedded = J(app.ev('DeepLink.firstStoryIn("see haven://s/c/p now")'));
  assert.equal(embedded?.postId, 'p', 'the on-device form is found in running text');
});

test('deep links: a media-only story reply is matched back to the right story by time and author', async () => {
  const { app } = await boot();
  const R = (msg, ctx) => J(app.ev(`DeepLink.storyReplyTarget(${JSON.stringify(msg)}, ${JSON.stringify(ctx)})`));
  const T0 = 1_700_000_000_000;
  const peer = BO;
  const live = [
    { circleId: 'default', id: 'old', author_short: BO.slice(0, 8), is_me: false, created_at: T0 - 30 * 3_600_000, has_media: true },
    { circleId: 'default', id: 'near', author_short: BO.slice(0, 8), is_me: false, created_at: T0 - 3_600_000, has_media: true },
    { circleId: 'default', id: 'mine', author_short: ME.slice(0, 8), is_me: true, created_at: T0 - 2 * 3_600_000, has_media: true },
  ];
  const reply = { id: 'm', body: '', media: ['img_x'], created_at: T0, is_me: false };
  assert.equal(R(reply, { peerHex: peer, liveStories: live, keptMine: [] }).postId, 'mine', 'a reply FROM the peer answers MY story');
  const mine = { ...reply, is_me: true };
  assert.equal(R(mine, { peerHex: peer, liveStories: live, keptMine: [] }).postId, 'near', 'my reply answers the peer\'s story within 24h');
  assert.equal(R({ ...mine, media: ['img_x', 'img_y'] }, { peerHex: peer, liveStories: live }), null, 'two attachments is not a story reply');
  assert.equal(R({ ...mine, unsent: true }, { peerHex: peer, liveStories: live }), null);
  const kept = R(reply, { peerHex: peer, liveStories: [], keptMine: [{ id: 'k1', createdAt: T0 - 3 * 86_400_000 }] });
  assert.equal(kept.postId, 'k1', 'a kept story stays matchable for a week');
  assert.equal(R(reply, { peerHex: peer, liveStories: [], keptMine: [{ id: 'k2', createdAt: T0 - 9 * 86_400_000 }] }), null);
  const linked = R({ ...reply, body: 'haven://s/default/zz' }, { peerHex: peer });
  assert.equal(linked.postId, 'zz', 'an explicit pointer wins over inference');
});

test('deep links: routing a post link opens its circle and focuses the card', async () => {
  const feed = [post({ id: 'target', body: 'the linked post' }), post({ id: 'other' })];
  const { app } = await boot({ state: { feeds: { default: feed } } });
  await tab(app, 'you');
  const r = await app.ev(`routeDeepLink(${JSON.stringify(app.ev('DeepLink.postLink("default", "target")'))})`);
  await app.settle();
  assert.equal(r, 'post');
  assert.ok(app.q('#view-circle').classList.contains('active'));
  assert.ok(app.q('.card[data-post="target"]'));
});

test('deep links: a post link into a circle I am not in says so', async () => {
  const { app } = await boot();
  await app.ev(`routeDeepLink(${JSON.stringify(app.ev('DeepLink.postLink("nope", "x")'))})`);
  assert.match(app.q('#toast').textContent, /circle/i);
});

test('deep links: a missing or unsent post is explained, not silently ignored', async () => {
  const { app } = await boot({ state: { feeds: { default: [post({ id: 'u', unsent: true }), post({ id: 'st', story: true, media: ['img_s'] })] } } });
  const go = (id) => app.ev(`openPostLink("default", ${JSON.stringify(id)})`);
  await go('missing'); assert.ok(app.q('#toast').textContent.length > 0);
  const missing = app.q('#toast').textContent;
  await go('u'); assert.notEqual(app.q('#toast').textContent, missing, 'unsent has its own message');
  const unsent = app.q('#toast').textContent;
  await go('st'); assert.notEqual(app.q('#toast').textContent, unsent, 'a story link has its own message');
});

test('deep links: a link to a comment resolves to the post that carries it', async () => {
  const withComment = post({ id: 'host', comments: [{ id: 'cm1', author_short: 'x', author_name: 'Cy', is_me: false, created_at: NOW, body: 'c', media: [], reactions: [] }] });
  const { app } = await boot({ state: { feeds: { default: [withComment] } } });
  await app.ev('openPostLink("default", "cm1")');
  await app.settle();
  assert.ok(app.q('.card[data-post="host"]'));
  assert.equal(app.ev('state.focusPost'), null, 'the focus is consumed by the render');
});

test('deep links: haven://c/<circle> switches circles; an unknown one toasts', async () => {
  const { app } = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 1 }, { id: 'work', name: 'Work', member_count: 3 }], feeds: { default: [], work: [post({ id: 'w1', body: 'work post' })] } } });
  assert.equal(await app.ev('routeDeepLink("haven://c/work")'), 'circle');
  await app.settle();
  assert.equal(app.ev('state.activeCircle'), 'work');
  assert.match(app.q('#view-circle').textContent, /work post/);
  assert.equal(await app.ev('routeDeepLink("haven://c/ghost")'), 'circle');
  assert.equal(app.ev('state.activeCircle'), 'work', 'an unknown circle does not move the user');
});

test('deep links: anything else is offered to the engine as an invite', async () => {
  const { app } = await boot({ be: { connect_by_link: ({ uri }) => uri.includes('good') } });
  assert.equal(await app.ev('routeDeepLink("haven:invite-good")'), 'invite');
  assert.equal(await app.ev('routeDeepLink("haven:invite-bad")'), null);
  assert.equal(lastCall(app, 'connect_by_link').args.uri, 'haven:invite-bad');
});

test('deep links: a story link shows the viewer for a live story and an expiry card otherwise', async () => {
  const story = post({ id: 'live', story: true, body: 'cap', media: ['img_s'], created_at: NOW - 3_600_000 });
  const { app } = await boot({ state: { feeds: { default: [story] }, dms: {} } });
  await app.ev('openStoryLink("default", "gone")');
  assert.match(app.q('#modal-root').textContent, /no longer available/i);
  app.q('#modal-root').replaceChildren();
  const be2 = await boot({ state: { feeds: { default: [] } }, be: { kept_stories: [{ id: 'kept1', body: 'kept body', media: ['img_k'], createdAt: NOW - 5 * 86_400_000, musicCatalogId: 'cat', musicTitle: 'Song', musicArtist: 'Art' }] } });
  await be2.app.ev('openStoryLink("default", "kept1")');
  assert.ok(be2.app.q('#modal-root').children.length > 0, 'a kept story opens in the viewer even past 24h');
});

// ── activity panel ──────────────────────────────────────────────────────────────────────────────
test('activity: rows read as who + what, unread rows are bold, tapping routes the link', async () => {
  const group = `dm:${HEX('a')}-${HEX('b')}-${HEX('c')}`;
  const rows = [
    { id: 'r1', kind: 'react', circle_id: 'default', actor_name: 'Bo', snippet: 'your post', created_at: NOW - 1000, emoji: '🎉', link: null },
    { id: 'r2', kind: 'dm', circle_id: group, actor_name: 'Cy', snippet: 'hello team', created_at: NOW - 2000, emoji: null, link: null },
    { id: 'r3', kind: 'dm', circle_id: DM, actor_name: 'Bo', snippet: 'psst', created_at: NOW - 3000, emoji: null, link: `haven://m/${encodeURIComponent(DM)}` },
    { id: 'r4', kind: 'app', circle_id: '', actor_name: 'Media is back', snippet: 'tap to view', created_at: NOW - 4000, emoji: null, link: null },
    { id: 'r5', kind: 'comment', circle_id: 'default', actor_name: 'Dee', snippet: 'c', created_at: NOW - 100_000, emoji: null, link: null },
  ];
  const { app } = await boot({ ...withDm(), be: { activity: { rows, seen_at: NOW - 50_000 } } });
  assert.equal(app.text('#badge-bell'), '4', 'four rows are newer than the seen watermark');
  await click(app, '#bell-btn');
  const names = app.qa('#modal-root .thread-item .name').map((n) => n.textContent);
  assert.ok(names.some((n) => /Bo · .*🎉/.test(n)), names.join('|'));
  assert.ok(names.some((n) => /Bo · sent you a message/i.test(n)));
  assert.ok(names.includes('Media is back'));
  assert.equal(app.qa('#modal-root .name.unread').length, 4);
  assert.ok(lastCall(app, 'mark_activity_seen'), 'opening the bell marks everything seen');
  // Tapping a row that carries a link closes the sheet and routes it.
  const dmRow = app.qa('#modal-root .thread-item').find((r) => /psst/.test(r.textContent));
  await click(app, dmRow);
  assert.ok(app.q('.thread-wrap'), 'the DM link opened the thread');
});

test('activity: an empty list says so, and a long one pages in', async () => {
  const { app } = await boot();
  await click(app, '#bell-btn');
  assert.match(app.q('#modal-root').textContent, /Nothing yet/i);
  const many = Array.from({ length: 95 }, (_, i) => ({ id: 'x' + i, kind: 'post', circle_id: 'default', actor_name: 'P' + i, snippet: 's', created_at: NOW - i * 1000, emoji: null, link: null }));
  const b = await boot({ be: { activity: { rows: many, seen_at: NOW } } });
  await click(b.app, '#bell-btn');
  assert.equal(b.app.qa('#modal-root .thread-item').length, 40, 'the first page only');
  const more = b.app.qa('#modal-root button').find((x) => /older/i.test(x.textContent));
  assert.match(more.textContent, /55/, 'says how many are left');
  await click(b.app, more);
  assert.equal(b.app.qa('#modal-root .thread-item').length, 80);
  await click(b.app, b.app.qa('#modal-root button').find((x) => /older/i.test(x.textContent)));
  assert.equal(b.app.qa('#modal-root .thread-item').length, 95);
  assert.ok(!b.app.qa('#modal-root button').some((x) => /older/i.test(x.textContent)), 'the button goes away at the end');
});

// ── You tab, profile, support ──────────────────────────────────────────────────────────────────
test('you: shows my profile, my posts across circles, and my stories gallery', async () => {
  const feeds = { default: [post({ id: 'mine1', body: 'my post one' }), post({ id: 'sto', story: true, media: ['img_s'], body: 'my story' }), BO_POST()], work: [post({ id: 'mine2', body: 'work post', created_at: NOW - 5000 })] };
  const { app } = await boot({ state: { feeds, circles: [{ id: 'default', name: 'My Circle', member_count: 1 }, { id: 'work', name: 'Work', member_count: 2 }], profile: { name: 'Ada', bio: 'maker', link: 'https://ada.example', emoji: '🦊', avatar: '' } },
    be: { kept_stories: [{ id: 'kept9', body: 'kept one', media: ['img_k'], createdAt: NOW - 3 * 86_400_000 }] } });
  await tab(app, 'you');
  const v = app.q('#view-you');
  assert.equal(v.querySelector('.profile-name').textContent, 'Ada');
  assert.equal(v.querySelector('.profile-bio').textContent, 'maker');
  assert.match(v.querySelector('.profile-link').textContent, /ada\.example/);
  assert.match(v.querySelector('.disc').textContent, /🦊/);
  const posts = v.querySelectorAll('.card.post');
  assert.deepEqual([...posts].map((c) => c.dataset.post), ['mine2', 'mine1'], 'only my posts, newest first, from every circle');
  assert.equal(v.querySelectorAll('.story-ring.cover').length, 2, 'a live story plus a revived kept one');
  await click(app, v.querySelector('.profile-link'));
  assert.deepEqual(app.opened, ['https://ada.example']);
});

test('you: a profile with no name or links invites the user to fill it in', async () => {
  const { app } = await boot({ state: { profile: { name: '', bio: '', link: '', emoji: '', avatar: '' }, feeds: { default: [] } } });
  await tab(app, 'you');
  assert.equal(app.q('#view-you .profile-name').textContent, 'You');
  assert.ok(app.q('#view-you .profile-bio'), 'the private-by-default hint');
  assert.match(app.q('#view-you').textContent, /Your posts/i);
});

test('you: editing the profile saves trimmed fields and picking an emoji writes through', async () => {
  const { app, s } = await boot();
  await tab(app, 'you');
  await click(app, '.profile-avatar');
  const m = app.q('#modal-root');
  assert.match(m.querySelector('.modal-head h2').textContent, /Edit/i);
  const name = m.querySelector('input.pill-field');
  assert.equal(name.value, 'Ada');
  await click(app, m.querySelectorAll('.emoji-cell')[4]);        // 🦊
  assert.equal(lastCall(app, 'set_profile').args.emoji, '🦊', 'the emoji writes through immediately');
  assert.equal(s.profile.emoji, '🦊');
  const name2 = app.q('#modal-root input.pill-field');
  name2.value = '  Ada L  ';
  app.q('#modal-root textarea.field-soft').value = ' maker ';
  await click(app, app.q('#modal-root .modal-foot .btn.primary'));
  const c = lastCall(app, 'set_profile').args;
  assert.equal(c.name, 'Ada L');
  assert.equal(c.bio, 'maker');
  assert.equal(app.q('#modal-root').children.length, 0);
  assert.match(app.q('#toast').textContent, /saved/i);
});

test('you: a chosen photo becomes the avatar and can be removed again', async () => {
  const { app } = await boot();
  await tab(app, 'you');
  await click(app, '.profile-avatar');
  const picker = app.q('#modal-root input[type="file"]');
  picker.files = [new app.ctx.File(['x'], 'me.jpg', { type: 'image/jpeg' })];
  picker.dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  await app.settle();
  assert.match(lastCall(app, 'set_profile').args.avatar, /^data:image\/jpeg/);
  const remove = app.qa('#modal-root button').find((b) => /Remove/i.test(b.textContent));
  assert.ok(remove, 'a Remove button appears once there is a photo');
  await click(app, remove);
  assert.equal(lastCall(app, 'set_profile').args.avatar, '');
});

test('support: feedback rows open a mailto with a guided template and diagnostics', async () => {
  const { app } = await boot();
  await tab(app, 'you');
  await click(app, '#tb-right button.icon-btn');
  const rowFor = (re) => app.qa('#modal-root .set-row').find((r) => re.test(r.textContent));
  await click(app, rowFor(/Report an Issue/i));
  const url = app.opened.at(-1);
  assert.match(url, /^mailto:blaine@wemiller\.com\?subject=/);
  const body = decodeURIComponent(url.split('&body=')[1]);
  assert.match(body, /Haven .* \(desktop, macos\)/);
  assert.match(body, /Locale: en-US/);
  await click(app, rowFor(/Suggest a Feature/i));
  assert.match(decodeURIComponent(app.opened.at(-1)), /Feature/i);
  await click(app, rowFor(/Ask a Question/i));
  assert.match(decodeURIComponent(app.opened.at(-1)), /Question/i);
  await click(app, rowFor(/My Other Apps/i));
  assert.equal(app.opened.at(-1), 'https://wemiller.com/apps/');
});

test('support: the translation-fix form only offers itself in a non-English UI and gates sending', async () => {
  const en = await boot();
  await tab(en.app, 'you');
  await click(en.app, '#tb-right button.icon-btn');
  assert.ok(!en.app.qa('#modal-root .set-row').some((r) => /translation/i.test(r.textContent)), 'English has no translation row');

  const app = (await (async () => {
    const { be } = (await import('./uiharness.mjs')).fakeBackend({});
    return loadApp({ backend: be, lang: 'de-DE', local: { 'haven-terms-accepted-version': '99', 'haven-named-nudged': '1' } });
  })());
  await tab(app, 'you');
  await click(app, '#tb-right button.icon-btn');
  const row = app.qa('#modal-root .set-row').find((r) => /Deutsch/.test(r.textContent));
  assert.ok(row, 'the row names the language in its own script');
  await click(app, row);
  const send = app.qa('#modal-root .modal-foot button')[0];
  assert.equal(send.style.display, 'none', 'hidden until both honesty checks are ticked');
  for (const chk of app.qa('#modal-root input[type="checkbox"]')) { chk.checked = true; chk.dispatchEvent(new app.ctx.Event('change', { bubbles: true })); }
  assert.notEqual(send.style.display, 'none');
  assert.ok(send.disabled, 'still needs the screen and the suggested text');
  const [screenIn, , suggested] = app.qa('#modal-root .col input[placeholder], #modal-root textarea');
  screenIn.value = 'Settings'; screenIn.dispatchEvent(new app.ctx.Event('input', { bubbles: true }));
  suggested.value = 'Besser'; suggested.dispatchEvent(new app.ctx.Event('input', { bubbles: true }));
  assert.ok(!send.disabled);
  await click(app, send);
  assert.match(decodeURIComponent(app.opened.at(-1)), /Translation fix \(de\)/);
});

test('settings: blocked people lists blocks and unblocking calls the backend', async () => {
  const { app } = await boot({ state: { blocked: [HEX('d')], contacts: [] } });
  await tab(app, 'you');
  await click(app, '#tb-right button.icon-btn');
  await click(app, app.qa('#modal-root .set-row').find((r) => /Blocked/i.test(r.textContent)));
  assert.match(app.q('#modal-root').textContent, /dddddddd/);
  const un = app.qa('#modal-root button').find((b) => /Unblock/i.test(b.textContent));
  assert.ok(un);
  await click(app, un);
  assert.equal(lastCall(app, 'unblock').args.idHex, HEX('d'));
});

// ── story captions: the cross-platform wire format ─────────────────────────────────────────────
test('story captions: encode writes the exact field widths phones expect', async () => {
  const { app } = await boot();
  const spec = { color: 2, font: 1, style: 3, x: 0.5, y: 0.7, size: 1.2, mediaScale: 1, mediaOffX: 0, mediaOffY: 0, mediaRotation: 0 };
  const enc = app.ev(`StoryCaptions.encode("  hello  ", ${JSON.stringify(spec)})`);
  assert.equal(enc, '\u00012,1,3,0.500,0.700,1.200,1.000,0.0000,0.0000,0.0000\u0001hello');
  assert.equal(app.ev(`StoryCaptions.encode("   ", ${JSON.stringify(spec)})`), '', 'no text and no reframing encodes nothing');
  const framed = app.ev(`StoryCaptions.encode("", ${JSON.stringify({ ...spec, mediaScale: 1.5 })})`);
  assert.ok(framed.startsWith('\u0001') && framed.endsWith('\u0001'), 'a reframed story with no caption is still authored');
  const rot = app.ev(`StoryCaptions.encode("r", ${JSON.stringify({ ...spec, mediaRotation: 0.25 })})`);
  assert.ok(rot.includes(',0.2500\u0001r'), 'rotation (radians) is the appended 10th field');
});

test('story captions: decode round-trips, and tolerates legacy and malformed bodies', async () => {
  const { app } = await boot();
  const spec = { color: 5, font: 2, style: 2, x: 0.25, y: 0.75, size: 0.8, mediaScale: 1.4, mediaOffX: 0.1, mediaOffY: -0.2, mediaRotation: 0.5 };
  const d = J(app.ev(`StoryCaptions.decode(StoryCaptions.encode("round trip", ${JSON.stringify(spec)}))`));
  assert.equal(d.text, 'round trip');
  for (const [k, v] of Object.entries(spec)) assert.ok(Math.abs(d.spec[k] - v) < 1e-9, `${k}: ${d.spec[k]} vs ${v}`);
  const plain = J(app.ev('StoryCaptions.decode("just words")'));
  assert.equal(plain.text, 'just words');
  assert.equal(plain.spec.x, 0.5);
  assert.deepEqual(J(app.ev('StoryCaptions.decode("")')).text, '');
  assert.equal(J(app.ev('StoryCaptions.decode("\\u0001unterminated")')).text, 'unterminated');
  const legacy6 = J(app.ev('StoryCaptions.decode("\\u00012,0,1,0.5,0.5,1\\u0001old")'));
  assert.equal(legacy6.text, 'old');
  assert.equal(legacy6.spec.style, 4, 'the legacy 6-field style bit maps to highlight');
  assert.equal(legacy6.spec.mediaScale, 1, 'absent framing is identity');
});

test('story captions: the overlay is positioned, styled per mode, and empty text yields nothing', async () => {
  const { app } = await boot();
  const mk = (style, color = 2) => app.ev(`StoryCaptions.overlay(StoryCaptions.encode("hi", ${JSON.stringify({ color, font: 0, style, x: 0.2, y: 0.4, size: 1, mediaScale: 1, mediaOffX: 0, mediaOffY: 0, mediaRotation: 0 })}))`);
  const d = mk(1);
  assert.equal(d.textContent, 'hi');
  assert.match(d.style.cssText, /left:20%;top:40%/);
  assert.ok(mk(0).style.textShadow.includes('rgba(0,0,0,.55)'));
  assert.ok(mk(2).style.textShadow.includes('1.5px'));
  assert.ok(mk(3).style.textShadow.includes('14px'), 'neon');
  const hi = mk(4, 0);
  assert.equal(hi.style.color, '#000', 'highlight on a light colour uses dark text');
  assert.equal(mk(4, 2).style.color, '#fff');
  assert.ok(hi.style.background);
  assert.equal(app.ev('StoryCaptions.overlay("")'), null);
  assert.equal(app.ev('StoryCaptions.overlay("\\u00010,0,1,0.5,0.5,1\\u0001   ")'), null);
});

// ── circles ─────────────────────────────────────────────────────────────────────────────────────
const TWO_CIRCLES = [{ id: 'default', name: 'My Circle', member_count: 1 }, { id: 'work', name: 'Work', member_count: 4 }];

test('circles: the switcher lists circles with member counts and switches the feed', async () => {
  const { app } = await boot({ state: { circles: TWO_CIRCLES, feeds: { default: [post({ body: 'home post' })], work: [post({ id: 'w', body: 'work post' })] } } });
  assert.match(app.text('#tb-circle-name'), /My Circle/);
  await click(app, '.circle-pill');
  const items = app.qa('#menu-root button');
  assert.ok(items.some((b) => /Work \(4\)/.test(b.textContent)));
  assert.ok(items.some((b) => /New circle/i.test(b.textContent)));
  await click(app, items.find((b) => /Work \(4\)/.test(b.textContent)));
  assert.match(app.q('#view-circle').textContent, /work post/);
  assert.match(app.text('#tb-circle-name'), /Work/);
  assert.equal(lastCall(app, 'feed').args.circleId, 'work');
});

test('circles: a new circle is created from the dialog and becomes active', async () => {
  const { app, s } = await boot({ be: { create_circle: () => 'new1' } });
  s.circles.push({ id: 'new1', name: 'Fresh', member_count: 0 });
  s.feeds.new1 = [];
  await click(app, '.circle-pill');
  await click(app, app.qa('#menu-root button').find((b) => /New circle/i.test(b.textContent)));
  await click(app, app.qa('#modal-root .btn.primary').at(-1));     // empty name: nothing created, dialog closes
  assert.equal(lastCall(app, 'create_circle'), undefined);
  await click(app, '.circle-pill');
  await click(app, app.qa('#menu-root button').find((b) => /New circle/i.test(b.textContent)));
  app.q('#modal-root input').value = '  Fresh  ';
  await click(app, app.qa('#modal-root .btn.primary').at(-1));
  assert.equal(lastCall(app, 'create_circle')?.args.name, 'Fresh');
  assert.equal(app.ev('state.activeCircle'), 'new1', 'the new circle becomes active');
});

test('circles: managing a circle renames it for everyone, but a nickname stays on this device', async () => {
  const { app } = await boot({ state: { circles: TWO_CIRCLES, feeds: { default: [], work: [] } } });
  await click(app, '.circle-pill');
  await click(app, app.qa('#menu-root button').find((b) => /Work/.test(b.textContent)));
  await click(app, '#tb-right button.icon-btn');                 // manage circle
  const m = () => app.q('#modal-root');
  assert.match(m().querySelector('.modal-head h2').textContent, /Work/);
  const [nameInp, nickInp] = m().querySelectorAll('.row input');
  assert.equal(nameInp.value, 'Work', 'the real name, never the nickname');
  nameInp.value = 'Work Crew';
  await click(app, m().querySelectorAll('.row .btn')[0]);
  assert.deepEqual(J(lastCall(app, 'rename_circle').args), { id: 'work', name: 'Work Crew' });

  await click(app, '#tb-right button.icon-btn');
  const nick = m().querySelectorAll('.row input')[1];
  nick.value = 'The Gang';
  await click(app, m().querySelectorAll('.row .btn')[1]);
  assert.equal(J(JSON.parse(app.localStorage.getItem('haven-circle-nick'))).work, 'The Gang');
  assert.match(app.text('#tb-circle-name'), /The Gang/, 'display sites use the nickname');
  assert.equal(app.calls.filter((c) => c.cmd === 'rename_circle').length, 1, 'a nickname never renames the circle');
});

test('circles: members can be added, promoted, messaged and removed from the manage sheet', async () => {
  const { app } = await boot({ state: { ...withDm().state, circles: TWO_CIRCLES, feeds: { default: [], work: [] } }, be: { grant_circle_admin: true, circle_admins: [ME] } });
  await click(app, '.circle-pill');
  await click(app, app.qa('#menu-root button').find((b) => /Work/.test(b.textContent)));
  await click(app, '#tb-right button.icon-btn');
  const row = () => app.q('#modal-root .list-item');
  const btn = (re) => [...row().querySelectorAll('button')].find((b) => re.test(b.textContent));
  await click(app, btn(/^Add$/));
  assert.deepEqual(J(lastCall(app, 'add_to_circle').args), { circleId: 'work', contactIdHex: BO });
  await click(app, btn(/Make admin|admin/i));
  assert.deepEqual(J(lastCall(app, 'grant_circle_admin').args), { circleId: 'work', adminHex: BO });
  await click(app, btn(/^Remove$/));
  assert.deepEqual(J(lastCall(app, 'remove_from_circle').args), { circleId: 'work', contactIdHex: BO });
  await click(app, '#tb-right button.icon-btn');
  await click(app, [...row().querySelectorAll('button')].find((b) => /Message/i.test(b.textContent)));
  assert.ok(app.q('.thread-wrap'), 'Message opens the private thread');
});

test('circles: a non-admin cannot promote and is told so', async () => {
  const { app } = await boot({ state: { ...withDm().state, circles: TWO_CIRCLES, feeds: { default: [], work: [] } }, be: { grant_circle_admin: false } });
  await click(app, '.circle-pill');
  await click(app, app.qa('#menu-root button').find((b) => /Work/.test(b.textContent)));
  await click(app, '#tb-right button.icon-btn');
  await click(app, [...app.q('#modal-root .list-item').querySelectorAll('button')].find((b) => /admin/i.test(b.textContent)));
  assert.ok(app.q('#toast').textContent.length > 0);
});

test('circles: leaving is offered for shared circles only, and returns to the personal one', async () => {
  const { app } = await boot({ state: { circles: TWO_CIRCLES, feeds: { default: [], work: [] } } });
  await click(app, '#tb-right button.icon-btn');                     // manage the default circle
  assert.ok(![...app.qa('#modal-root button')].some((b) => /Leave/i.test(b.textContent)), 'the personal circle cannot be left');
  app.q('#modal-root').replaceChildren();
  await click(app, '.circle-pill');
  await click(app, app.qa('#menu-root button').find((b) => /Work/.test(b.textContent)));
  await click(app, '#tb-right button.icon-btn');
  await click(app, [...app.qa('#modal-root button')].find((b) => /Leave/i.test(b.textContent)));
  assert.equal(lastCall(app, 'leave_circle').args.id, 'work');
  assert.equal(app.ev('state.activeCircle'), 'default');
});

test('circles: per-circle relays can be toggled from the manage sheet', async () => {
  const RL = [{ node_hex: HEX('e'), name: 'Home relay', active: true, is_s3: false, is_default: false, reachable: true, hosted: false }, { node_hex: HEX('f'), name: 'Default one', active: true, is_s3: false, is_default: true, reachable: true, hosted: false }];
  const { app } = await boot({ state: { circles: TWO_CIRCLES, feeds: { default: [], work: [] } }, be: { relays: RL, circle_relays: [] } });
  await click(app, '#tb-right button.icon-btn');
  const boxes = app.qa('#modal-root input[type="checkbox"]');
  assert.equal(boxes.length, 2);
  assert.ok(boxes[1].checked && boxes[1].disabled, 'the all-circles default is shown on and locked');
  boxes[0].checked = true;
  boxes[0].dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  await app.settle();
  assert.deepEqual(J(lastCall(app, 'set_circle_relay').args), { nodeHex: HEX('e'), circleId: 'default', on: true });
});

// ── people: connect sheet, requests, contacts ──────────────────────────────────────────────────
test('connect: pending requests badge the tab and the banner opens the review sheet', async () => {
  const { app, s } = await boot({ state: { ...withDm().state, pending: [{ id_hex: HEX('c'), name: 'Cy', verify_hex: 'f'.repeat(64) }] } });
  assert.equal(app.text('#badge-circle'), '1');
  const banner = app.q('.nudge-banner');
  assert.match(banner.textContent, /connection request/i);
  await click(app, banner);
  const m = app.q('#modal-root');
  assert.match(m.textContent, /Cy/);
  assert.match(m.textContent, /ffffffffffffffff/, 'the safety number prefix is shown');
  assert.match(m.textContent, /haven:invite/, 'my own invite is on the same sheet');
  assert.ok(m.querySelector('.qr-box svg'), 'a QR code is drawn for the invite');
  await click(app, [...m.querySelectorAll('button')].find((b) => /Accept/i.test(b.textContent)));
  assert.equal(lastCall(app, 'approve').args.idHex, HEX('c'));
  await click(app, [...m.querySelectorAll('button')].find((b) => /Ignore/i.test(b.textContent)));
  assert.equal(lastCall(app, 'dismiss').args.idHex, HEX('c'));
  void s;
});

test('connect: pasting an invite connects; junk is refused; copy buttons use the clipboard', async () => {
  const copied = [];
  const { app } = await boot({ ...withDm(), be: { connect_by_link: ({ uri }) => uri.startsWith('haven:') } });
  app.ctx.navigator.clipboard.writeText = async (t) => { copied.push(t); };
  await click(app, '#tb-right button.icon-btn');                      // circle sheet
  await click(app, [...app.qa('#modal-root button')].find((b) => /Invite someone/i.test(b.textContent)));
  const m = app.q('#modal-root');
  const field = m.querySelector('input');
  field.value = 'haven:abc.def';
  await click(app, [...m.querySelectorAll('button.primary')].find((b) => /Connect/i.test(b.textContent)));
  assert.equal(lastCall(app, 'connect_by_link').args.uri, 'haven:abc.def');
  assert.equal(field.value, '', 'cleared after a successful connect');
  field.value = 'nonsense';
  await click(app, [...m.querySelectorAll('button.primary')].find((b) => /Connect/i.test(b.textContent)));
  assert.equal(field.value, 'nonsense', 'kept so the user can fix it');
  await click(app, [...m.querySelectorAll('button')].find((b) => /Copy haven:\/\/ link/i.test(b.textContent)));
  await click(app, [...m.querySelectorAll('button')].find((b) => /Copy web link/i.test(b.textContent)));
  assert.deepEqual(copied, ['haven:invite', 'https://haven.is/invite']);
});

test('connect: the contact list can message or block someone', async () => {
  const { app } = await boot(withDm());
  await click(app, '#tb-right button.icon-btn');
  await click(app, [...app.qa('#modal-root button')].find((b) => /Invite someone/i.test(b.textContent)));
  const item = [...app.qa('#modal-root .list-item')].find((r) => /Bo/.test(r.textContent));
  await click(app, item.querySelector('.kebab'));
  await click(app, menuBtn(app, /Block/i));
  assert.equal(lastCall(app, 'block').args.idHex, BO);
  await click(app, '#tb-right button.icon-btn');
  await click(app, [...app.qa('#modal-root button')].find((b) => /Invite someone/i.test(b.textContent)));
  await click(app, [...app.qa('#modal-root .list-item button')].find((b) => /Message/i.test(b.textContent)));
  assert.ok(app.q('.thread-wrap'));
});

test('connect: the relay nudge appears for a busy circle with no relay and can be dismissed for good', async () => {
  const { app } = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 5 }], feeds: { default: [] } } });
  const nudge = app.q('.nudge-banner');
  assert.ok(nudge, 'more than two other members and no relay of its own');
  assert.match(nudge.textContent, /relay/i);
  await click(app, nudge.querySelector('.nudge-x'));
  assert.ok(!app.q('.nudge-banner'));
  assert.match(app.localStorage.getItem('haven-relay-nudge-dismissed'), /default/);
  const again = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 5 }], feeds: { default: [] } }, local: { 'haven-relay-nudge-dismissed': '["default"]' } });
  assert.ok(!again.app.q('.nudge-banner'), 'dismissal is permanent');
});

test('connect: no nudge when this PC already relays or the circle is small', async () => {
  const hosting = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 5 }], feeds: { default: [] } }, be: { relay_status: { hosting: true, started: true, internet_active: true } } });
  assert.ok(!hosting.app.q('.nudge-banner'));
  const armed = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 5 }], feeds: { default: [] } }, be: { autostart_status: { login_item: false, host_on_launch: true } } });
  assert.ok(!armed.app.q('.nudge-banner'));
  const small = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 2 }], feeds: { default: [] } } });
  assert.ok(!small.app.q('.nudge-banner'));
  const own = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 5 }], feeds: { default: [] } }, be: { circle_relays: [HEX('e')], relays: [{ node_hex: HEX('e'), active: true, name: 'r' }] } });
  assert.ok(!own.app.q('.nudge-banner'), 'a circle with an active relay of its own needs no nudge');
});

test('connect: the nudge walkthrough can turn this PC into the relay', async () => {
  const { app } = await boot({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 5 }], feeds: { default: [] } }, be: { start_hosting: 'haven:relay' } });
  await click(app, '.nudge-body');
  assert.match(app.q('#modal-root').textContent, /relay/i);
  await click(app, app.qa('#modal-root .btn.primary').at(-1));
  assert.ok(lastCall(app, 'start_hosting'));
  assert.equal(app.q('#modal-root').children.length, 0);
});

test('circle upgrades: someone elses offer names them, and following is an explicit click', async () => {
  const offer = { legacy_circle_id: 'default', new_circle_id: 'owned:x', from_hex: BO, from_name: 'Bo', name: 'Work', mine: false };
  const { app } = await boot({ be: { pending_circle_upgrades: [offer], accept_circle_upgrade: true } });
  const card = app.q('.nudge-banner');
  assert.match(card.textContent, /Bo/);
  await click(app, card.querySelector('.nudge-cta'));
  assert.deepEqual(J(lastCall(app, 'accept_circle_upgrade').args), { circleId: 'default', newCircleId: 'owned:x' });
});

test('circle upgrades: the offer to upgrade my own circle calls upgrade_circle', async () => {
  const { app } = await boot({ be: { can_offer_circle_upgrade: true, upgrade_circle: 'owned:new' } });
  await click(app, app.q('.nudge-cta'));
  assert.ok(lastCall(app, 'upgrade_circle'));
});

// ── settings sheets ────────────────────────────────────────────────────────────────────────────
const openSettingsRow = async (app, re) => {
  await tab(app, 'you');
  await click(app, '#tb-right button.icon-btn');
  await click(app, app.qa('#modal-root .set-row').find((r) => re.test(r.textContent)));
};
const modalBtn = (app, re) => [...app.qa('#modal-root button')].find((b) => re.test(b.textContent));
const RELAY = (over = {}) => ({ node_hex: HEX('e'), name: 'Home relay', active: true, is_s3: false, is_default: false, reachable: true, hosted: false, ...over });

test('relays: each configured relay can be deactivated, made default, renamed and deleted', async () => {
  const { app } = await boot({ be: { relays: [RELAY()] } });
  await openSettingsRow(app, /Relays/);
  assert.match(app.q('#modal-root').textContent, /Home relay/);
  assert.match(app.q('#modal-root').textContent, /Reachable/i);
  await click(app, modalBtn(app, /^Deactivate$/));
  assert.equal(lastCall(app, 'forget_relay').args.nodeHex, HEX('e'));
  await click(app, modalBtn(app, /Make default/i));
  assert.equal(lastCall(app, 'set_default_relay').args.nodeHex, HEX('e'));
  app.ctx.__prompt = '  Studio  ';
  await click(app, modalBtn(app, /^Rename$/));
  assert.deepEqual(J(lastCall(app, 'rename_relay').args), { nodeHex: HEX('e'), name: 'Studio' });
  await click(app, modalBtn(app, /^Delete$/));
  assert.equal(lastCall(app, 'erase_relay').args.nodeHex, HEX('e'));
});

test('relays: a deactivated relay offers Reactivate; a default one offers to unset', async () => {
  const off = await boot({ be: { relays: [RELAY({ active: false })] } });
  await openSettingsRow(off.app, /Relays/);
  assert.match(off.app.q('#modal-root').textContent, /config kept|Deactivated/i);
  await click(off.app, modalBtn(off.app, /Reactivate/i));
  assert.equal(lastCall(off.app, 'reactivate_relay').args.nodeHex, HEX('e'));
  const def = await boot({ be: { relays: [RELAY({ is_default: true })] } });
  await openSettingsRow(def.app, /Relays/);
  await click(def.app, modalBtn(def.app, /Unset default/i));
  assert.equal(lastCall(def.app, 'set_default_relay').args.nodeHex, '');
});

test('relays: adopting a relay validates the node id first', async () => {
  const { app } = await boot();
  await openSettingsRow(app, /Relays/);
  const input = app.qa('#modal-root input').find((i) => /node|relay/i.test(i.placeholder));
  input.value = 'too short';
  await click(app, modalBtn(app, /Add Haven relay/i));
  assert.equal(lastCall(app, 'adopt_relay'), undefined);
  input.value = HEX('9');
  await click(app, modalBtn(app, /Add Haven relay/i));
  assert.equal(lastCall(app, 'adopt_relay').args.nodeHex, HEX('9'));
});

test('relays: hosting starts and stops, and shows the link and live tunnel while hosting', async () => {
  const idle = await boot();
  await openSettingsRow(idle.app, /Relays/);
  await click(idle.app, modalBtn(idle.app, /Start hosting/i));
  assert.ok(lastCall(idle.app, 'start_hosting'));

  const on = await boot({ be: { relay_status: { hosting: true, started: true, internet_active: true, has_relay: true, relay_active: true, relay_link: HEX('7'), live_media_url: 'https://a.trycloudflare.com', live_derp_url: 'https://b.trycloudflare.com', path_routed: false } } });
  await openSettingsRow(on.app, /Relays/);
  const m = on.app.q('#modal-root').textContent;
  assert.match(m, new RegExp(HEX('7')));
  assert.match(m, /a\.trycloudflare/);
  assert.match(m, /b\.trycloudflare/, 'a dual tunnel shows both origins');
  await click(on.app, modalBtn(on.app, /Stop hosting/i));
  assert.ok(lastCall(on.app, 'stop_hosting'));

  const routed = await boot({ be: { relay_status: { hosting: true, started: true, internet_active: true, relay_link: null, live_media_url: 'https://one.example', live_derp_url: null, path_routed: true } } });
  await openSettingsRow(routed.app, /Relays/);
  assert.match(routed.app.q('#modal-root').textContent, /one\.example/);
});

test('relays: the front-door mode and URLs are saved together; token entry follows the mode', async () => {
  const { app } = await boot();
  await openSettingsRow(app, /Relays/);
  const radios = app.qa('#modal-root input[type="radio"]');
  assert.equal(radios.length, 3);
  const tokenIn = app.qa('#modal-root input[type="password"]')[0];
  assert.ok(tokenIn.disabled, 'auto mode needs no token');
  radios[1].checked = true; radios[1].dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  assert.ok(!tokenIn.disabled, 'bundled mode takes a token');
  tokenIn.value = ' tok ';
  app.qa('#modal-root input').find((i) => i.placeholder === 'https://relay.example.com').value = ' https://r.example ';
  await click(app, modalBtn(app, /Save front door/i));
  const a = lastCall(app, 'set_relay_public_settings').args;
  assert.equal(a.frontDoor, 'bundled');
  assert.equal(a.autoTunnel, false);
  assert.equal(a.publicUrl, 'https://r.example');
  assert.equal(a.tunnelToken, 'tok');
  radios[2].checked = true; radios[2].dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  assert.ok(tokenIn.disabled, 'manual mode has no token either');
});

test('relays: media limits and always-on options persist through the backend', async () => {
  const { app } = await boot();
  await openSettingsRow(app, /Relays/);
  const sels = app.qa('#modal-root select');
  sels[0].value = '90'; sels[0].onchange();
  await app.settle();
  assert.deepEqual(J(lastCall(app, 'set_relay_media_limits').args), { maxAgeDays: 90, maxBytes: 32 * 1024 ** 3 });
  const boxes = app.qa('#modal-root input[type="checkbox"]');
  const login = boxes[0], host = boxes[1];
  login.checked = true; host.checked = true;
  await click(app, modalBtn(app, /^Save$/));
  assert.deepEqual(J(lastCall(app, 'set_autostart').args), { loginItem: true, hostOnLaunch: true });
});

test('relays: deleted relays can be restored or forgotten for good', async () => {
  const { app } = await boot({ be: { erased_relays: [{ entry: { hex: HEX('4'), name: 'Old one' }, circles: ['default'], was_default: false, erased_at: 1 }] } });
  await openSettingsRow(app, /Relays/);
  assert.match(app.q('#modal-root details').textContent, /Old one/);
  await click(app, modalBtn(app, /^Restore$/));
  assert.equal(lastCall(app, 'restore_erased_relay').args.nodeHex, HEX('4'));
  await click(app, modalBtn(app, /^Forget$/));
  assert.equal(lastCall(app, 'drop_erased_relay').args.nodeHex, HEX('4'));
});

test('relays: an S3 bucket is added with its fields; a failure toasts instead of throwing', async () => {
  const { app } = await boot({ be: { add_s3_relay: () => { throw new Error('bad creds'); } } });
  await openSettingsRow(app, /Relays/);
  const f = (ph) => app.qa('#modal-root input').find((i) => i.placeholder === ph);
  const byPh = (re) => app.qa('#modal-root input').find((i) => re.test(i.placeholder));
  byPh(/endpoint|https:\/\/.*s3|r2/i).value = ' https://s3.example ';
  byPh(/bucket/i).value = 'bkt';
  byPh(/access/i).value = 'AK';
  app.qa('#modal-root input[type="password"]').at(-1).value = 'SECRET';
  void f;
  await click(app, modalBtn(app, /Add S3/i));
  const a = lastCall(app, 'add_s3_relay').args;
  assert.equal(a.endpoint, 'https://s3.example');
  assert.equal(a.bucket, 'bkt');
  assert.equal(a.secretKey, 'SECRET');
  assert.equal(a.setDefault, true);
  assert.match(app.q('#toast').textContent, /bad creds/);
});

test('identities: lists, switches (with confirmation), renames, creates, imports and removes', async () => {
  const ids = [{ node_hex: HEX('a'), label: 'Main', active: true }, { node_hex: HEX('c'), label: 'Side', active: false }];
  const { app } = await boot({ be: { identities: ids, switch_identity: null, add_identity: HEX('d'), import_identity: HEX('f') } });
  await openSettingsRow(app, /Identities/);
  assert.match(app.q('#modal-root').textContent, /Main/);
  assert.match(app.q('#modal-root').textContent, /Active/i);
  assert.equal(app.qa('#modal-root button').filter((b) => /^Switch$/i.test(b.textContent)).length, 1, 'only the inactive one can be switched to');
  app.ctx.__confirm = false;
  await click(app, modalBtn(app, /^Switch$/i));
  assert.equal(lastCall(app, 'switch_identity'), undefined);
  app.ctx.__confirm = true;
  await click(app, modalBtn(app, /^Switch$/i));
  assert.equal(lastCall(app, 'switch_identity').args.nodeHex, HEX('c'));
  await click(app, modalBtn(app, /^Remove$/i));
  assert.equal(lastCall(app, 'remove_identity').args.nodeHex, HEX('c'));

  await click(app, [...app.qa('#modal-root .list-item')][0].querySelector('button.ghost'));      // rename
  app.q('#modal-root input').value = 'Renamed';
  await click(app, modalBtn(app, /^Save$/));
  assert.deepEqual(J(lastCall(app, 'rename_identity').args), { nodeHex: HEX('a'), label: 'Renamed' });

  await click(app, modalBtn(app, /New identity/i));
  app.q('#modal-root input').value = 'Work';
  await click(app, modalBtn(app, /^Create$/));
  assert.equal(lastCall(app, 'add_identity').args.label, 'Work');

  await click(app, modalBtn(app, /^Import$/i));
  const [lab, seed] = app.qa('#modal-root input');
  lab.value = 'Phone'; seed.value = ' haven-seed:AAAA ';
  await click(app, app.qa('#modal-root .btn.primary').at(-1));
  assert.deepEqual(J(lastCall(app, 'import_identity').args), { label: 'Phone', seedB64: 'haven-seed:AAAA' });
});

test('devices: a not-yet-linked device can become primary or ask to be linked', async () => {
  const { app } = await boot();
  await openSettingsRow(app, /Devices/);
  assert.match(app.q('#modal-root').textContent, /isn.t linked yet/i);
  await click(app, modalBtn(app, /Make .*primary/i));
  assert.ok(lastCall(app, 'enable_device_roster'));
  await openSettingsRow(app, /Devices/);
  await click(app, modalBtn(app, /linked device|link/i));
  assert.ok(lastCall(app, 'request_device_enrollment'));
});

test('devices: a primary lists devices, revokes with confirmation, and mints a link code', async () => {
  const roster = { enabled: true, this_device_authorized: true, devices: [
    { node_hex: ME, name: 'Primary (this account\'s master key)', is_this_device: true, is_primary: true },
    { node_hex: HEX('9'), name: 'Laptop', is_this_device: false, is_primary: false },
  ] };
  const { app } = await boot({ be: { device_roster: roster, enroll_mint_ticket: 'haven-enroll:TICKET123', enroll_pending: [{ device_hex: HEX('8'), name: 'Tablet' }], enroll_approve: null } });
  await openSettingsRow(app, /Devices/);
  assert.match(app.q('#modal-root').textContent, /Laptop/);
  assert.match(app.q('#modal-root').textContent, /Tablet/);
  assert.equal(app.qa('#modal-root button').filter((b) => /^Revoke$/i.test(b.textContent)).length, 1, 'the primary key can never be revoked');
  app.ctx.__confirm = false;
  await click(app, modalBtn(app, /^Revoke$/i));
  assert.equal(lastCall(app, 'revoke_device'), undefined);
  app.ctx.__confirm = true;
  await click(app, modalBtn(app, /^Revoke$/i));
  assert.equal(lastCall(app, 'revoke_device').args.nodeHex, HEX('9'));
  await click(app, modalBtn(app, /^Approve$/i));
  assert.equal(lastCall(app, 'enroll_approve').args.deviceHex, HEX('8'));
  await click(app, modalBtn(app, /^Dismiss$/i));
  assert.equal(lastCall(app, 'enroll_reject').args.deviceHex, HEX('8'));
  await click(app, modalBtn(app, /isn.t my primary/i));
  assert.ok(lastCall(app, 'step_down_as_primary'));
  await click(app, modalBtn(app, /secure|Add a device|Add device/i));
  assert.match(app.q('#modal-root').textContent, /TICKET123/);
  assert.ok(app.q('#modal-root .qr-box svg'), 'the ticket is drawn as a QR');
});

test('devices: minting a link code can fail and says why', async () => {
  const roster = { enabled: true, this_device_authorized: true, devices: [] };
  const { app } = await boot({ be: { device_roster: roster, enroll_mint_ticket: () => { throw new Error('no seed'); } } });
  await openSettingsRow(app, /Devices/);
  await click(app, modalBtn(app, /secure|Add a device|Add device/i));
  assert.match(app.q('#toast').textContent, /no seed/);
});

test('devices: relay-history card shows progress while running and a summary when done', async () => {
  const running = { state: 'scanning', circles_done: 1, circles_total: 3, entries_checked: 10, entries_found: 40, fraction: 0.25 };
  const { app } = await boot({ be: { device_roster: { enabled: false, this_device_authorized: false, devices: [] }, relay_history_status: running } });
  await openSettingsRow(app, /Devices/);
  const m = app.q('#modal-root');
  assert.ok(m.querySelector('progress'));
  assert.match(m.textContent, /1.*3/);
  app.ctx.__confirm = true;
  await click(app, modalBtn(app, /^Cancel$/i));
  assert.ok(lastCall(app, 'relay_history_cancel'));

  const done = await boot({ be: { relay_history_status: { state: 'done', outcome: 'added', posts_added: 12, media_done: 3, media_missing: 2, relay_errors: 1, retention_caveat: true } } });
  await openSettingsRow(done.app, /Devices/);
  assert.match(done.app.q('#modal-root').textContent, /12/);
  await click(done.app, [...done.app.qa('#modal-root button')].find((b) => /^Dismiss$/i.test(b.textContent)));
  assert.ok(lastCall(done.app, 'relay_history_dismiss'));
  const start = await boot({ be: { relay_history_status: { state: 'idle' } } });
  await openSettingsRow(start.app, /Devices/);
  await click(start.app, [...start.app.qa('#modal-root button')].find((b) => /history|relays/i.test(b.textContent) && !/Make|link/i.test(b.textContent)));
  assert.ok(lastCall(start.app, 'relay_history_start'));
  const sat = await boot({ be: { relay_history_status: { state: 'idle', unavailable: 'satellite' } } });
  await openSettingsRow(sat.app, /Devices/);
  assert.match(sat.app.q('#modal-root').textContent, /satellite|low.data/i);
});

test('advanced: shows the node id, runs the self-test, and Start over asks first', async () => {
  const { app } = await boot();
  await openSettingsRow(app, /Advanced/);
  assert.match(app.q('#modal-root').textContent, new RegExp('node id: ' + ME));
  await click(app, modalBtn(app, /self-test/i));
  assert.match(app.q('#modal-root').textContent, /passed|checks/i);
  app.q('#modal-root').replaceChildren();
  await openSettingsRow(app, /Advanced/);
  await click(app, modalBtn(app, /^Start over$/i));
  assert.equal(lastCall(app, 'reset'), undefined, 'a confirmation comes first');
  assert.match(app.q('#modal-root').textContent, /Start over\?/i);
});

test('advanced: storage limits save, unused media is cleaned, and the manage-media screen deletes', async () => {
  const inv = [
    { reference: 'img_big', bytes: 5_000_000, mtime_ms: 1, kind: 'image', circle_name: 'My Circle', snippet: 'a beach', is_orphan: false, is_pinned: false },
    { reference: 'vid_pin', bytes: 2_000_000, mtime_ms: 1, kind: 'video', circle_name: 'Work', snippet: null, is_orphan: false, is_pinned: true },
    { reference: 'img_orphan', bytes: 1_000, mtime_ms: 1, kind: 'image', circle_name: 'My Circle', snippet: null, is_orphan: true, is_pinned: false },
  ];
  const { app } = await boot({ be: { media_inventory: inv, media_delete_selected: 5_000_000, media_cleanup: { bytes: 1000, files: 1 }, media_pinned_count: 1 } });
  await openSettingsRow(app, /Advanced/);
  const sels = app.qa('#modal-root select.pill-field');
  sels[0].value = '30'; sels[0].onchange(); await app.settle();
  assert.deepEqual(J(lastCall(app, 'set_media_limits').args), { days: 30, gb: 0 });
  await click(app, modalBtn(app, /Clean up unused/i));
  assert.match(app.q('#modal-root').textContent, /Freed|1 file/i);

  await click(app, modalBtn(app, /Manage media/i));
  const m = app.q('#modal-root');
  assert.equal(m.querySelectorAll('.list-item').length, 3);
  assert.match(m.textContent, /a beach/);
  assert.match(m.textContent, /Not linked|unused/i, 'orphans are labelled');
  assert.equal(m.querySelectorAll('input[type="checkbox"]').length, 2, 'the pinned row has no checkbox');
  const box = m.querySelectorAll('input[type="checkbox"]')[0];
  box.checked = true; box.onchange();
  await click(app, [...m.querySelectorAll('button.primary')].find((b) => /Remove/i.test(b.textContent)));
  assert.deepEqual(J(lastCall(app, 'media_delete_selected').args.refs), ['img_big']);
  await click(app, [...app.qa('#modal-root .list-item button')].find((b) => /^Keep$/i.test(b.textContent)));
  assert.equal(lastCall(app, 'media_pin').args.refs[0], 'img_big');
  const pinnedRow = [...app.qa('#modal-root .list-item')].find((r) => /Work/.test(r.textContent));
  await click(app, pinnedRow.querySelector('button'));
  assert.equal(lastCall(app, 'media_unpin').args.refs[0], 'vid_pin');
});

test('privacy & media: the toggles write through to the backend', async () => {
  const { app } = await boot();
  await openSettingsRow(app, /Privacy/);
  const boxes = app.qa('#modal-root input[type="checkbox"], #modal-root input[type="radio"], #modal-root select');
  assert.ok(boxes.length >= 2, 'controls are rendered');
  const first = app.qa('#modal-root input[type="checkbox"]')[0];
  first.checked = true;
  first.dispatchEvent(new app.ctx.Event('change', { bubbles: true }));
  await app.settle();
  assert.ok(lastCall(app, 'set_privacy_prefs'), 'a privacy toggle is persisted');
});

test('scheduled: lists queued sends and cancels one', async () => {
  const items = [{ id: 'sch-1', kind: 'post', circle_id: 'default', body: 'later post', media_count: 2, has_music: true, send_at_ms: NOW + 3_600_000 }];
  const { app } = await boot({ be: { scheduled: items } });
  await openSettingsRow(app, /Scheduled/);
  assert.match(app.q('#modal-root').textContent, /later post/);
  await click(app, [...app.qa('#modal-root button')].find((b) => /Cancel|Delete|Remove/i.test(b.textContent)));
  assert.equal(lastCall(app, 'cancel_scheduled').args.id, 'sch-1');
});

// ── Haven-first ICE policy (calls) ─────────────────────────────────────────────────────────────
test('calls: public STUN is the last resort, never a companion to a working Haven relay', async () => {
  const { app } = await boot();
  const urls = () => J(app.ev('iceServers()')).flatMap((s) => [].concat(s.urls));
  assert.ok(urls().some((u) => u.includes('google')), 'no Haven relay at all: Google STUN is the fallback');
  app.ctx.__havenFabricDerp = ['https://derp.example'];
  assert.ok(!urls().some((u) => u.includes('google')), 'a configured fabric carries the call — no third party');
  app.ctx.__havenFabricDerp = [];
  app.ctx.__havenFabricTurn = { urls: ['turn:turn.example.com:3478'], user: 'haven', pass: 'pw' };
  const servers = J(app.ev('iceServers()'));
  assert.deepEqual(servers[0], { urls: ['turn:turn.example.com:3478'], username: 'haven', credential: 'pw' });
  assert.deepEqual(servers[1], { urls: ['stun:turn.example.com:3478'] }, 'the TURN host doubles as our own STUN');
  assert.ok(!urls().some((u) => u.includes('google')), 'a public TURN means Google is not needed');
  app.ctx.__havenFabricTurn = { urls: ['turn:10.0.0.5:3478'], user: 'haven', pass: 'pw' };
  assert.ok(urls().some((u) => u.includes('google')), 'a private-address TURN with no fabric is not usable from outside');
});

// ── first run: onboarding, terms, seedless linking ─────────────────────────────────────────────
const fresh = (over = {}) => loadApp({ backend: { needs_onboarding: true, ...over }, local: {} });
const overlay = (app) => app.q('#onboard-overlay');
const obBtn = (app, re) => [...overlay(app).querySelectorAll('button')].find((b) => re.test(b.textContent));

test('onboarding: a fresh install shows the welcome with three clearly different paths and touches no engine command', async () => {
  const app = await fresh();
  assert.ok(overlay(app));
  const choices = overlay(app).querySelectorAll('button.btn.ghost');
  assert.equal(choices.length, 3, 'new / add this device / move the account');
  assert.deepEqual(app.commands().filter((c) => !['needs_onboarding'].includes(c)), [], 'no engine command before an identity exists');
});

test('onboarding: new-to-Haven walks name → how it works → ground rules, then creates the identity', async () => {
  const app = await fresh({ onboard_create: null });
  await click(app, overlay(app).querySelectorAll('button.btn.ghost')[0]);
  const next = () => obBtn(app, /Continue|agree/i);
  assert.ok(next().disabled, 'a name is required to continue');
  const name = overlay(app).querySelector('input.pill-field');
  name.value = 'Ada';
  name.dispatchEvent(new app.ctx.Event('input', { bubbles: true }));
  assert.ok(!next().disabled);
  await click(app, [...overlay(app).querySelectorAll('.emoji-cell')][3]);          // pick an emoji (redraws)
  assert.equal(overlay(app).querySelector('input.pill-field').value, 'Ada', 'the typed name survives a redraw');
  await click(app, next());                                                       // → how it works
  assert.match(overlay(app).textContent, /Private by design|private/i);
  await click(app, next());                                                       // → ground rules
  assert.match(overlay(app).textContent, /rules/i);
  assert.equal(lastCall(app, 'onboard_create'), undefined, 'nothing is created before agreeing');
  await click(app, next());                                                       // agree
  assert.ok(lastCall(app, 'onboard_create'));
  assert.equal(app.localStorage.getItem('haven-terms-accepted-version'), '1', 'agreeing is recorded');
  const stash = JSON.parse(app.localStorage.getItem('haven-pending-profile'));
  assert.equal(stash.name, 'Ada');
  assert.equal(stash.emoji, '⭐️', 'the chosen emoji (4th in the palette) rides with the stashed profile');
});

test('onboarding: a failed create is reported and does not strand the user', async () => {
  const app = await fresh({ onboard_create: () => { throw new Error('disk full'); } });
  await click(app, overlay(app).querySelectorAll('button.btn.ghost')[0]);
  const name = overlay(app).querySelector('input.pill-field');
  name.value = 'Ada'; name.dispatchEvent(new app.ctx.Event('input', { bubbles: true }));
  for (let i = 0; i < 3; i++) await click(app, obBtn(app, /Continue|agree/i));
  assert.match(app.q('#toast').textContent, /disk full/);
  assert.ok(overlay(app), 'the screen stays up');
});

test('onboarding: linking a device uses the secure ticket path for haven-enroll codes and the legacy path for seeds', async () => {
  const app = await fresh({ onboard_link_seedless: null, onboard_link: null });
  await click(app, overlay(app).querySelectorAll('button.btn.ghost')[1]);          // add this device
  const box = overlay(app).querySelector('input.field-capsule');
  await click(app, obBtn(app, /Add this device/i));
  assert.equal(lastCall(app, 'onboard_link'), undefined, 'an empty box asks for a code first');
  assert.match(app.q('#toast').textContent, /paste/i);
  box.value = ' haven-enroll:ABC ';
  await click(app, obBtn(app, /Add this device/i));
  assert.deepEqual(J(lastCall(app, 'onboard_link_seedless').args), { ticket: 'haven-enroll:ABC' });
  box.value = 'haven-seed:XYZ';
  await click(app, obBtn(app, /Add this device/i));
  assert.deepEqual(J(lastCall(app, 'onboard_link').args), { code: 'haven-seed:XYZ' });
  assert.equal(app.localStorage.getItem('haven-terms-accepted-version'), '1', 'a linked device inherits agreement');
});

test('onboarding: "move the account" words the button differently, and Back returns to the choices', async () => {
  const app = await fresh();
  await click(app, overlay(app).querySelectorAll('button.btn.ghost')[2]);
  assert.ok(obBtn(app, /Move/i), 'the move path is labelled for what it does');
  await click(app, obBtn(app, /Back/i));
  assert.equal(overlay(app).querySelectorAll('button.btn.ghost').length, 3);
});

test('onboarding: link failures are surfaced as a toast', async () => {
  const app = await fresh({ onboard_link: () => { throw new Error('bad code'); } });
  await click(app, overlay(app).querySelectorAll('button.btn.ghost')[1]);
  overlay(app).querySelector('input.field-capsule').value = 'garbage';
  await click(app, obBtn(app, /Add this device/i));
  assert.match(app.q('#toast').textContent, /bad code/);
});

test('terms gate: an existing identity that never agreed must agree before the app loads', async () => {
  const { be } = fakeBackend({});
  const app = await loadApp({ backend: be, local: {} });
  assert.ok(overlay(app), 'the gate is up');
  assert.ok(!app.commands().includes('bootstrap'), 'nothing loads behind the gate');
  await click(app, obBtn(app, /agree/i));
  assert.equal(app.q('#onboard-overlay'), null, 'the gate is removed');
  assert.ok(app.commands().includes('bootstrap'), 'agreeing continues into boot');
  assert.equal(app.localStorage.getItem('haven-terms-accepted-version'), '1');
});

test('terms: acceptance survives broken storage through the in-memory mirror', async () => {
  const { be } = fakeBackend({});
  const app = await loadApp({ backend: be, local: {} });
  app.localStorage.setItem = () => { throw new Error('quota'); };
  app.localStorage.getItem = () => { throw new Error('denied'); };
  assert.equal(app.ev('Terms.accepted()'), false);
  app.ev('Terms.accept()');
  assert.equal(app.ev('Terms.accepted()'), true, 'a gate that cannot be passed is worse than none');
});

test('onboarding: a profile typed before the restart is applied on the first real boot', async () => {
  const { be, s } = fakeBackend({});
  const app = await loadApp({ backend: be, local: { 'haven-terms-accepted-version': '99', 'haven-named-nudged': '1', 'haven-pending-profile': JSON.stringify({ name: 'Newbie', emoji: '🌸', avatar: '' }) } });
  const c = lastCall(app, 'set_profile');
  assert.equal(c.args.name, 'Newbie');
  assert.equal(c.args.emoji, '🌸');
  assert.equal(s.profile.name, 'Newbie');
  assert.equal(app.localStorage.getItem('haven-pending-profile'), null, 'consumed once');
});

test('onboarding: if applying the profile fails it is kept for the next launch', async () => {
  const { be } = fakeBackend({});
  be.set_profile = () => { throw new Error('engine not ready'); };
  const app = await loadApp({ backend: be, local: { 'haven-terms-accepted-version': '99', 'haven-named-nudged': '1', 'haven-pending-profile': JSON.stringify({ name: 'Newbie' }) } });
  assert.equal(JSON.parse(app.localStorage.getItem('haven-pending-profile')).name, 'Newbie');
});

test('first boot with no name sends the user to the You tab exactly once', async () => {
  const { be } = fakeBackend({ state: { profile: { name: '', bio: '', link: '', emoji: '', avatar: '' } } });
  const app = await loadApp({ backend: be, local: { 'haven-terms-accepted-version': '99' } });
  assert.ok(app.q('#view-you').classList.contains('active'));
  assert.equal(app.localStorage.getItem('haven-named-nudged'), '1');
  const again = await loadApp({ backend: be, local: { 'haven-terms-accepted-version': '99', 'haven-named-nudged': '1' } });
  assert.ok(again.q('#view-circle').classList.contains('active'), 'never nagged twice');
});

test('seedless linking: a device waiting for its grant shows the waiting screen and relaunches when granted', async () => {
  const { be } = fakeBackend({});
  be.seedless_status = { seedless: true, linked: false, linking: true };
  be.finish_enroll = null;
  const app = await loadApp({ backend: be, local: { 'haven-terms-accepted-version': '99' } });
  assert.ok(overlay(app));
  assert.ok(!app.commands().includes('bootstrap'), 'nothing loads while linking');
  assert.match(overlay(app).textContent, /Waiting/i);
  await app.emit('haven:enrolled', {});
  assert.ok(lastCall(app, 'finish_enroll'), 'the grant landing relaunches into the linked app');
});

test('demo mode skips the relay nudge', async () => {
  const { be } = fakeBackend({ state: { circles: [{ id: 'default', name: 'My Circle', member_count: 9 }] } });
  be.demo_mode = true;
  const app = await loadApp({ backend: be, local: { 'haven-terms-accepted-version': '99', 'haven-named-nudged': '1' } });
  assert.ok(!app.q('.nudge-banner'));
});

// ── stories ─────────────────────────────────────────────────────────────────────────────────────
const storyFeed = () => [
  post({ id: 'bs1', is_me: false, author_short: BO.slice(0, 8), author_name: 'Bo', story: true, body: 'bo one', media: ['img_b1'], created_at: NOW - 3 * 3_600_000 }),
  post({ id: 'bs2', is_me: false, author_short: BO.slice(0, 8), author_name: 'Bo', story: true, body: 'bo two', media: ['img_b2'], created_at: NOW - 2 * 3_600_000 }),
  post({ id: 'ms1', is_me: true, author_name: 'You', story: true, body: 'mine', media: ['img_m1'], created_at: NOW - 1 * 3_600_000 }),
];
const storyBoot = (be = {}) => boot({ state: { ...withDm().state, feeds: { default: storyFeed() } }, be });
const bars = (app) => app.qa('#modal-root .seg');

test('stories: the tray has one ring per author; tapping opens the viewer at their first story', async () => {
  const { app } = await storyBoot();
  const rings = app.qa('.story-ring.cover');
  assert.equal(rings.length, 2, 'Bo and me');
  assert.match(rings.map((r) => r.textContent).join('|'), /Bo/);
  await click(app, rings.find((r) => /Bo/.test(r.textContent)));
  assert.ok(app.q('#modal-root .story-stage'));
  assert.match(app.q('#modal-root .story-top').textContent, /Bo/);
  assert.equal(bars(app).length, 2, 'two segments for Bo\'s two stories');
  assert.equal(bars(app).filter((b) => b.classList.contains('on')).length, 1);
});

test('stories: tap zones, arrow keys and Escape navigate and close the viewer', async () => {
  const { app } = await storyBoot();
  await click(app, app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  assert.equal(bars(app).filter((b) => b.classList.contains('on')).length, 1);
  await app.winEvent('keydown', { key: 'ArrowDown' });                 // next story (same author)
  assert.equal(bars(app).filter((b) => b.classList.contains('on')).length, 2);
  await app.winEvent('keydown', { key: 'ArrowUp' });                   // previous story
  assert.equal(bars(app).filter((b) => b.classList.contains('on')).length, 1);
  await app.winEvent('keydown', { key: 'ArrowLeft' });                 // previous author: me (most recent poster is first)
  assert.match(app.q('#modal-root .story-top').textContent, /You/);
  await app.winEvent('keydown', { key: 'ArrowLeft' });                 // already first: stays
  assert.match(app.q('#modal-root .story-top').textContent, /You/);
  await app.winEvent('keydown', { key: 'ArrowRight' });                // next author: Bo, at their first story
  assert.match(app.q('#modal-root .story-top').textContent, /Bo/);
  await app.winEvent('keydown', { key: 'ArrowRight' });                // past the last author → closes
  assert.equal(app.q('#modal-root').children.length, 0, 'the viewer closes at the end');
});

test('stories: stills auto-advance after five seconds', async () => {
  const { app } = await storyBoot();
  await click(app, app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  assert.equal(bars(app).filter((b) => b.classList.contains('on')).length, 1);
  await app.timers.advance(4900);
  assert.equal(bars(app).filter((b) => b.classList.contains('on')).length, 1, 'not yet');
  await app.timers.advance(200);
  assert.equal(bars(app).filter((b) => b.classList.contains('on')).length, 2, 'advanced to the second story');
});

test('stories: closing the viewer stops its timers and key handling', async () => {
  const { app } = await storyBoot();
  await click(app, app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  app.q('#modal-root').replaceChildren();          // closed from outside (the observer cleans up)
  await app.settle();
  await app.winEvent('keydown', { key: 'ArrowRight' });
  assert.equal(app.q('#modal-root').children.length, 0, 'a closed viewer does not reopen or react to keys');
});

test("stories: replying to someone else's story sends them a private DM carrying the story pointer", async () => {
  const { app } = await storyBoot();
  await click(app, app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  const input = app.q('#modal-root .story-bottom input');
  assert.match(input.placeholder, /Bo/);
  await click(app, [...app.qa('#modal-root .story-bottom button')].find((b) => /Send/i.test(b.textContent)));
  assert.equal(lastCall(app, 'send_dm'), undefined, 'an empty reply sends nothing');
  input.value = '  love this  ';
  await click(app, [...app.qa('#modal-root .story-bottom button')].find((b) => /Send/i.test(b.textContent)));
  const c = lastCall(app, 'send_dm').args;
  assert.equal(c.circleId, DM);
  assert.ok(c.body.startsWith('love this\n'), c.body);
  assert.equal(app.ev(`DeepLink.story(${JSON.stringify(c.body.split('\n')[1])})`).postId, 'bs1', 'the reply points at that story');
  assert.equal(input.value, '');
});

test('stories: a reply to someone who is not a contact is refused with a message', async () => {
  const { app } = await boot({ state: { feeds: { default: storyFeed() } } });          // no contacts
  await click(app, app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  app.q('#modal-root .story-bottom input').value = 'hi';
  await click(app, [...app.qa('#modal-root .story-bottom button')].find((b) => /Send/i.test(b.textContent)));
  assert.equal(lastCall(app, 'send_dm'), undefined);
  assert.ok(app.q('#toast').textContent.length > 0);
});

test('stories: my own story offers Keep, which toggles through the backend', async () => {
  const { app } = await storyBoot({ toggle_kept_story: true });
  await click(app, app.qa('.story-ring.cover').find((r) => /You/.test(r.textContent)));
  const keep = app.q('#modal-root .story-bottom .chip');
  assert.notEqual(keep.style.display, 'none');
  assert.equal(app.q('#modal-root .story-bottom input').parentNode.style.display, 'none', 'no reply box on my own story');
  await click(app, keep);
  const entry = lastCall(app, 'toggle_kept_story').args.entry;
  assert.equal(entry.id, 'ms1');
  assert.deepEqual(J(entry.media), ['img_m1']);
  assert.ok(keep.classList.contains('tint-pink'), 'kept state is shown');
});

test("stories: another person's story has no Keep control", async () => {
  const { app } = await storyBoot();
  await click(app, app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  assert.equal(app.q('#modal-root .story-bottom .chip').style.display, 'none');
});

test('stories: a song attached to a story is resolved once and not played in data-saver mode', async () => {
  const feed = storyFeed();
  feed[0].music = { catalog_id: 'c1', title: 'Tune', artist: 'Band', artwork_url: '', duration_ms: 1000 };
  const { app } = await boot({ state: { ...withDm().state, feeds: { default: feed } }, be: { music_resolve: { preview_url: 'https://audio.example/x.m4a' } } });
  await click(app, app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  assert.equal(app.calls.filter((c) => c.cmd === 'music_resolve').length, 1);
  assert.equal(lastCall(app, 'music_resolve').args.title, 'Tune');
  const saver = await boot({ state: { ...withDm().state, feeds: { default: feed } }, be: { privacy_prefs: { notification_detail: 'full', super_data_saver: true, send_original: false }, music_resolve: { preview_url: 'https://audio.example/x.m4a' } } });
  await click(saver.app, saver.app.qa('.story-ring.cover').find((r) => /Bo/.test(r.textContent)));
  assert.equal(lastCall(saver.app, 'music_resolve'), undefined, 'the data saver never fetches the song');
});

test('stories: a story reply card in a DM opens the viewer, or explains that it expired', async () => {
  const link = (id) => `see this haven://s/default/${id}`;
  const dmMsgs = [
    post({ id: 'r1', is_me: false, author_short: BO.slice(0, 8), author_name: 'Bo', body: link('bs1') }),
    post({ id: 'r2', is_me: false, author_short: BO.slice(0, 8), author_name: 'Bo', body: link('gone'), created_at: NOW - 500 }),
  ];
  const { app } = await boot({ state: { ...withDm().state, feeds: { default: storyFeed() }, dms: { [DM]: dmMsgs, default: storyFeed() } } });
  await tab(app, 'messages');
  await click(app, '.thread-item');
  const cards = app.qa('.story-reply-card');
  assert.ok(cards.length >= 1, 'story pointers render as cards');
});

// ── composer ────────────────────────────────────────────────────────────────────────────────────
const composerMenu = async (app) => click(app, '#composer-slot .composer-plus');
const composerItem = (app, re) => menuBtn(app, re);

test('composer: the + menu offers every attachment path, in the macOS order', async () => {
  const { app } = await boot();
  await composerMenu(app);
  const labels = app.qa('#menu-root button').map((b) => b.textContent.trim());
  assert.match(labels.join('|'), /Photo or Video.*Camera.*Voice.*song.*Disappears.*Send later/i);
});

test('composer: a post carries its attachment, thumb companion, music and retention to the backend', async () => {
  const { app } = await boot();
  const add = app.ev('state.composerAdd');
  await add('img_one', false, false, 'img_thumb');
  assert.equal(app.qa('#composer-slot .attach-preview .chip').length, 1);
  await composerMenu(app);
  await click(app, composerItem(app, /Disappears/i));
  await click(app, composerItem(app, /1 day|day/i));
  assert.match(app.q('#composer-slot').textContent, /1d/, 'the chosen lifetime is shown as a chip');
  app.q('#composer-slot textarea').value = 'with a photo';
  await click(app, '.composer-send');
  const c = lastCall(app, 'post').args;
  assert.equal(c.body, 'with a photo');
  assert.deepEqual(J(c.media), ['img_one', 'thumb:img_one:img_thumb']);
  assert.equal(c.retentionSecs, 86400);
  assert.equal(app.qa('#composer-slot .attach-preview .chip').length, 0, 'attachments clear after sending');
  assert.ok(!/1d/.test(app.q('#composer-slot').textContent), 'retention is per-post and resets');
});

test('composer: an attachment can be removed before sending, and a video reveals the mute toggle', async () => {
  const { app } = await boot();
  const add = app.ev('state.composerAdd');
  await add('vid_clip', true, false, null);
  const mute = app.q('#composer-slot .row button.btn');
  assert.notEqual(mute.style.display, 'none', 'a video can be muted');
  await click(app, mute);
  assert.ok(mute.classList.contains('primary'));
  app.q('#composer-slot textarea').value = 'clip';
  await click(app, app.q('#composer-slot .chip .x'));
  assert.equal(app.qa('#composer-slot .chip').length, 0);
  assert.equal(mute.style.display, 'none');
  await click(app, '.composer-send');
  assert.equal(lastCall(app, 'post').args.muteVideo, false, 'removing the video resets the mute choice');
});

test('composer: Enter posts, Shift+Enter does not, and a blank composer posts nothing', async () => {
  const { app } = await boot();
  const ta = app.q('#composer-slot textarea');
  const key = (extra = {}) => ta.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter', ...extra }));
  ta.value = 'hello'; key({ shiftKey: true }); await app.settle();
  assert.equal(lastCall(app, 'post'), undefined);
  key(); await app.settle();
  assert.equal(lastCall(app, 'post').args.body, 'hello');
  assert.match(app.q('#toast').textContent, /posted/i);
});

test('composer: Send later needs content, validates the time, and queues through the backend', async () => {
  const { app } = await boot();
  await composerMenu(app);
  await click(app, composerItem(app, /Send later/i));
  assert.match(app.q('#toast').textContent, /something/i, 'nothing to schedule yet');
  app.q('#composer-slot textarea').value = 'for later';
  await composerMenu(app);
  await click(app, composerItem(app, /Send later/i));
  const dlg = app.q('#modal-root');
  const input = dlg.querySelector('input');
  input.value = '2001-01-01T00:00';
  await click(app, dlg.querySelector('.btn.primary'));
  assert.equal(lastCall(app, 'schedule_message'), undefined, 'a time in the past is refused');
  assert.match(app.q('#toast').textContent, /future/i);
  const d = new Date(Date.now() + 7_200_000), p = (n) => String(n).padStart(2, '0');
  input.value = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  await click(app, dlg.querySelector('.btn.primary'));
  const c = lastCall(app, 'schedule_message').args;
  assert.equal(c.kind, 'post');
  assert.equal(c.body, 'for later');
  assert.ok(c.sendAtMs > Date.now());
  assert.equal(app.q('#composer-slot textarea').value, '', 'the composer clears once scheduled');
});

test('composer: the sync badge appears only when the circle is device-only or still syncing', async () => {
  const { app, be } = await boot({ be: { sync_status: 'local' } });
  await app.timers.advance(2600);
  await app.settle();
  const badge = app.q('#composer-slot .sync-badge');
  assert.ok(!badge.classList.contains('hide'));
  assert.match(badge.textContent, /device/i);
  be.sync_status = 'syncing';
  await app.timers.advance(2600); await app.settle();
  assert.match(app.q('#composer-slot .sync-badge').textContent, /sync/i);
  be.sync_status = 'synced';
  await app.timers.advance(2600); await app.settle();
  assert.ok(app.q('#composer-slot .sync-badge').classList.contains('hide'), 'green says nothing at all');
});

// ── reactions: emoji store and picker ──────────────────────────────────────────────────────────
test('reactions: the quick row learns the emoji you use and the picker records picks', async () => {
  const { app } = await social();
  assert.deepEqual(J(app.ev('frequentEmoji(3)')), ['❤️', '😂', '👍']);
  const card = () => app.q('.card[data-post="bp1"]');
  const quick = () => [...card().querySelectorAll('.quick button')].filter((b) => b.title && /React/i.test(b.title));
  await click(app, quick()[2]);                                          // 👍
  assert.equal(lastCall(app, 'react').args.emoji, '👍');
  assert.equal(app.ev('frequentEmoji(1)')[0], '👍', 'it moves to the front');
  assert.equal(JSON.parse(app.localStorage.getItem('haven-emoji-freq'))['👍'], 1);
  await click(app, card().querySelector('.quick .more'));
  const grid = app.qa('#menu-root .menu button');
  assert.equal(grid.length, 12);
  await click(app, grid.find((b) => b.textContent === '🎉'));
  assert.equal(lastCall(app, 'react').args.emoji, '🎉');
  assert.equal(app.q('#menu-root').children.length, 0, 'the picker closes after a pick');
});

test('reactions: quick-react never removes an existing reaction of mine', async () => {
  const { app } = await social();
  await app.ev('quickReact("default", "bp1", "😂", [{ emoji: "😂", count: 1, mine: true }])');
  assert.equal(lastCall(app, 'react'), undefined);
  assert.equal(lastCall(app, 'unreact'), undefined);
});

test('reactions: a post with many distinct emoji caps the pills but always keeps mine', async () => {
  const many = ['a', 'b', 'c', 'd', 'e', 'f'].map((e, i) => ({ emoji: e, count: 10 - i, mine: false, authors: [] }));
  many.push({ emoji: 'z', count: 1, mine: true, authors: [] });
  const { app } = await boot({ state: { feeds: { default: [post({ reactions: many })] } } });
  const pills = app.qa('.card[data-post="p1"] .react-pill');
  assert.equal(pills.length, 5, 'four chips plus the overflow counter');
  assert.ok([...pills].some((p) => p.classList.contains('mine')), 'my own reaction is never hidden');
  assert.match(pills.at(-1).textContent, /\+3/);
});

// ── media refs and tiles ────────────────────────────────────────────────────────────────────────
test('media refs: kinds are told apart by prefix, including the legacy single-letter schemes', async () => {
  const { app } = await boot();
  const k = (r) => J(app.ev(`[isVideoRef(${JSON.stringify(r)}), isAudioRef(${JSON.stringify(r)}), isFileRef(${JSON.stringify(r)}), isSyntheticMedia(${JSON.stringify(r)})]`));
  assert.deepEqual(k('vid_ab'), [true, false, false, false]);
  assert.deepEqual(k('v:ab'), [true, false, false, false]);
  assert.deepEqual(k('aud_ab'), [false, true, false, false]);
  assert.deepEqual(k('a:ab'), [false, true, false, false]);
  assert.deepEqual(k('file_ab'), [false, false, true, false]);
  assert.deepEqual(k('img_ab'), [false, false, false, false]);
  assert.deepEqual(k('thumb:img_a:img_b'), [false, false, false, true]);
  assert.deepEqual(k('geo:1,2,x'), [false, false, false, true]);
  assert.deepEqual(k('i:abc'), [false, false, false, false], 'a one-letter scheme is a legacy media ref, not a marker');
});

test('media refs: companions are learned and hidden from the visible set', async () => {
  const { app } = await boot();
  const media = ['img_full', 'thumb:img_full:img_tiny', 'vid_clip', 'poster:vid_clip:img_still', 'img_still', 'orig:img_full:img_orig', 'img_orig', 'preview:img_full:img_prev', 'img_prev', 'geo:1,2,Place', 'img_tiny'];
  const shown = J(app.ev(`displayMediaRefs(${JSON.stringify(media)})`));
  assert.deepEqual(shown, ['img_full', 'vid_clip'], 'only the real content is shown');
  assert.equal(app.ev('ThumbIndex.thumbFor("img_full")'), 'img_prev', 'a 512px preview outranks the thumb');
  assert.equal(app.ev('PosterIndex.posterFor("vid_clip")'), 'img_still');
  assert.equal(app.ev(`posterRefFor(${JSON.stringify(media)}, "vid_clip")`), 'img_still');
  app.ev('ThumbIndex.learn(["thumb:img_full:img_downgrade"])');
  assert.equal(app.ev('ThumbIndex.thumbFor("img_full")'), 'img_prev', 'a later thumb cannot downgrade a preview');
  assert.equal(app.ev('ThumbIndex.thumbFor("nope")'), null);
});

test('media tiles: a ready blob becomes the image source', async () => {
  const { app } = await boot({ state: { feeds: { default: [BO_POST({ media: ['img_ready'], reactions: [] })] } }, be: { media_data_url: 'data:image/jpeg;base64,AAAA' } });
  const img = app.q('.card[data-post="bp1"] .post-media img, .card[data-post="bp1"] .post-media video');
  assert.ok(img, 'a tile was rendered');
  assert.equal(img.src, 'data:image/jpeg;base64,AAAA');
  assert.ok(app.calls.some((c) => c.cmd === 'media_data_url' && c.args.reference === 'img_ready'));
});

test('media tiles: a blob that has not arrived shows a loading box that polls, then gives up with a retry', async () => {
  const { app, be } = await boot({ state: { feeds: { default: [BO_POST({ media: ['img_late'], reactions: [] })] } }, be: { media_data_url: null, media_evicted_size: null } });
  const box = () => app.q('.card[data-post="bp1"] .media-evicted');
  assert.ok(box(), 'a placeholder, not a broken image');
  assert.match(box().textContent, /loading/i);
  await app.timers.advance(2100);
  await app.settle();
  assert.ok(box(), 'still waiting after the first poll');
  await app.timers.advance(46_000);
  await app.settle();
  assert.match(box().textContent, /not available yet/i, 'it does not spin forever');
  be.media_data_url = 'data:image/jpeg;base64,BBBB';
  await click(app, box().querySelector('button'));                       // Retry
  assert.ok(lastCall(app, 'media_download'), 'retry asks the engine to fetch again');
  await app.timers.advance(2100);
  await app.settle();
  assert.ok(!box(), 'the placeholder is replaced once the bytes land');
});

test('media tiles: a deliberately evicted blob offers a sized Download instead of silently refetching', async () => {
  const { app, be } = await boot({ state: { feeds: { default: [BO_POST({ media: ['img_gone'], reactions: [] })] } }, be: { media_data_url: null, media_evicted_size: 3_500_000, media_is_wanted: false } });
  const box = () => app.q('.card[data-post="bp1"] .media-evicted');
  assert.match(box().textContent, /3\.3 MB|3\.4 MB|MB/);
  assert.equal(lastCall(app, 'media_download'), undefined, 'nothing is fetched until the user asks');
  await click(app, box().querySelector('button'));
  assert.ok(lastCall(app, 'media_download'));
  await app.timers.advance(46_500);
  await app.settle();
  assert.match(box().textContent, /no longer available/i);
  const ask = [...box().querySelectorAll('button')].find((b) => /ask/i.test(b.textContent));
  assert.ok(ask, "someone else's post offers to ask the author for it back");
  be.media_is_wanted = true;
  await click(app, ask);
  assert.deepEqual(J(lastCall(app, 'media_request_when_available').args), { reference: 'img_gone', circleId: 'default', postId: 'bp1', authorShort: BO.slice(0, 8) });
  assert.match(box().textContent, /🔔/, 'then it says it will tell you when it is back');
});

test('media tiles: my own missing blob does not offer to ask myself for it', async () => {
  const { app } = await boot({ state: { feeds: { default: [post({ media: ['img_mine'], reactions: [] })] } }, be: { media_data_url: null, media_evicted_size: 1000, media_is_wanted: false } });
  const box = () => app.q('.card[data-post="p1"] .media-evicted');
  await click(app, box().querySelector('button'));
  await app.timers.advance(46_500); await app.settle();
  assert.ok(![...box().querySelectorAll('button')].some((b) => /ask/i.test(b.textContent)));
});

test('media: a post with several photos renders a carousel; one photo a single tile; a location alone no empty box', async () => {
  const some = (n) => Array.from({ length: n }, (_, i) => `img_${i}`);
  const c3 = await boot({ state: { feeds: { default: [post({ media: some(3) })] } }, be: { media_data_url: 'data:image/jpeg;base64,AA' } });
  assert.ok(c3.app.q('.post-media.carousel'));
  const one = await boot({ state: { feeds: { default: [post({ media: some(1) })] } }, be: { media_data_url: 'data:image/jpeg;base64,AA' } });
  assert.ok(one.app.q('.post-media.single'));
  const geoOnly = await boot({ state: { feeds: { default: [post({ media: ['geo:37.5,-122.2,Golden Gate'] })] } } });
  assert.ok(!geoOnly.app.q('.post-media.carousel') && !geoOnly.app.q('.post-media.single'), 'a location-only post draws no empty media box');
  assert.match(geoOnly.app.q('.card[data-post="p1"]').textContent, /Golden Gate/);
});

test('media: a post with a song shows the now-playing chip, and its sound toggle follows the global setting', async () => {
  const music = { catalog_id: 'c', title: 'Tune', artist: 'Band', artwork_url: '', duration_ms: 1 };
  const { app } = await boot({ state: { feeds: { default: [post({ music })] } } });
  const chip = app.q('.song-chip');
  assert.match(chip.textContent, /Tune.*Band/);
  await click(app, chip.querySelector('.song-sound'));
  assert.equal(lastCall(app, 'set_video_sound').args.on, true);
});

test('media: my own post with attachments links to where it is stored', async () => {
  const { app } = await boot({ state: { feeds: { default: [post({ media: ['img_x'] })] } }, be: { media_data_url: 'data:image/jpeg;base64,AA', media_backup_rows: { rows: [{ dest: HEX('e'), have: 3 }], ownRelay: '' } } });
  const stored = app.q('.card[data-post="p1"] .post-head .icon-btn');
  assert.ok(stored, 'the cloud badge is offered on my own posts with media');
  await click(app, stored);
  assert.ok(lastCall(app, 'media_backup_rows'), 'the sheet asks where each blob lives');
  assert.equal(lastCall(app, 'media_backup_rows').args.refs[0], 'img_x');
});

// ── Instagram import sheet ──────────────────────────────────────────────────────────────────────
const IG_SUMMARY = { posts: 12, reels: 3, stories: 5, items: 20, mediaCount: 40, totalBytes: 123_000_000, missing: 2, earliest: Date.UTC(2015, 2, 1), latest: Date.UTC(2024, 5, 1) };
const igOpen = async (status) => {
  const h = await boot({ be: { instagram_status: status, instagram_read: null, instagram_run: null, instagram_reset: null, instagram_cancel: null, instagram_resume: null } });
  await openSettingsRow(h.app, /Instagram/);
  return h;
};

test('instagram: the walkthrough takes three steps and the last one picks the archive', async () => {
  const { app } = await igOpen({ phase: 'idle' });
  assert.match(app.q('#modal-root').textContent, /JSON/);
  assert.equal(app.qa('#modal-root .ig-dot.on').length, 1);
  await click(app, modalBtn(app, /Open Instagram|Instagram/i) && [...app.qa('#modal-root .btn.primary')][0]);
  assert.match(app.opened.at(-1), /accountscenter\.instagram\.com/);
  await click(app, modalBtn(app, /requested/i));
  assert.match(app.q('#modal-root').textContent, /wait|email|hours/i);
  await click(app, modalBtn(app, /have the file|have it/i));
  app.ctx.__pick = null;
  await click(app, [...app.qa('#modal-root .btn.primary')][0]);
  assert.equal(lastCall(app, 'instagram_read'), undefined, 'cancelling the picker reads nothing');
  assert.deepEqual(J(app.dialogOpens.at(-1).filters), [{ name: 'Zip', extensions: ['zip'] }]);
  app.ctx.__pick = '/Users/me/instagram-export.zip';
  await click(app, [...app.qa('#modal-root .btn.primary')][0]);
  assert.equal(lastCall(app, 'instagram_read').args.path, '/Users/me/instagram-export.zip');
});

test('instagram: a previewed archive shows what is in it and imports into the active circle', async () => {
  const { app } = await igOpen({ phase: 'previewing', summary: IG_SUMMARY });
  const m = app.q('#modal-root');
  assert.match(m.textContent, /12/);
  assert.match(m.textContent, /117 MB/, 'size is human-readable');
  assert.match(m.textContent, /2015.*2024/s, 'the date span');
  assert.match(m.textContent, /2.*(missing|not)/i, 'files named by the archive but absent are called out');
  const btn = () => app.qa('#modal-root .modal-foot .btn.primary')[0];
  assert.match(btn().textContent, /15/, 'stories are excluded by default: 20 items minus 5 stories');
  const stories = app.qa('#modal-root input[type="checkbox"]')[0];
  stories.checked = true; stories.onchange();
  await app.settle();
  assert.match(btn().textContent, /20/, 'including stories counts them');
  await click(app, btn());
  assert.deepEqual(J(lastCall(app, 'instagram_run').args), { circleId: 'default', includeStories: true, matchSongs: false });
  await click(app, modalBtn(app, /different file/i));
  assert.ok(lastCall(app, 'instagram_reset'));
});

test('instagram: a one-item archive uses the singular button', async () => {
  const { app } = await igOpen({ phase: 'previewing', summary: { ...IG_SUMMARY, items: 1, stories: 0, posts: 1, reels: 0, missing: 0 } });
  assert.match(app.qa('#modal-root .modal-foot .btn.primary')[0].textContent, /1\b/);
});

test('instagram: while importing, progress updates in place and Stop is confirmed', async () => {
  const { app } = await igOpen({ phase: 'importing', done: 3, total: 10, running: true });
  assert.equal(app.q('#modal-root .ig-big').textContent, '3');
  const bigBefore = app.q('#modal-root .ig-big');
  await app.emit('haven:import', { phase: 'importing', done: 7, total: 10, running: true });
  assert.equal(app.q('#modal-root .ig-big'), bigBefore, 'the open sheet is updated, not torn down and rebuilt');
  assert.equal(bigBefore.textContent, '7');
  assert.equal(app.q('#modal-root .ig-bar i').style.width, '70%');
  assert.ok(app.q('#import-pill'), 'a pill shows progress elsewhere');
  assert.match(app.q('#import-pill .ip-count').textContent, /7.*10/);
  app.ctx.__confirm = false;
  await click(app, modalBtn(app, /^Stop/i));
  assert.equal(lastCall(app, 'instagram_cancel'), undefined);
  app.ctx.__confirm = true;
  await click(app, modalBtn(app, /^Stop/i));
  assert.ok(lastCall(app, 'instagram_cancel'));
  await click(app, modalBtn(app, /Browse|while/i));
  assert.equal(app.q('#modal-root').children.length, 0, 'the run carries on without the sheet');
});

test('instagram: the progress pill clears when the run ends and reopens the sheet when tapped', async () => {
  const { app } = await boot({ be: { instagram_status: { phase: 'importing', done: 1, total: 4, running: true } } });
  const pill = app.q('#import-pill');
  assert.ok(pill, 'a run in flight at launch is surfaced');
  await click(app, pill);
  assert.match(app.q('#modal-root').textContent, /Instagram/i);
  await app.emit('haven:import', { phase: 'finished', imported: 4, skipped: 0 });
  assert.equal(app.q('#import-pill'), null);
});

test('instagram: a finished run reports counts, can resume a stopped one, and Done resets', async () => {
  const { app } = await igOpen({ phase: 'finished', imported: 18, skipped: 2, resumeFrom: 5 });
  const m = app.q('#modal-root').textContent;
  assert.match(m, /18/);
  assert.match(m, /2/);
  await click(app, modalBtn(app, /Pick up where it stopped/i));
  assert.ok(lastCall(app, 'instagram_resume'));
  await click(app, [...app.qa('#modal-root button')].find((b) => /^Done$/i.test(b.textContent)));
  assert.ok(lastCall(app, 'instagram_reset'));
  const clean = await igOpen({ phase: 'finished', imported: 3, skipped: 0 });
  assert.ok(!clean.app.qa('#modal-root button').some((b) => /Pick up/i.test(b.textContent)), 'nothing to resume');
});

test('instagram: a failure shows its message and offers another file', async () => {
  const { app } = await igOpen({ phase: 'failed', message: 'That file isn’t a readable Instagram archive.' });
  assert.match(app.q('#modal-root').textContent, /readable Instagram archive/);
  await click(app, modalBtn(app, /another|try/i));
  assert.ok(lastCall(app, 'instagram_reset'));
});

test('instagram: a missing file dialog is reported rather than failing silently', async () => {
  const { app } = await igOpen({ phase: 'idle' });
  delete app.ctx.__TAURI__.dialog;
  app.ev('IG.step = 2');
  await app.ev('instagramImportSheet()');
  await click(app, [...app.qa('#modal-root .btn.primary')][0]);
  assert.ok(app.q('#toast').textContent.length > 0);
});

// ── calls: signalling state machine, with a fake WebRTC stack ──────────────────────────────────
const SESSION = 'sess-1';
const callOn = (over = {}) => boot({ ...withDm(), ...over });
const ev = (app, kind, extra = {}) => app.emit('haven:call', { kind, sessionId: SESSION, from: BO, ...extra });
const callState = (app) => J(app.ev('({ringing: call.ringing, connecting: call.connecting, inCall: call.inCall, session: call.session, roster: [...call.roster].sort(), name: call.name})'));

test('calls: an incoming invite rings with the caller\'s name, and declining silences it everywhere', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME], groupName: 'Bo' });
  assert.deepEqual(callState(app).ringing, true);
  assert.match(app.q('#modal-root .call-overlay').textContent, /Incoming call/i);
  assert.match(app.q('#modal-root .call-overlay').textContent, /Bo/);
  assert.equal(lastCall(app, 'qa_set_call_state').args.ringing, true, 'the QA channel is told');
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Decline/i.test(b.textContent)));
  assert.equal(callState(app).ringing, false);
  assert.equal(app.q('#modal-root').children.length, 0);
  assert.ok(lastCall(app, 'call_handled_elsewhere'), 'my other devices stop ringing');
  assert.equal(lastCall(app, 'call_hangup').args.sessionId, SESSION);
});

test('calls: a session already left is not re-rung by retransmitted invites', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME] });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Decline/i.test(b.textContent)));
  await ev(app, 'invite', { roster: [BO, ME] });
  assert.equal(callState(app).ringing, false, 'the tombstone suppresses a replay');
  await ev(app, 'invite', { sessionId: 'other-session', roster: [BO, ME] });
  assert.equal(callState(app).ringing, true, 'a genuinely new session still rings');
});

test('calls: an unanswered ring ends as a missed call after the ring timeout', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME], groupName: 'Bo' });
  await app.timers.advance(59_000);
  assert.equal(callState(app).ringing, true);
  await app.timers.advance(2_000);
  assert.equal(callState(app).ringing, false);
  assert.match(app.q('#toast').textContent, /Missed call/i);
});

test('calls: another of my devices answering silences this ring, but never ends an answered call', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME] });
  await ev(app, 'handledElsewhere', { sessionId: 'someone-else' });
  assert.equal(callState(app).ringing, true, 'a different session is ignored');
  await ev(app, 'handledElsewhere');
  assert.equal(callState(app).ringing, false);

  const b = await callOn();
  await ev(b.app, 'invite', { sessionId: 's2', roster: [BO, ME] });
  await click(b.app, [...b.app.qa('#modal-root .call-overlay button')].find((x) => /Accept/i.test(x.textContent)));
  assert.equal(callState(b.app).inCall, true);
  await ev(b.app, 'handledElsewhere', { sessionId: 's2' });
  assert.equal(callState(b.app).inCall, true, 'a late "handled elsewhere" cannot hang up a conversation in progress');
  await ev(b.app, 'endedElsewhere', { sessionId: 'unrelated' });
  assert.equal(callState(b.app).inCall, true);
  await ev(b.app, 'endedElsewhere', { sessionId: 's2' });
  assert.equal(callState(b.app).inCall, false, 'but my account ending the session does end it');
});

test('calls: accepting acquires media, tells the caller, and joins the mesh with a connection per peer', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME], groupName: 'Bo' });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Accept/i.test(b.textContent)));
  assert.deepEqual(callState(app).inCall, true);
  assert.deepEqual(J(lastCall(app, 'call_accept').args), { sessionId: SESSION, to: [BO] });
  assert.ok(lastCall(app, 'call_handled_elsewhere'));
  assert.ok(app.rtc.length >= 1, 'a peer connection exists for the caller');
  assert.ok(app.q('#modal-root .call-screen'), 'the in-call screen replaced the ring');
  assert.equal(app.ctx.__media.gum[0].audio, true);
  assert.equal(lastCall(app, 'call_camera_state').args.on, false, 'calls start audio-only and say so');
  // the smaller hex is the offerer: ME (aaaa…) < BO (bbbb…) so we send the offer
  assert.equal(lastCall(app, 'call_signal').args.kind, 'offer');
});

test('calls: the callee side answers an offer and applies ICE candidates only for the live session', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME] });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Accept/i.test(b.textContent)));
  const n0 = app.calls.filter((c) => c.cmd === 'call_signal').length;
  await ev(app, 'offer', { sessionId: 'stale', json: JSON.stringify({ sdp: 'x' }) });
  assert.equal(app.calls.filter((c) => c.cmd === 'call_signal').length, n0, 'a signal for another session is dropped');
  await ev(app, 'offer', { json: JSON.stringify({ t: 'offer', sdp: 'their-offer' }) });
  const pc = app.rtc.at(-1);
  assert.equal(pc.remote.sdp, 'their-offer');
  assert.equal(lastCall(app, 'call_signal').args.kind, 'answer');
  assert.equal(JSON.parse(lastCall(app, 'call_signal').args.json).sdp, 'answer-sdp');
  await ev(app, 'ice', { json: JSON.stringify({ c: 'cand', m: 0, i: 'audio' }) });
  assert.equal(pc.ice.length, 1);
  await ev(app, 'ice', { sessionId: 'stale', json: JSON.stringify({ c: 'late' }) });
  assert.equal(pc.ice.length, 1);
  await ev(app, 'answer', { json: JSON.stringify({ sdp: 'their-answer' }) });
  assert.equal(pc.remote.sdp, 'their-answer');
});

test('calls: a peer hanging up the last other participant ends the call; a stale BYE is ignored', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME] });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Accept/i.test(b.textContent)));
  await ev(app, 'hangup', { sessionId: 'old-call' });
  assert.equal(callState(app).inCall, true, 'a BYE from an earlier call does not hang up this one');
  const tracks = app.ev('call.localStream.getTracks()');
  assert.ok(tracks.length > 0);
  await ev(app, 'hangup', {});
  assert.equal(callState(app).inCall, false);
  assert.equal(app.rtc.at(-1).closed, true, 'connections are closed');
  assert.equal(app.ev('call.localStream'), null);
  assert.ok(tracks.every((t) => t.stopped), 'the microphone is released');
});

test('calls: hanging up tears down locally first, even if the backend call fails', async () => {
  const { app } = await callOn({ be: { call_hangup: () => { throw new Error('boom'); } } });
  await ev(app, 'invite', { roster: [BO, ME] });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Accept/i.test(b.textContent)));
  await app.ev('callHangup()');
  await app.settle();
  assert.equal(callState(app).inCall, false, 'leaving a call is a right, not a request');
  assert.equal(app.q('#modal-root').children.length, 0);
});

test('calls: both people calling each other at once connect instead of ringing forever (glare)', async () => {
  const { app } = await callOn();
  await app.ev(`callStart([${JSON.stringify(BO)}], "Bo", false)`);
  assert.equal(callState(app).connecting || callState(app).inCall, true);
  assert.equal(lastCall(app, 'call_group_invite').args.to[0], BO);
  await ev(app, 'invite', { sessionId: 'their-own-session', roster: [BO, ME] });
  const s = callState(app);
  assert.equal(s.inCall, true);
  assert.equal(s.session, `glare:${ME}-${BO}`, 'both ends derive the same session id from the sorted hexes');
  assert.equal(lastCall(app, 'call_accept').args.sessionId, s.session);
});

test('calls: an outgoing call that nobody answers hangs up after the dial timeout', async () => {
  const { app } = await callOn({ be: { call_group_invite: null } });
  app.ctx.__media.deny = true;
  await app.ev(`callStart([${JSON.stringify(BO)}], "Bo", false)`);
  assert.equal(callState(app).connecting, true);
  assert.match(app.q('#modal-root .call-screen').textContent, /Calling Bo/i);
  await app.timers.advance(61_000);
  assert.equal(callState(app).connecting, false);
  assert.match(app.q('#toast').textContent, /No answer/i);
  assert.ok(lastCall(app, 'call_hangup'), 'the far side stops ringing');
});

test('calls: when the other side accepts our call the mesh connects and sends an offer', async () => {
  const { app } = await callOn();
  await app.ev(`callStart([${JSON.stringify(BO)}], "Bo", false)`);
  const session = app.ev('call.session');
  await app.emit('haven:call', { kind: 'accept', sessionId: session, from: BO });
  assert.equal(callState(app).inCall, true);
  assert.equal(lastCall(app, 'call_signal').args.kind, 'offer', 'the smaller hex offers');
  await app.emit('haven:call', { kind: 'camera', sessionId: session, from: BO, on: false });
  assert.equal(app.ev('call.camOff["' + BO + '"]'), true, 'their camera-off state is remembered');
  await app.emit('haven:call', { kind: 'camera', sessionId: session, from: BO, on: true });
  assert.equal(app.ev('call.camOff["' + BO + '"]'), undefined);
});

test('calls: mic, camera and minimize controls behave', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME] });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Accept/i.test(b.textContent)));
  await app.ev('toggleMic()');
  assert.equal(app.ev('call.micOn'), false);
  assert.equal(app.ev('call.localStream.getAudioTracks()[0].enabled'), false);
  await app.ev('toggleMic()');
  assert.equal(app.ev('call.micOn'), true);
  await app.ev('toggleCam()');
  assert.equal(app.ev('call.camOn'), true);
  assert.equal(lastCall(app, 'call_camera_state').args.on, true, 'peers are told the camera went on');
  await click(app, app.q('.call-topbar .call-chip'));
  assert.equal(app.ev('call.minimized'), true);
  assert.equal(app.q('#tab-call').hidden, false, 'the call docks into a Call tab');
  await click(app, '#tab-call');
  assert.equal(app.ev('call.minimized'), false);
  assert.ok(app.q('#modal-root .call-screen'));
});

test('calls: the QA driver can place, answer and end calls and report the rendered layout', async () => {
  const { app } = await callOn();
  await app.emit('haven:qa-ui', { action: 'call_start', to: BO.toUpperCase() });
  assert.equal(callState(app).connecting || callState(app).inCall, true);
  await app.emit('haven:qa-ui', { action: 'call_minimize' });
  assert.equal(app.ev('call.minimized'), true);
  await app.emit('haven:qa-ui', { action: 'call_expand' });
  assert.equal(app.ev('call.minimized'), false);
  await app.emit('haven:qa-ui', { action: 'probe' });
  const probe = JSON.parse(lastCall(app, 'qa_set_call_state').args.trail.replace(/^probe:/, ''));
  assert.equal(probe.screen, true);
  assert.equal(probe.solo, true, 'a 1:1 call is the full-bleed layout');
  assert.equal(probe.grid, false);
  await app.emit('haven:qa-ui', { action: 'call_end' });
  assert.equal(callState(app).connecting || callState(app).inCall, false);
});

test('calls: three or more people use the tile grid, and adding to a call re-broadcasts the roster', async () => {
  const CY = HEX('c');
  const { app } = await callOn({ state: { ...withDm().state, contacts: [...withDm().state.contacts, { id_hex: CY, name: 'Cy', verify_hex: 'v', emoji: '', avatar: '', bio: '', link: '' }] } });
  await ev(app, 'invite', { roster: [BO, CY, ME] });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Accept/i.test(b.textContent)));
  assert.ok(app.q('.call-grid'), 'a group call uses the grid');
  assert.match(app.q('.call-title .st').textContent, /3/);
  const before = app.calls.filter((c) => c.cmd === 'call_group_invite').length;
  await app.ev('addToCall(["' + HEX('d') + '"])');
  assert.equal(app.calls.filter((c) => c.cmd === 'call_group_invite').length, before + 1);
  assert.ok(J(lastCall(app, 'call_group_invite').args.roster).includes(HEX('d')));
  await app.ev('addToCall(["' + HEX('d') + '"])');
  assert.equal(app.calls.filter((c) => c.cmd === 'call_group_invite').length, before + 1, 'an existing participant is not re-invited');
});

test('calls: the loudest participant is highlighted only after two consecutive polls', async () => {
  const { app } = await callOn();
  await ev(app, 'invite', { roster: [BO, ME] });
  await click(app, [...app.qa('#modal-root .call-overlay button')].find((b) => /Accept/i.test(b.textContent)));
  const pc = app.rtc.at(-1);
  pc.statsRows = [{ type: 'inbound-rtp', kind: 'audio', audioLevel: 0.2 }];
  await app.timers.advance(1000); await app.settle();
  assert.equal(app.ev('call.activeSpeaker'), null, 'one poll is not enough');
  await app.timers.advance(1000); await app.settle();
  assert.equal(app.ev('call.activeSpeaker'), BO);
  pc.statsRows = [{ type: 'inbound-rtp', kind: 'audio', audioLevel: 0.001 }];
  await app.timers.advance(1000); await app.settle();
  assert.equal(app.ev('call.activeSpeaker'), null, 'silence clears it');
});

test('calls: hairpin frames are byte-compatible with the phones (7-byte header, 16-bit seq, 32-bit pts)', async () => {
  const { app } = await boot();
  const packed = app.ev('new Uint8Array(packHairpin(1, 0x0102, 0x0A0B0C0D, new Uint8Array([9, 8, 7])))');
  assert.deepEqual([...packed], [1, 0x01, 0x02, 0x0A, 0x0B, 0x0C, 0x0D, 9, 8, 7]);
  const back = app.ev('(() => { const u = unpackHairpin(packHairpin(2, 65535, 5, new Uint8Array([1, 2]))); return { type: u.type, seq: u.seq, payload: [...u.payload] }; })()');
  assert.deepEqual(J(back), { type: 2, seq: 65535, payload: [1, 2] });
  assert.equal(app.ev('unpackHairpin(new Uint8Array([1, 0, 0]).buffer)'), null, 'shorter than the header');
  assert.equal(app.ev('unpackHairpin(new Uint8Array([9, 0, 0, 0, 0, 0, 0, 1]).buffer)'), null, 'unknown frame type');
});

test('calls: the hairpin URL is derived from the fabric origin and only for http(s)', async () => {
  const { app } = await boot();
  assert.equal(app.ev('hairpinWsUrl()'), '');
  app.ctx.__havenFabricDerp = ['https://relay.example.com/'];
  assert.equal(app.ev('fabricPublicBase()'), 'https://relay.example.com');
  assert.equal(app.ev('hairpinWsUrl()'), 'wss://relay.example.com/webrtc/hairpin');
  app.ctx.__havenFabricDerp = ['http://10.0.0.5:8080'];
  assert.equal(app.ev('hairpinWsUrl()'), 'ws://10.0.0.5:8080/webrtc/hairpin');
  app.ctx.__havenFabricDerp = ['ftp://nope'];
  assert.equal(app.ev('hairpinWsUrl()'), '');
});

// ── story composer and song picker ─────────────────────────────────────────────────────────────
const withRect = (fn) => {
  const orig = StubElement.prototype.getBoundingClientRect;
  StubElement.prototype.getBoundingClientRect = function () { return { x: 0, y: 0, left: 0, top: 0, right: 200, bottom: 356, width: 200, height: 356 }; };
  return Promise.resolve(fn()).finally(() => { StubElement.prototype.getBoundingClientRect = orig; });
};
const ptr = (app, node, type, init) => node.dispatchEvent(new app.ctx.Event(type, { bubbles: true, pointerId: 1, buttons: 1, ...init }));

test('story composer: typing shows a styled caption in the preview and posting encodes the wire caption', async () => {
  await withRect(async () => {
    const { app } = await boot({ be: { post_story: null } });
    await click(app, '.story-ring.add');
    const m = () => app.q('#modal-root');
    assert.match(m().textContent, /New story/i);
    const ta = m().querySelector('textarea');
    ta.value = 'hello story';
    ta.dispatchEvent(new app.ctx.Event('input', { bubbles: true }));
    assert.equal(m().querySelector('.story-cap').textContent, 'hello story');
    const frame = m().querySelector('.modal-body > .col > div[style*="aspect-ratio"]') ?? [...m().querySelectorAll('div')].find((d) => /aspect-ratio:9\/16/.test(d.getAttribute('style') || ''));
    ptr(app, frame, 'pointerdown', { clientX: 50, clientY: 89 });          // 25% / 25%
    assert.match(m().querySelector('.story-cap').style.cssText, /left:25%;top:25%/);
    await click(app, [...m().querySelectorAll('button')].find((b) => b.title === 'Caption color' || /color/i.test(b.title)));
    await click(app, [...m().querySelectorAll('button')].find((b) => /Aa ·/.test(b.textContent)));
    await click(app, [...m().querySelectorAll('button')].find((b) => b.textContent === 'Ag'));
    await click(app, '#modal-root .composer-send');
    const c = lastCall(app, 'post_story').args;
    const decoded = J(app.ev(`StoryCaptions.decode(${JSON.stringify(c.body)})`));
    assert.equal(decoded.text, 'hello story');
    assert.ok(Math.abs(decoded.spec.x - 0.25) < 1e-6 && Math.abs(decoded.spec.y - 0.25) < 1e-6);
    assert.equal(decoded.spec.color, 0 + 0, 'the first swatch (index 0) is the default colour');
    assert.equal(decoded.spec.font, 1, 'one tap on the font button');
    assert.equal(decoded.spec.style, 2, 'one tap on style steps plain/glow/shadow from the default glow');
    assert.equal(c.media, null);
    assert.equal(m().children.length, 0, 'the dialog closes after posting');
  });
});

test('story composer: zoom, rotate and pan frame the media, and Reset restores the identity', async () => {
  await withRect(async () => {
    const { app } = await boot({ be: { post_story: null, media_data_url: 'data:image/jpeg;base64,AA' } });
    await click(app, '.story-ring.add');
    await app.ev('state.composerAdd')('img_pic', false, false, null);
    await app.settle();
    const m = () => app.q('#modal-root');
    const frame = [...m().querySelectorAll('div')].find((d) => /aspect-ratio:9\/16/.test(d.getAttribute('style') || ''));
    const media = () => m().querySelector('[data-story-media]');
    assert.ok(media(), 'the attached photo is previewed');
    const wheel = (extra) => frame.dispatchEvent(new app.ctx.Event('wheel', { bubbles: true, deltaY: -40, ...extra }));
    wheel({});
    assert.match(media().style.transform, /scale\(1\.[1-9]/, 'wheel up zooms in');
    wheel({ deltaY: 40, shiftKey: true });
    assert.match(media().style.transform, /rotate\(12deg\)/);
    ptr(app, frame, 'pointerdown', { clientX: 100, clientY: 100, altKey: true });
    ptr(app, frame, 'pointermove', { clientX: 120, clientY: 100, altKey: true });
    assert.match(media().style.transform, /translate\(10%/, 'alt-drag pans by a fraction of the frame');
    const reset = [...m().querySelectorAll('button')].find((b) => /reset/i.test(b.textContent));
    assert.notEqual(reset.style.display, 'none');
    await click(app, reset);
    assert.match(media().style.transform, /translate\(0%, 0%\) rotate\(0deg\) scale\(1\)/);
    assert.equal(reset.style.display, 'none');
    await click(app, '#modal-root .composer-send');
    const c = lastCall(app, 'post_story').args;
    assert.equal(c.media, 'img_pic');
    assert.equal(J(app.ev(`StoryCaptions.decode(${JSON.stringify(c.body)})`)).spec.mediaScale, 1);
  });
});

test('song picker: typing debounces the search; a late answer never overwrites a newer one', async () => {
  const hits = (n) => Array.from({ length: n }, (_, i) => ({ catalog_id: 'c' + i, title: 'Song ' + i, artist: 'Band', artwork_url: '', duration_ms: 1000, preview_url: 'https://a.example/' + i }));
  let resolveFirst;
  const { app } = await boot({ be: { music_search: (a) => a.query === 'one' ? new Promise((r) => { resolveFirst = () => r(hits(1)); }) : hits(3) } });
  await app.ev('musicDialog(() => {}, {})');
  const input = app.q('#modal-root input');
  input.value = 'one'; input.dispatchEvent(new app.ctx.Event('input', { bubbles: true }));
  await app.timers.advance(200);
  assert.equal(lastCall(app, 'music_search'), undefined, 'the debounce waits');
  await app.timers.advance(150); await app.settle();
  assert.equal(lastCall(app, 'music_search').args.query, 'one');
  input.value = 'two';
  input.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  assert.equal(app.qa('#modal-root .song-chip').length, 3, 'the newer search shows');
  resolveFirst(); await app.settle();
  assert.equal(app.qa('#modal-root .song-chip').length, 3, 'the stale answer is discarded');
});

test('song picker: picking a song hands it to the caller and closes; art auditions one preview at a time', async () => {
  const hits = [{ catalog_id: 'c1', title: 'Alpha', artist: 'A', artwork_url: 'https://x/a.jpg', duration_ms: 5, preview_url: 'https://p/1' }, { catalog_id: 'c2', title: 'Beta', artist: '', artwork_url: '', duration_ms: 0, preview_url: 'https://p/2' }];
  const picked = [];
  const { app } = await boot({ be: { music_search: hits, music_suggestions: [hits[1]] } });
  app.ctx.__picked = picked;
  await app.ev('musicDialog((m) => __picked.push(m), { caption: () => "beach day" })');
  const input = app.q('#modal-root input');
  input.value = 'a'; input.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  const arts = app.qa('#modal-root .song-art-btn.playable');
  assert.equal(arts.length, 2);
  await click(app, arts[0]);
  assert.match(app.qa('#modal-root .song-art-glyph')[0].innerHTML, /./);
  await click(app, arts[1]);                                            // starting another stops the first
  await click(app, arts[1]);                                            // tapping again stops it
  assert.equal(picked.length, 0, 'auditioning never attaches');
  await click(app, app.qa('#modal-root .song-chip')[0]);
  assert.deepEqual(J(picked[0]), { catalog_id: 'c1', title: 'Alpha', artist: 'A', artwork_url: 'https://x/a.jpg', duration_ms: 5 });
  assert.equal(app.q('#modal-root').children.length, 0);
  await app.ev('musicDialog(() => {}, { caption: () => "beach day", genre: "Pop", createdAt: 123 })');
  await click(app, [...app.qa('#modal-root .picker-tabs button')].find((b) => /Suggest/i.test(b.textContent)));
  const sug = lastCall(app, 'music_suggestions').args;
  assert.deepEqual(J(sug), { caption: 'beach day', genre: 'Pop', createdAtMs: 123, limit: 12 });
  assert.equal(app.qa('#modal-root .song-chip').length, 1);
});

test('song picker: an empty search clears results, and no hits says so', async () => {
  const { app } = await boot({ be: { music_search: [] } });
  await app.ev('musicDialog(() => {}, {})');
  const input = app.q('#modal-root input');
  input.value = '   '; input.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  assert.equal(lastCall(app, 'music_search'), undefined);
  input.value = 'nothing'; input.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  assert.match(app.q('#modal-root').textContent, /No songs|no results|found/i);
});

test('songs: artwork and links tolerate every platform\'s encoding of the track fields', async () => {
  const { app } = await boot();
  assert.equal(app.ev('musicArtwork({ artwork_url: "https://a/x.jpg" })'), 'https://a/x.jpg');
  assert.equal(app.ev('musicArtwork({ artwork_url: "start:1500;https://a/x.jpg" })'), 'https://a/x.jpg', 'Apple packs the story section start in front');
  assert.equal(app.ev('musicArtwork({ artwork_url: "start:1500" })'), '', 'a bare section marker is not a URL');
  assert.equal(app.ev('musicArtwork(null)'), '');
  assert.equal(app.ev('musicLink({ catalog_id: "https://music.apple.com/x", title: "t" })'), 'https://music.apple.com/x');
  assert.equal(app.ev('musicLink({ catalog_id: "12345", title: "Hello World", artist: "Adele" })'), 'https://music.apple.com/search?term=Hello%20World%20Adele');
  assert.equal(app.ev('musicLink({ catalog_id: "1", title: "", artist: "" })'), null);
  assert.equal(app.ev('musicLink(null)'), null);
});

// ── re-optimize media I already shared ─────────────────────────────────────────────────────────
const CAND = (n, bytes = 5_000_000) => Array.from({ length: n }, (_, i) => ({ reference: `img_c${i}`, circle_id: 'default', bytes, width: 4000, height: 3000, format: 'jpeg', reason: 'oversized', first_shared_ms: 1, legacy_by_age: i === 0 }));
const reoptOpen = async (be = {}) => {
  const h = await boot({ be: { media_data_url: 'data:image/jpeg;base64,AAAA', ...be } });
  await openSettingsRow(h.app, /Advanced/);
  return h;
};
const reoptBtn = (app) => app.q('#modal-root .card .col > button.btn');

test('re-optimize: scanning reports what can shrink, and a clean library says so', async () => {
  const clean = await reoptOpen({ reoptimize_scan: { candidates: [], videos_above_target: 0, video_bytes: 0, batch_limit: 25 } });
  await click(clean.app, modalBtn(clean.app, /Re-?optimi[sz]e|Shrink|Check/i));
  assert.match(clean.app.q('#modal-root').textContent, /already|small|✓/i);

  const some = await reoptOpen({ reoptimize_scan: { candidates: CAND(3), videos_above_target: 2, video_bytes: 90_000_000, batch_limit: 25 } });
  await click(some.app, modalBtn(some.app, /Re-?optimi[sz]e|Shrink|Check/i));
  const txt = some.app.q('#modal-root').textContent;
  assert.match(txt, /3 photos/);
  assert.match(txt, /14 MB|15 MB/, 'total bytes');
  assert.match(txt, /legacy|older/i, 'age-based candidates are called out');
  assert.match(txt, /2 videos|video/i, 'videos are reported but not re-encoded here');
  assert.match(modalBtn(some.app, /Shrink/i).textContent, /3 photos/);
});

test('re-optimize: a run re-encodes each photo, swaps the refs, re-shares the posts and summarises', async () => {
  const { app, be } = await reoptOpen({
    reoptimize_scan: { candidates: CAND(2), videos_above_target: 0, video_bytes: 0, batch_limit: 25 },
    reoptimize_headroom: true,
    reoptimize_accept: ({ reference }) => 'new_' + reference,
    reoptimize_targets: [{ circle_id: 'default', event_id: 'ev1', media: ['img_c0', 'thumb:img_c0:img_t'] }, { circle_id: 'default', event_id: 'ev2', media: ['img_other'] }],
    reoptimize_apply: true,
  });
  await click(app, modalBtn(app, /Re-?optimi[sz]e|Shrink|Check/i));
  be.reoptimize_scan = { candidates: [], videos_above_target: 0, video_bytes: 0, batch_limit: 25 };      // after the run, nothing is left
  await click(app, modalBtn(app, /Shrink/i));
  await app.settle();
  const accepts = app.calls.filter((c) => c.cmd === 'reoptimize_accept');
  assert.deepEqual(accepts.map((c) => c.args.reference), ['img_c0', 'img_c1']);
  assert.equal(accepts[0].args.dataBase64, 'AAAA', 'the re-encoded JPEG goes to the engine');
  const apply = app.calls.filter((c) => c.cmd === 'reoptimize_apply');
  assert.equal(apply.length, 1, 'only the post that carried a swapped photo is re-shared');
  assert.deepEqual(J(apply[0].args), { circleId: 'default', eventId: 'ev1', media: ['new_img_c0', 'thumb:img_c0:img_t'] });
  assert.match(app.q('#modal-root').textContent, /✓.*2 (photos|items)/s, 'a summary is shown');
});

test('re-optimize: running out of disk stops the batch with a warning; a declined photo is skipped', async () => {
  const lowDisk = await reoptOpen({ reoptimize_scan: { candidates: CAND(2), videos_above_target: 0, video_bytes: 0, batch_limit: 25 }, reoptimize_headroom: false });
  await click(lowDisk.app, modalBtn(lowDisk.app, /Re-?optimi/i));
  await click(lowDisk.app, modalBtn(lowDisk.app, /Shrink/i));
  assert.equal(lastCall(lowDisk.app, 'reoptimize_accept'), undefined);
  assert.match(lowDisk.app.q('#modal-root').textContent, /⚠️/);

  const declines = await reoptOpen({ reoptimize_scan: { candidates: CAND(1), videos_above_target: 0, video_bytes: 0, batch_limit: 25 }, reoptimize_headroom: true, reoptimize_accept: null });
  await click(declines.app, modalBtn(declines.app, /Re-?optimi/i));
  await click(declines.app, modalBtn(declines.app, /Shrink/i));
  assert.equal(lastCall(declines.app, 'reoptimize_skip').args.reference, 'img_c0', 'a photo that cannot be shrunk is remembered so it is not retried forever');
  assert.equal(lastCall(declines.app, 'reoptimize_apply'), undefined, 'nothing changed, nothing re-shared');
  assert.match(declines.app.q('#modal-root').textContent, /smaller|nothing/i);
});

test('re-optimize: a failed scan is reported instead of throwing', async () => {
  const { app } = await reoptOpen({ reoptimize_scan: () => { throw new Error('disk busy'); } });
  await click(app, modalBtn(app, /Re-?optimi/i));
  assert.match(app.q('#modal-root').textContent, /disk busy/);
});

test('re-optimize: byte accounting helpers', async () => {
  const { app } = await boot();
  assert.equal(app.ev('base64ByteLength("")'), 0);
  assert.equal(app.ev('base64ByteLength("QQ==")'), 1);
  assert.equal(app.ev('base64ByteLength("QUI=")'), 2);
  assert.equal(app.ev('base64ByteLength("QUJD")'), 3);
});

// ── DM thread details ───────────────────────────────────────────────────────────────────────────
const openThread = async (msgs, extra = {}) => {
  const base = withDm();
  const h = await boot({ ...base, state: { ...base.state, dms: { [DM]: msgs }, ...(extra.state ?? {}) }, be: extra.be });
  await tab(h.app, 'messages');
  await click(h.app, '.thread-item');
  return h;
};
const dmMsg = (over = {}) => post({ id: 'x' + Math.random().toString(36).slice(2, 6), is_me: false, author_short: BO.slice(0, 8), author_name: 'Bo', body: 'hi', created_at: NOW - 1000, ...over });
const ctxMenu = async (app, bubble) => { bubble.dispatchEvent(new app.ctx.Event('contextmenu', { bubbles: true, clientX: 10, clientY: 10 })); await app.settle(); };

test('dm thread: my own message can be edited in place, keeping its attachments, or deleted', async () => {
  const mine = dmMsg({ id: 'mine1', is_me: true, body: 'typo here', media: ['img_pic'], music: { catalog_id: 'c', title: 'T', artist: 'A', artwork_url: '', duration_ms: 1 } });
  const { app } = await openThread([mine]);
  const col = app.q('.bubble-row.me .bubble-col');
  await ctxMenu(app, col);
  assert.ok(menuBtn(app, /^Edit/i) && menuBtn(app, /Delete/i));
  await click(app, menuBtn(app, /^Edit/i));
  const ta = app.q('.dm-composer textarea');
  assert.equal(ta.value, 'typo here');
  assert.notEqual(app.q('.edit-bar').style.display, 'none');
  ta.value = 'fixed';
  ta.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  const c = lastCall(app, 'edit_post').args;
  assert.deepEqual(J({ ...c, music: undefined }), { circleId: DM, target: 'mine1', body: 'fixed', media: ['img_pic'] });
  assert.equal(c.music.title, 'T', 'an edit carries the existing song so it is not stripped');
  assert.equal(app.q('.edit-bar').style.display, 'none');
  assert.equal(lastCall(app, 'send_dm'), undefined, 'an edit is not a new message');

  await ctxMenu(app, app.q('.bubble-row.me .bubble-col'));
  await click(app, menuBtn(app, /Delete/i));
  assert.deepEqual(J(lastCall(app, 'unsend_post').args), { circleId: DM, target: 'mine1' });
});

test("dm thread: someone else's message offers reactions but no edit or delete; cancelling an edit clears the box", async () => {
  const theirs = dmMsg({ id: 't1', body: 'from bo' });
  const mine = dmMsg({ id: 'm9', is_me: true, body: 'mine' });
  const { app } = await openThread([theirs, mine]);
  await ctxMenu(app, app.qa('.bubble-col')[0]);
  assert.ok(menuBtn(app, /React/i));
  assert.ok(!menuBtn(app, /^Edit/i) && !menuBtn(app, /Delete/i));
  await click(app, [...app.qa('#menu-root button')].find((b) => /React/i.test(b.textContent)));
  assert.equal(lastCall(app, 'react').args.target, 't1');
  await ctxMenu(app, app.qa('.bubble-col')[1]);
  await click(app, menuBtn(app, /^Edit/i));
  await click(app, [...app.qa('.edit-bar button')].find((b) => /Cancel/i.test(b.textContent)));
  assert.equal(app.q('.dm-composer textarea').value, '');
});

test('dm thread: group threads label each incoming sender, 1:1 threads do not', async () => {
  const CY = HEX('c');
  const group = `dm:${[ME, BO, CY].sort().join('-')}`;
  const base = withDm();
  const { app } = await boot({ state: { ...base.state, threads: [{ circle_id: group, name: 'Bo, Cy', last_body: 'yo', last_at: NOW, member_count: 3, unread: 0 }], dms: { [group]: [dmMsg({ author_name: 'Bo', body: 'hello team' }), dmMsg({ is_me: true, body: 'hi' })] } } });
  await tab(app, 'messages');
  await click(app, '.thread-item');
  const senders = app.qa('.chat-sender');
  assert.equal(senders.length, 1, 'only incoming messages are labelled');
  assert.equal(senders[0].textContent, 'Bo');
  const one = await openThread([dmMsg({ body: 'one to one' })]);
  assert.equal(one.app.qa('.chat-sender').length, 0);
});

test('dm thread: a secret message stays hidden until tapped, then hides itself again', async () => {
  const { app } = await openThread([dmMsg({ body: '\u0002the plan' })]);
  const bubble = app.q('.chat-bubble.secret');
  assert.match(bubble.textContent, /reveal/i);
  assert.ok(!/the plan/.test(app.q('.chat').textContent));
  await click(app, bubble);
  assert.match(bubble.textContent, /the plan/);
  await app.timers.advance(5100);
  assert.match(bubble.textContent, /reveal/i, 'it re-hides after five seconds');
  const preview = await boot({ state: { ...withDm().state, threads: [{ circle_id: DM, name: 'Bo', last_body: '\u0002secret words', last_at: NOW, member_count: 2, unread: 0 }] } });
  await tab(preview.app, 'messages');
  assert.ok(!/secret words/.test(preview.app.q('.thread-item').textContent), 'a secret never leaks into the thread list preview');
});

test('dm thread: send-secretly marks the outgoing body and the disappearing timer rides along', async () => {
  const { app } = await openThread([dmMsg()]);
  await click(app, '.dm-composer .composer-plus');
  await click(app, menuBtn(app, /secretly/i));
  const ta = app.q('.dm-composer textarea');
  assert.match(ta.placeholder, /secret/i);
  await click(app, '.dm-composer .composer-plus');
  await click(app, menuBtn(app, /Disappears/i));
  await click(app, menuBtn(app, /1 hour/i));
  ta.value = 'shh';
  ta.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  const c = lastCall(app, 'send_dm').args;
  assert.equal(c.body, '\u0002shh');
  assert.equal(c.retentionSecs, 3600);
  // The disappearing setting is sticky for the conversation (Apple parity).
  ta.value = 'again';
  ta.dispatchEvent(new app.ctx.Event('keydown', { bubbles: true, key: 'Enter' }));
  await app.settle();
  assert.equal(lastCall(app, 'send_dm').args.retentionSecs, 3600);
});

test('dm thread: reactions, an unsent tombstone, a song chip and a location chip render', async () => {
  const msgs = [
    dmMsg({ id: 'r1', body: 'react to me', reactions: [{ emoji: '🔥', count: 3, mine: true, authors: [] }, { emoji: '👍', count: 1, mine: false, authors: [] }] }),
    dmMsg({ id: 'u1', unsent: true, body: 'x' }),
    dmMsg({ id: 'mu', body: 'with song', music: { catalog_id: 'https://music.apple.com/x', title: 'Tune', artist: 'Band', artwork_url: '', duration_ms: 1 } }),
    dmMsg({ id: 'g', body: '', media: ['geo:37.5,-122.25,Golden Gate'] }),
  ];
  const { app } = await openThread(msgs);
  const chips = app.qa('.msg-react');
  assert.equal(chips.length, 2);
  assert.match(chips[0].textContent, /🔥 3/);
  assert.ok(chips[0].classList.contains('mine'));
  assert.equal(chips[1].textContent, '👍', 'a count of one is not printed');
  await click(app, chips[0]);
  assert.equal(lastCall(app, 'unreact').args.emoji, '🔥');
  await click(app, chips[1]);
  assert.equal(lastCall(app, 'react').args.emoji, '👍');
  assert.match(app.q('.chat-bubble.tombstone').textContent, /unsent/i);
  const song = app.q('.chat .song-chip');
  assert.match(song.textContent, /Tune/);
  await click(app, song);
  assert.equal(app.opened.at(-1), 'https://music.apple.com/x');
  assert.match(app.q('.chat').textContent, /Golden Gate/);
});

test('dm thread: the back button returns to the list and a pending draft is consumed exactly once', async () => {
  const h = await boot({ ...withDm(), be: { message_author: () => ({ dm: DM, name: 'Bo', draft: 'link-to-post' }) }, state: { ...withDm().state, feeds: { default: [BO_POST()] } } });
  const { app } = h;
  await click(app, '.card[data-post="bp1"] .kebab');
  await click(app, menuBtn(app, /Message Bo/i));
  assert.equal(app.q('.dm-composer textarea').value, 'link-to-post');
  assert.equal(app.ev('state.pendingDraft'), null, 'consumed once');
  await click(app, app.q('.dm-head .icon-btn'));                      // back
  assert.ok(app.q('.thread-list'), 'the list is showing again');
});
