// push/worker.test.mjs — the blind push relay's security contract, run offline.
//
//   node --test push/worker.test.mjs
//
// The worker is imported as-is and driven through its real `fetch` handler with Request objects.
// Its two outside dependencies are faked: the `TOKENS` KV binding (an in-memory Map) and the global
// `fetch` it uses to reach APNs (a recorder that never touches the network). Registration
// signatures are made with node:crypto Ed25519 keys, exactly the shape the apps produce
// (`haven-push-register-v1:<nodeId>:<token>:<ts>`, nodeId = hex Ed25519 public key).
import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign as edSign } from 'node:crypto';

import worker from './worker.js';

// ── fakes ────────────────────────────────────────────────────────────────────────────────────────

function fakeKV() {
  const m = new Map();
  const writes = [];
  return {
    map: m,
    writes,
    async get(k, type) {
      const v = m.has(k) ? m.get(k).value : null;
      if (v == null) return null;
      return type === 'json' ? JSON.parse(v) : v;
    },
    async put(k, v, opts) { writes.push({ k, v, opts }); m.set(k, { value: v, opts }); },
    async delete(k) { m.delete(k); },
    async list({ prefix = '', cursor } = {}) {
      return { keys: [...m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true };
    },
  };
}

const apnsKey = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  .privateKey.export({ type: 'pkcs8', format: 'pem' });

function fakeEnv() {
  return {
    TOKENS: fakeKV(),
    APNS_KEY: apnsKey,
    APNS_KEY_ID: 'ABCDEFGHIJ',
    APNS_TEAM_ID: 'TEAM123456',
    APNS_TOPIC: 'com.example.haven',
    APNS_HOST: 'api.push.apple.com',
  };
}

/// Replace global fetch with a recorder answering `status` (or a per-call function).
function stubApns(status = 200) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init, body: init?.body ? JSON.parse(init.body) : undefined });
    const s = typeof status === 'function' ? status(String(url)) : status;
    return new Response(s === 200 ? '' : JSON.stringify({ reason: 'BadDeviceToken' }), { status: s });
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

let ipSeq = 0;
const freshIp = () => `10.0.${Math.floor(++ipSeq / 250)}.${ipSeq % 250}`;

function post(path, body, ip = freshIp()) {
  return new Request(`https://push.example${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'cf-connecting-ip': ip },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

function identity() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  const nodeId = Buffer.from(raw).toString('hex');
  return {
    nodeId,
    sign(material, ts) {
      const msg = Buffer.from(`haven-push-register-v1:${nodeId}:${material}:${ts}`);
      return edSign(null, msg, privateKey).toString('base64');
    },
  };
}

const now = () => Math.floor(Date.now() / 1000);
const TOKEN_A = 'aa'.repeat(32);
const TOKEN_B = 'bb'.repeat(32);

async function register(env, id, token, extra = {}, path = '/register') {
  const ts = now();
  const res = await worker.fetch(post(path, { nodeId: id.nodeId, token, ts, sig: id.sign(token, ts), ...extra }), env);
  return { res, body: await res.json() };
}

// ── /register ────────────────────────────────────────────────────────────────────────────────────

test('/register accepts a registration signed by the identity key and stores the token', async () => {
  const env = fakeEnv();
  const id = identity();
  const { res, body } = await register(env, id, TOKEN_A, { platform: 'macos', sandbox: true });
  assert.equal(res.status, 200);
  assert.equal(body.devices, 1);
  assert.deepEqual(await env.TOKENS.get(id.nodeId, 'json'),
    { tokens: [{ token: TOKEN_A, sandbox: true, platform: 'macos' }] });
});

test('/register rejects a signature made by a different identity (token hijack)', async () => {
  const env = fakeEnv();
  const victim = identity();
  const attacker = identity();
  const ts = now();
  const res = await worker.fetch(post('/register', {
    nodeId: victim.nodeId, token: TOKEN_A, ts, sig: attacker.sign(TOKEN_A, ts),
  }), env);
  assert.equal(res.status, 401);
  assert.equal(env.TOKENS.map.size, 0, 'nothing may be written for an unauthenticated registration');
});

test('/register rejects a signature over a different token (signature is bound to the token)', async () => {
  const env = fakeEnv();
  const id = identity();
  const ts = now();
  const res = await worker.fetch(post('/register', { nodeId: id.nodeId, token: TOKEN_B, ts, sig: id.sign(TOKEN_A, ts) }), env);
  assert.equal(res.status, 401);
});

test('/register rejects a stale timestamp outside the 5-minute window (replay)', async () => {
  const env = fakeEnv();
  const id = identity();
  const ts = now() - 301;
  const res = await worker.fetch(post('/register', { nodeId: id.nodeId, token: TOKEN_A, ts, sig: id.sign(TOKEN_A, ts) }), env);
  assert.equal(res.status, 401);
});

test('/register rejects missing / malformed fields with 4xx, never 500', async () => {
  const env = fakeEnv();
  const id = identity();
  const ts = now();
  const cases = [
    { nodeId: id.nodeId, token: 'NOT-HEX', ts, sig: id.sign('NOT-HEX', ts) },   // non-hex token
    { token: TOKEN_A, ts, sig: id.sign(TOKEN_A, ts) },                           // no nodeId
    { nodeId: id.nodeId, token: TOKEN_A, ts },                                    // no sig
    { nodeId: id.nodeId, token: TOKEN_A, ts, sig: '!!!not base64!!!' },           // garbage sig
    { nodeId: 'abcd', token: TOKEN_A, ts, sig: id.sign(TOKEN_A, ts) },            // short node id
  ];
  for (const body of cases) {
    const res = await worker.fetch(post('/register', body), env);
    assert.ok(res.status >= 400 && res.status < 500, `expected 4xx for ${JSON.stringify(body)}, got ${res.status}`);
  }
  assert.equal(env.TOKENS.map.size, 0);
});

test('/register keeps one entry per token, supports multiple devices, and skips no-op writes', async () => {
  const env = fakeEnv();
  const id = identity();
  await register(env, id, TOKEN_A);
  await register(env, id, TOKEN_B);
  const writesBefore = env.TOKENS.writes.length;
  // Re-registering the newest token unchanged is the every-launch path: no KV write.
  const { body } = await register(env, id, TOKEN_B);
  assert.equal(body.devices, 2);
  assert.equal(env.TOKENS.writes.length, writesBefore, 'an unchanged re-registration must not spend a KV write');
  const rec = await env.TOKENS.get(id.nodeId, 'json');
  assert.deepEqual(rec.tokens.map((t) => t.token), [TOKEN_A, TOKEN_B]);
});

test('/register caps an identity at 10 tokens, evicting the oldest', async () => {
  const env = fakeEnv();
  const id = identity();
  for (let i = 0; i < 12; i++) await register(env, id, i.toString(16).padStart(2, '0').repeat(16));
  const rec = await env.TOKENS.get(id.nodeId, 'json');
  assert.equal(rec.tokens.length, 10);
  assert.equal(rec.tokens[0].token, '02'.repeat(16));
});

test('/register-voip and /register-owner also require the identity signature', async () => {
  const env = fakeEnv();
  const id = identity();
  const other = identity();
  for (const path of ['/register-voip', '/register-owner']) {
    const ts = now();
    const bad = await worker.fetch(post(path, { nodeId: id.nodeId, token: TOKEN_A, ts, sig: other.sign(TOKEN_A, ts) }), env);
    assert.equal(bad.status, 401, path);
    const { res } = await register(env, id, TOKEN_A, {}, path);
    assert.equal(res.status, 200, path);
  }
  assert.deepEqual((await env.TOKENS.get(`voip:${id.nodeId}`, 'json')).tokens, [{ token: TOKEN_A, sandbox: false }]);
  assert.deepEqual(await env.TOKENS.get(`owner:${id.nodeId}`, 'json'), { token: TOKEN_A, sandbox: false });
});

// ── /notify ──────────────────────────────────────────────────────────────────────────────────────

test('/notify forwards the sealed ciphertext untouched to every registered device', async () => {
  const env = fakeEnv();
  const id = identity();
  await register(env, id, TOKEN_A);
  await register(env, id, TOKEN_B, { platform: 'macos', sandbox: true });
  const apns = stubApns(200);
  try {
    const sealed = Buffer.from('opaque-sealed-banner-bytes\u0000ÿ').toString('base64');
    const res = await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: sealed }), env);
    assert.equal(res.status, 200);
    assert.equal(apns.calls.length, 2);
    const ios = apns.calls.find((c) => c.url.endsWith(TOKEN_A));
    const mac = apns.calls.find((c) => c.url.endsWith(TOKEN_B));
    assert.equal(ios.body.e, sealed, 'ciphertext must be forwarded byte-for-byte');
    assert.equal(ios.body.aps['mutable-content'], 1, 'iOS gets the NSE path');
    assert.equal(ios.init.headers['apns-push-type'], 'alert');
    assert.ok(ios.url.startsWith('https://api.push.apple.com/'));
    // The fallback banner must never contain anything but generic text.
    assert.deepEqual(ios.body.aps.alert, { title: 'Haven', body: 'New activity' });
    assert.equal(mac.body.e, sealed);
    assert.equal(mac.body.aps.alert, undefined, 'macOS gets a silent push, no banner');
    assert.equal(mac.init.headers['apns-push-type'], 'background');
    assert.ok(mac.url.startsWith('https://api.sandbox.push.apple.com/'), 'sandbox tokens go to the sandbox host');
    assert.match(ios.init.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/, 'ES256 provider JWT');
  } finally { apns.restore(); }
});

test('/notify answers an unregistered node exactly like a registered one (no existence oracle) and sends nothing', async () => {
  const env = fakeEnv();
  const apns = stubApns(200);
  try {
    const res = await worker.fetch(post('/notify', { nodeId: identity().nodeId, ciphertext: 'AAAA' }), env);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { ok: true });
    assert.equal(apns.calls.length, 0);
  } finally { apns.restore(); }
});

test('/notify requires ciphertext unless silent', async () => {
  const env = fakeEnv();
  const res = await worker.fetch(post('/notify', { nodeId: identity().nodeId }), env);
  assert.equal(res.status, 400);
});

test('/notify prunes tokens APNs reports as gone (410) and keeps the rest', async () => {
  const env = fakeEnv();
  const id = identity();
  await register(env, id, TOKEN_A);
  await register(env, id, TOKEN_B);
  const apns = stubApns((url) => (url.endsWith(TOKEN_A) ? 410 : 200));
  try {
    await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'AAAA' }), env);
    assert.deepEqual((await env.TOKENS.get(id.nodeId, 'json')).tokens.map((t) => t.token), [TOKEN_B]);
  } finally { apns.restore(); }
});

test('/notify inlines the sealed event only while the payload fits APNs 4KB', async () => {
  const env = fakeEnv();
  const id = identity();
  await register(env, id, TOKEN_A);
  const apns = stubApns(200);
  try {
    await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'AAAA', event: 'E'.repeat(100) }), env);
    await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'AAAA', event: 'E'.repeat(5000) }), env);
    assert.equal(apns.calls[0].body.ev, 'E'.repeat(100));
    assert.equal(apns.calls[1].body.ev, undefined, 'an oversized event must be dropped, not sent');
    assert.ok(apns.calls.every((c) => c.init.body.length < 4096));
  } finally { apns.restore(); }
});

test('/notify is rate limited per source IP (60/min) and the limit answers uniformly', async () => {
  const env = fakeEnv();
  const id = identity();
  await register(env, id, TOKEN_A);
  const apns = stubApns(200);
  try {
    const ip = '192.0.2.77';
    for (let i = 0; i < 60; i++) await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'AAAA' }, ip), env);
    assert.equal(apns.calls.length, 60);
    const res = await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'AAAA' }, ip), env);
    assert.equal(res.status, 200);
    assert.equal(apns.calls.length, 60, 'the 61st request must not reach APNs');
    // A different source is unaffected.
    await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'AAAA' }, '192.0.2.78'), env);
    assert.equal(apns.calls.length, 61);
  } finally { apns.restore(); }
});

// ── /call ────────────────────────────────────────────────────────────────────────────────────────

test('/call rings VoIP tokens with a short expiry and the .voip topic', async () => {
  const env = fakeEnv();
  const id = identity();
  await register(env, id, TOKEN_A, {}, '/register-voip');
  const apns = stubApns(200);
  try {
    const res = await worker.fetch(post('/call', { nodeId: id.nodeId, ciphertext: 'c2VhbGVk' }), env);
    assert.equal(res.status, 200);
    assert.equal(apns.calls.length, 1);
    const h = apns.calls[0].init.headers;
    assert.equal(h['apns-push-type'], 'voip');
    assert.equal(h['apns-topic'], 'com.example.haven.voip');
    const exp = Number(h['apns-expiration']);
    assert.ok(exp > now() && exp <= now() + 46, 'a late call push must expire instead of ringing a ghost call');
    assert.deepEqual(apns.calls[0].body, { e: 'c2VhbGVk' });
  } finally { apns.restore(); }
});

test('/call falls back to a generic alert push when no VoIP token works', async () => {
  const env = fakeEnv();
  const id = identity();
  await register(env, id, TOKEN_A);   // regular token only
  const apns = stubApns(200);
  try {
    await worker.fetch(post('/call', { nodeId: id.nodeId, ciphertext: 'c2VhbGVk' }), env);
    assert.equal(apns.calls.length, 1);
    assert.equal(apns.calls[0].body.call, 1);
    assert.equal(apns.calls[0].body.aps.alert.body, 'Incoming call');
    assert.equal(apns.calls[0].body.e, 'c2VhbGVk');
  } finally { apns.restore(); }
});

test('/call for an unknown node answers 200 and sends nothing', async () => {
  const env = fakeEnv();
  const apns = stubApns(200);
  try {
    const res = await worker.fetch(post('/call', { nodeId: identity().nodeId, ciphertext: 'x' }), env);
    assert.equal(res.status, 200);
    assert.equal(apns.calls.length, 0);
  } finally { apns.restore(); }
});

// ── /flag ────────────────────────────────────────────────────────────────────────────────────────

function signedFlag(reporter, subject, reason, ts = now(), action = 'report') {
  const material = `flag-v1:${subject}:${action}:${reason}`;
  return { actor: reporter.nodeId, subject, action, reason, ts, sig: reporter.sign(material, ts) };
}

test('/flag stores subject/action/category only — never the reporter — with a 90-day TTL', async () => {
  const env = fakeEnv();
  const reporter = identity();
  const subject = identity().nodeId;
  const res = await worker.fetch(post('/flag', signedFlag(reporter, subject, 'harassment')), env);
  assert.equal(res.status, 200);
  const rows = [...env.TOKENS.map.entries()].filter(([k]) => k.startsWith('ledger:'));
  assert.equal(rows.length, 1);
  const [key, { value, opts }] = rows[0];
  assert.deepEqual(JSON.parse(value), { subject, action: 'report', reason: 'harassment' });
  assert.ok(!key.includes(reporter.nodeId) && !value.includes(reporter.nodeId), 'reporter must not be stored');
  assert.equal(opts.expirationTtl, 90 * 24 * 3600);
});

test('/flag replayed inside the window rewrites the same row instead of adding one', async () => {
  const env = fakeEnv();
  const reporter = identity();
  const body = signedFlag(reporter, identity().nodeId, 'spam');
  await worker.fetch(post('/flag', body), env);
  await worker.fetch(post('/flag', body), env);
  assert.equal([...env.TOKENS.map.keys()].filter((k) => k.startsWith('ledger:')).length, 1);
});

test('/flag refuses non-report actions, unsigned flags and re-aimed signatures', async () => {
  const env = fakeEnv();
  const reporter = identity();
  const subject = identity().nodeId;
  // block is a private act and must not be expressible.
  let res = await worker.fetch(post('/flag', signedFlag(reporter, subject, 'x', now(), 'block')), env);
  assert.equal(res.status, 400);
  // A signature for subject A cannot be re-aimed at subject B.
  const good = signedFlag(reporter, subject, 'spam');
  res = await worker.fetch(post('/flag', { ...good, subject: identity().nodeId }), env);
  assert.equal(res.status, 401);
  // Nor its category changed.
  res = await worker.fetch(post('/flag', { ...good, reason: 'csam' }), env);
  assert.equal(res.status, 401);
  // A registration signature (over a hex token) is not a flag signature.
  const ts = now();
  res = await worker.fetch(post('/flag', { actor: reporter.nodeId, subject, action: 'report', reason: '', ts, sig: reporter.sign(TOKEN_A, ts) }), env);
  assert.equal(res.status, 401);
  assert.equal([...env.TOKENS.map.keys()].filter((k) => k.startsWith('ledger:')).length, 0);
});

test('/flag truncates the category to 64 chars (no free text leaves the circle)', async () => {
  const env = fakeEnv();
  const reporter = identity();
  const long = 'r'.repeat(200);
  // The client signs the truncated category — that is what the worker verifies.
  const body = signedFlag(reporter, identity().nodeId, long.slice(0, 64));
  body.reason = long;
  const res = await worker.fetch(post('/flag', body), env);
  assert.equal(res.status, 200);
  const [, { value }] = [...env.TOKENS.map.entries()].find(([k]) => k.startsWith('ledger:'));
  assert.equal(JSON.parse(value).reason.length, 64);
});

// ── misc ─────────────────────────────────────────────────────────────────────────────────────────

test('GET is a health check and unknown paths are 404', async () => {
  const env = fakeEnv();
  const get = await worker.fetch(new Request('https://push.example/'), env);
  assert.deepEqual(await get.json(), { ok: true, service: 'haven-push' });
  const nf = await worker.fetch(post('/nope', {}), env);
  assert.equal(nf.status, 404);
});

test('scheduled() silently nudges every S3 owner and drops owners whose token died', async () => {
  const env = fakeEnv();
  const alive = identity();
  const dead = identity();
  await register(env, alive, TOKEN_A, {}, '/register-owner');
  await register(env, dead, TOKEN_B, {}, '/register-owner');
  const apns = stubApns((url) => (url.endsWith(TOKEN_B) ? 410 : 200));
  try {
    const pending = [];
    await worker.scheduled({}, env, { waitUntil: (p) => pending.push(p) });
    await Promise.all(pending);
    assert.equal(apns.calls.length, 2);
    for (const c of apns.calls) {
      assert.deepEqual(c.body, { aps: { 'content-available': 1 }, remint: 1 });
      assert.equal(c.init.headers['apns-push-type'], 'background');
    }
    assert.ok(await env.TOKENS.get(`owner:${alive.nodeId}`));
    assert.equal(await env.TOKENS.get(`owner:${dead.nodeId}`), null);
  } finally { apns.restore(); }
});

// ── cross-implementation contract with the Rust core ─────────────────────────────────────────────

test('a registration signed by the Rust core (shared vector) verifies in the worker', async () => {
  // Same constants as core/haven-ffi/tests/links_and_moderation.rs
  // (push_registration_signature_matches_the_worker_vector): Account::from_seed([0x42; 32])
  // .sign_push_registration(TOKEN, TS). If either side changes the signed message, one of the two
  // tests fails instead of every device silently losing push.
  const nodeId = 'a2cdb6c5843e48f2b000afce44b4ba4aa83b8d2cd762d12857b1640dd90f5367';
  const token = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
  const ts = 1_800_000_000;
  const sig = 'rnpFvI/SWgHX41JnDTwq2iaKI430QtUkANrLLUhD3j59ygsJKZyLc3ZOpap1Su8uJSKc/DsK//rejAgNn/BJAA==';
  const realNow = Date.now;
  Date.now = () => ts * 1000 + 10_000;   // inside the 5-minute freshness window
  try {
    const env = fakeEnv();
    const ok = await worker.fetch(post('/register', { nodeId, token, ts, sig }), env);
    assert.equal(ok.status, 200);
    const flipped = Buffer.from(sig, 'base64'); flipped[5] ^= 1;
    const bad = await worker.fetch(post('/register', { nodeId, token, ts, sig: flipped.toString('base64') }), fakeEnv());
    assert.equal(bad.status, 401);
  } finally { Date.now = realNow; }
});

// ── Android FCM wake (optional layer; content-free) ──────────────────────────────────────────────

import { generateKeyPairSync as genKeys } from 'node:crypto';

const FCM_TOKEN = 'fcm_' + 'AbC-_9:'.repeat(30);
const fcmSa = () => JSON.stringify({
  project_id: 'haven-test',
  client_email: 'push@haven-test.iam.gserviceaccount.com',
  private_key: genKeys('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' }),
  token_uri: 'https://oauth2.googleapis.com/token',
});

// Exact-host (or subdomain) match; a substring check would also accept evil.example/?x=apple.com.
function onHost(u, domain) {
  try { const h = new URL(u).hostname; return h === domain || h.endsWith('.' + domain); } catch { return false; }
}

function stubFcm(sendStatus = 200) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    calls.push({ url: u, init, body: init?.body && onHost(u, 'fcm.googleapis.com') ? JSON.parse(init.body) : init?.body });
    if (onHost(u, 'oauth2.googleapis.com')) return new Response(JSON.stringify({ access_token: 'ya29.fake' }), { status: 200 });
    if (onHost(u, 'fcm.googleapis.com')) {
      return sendStatus === 200
        ? new Response('{}', { status: 200 })
        : new Response(JSON.stringify({ error: { status: 'UNREGISTERED' } }), { status: sendStatus });
    }
    return new Response('', { status: 200 });   // APNs
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

async function registerAndroid(env, id, token = FCM_TOKEN) {
  const ts = now();
  const res = await worker.fetch(post('/register', {
    nodeId: id.nodeId, token, platform: 'android', ts, sig: id.sign(`fcm-v1:${token}`, ts),
  }), env);
  return { res, body: await res.json() };
}

test('/register accepts an Android FCM token signed over fcm-v1:<token>', async () => {
  const env = fakeEnv();
  const id = identity();
  const { res, body } = await registerAndroid(env, id);
  assert.equal(res.status, 200);
  assert.equal(body.devices, 1);
  const rec = JSON.parse(env.TOKENS.map.get(id.nodeId).value);
  assert.equal(rec.tokens[0].platform, 'android');
});

test('/register rejects an Android token signed WITHOUT the fcm-v1 prefix (no cross-protocol replay)', async () => {
  const env = fakeEnv();
  const id = identity();
  const ts = now();
  const res = await worker.fetch(post('/register', {
    nodeId: id.nodeId, token: FCM_TOKEN, platform: 'android', ts, sig: id.sign(FCM_TOKEN, ts),
  }), env);
  assert.equal(res.status, 401);
  // …and a non-token string never registers as android either.
  const bad = await worker.fetch(post('/register', {
    nodeId: id.nodeId, token: 'short', platform: 'android', ts, sig: id.sign('fcm-v1:short', ts),
  }), env);
  assert.equal(bad.status, 400);
});

test('/notify wakes an Android device with a data-only, content-free, high-priority message', async () => {
  const env = { ...fakeEnv(), FCM_SERVICE_ACCOUNT: fcmSa() };
  const id = identity();
  await registerAndroid(env, id);
  const fcm = stubFcm(200);
  try {
    const res = await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'c2VjcmV0', event: 'ZXZlbnQ=' }), env);
    assert.equal(res.status, 200);
    const send = fcm.calls.find((c) => c.url.includes('/v1/projects/haven-test/messages:send'));
    assert.ok(send, 'FCM send happened');
    assert.equal(send.init.headers.authorization, 'Bearer ya29.fake');
    const m = send.body.message;
    assert.equal(m.token, FCM_TOKEN);
    assert.deepEqual(m.data, { w: '1' }, 'the wake carries no content at all');
    assert.equal(m.notification, undefined, 'data-only: no notification block');
    assert.equal(m.android.priority, 'HIGH');
    assert.ok(!JSON.stringify(send.body).includes('c2VjcmV0'), 'ciphertext never reaches FCM');
    assert.equal(fcm.calls.filter((c) => onHost(c.url, 'apple.com')).length, 0, 'no APNs call for an Android-only node');
  } finally { fcm.restore(); }
});

test('/notify prunes an Android token FCM reports UNREGISTERED and never touches APNs tokens', async () => {
  const env = { ...fakeEnv(), FCM_SERVICE_ACCOUNT: fcmSa() };
  const id = identity();
  await register(env, id, TOKEN_A);
  await registerAndroid(env, id);
  const fcm = stubFcm(404);
  try {
    const res = await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'YQ==' }), env);
    assert.equal(res.status, 200, 'the iOS device still succeeded');
    const rec = JSON.parse(env.TOKENS.map.get(id.nodeId).value);
    assert.deepEqual(rec.tokens.map((t) => t.token), [TOKEN_A], 'dead Android token dropped, iOS kept');
    assert.ok(fcm.calls.some((c) => c.url.endsWith(TOKEN_A)), 'APNs got only the hex token');
    assert.ok(!fcm.calls.some((c) => onHost(c.url, 'apple.com') && c.url.includes(FCM_TOKEN)));
  } finally { fcm.restore(); }
});

test('Android push is a silent no-op until FCM_SERVICE_ACCOUNT is configured', async () => {
  const env = fakeEnv();   // no service account
  const id = identity();
  await registerAndroid(env, id);
  const fcm = stubFcm(200);
  try {
    const res = await worker.fetch(post('/notify', { nodeId: id.nodeId, ciphertext: 'YQ==' }), env);
    assert.ok([200, 502].includes(res.status), 'never a 500');
    assert.equal(fcm.calls.length, 0, 'nothing is sent');
  } finally { fcm.restore(); }
});

test('/call wakes Android with a short-lived data message and does not send its token to APNs', async () => {
  const env = { ...fakeEnv(), FCM_SERVICE_ACCOUNT: fcmSa() };
  const id = identity();
  await registerAndroid(env, id);
  const fcm = stubFcm(200);
  try {
    const res = await worker.fetch(post('/call', { nodeId: id.nodeId, ciphertext: 'c2VhbGVk' }), env);
    assert.equal(res.status, 200);
    const send = fcm.calls.find((c) => c.url.includes('messages:send'));
    assert.deepEqual(send.body.message.data, { w: '1', c: '1' });
    assert.equal(send.body.message.android.ttl, '45s');
    assert.equal(fcm.calls.filter((c) => onHost(c.url, 'apple.com')).length, 0);
  } finally { fcm.restore(); }
});

// ── Web Push (browsers) ──────────────────────────────────────────────────────────────────────────
//
// A browser holds no account key: it registers with its DEVICE key plus the credential the
// account signed for that device. `webDevice` builds exactly what the core produces
// (core/haven-p2p/src/device.rs `DeviceCredential::signing_bytes`): the signed bytes and the
// Ed25519 half of the account's signature over them.
import { createPublicKey, verify as cryptoVerify } from 'node:crypto';

const vapidPair = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const vapidJwk = vapidPair.privateKey.export({ format: 'jwk' });
const VAPID_PUBLIC = Buffer.concat([Buffer.from([4]), Buffer.from(vapidJwk.x, 'base64url'), Buffer.from(vapidJwk.y, 'base64url')]).toString('base64url');
const webEnv = () => ({ ...fakeEnv(), VAPID_PUBLIC_KEY: VAPID_PUBLIC, VAPID_PRIVATE_KEY: vapidJwk.d, VAPID_SUBJECT: 'https://haven.example/contact' });

function edIdentity() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = Buffer.from(publicKey.export({ format: 'der', type: 'spki' }).subarray(-32));
  return { raw, hex: raw.toString('hex'), signRaw: (bytes) => edSign(null, bytes, privateKey) };
}

/// A device the account has linked. `name` decides whether it is a web device ("🌐 …").
function webDevice(account, name = '🌐 Chrome on Mac') {
  const dev = edIdentity();
  const nameB = Buffer.from(name, 'utf8');
  const head = Buffer.alloc(12);
  head.writeBigUInt64LE(1700000000n, 0);
  head.writeUInt32LE(nameB.length, 8);
  // The bundle is ed25519(32) ‖ x25519(32) ‖ post-quantum keys; only its first 32 bytes matter here.
  const bundle = Buffer.concat([dev.raw, Buffer.alloc(200, 7)]);
  const signed = Buffer.concat([Buffer.from('haven-device-cred-v1'), account.raw, head, nameB, bundle]);
  return {
    dev,
    cred: signed.toString('base64'),
    credSig: account.signRaw(signed).toString('base64'),
    sign: (endpoint, ts) => dev.signRaw(Buffer.from(`haven-push-register-v1:${dev.hex}:webpush-v1:${endpoint}:${ts}`)).toString('base64'),
  };
}

const ENDPOINT = 'https://fcm.googleapis.com/fcm/send/abc123:def';
function webReg(account, d, over = {}) {
  const ts = now();
  const endpoint = over.token ?? ENDPOINT;
  return { nodeId: account.hex, platform: 'web', token: endpoint, ts, sig: d.sign(endpoint, ts), deviceId: d.dev.hex, cred: d.cred, credSig: d.credSig, ...over };
}
async function send(env, path, body) {
  const res = await worker.fetch(post(path, body), env);
  return { res, body: await res.json() };
}

test('a browser asks for the VAPID key cross-origin; there is none until Web Push is configured', async () => {
  const get = (env) => worker.fetch(new Request('https://push.example/webpush'), env);
  assert.equal((await get(fakeEnv())).status, 404);
  const res = await get(webEnv());
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  assert.deepEqual(await res.json(), { key: VAPID_PUBLIC });
  const pre = await worker.fetch(new Request('https://push.example/register', { method: 'OPTIONS' }), webEnv());
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get('access-control-allow-origin'), '*');
  assert.match(pre.headers.get('access-control-allow-headers'), /content-type/);
});

test('a linked browser registers its endpoint with its device key and the account-signed credential', async () => {
  const env = webEnv();
  const account = edIdentity();
  const d = webDevice(account);
  const { res, body } = await send(env, '/register', webReg(account, d));
  assert.equal(res.status, 200, JSON.stringify(body));
  const [t] = (await env.TOKENS.get(account.hex, 'json')).tokens;
  assert.equal(t.token, ENDPOINT);
  assert.equal(t.platform, 'web');
  assert.equal(t.device, d.dev.hex);
  assert.ok(t.exp > now() + 29 * 86400, 'a registration lasts about thirty days');

  // Renewing it straight away is not a KV write; a new endpoint replaces the old one.
  const writes = env.TOKENS.writes.length;
  assert.equal((await send(env, '/register', webReg(account, d))).res.status, 200);
  assert.equal(env.TOKENS.writes.length, writes);
  const next = 'https://updates.push.services.mozilla.com/wpush/v2/xyz';
  assert.equal((await send(env, '/register', webReg(account, d, { token: next }))).res.status, 200);
  assert.deepEqual((await env.TOKENS.get(account.hex, 'json')).tokens.map((x) => x.token), [next]);
});

test('nobody registers a browser under an account that has not linked it', async () => {
  const env = webEnv();
  const account = edIdentity(), stranger = edIdentity();
  const d = webDevice(account);
  const refused = async (body, why) => {
    const { res } = await send(env, '/register', body);
    assert.equal(res.status, 401, why);
  };
  // A credential signed by some other account, presented under the victim's node id.
  const forged = webDevice(stranger);
  await refused(webReg(account, forged), 'a credential the account did not sign');
  // A real credential, but the endpoint signed by a different device key.
  const other = webDevice(account);
  await refused({ ...webReg(account, d), sig: other.sign(ENDPOINT, now()) }, 'signed by another device');
  await refused({ ...webReg(account, d), deviceId: other.dev.hex }, 'the credential names a different device');
  // A signature over a different endpoint, and one without the webpush prefix.
  await refused({ ...webReg(account, d), token: 'https://fcm.googleapis.com/fcm/send/other' }, 'signed for another endpoint');
  const ts = now();
  await refused({ ...webReg(account, d), ts, sig: d.dev.signRaw(Buffer.from(`haven-push-register-v1:${d.dev.hex}:${ENDPOINT}:${ts}`)).toString('base64') }, 'no webpush-v1 prefix');
  // A stale timestamp.
  const old = now() - 3600;
  await refused({ ...webReg(account, d), ts: old, sig: d.sign(ENDPOINT, old) }, 'stale');
  // A credential for a device the account did NOT mark as a browser (a phone's credential).
  const phone = webDevice(account, "Blaine's iPhone");
  await refused(webReg(account, phone), 'not a web device');
  // A tampered credential: the mark added after the account signed.
  const tampered = Buffer.from(phone.cred, 'base64');
  await refused({ ...webReg(account, phone), cred: Buffer.concat([tampered.subarray(0, 64), Buffer.from('🌐 '), tampered.subarray(64)]).toString('base64') }, 'tampered');
  assert.equal(env.TOKENS.map.size, 0, 'nothing is stored for a refused registration');
});

test('an endpoint must be a known push service over https, and Web Push must be configured', async () => {
  const account = edIdentity();
  const d = webDevice(account);
  for (const bad of [
    'https://evil.example/hook', 'http://fcm.googleapis.com/fcm/send/x', 'https://fcm.googleapis.com.evil.example/x',
    'https://fcm.googleapis.com:8443/x', 'https://user@fcm.googleapis.com/x', 'not a url', `https://fcm.googleapis.com/${'a'.repeat(1100)}`,
  ]) {
    const { res } = await send(webEnv(), '/register', webReg(account, d, { token: bad }));
    assert.equal(res.status, 400, bad);
  }
  for (const good of ['https://web.push.apple.com/QGx', 'https://db5p.notify.windows.com/w/?token=abc']) {
    const { res } = await send(webEnv(), '/register', webReg(account, d, { token: good }));
    assert.equal(res.status, 200, good);
  }
  assert.equal((await send(fakeEnv(), '/register', webReg(account, d))).res.status, 404, 'off until the owner sets the VAPID keys');
});

test('/notify rings a browser with an empty, VAPID-signed push — and nothing else', async () => {
  const env = webEnv();
  const account = edIdentity();
  await send(env, '/register', webReg(account, webDevice(account)));
  const apns = stubApns(200);
  try {
    const { res } = await send(env, '/notify', { nodeId: account.hex, ciphertext: 'c2VhbGVk', event: 'ZXZlbnQ=' });
    assert.equal(res.status, 200);
    assert.equal(apns.calls.length, 1, 'one request, to the push service only');
    const call = apns.calls[0];
    assert.equal(call.url, ENDPOINT);
    assert.equal(call.init.method, 'POST');
    assert.equal(call.init.body, undefined, 'no payload: nothing to read, nothing to decrypt');
    assert.equal(call.init.headers.ttl, '300');
    const m = /^vapid t=([^,]+), k=(.+)$/.exec(call.init.headers.authorization);
    assert.ok(m, call.init.headers.authorization);
    assert.equal(m[2], VAPID_PUBLIC);
    const [h, c, s] = m[1].split('.');
    assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url')), { typ: 'JWT', alg: 'ES256' });
    const claims = JSON.parse(Buffer.from(c, 'base64url'));
    assert.equal(claims.aud, 'https://fcm.googleapis.com');
    assert.equal(claims.sub, 'https://haven.example/contact');
    assert.ok(claims.exp > now() && claims.exp <= now() + 24 * 3600, 'the push services refuse a token valid for more than a day');
    const pub = createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: vapidJwk.x, y: vapidJwk.y }, format: 'jwk' });
    assert.ok(cryptoVerify('sha256', Buffer.from(`${h}.${c}`), { key: pub, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')), 'signed by the VAPID key');

    // A silent notify (my own post reaching my other devices) must not ring a browser: a browser
    // has to show something for every push it gets.
    await send(env, '/notify', { nodeId: account.hex, silent: true });
    assert.equal(apns.calls.length, 1);
    // A call rings it too, briefly.
    await send(env, '/call', { nodeId: account.hex, ciphertext: '_' });
    assert.equal(apns.calls.length, 2);
    assert.equal(apns.calls[1].init.headers.ttl, '45');
  } finally { apns.restore(); }
});

test('a browser that unsubscribed, or whose registration lapsed, is forgotten', async () => {
  const env = webEnv();
  const account = edIdentity();
  await send(env, '/register', webReg(account, webDevice(account)));
  const gone = stubApns(410);
  try {
    await send(env, '/notify', { nodeId: account.hex, ciphertext: 'c2VhbGVk' });
  } finally { gone.restore(); }
  assert.equal(await env.TOKENS.get(account.hex, 'json'), null, 'a 410 from the push service drops the endpoint');

  await send(env, '/register', webReg(account, webDevice(account)));
  const rec = await env.TOKENS.get(account.hex, 'json');
  rec.tokens[0].exp = now() - 1;
  await env.TOKENS.put(account.hex, JSON.stringify(rec));
  const quiet = stubApns(200);
  try {
    await send(env, '/notify', { nodeId: account.hex, ciphertext: 'c2VhbGVk' });
    assert.equal(quiet.calls.length, 0, 'an expired registration is not rung');
  } finally { quiet.restore(); }
  assert.equal(await env.TOKENS.get(account.hex, 'json'), null);
});

test('a browser registration leaves the account\'s phones exactly as they were', async () => {
  const env = webEnv();
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = Buffer.from(publicKey.export({ format: 'der', type: 'spki' }).subarray(-32));
  const account = { raw, hex: raw.toString('hex'), signRaw: (b) => edSign(null, b, privateKey) };
  const ts = now();
  const sig = account.signRaw(Buffer.from(`haven-push-register-v1:${account.hex}:${TOKEN_A}:${ts}`)).toString('base64');
  assert.equal((await send(env, '/register', { nodeId: account.hex, token: TOKEN_A, ts, sig })).res.status, 200);
  await send(env, '/register', webReg(account, webDevice(account)));
  const apns = stubApns((url) => (url.startsWith('https://fcm.googleapis.com') ? 410 : 200));
  try {
    const { res } = await send(env, '/notify', { nodeId: account.hex, ciphertext: 'c2VhbGVk' });
    assert.equal(res.status, 200);
    assert.equal(apns.calls.filter((c) => c.url.includes('api.push.apple.com')).length, 1, 'the phone is still pushed');
  } finally { apns.restore(); }
  assert.deepEqual((await env.TOKENS.get(account.hex, 'json')).tokens.map((t) => t.token), [TOKEN_A], 'only the dead browser is dropped');
});


test('a browser registration built by the Rust core (shared vector) verifies in the worker', async () => {
  // push/webpush-vector.json is produced by core/haven-ffi/tests/links_and_moderation.rs
  // (web_push_registration_matches_the_worker_vector) from fixed seeds. The worker reads the
  // credential's raw bytes, so this is what keeps its parser and the core's layout the same thing.
  const { readFileSync } = await import('node:fs');
  const v = JSON.parse(readFileSync(new URL('./webpush-vector.json', import.meta.url), 'utf8'));
  const realNow = Date.now;
  Date.now = () => v.ts * 1000 + 10_000;
  try {
    const env = webEnv();
    const ok = await send(env, '/register', v);
    assert.equal(ok.res.status, 200, JSON.stringify(ok.body));
    assert.equal((await env.TOKENS.get(v.nodeId, 'json')).tokens[0].device, v.deviceId);
    const flipped = Buffer.from(v.cred, 'base64'); flipped[70] ^= 1;   // inside the signed name
    assert.equal((await send(webEnv(), '/register', { ...v, cred: flipped.toString('base64') })).res.status, 401);
  } finally { Date.now = realNow; }
});
