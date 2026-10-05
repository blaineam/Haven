// web/open/open.test.mjs — the /open landing page's link detection (node --test).
//
// /open is where every shared Haven link lands when the app does not intercept it (no app
// installed, an in-app browser, a desktop). Its `detectLink()` turns the #fragment into the
// haven:// URL the "Open in Haven" button launches. The function is lifted verbatim out of
// index.html's inline script and run against a stubbed `location`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'index.html'), 'utf8');

function liftDetectLink() {
  const start = html.indexOf('function detectLink()');
  assert.ok(start >= 0, 'detectLink not found in web/open/index.html');
  let depth = 0;
  let end = -1;
  for (let i = html.indexOf('{', start); i < html.length; i++) {
    if (html[i] === '{') depth++;
    else if (html[i] === '}' && --depth === 0) { end = i + 1; break; }
  }
  const src = html.slice(start, end);
  return (hash) => {
    const ctx = vm.createContext({ location: { hash } });
    vm.runInContext(`${src}\nglobalThis.r = detectLink();`, ctx);
    return ctx.r == null ? null : JSON.parse(JSON.stringify(ctx.r));
  };
}

const detect = liftDetectLink();

test('an invite fragment becomes the haven://invite link', () => {
  assert.deepEqual(detect('#abc123.VERIFYxyz'), { kind: 'invite', appUrl: 'haven://invite#abc123.VERIFYxyz' });
});

test('a post fragment becomes haven://p/<circle>/<post>, not an invite', () => {
  assert.deepEqual(detect('#p/c1ABC.p9XYZ'), { kind: 'post', appUrl: 'haven://p/c1ABC/p9XYZ' });
  // Only the FIRST dot splits: post ids may not contain one, circle ids are dot-free tokens.
  assert.deepEqual(detect('#p/dm%3Aa-b.post'), { kind: 'post', appUrl: 'haven://p/dm%3Aa-b/post' });
});

test('empty or malformed fragments are "nothing to open", never a launch', () => {
  for (const h of ['', '#', '#noDotHere', '#.leading', '#trailing.', '#p/', '#p/.x', '#p/x.', '#p/nodot']) {
    assert.equal(detect(h), null, h);
  }
});

// KNOWN BUG: the apps share STORY links as https://<host>/open/#s/<circle>.<post> (Android
// DeepLink.storyUrl, Apple DeepLink). detectLink() has no `s/` branch, so a story link falls through
// to the invite check and the page says "You've been invited to Haven" and launches
// haven://invite#s/<circle>.<post>. Fix = an `s/` branch (→ haven://s/<circle>/<post>) plus story
// copy in COPY and web/i18n.
test('a story fragment is recognised as a story, not an invite',
  { todo: 'web/open/index.html detectLink() lacks the s/ story branch — story links render as invites' }, () => {
    const r = detect('#s/c1ABC.p9XYZ');
    assert.notEqual(r?.kind, 'invite');
    assert.equal(r?.appUrl, 'haven://s/c1ABC/p9XYZ');
  });
