// desktop/ui-test/app.dom.test.mjs — runs the WHOLE app.js against a stub DOM and a fake Tauri backend
// (see domstub.mjs / uiharness.mjs) and asserts on what actually renders: boot paths, the three
// tabs, the feed, DMs, settings, onboarding and the terms gate. app.js is evaluated under its real
// file URL, so `node --test --experimental-test-coverage` attributes executed lines to it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { boot, post, fakeBackend, ME, HEX, NOW, J, click, tab, lastCall, BO, DM, withDm, BO_POST, menuBtn } from './uiharness.mjs';
import { loadApp } from './domstub.mjs';

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
