// web-client/sw.test.mjs — the service worker's whole contract, run offline.
//
//   node --test web-client/sw.test.mjs
//
// sw.js is loaded as-is into a fake ServiceWorkerGlobalScope.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

function load({ pages = [], language = 'en-US' } = {}) {
  const handlers = new Map();
  const shown = [], opened = [], focused = [];
  const scope = 'https://relay.example/app/';
  const self = {
    navigator: { language },
    registration: { scope, showNotification: async (title, opts) => { shown.push({ title, ...opts }); } },
    clients: {
      matchAll: async () => pages.map((p) => ({ ...p, focus: async () => { focused.push(p.url); } })),
      openWindow: async (url) => { opened.push(url); },
      claim: async () => {},
    },
    skipWaiting: () => {},
    addEventListener: (name, fn) => handlers.set(name, fn),
  };
  vm.runInNewContext(readFileSync(new URL('./sw.js', import.meta.url), 'utf8'), { self });
  const fire = async (name, extra = {}) => {
    let work;
    handlers.get(name)({ waitUntil: (p) => { work = p; }, ...extra });
    await work;
  };
  return { handlers, shown, opened, focused, fire, scope };
}

test('it handles pushes and clicks — and never a single request', () => {
  const { handlers } = load();
  assert.deepEqual([...handlers.keys()].sort(), ['activate', 'install', 'notificationclick', 'push']);
  assert.equal(handlers.has('fetch'), false, 'no fetch handler: the page always loads what the relay serves now');
});

test('a push with no Haven page in front shows one line that says nothing about who or what', async () => {
  const sw = load({ pages: [{ url: 'https://relay.example/app/', visibilityState: 'hidden' }] });
  await sw.fire('push', { data: null });
  await sw.fire('push', { data: null });
  assert.equal(sw.shown.length, 2);
  for (const n of sw.shown) {
    assert.equal(n.title, 'Haven');
    assert.equal(n.body, 'Something new is waiting for you.');
    assert.equal(n.tag, 'haven', 'one tag: a second push replaces the first instead of stacking');
  }
});

test('a push while a Haven page is visible shows nothing: the page tells the person itself', async () => {
  const sw = load({ pages: [{ url: 'https://relay.example/app/', visibilityState: 'visible' }] });
  await sw.fire('push');
  assert.equal(sw.shown.length, 0);
});

test('the line is in the browser\'s language, falling back to English', async () => {
  for (const [language, want] of [['de-DE', /wartet auf dich/], ['ja', /新しいお知らせ/], ['pt-BR', /esperando por você/], ['fr-FR', /waiting for you/]]) {
    const sw = load({ language });
    await sw.fire('push');
    assert.match(sw.shown[0].body, want, language);
  }
});

test('clicking the notification goes to the open Haven page, or opens one', async () => {
  let closed = 0;
  const notification = { close: () => { closed += 1; } };
  const withPage = load({ pages: [{ url: 'https://relay.example/app/#feed', visibilityState: 'hidden' }] });
  await withPage.fire('notificationclick', { notification });
  assert.deepEqual(withPage.focused, ['https://relay.example/app/#feed']);
  assert.deepEqual(withPage.opened, []);

  // A page of some OTHER site on the same origin is not Haven's.
  const without = load({ pages: [{ url: 'https://relay.example/status', visibilityState: 'visible' }] });
  await without.fire('notificationclick', { notification });
  assert.deepEqual(without.opened, [without.scope]);
  assert.equal(closed, 2);
});
