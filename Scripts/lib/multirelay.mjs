// Pure decisions for the `multirelay` e2e step (Scripts/qa-e2e-full.mjs): friends who each run
// their OWN relay must interoperate without colliding. Everything here is a judgement over data the
// harness already read — relay store listings, `relay_stats` dump rows, the counting proxy's hit
// log, a relay's exit status — so it is unit-tested (multirelay.test.mjs, soren suite `qa-harness`)
// instead of being trusted. The only side effect in this file is `crypto` for the stranger's
// request signature, which is deterministic given its inputs.
import { createHash, createPrivateKey, generateKeyPairSync, sign as edSign } from 'node:crypto';

// ── ports ────────────────────────────────────────────────────────────────────────────────────

/** Ports the fleet already owns and a harness relay must never take: the stub's in-app relay
 *  (8674 media, 8675 path proxy), its DERP (3340) and TURN (3478). The user's own `haven-relay`
 *  defaults to 8674 as well. */
export const RESERVED_PORTS = Object.freeze([8674, 8675, 3340, 3478]);

/**
 * The step's port plan from one base. Every relay gets a PUBLIC port (the counting proxy — what
 * clients are told) and an INTERNAL one (the relay's `--http`, loopback only). `ra2` is R_A after
 * its restart on a new port. Throws when the plan would touch a reserved port or collide with
 * itself, because a silent overlap here is exactly the bug the step exists to catch.
 */
export function portPlan(base = 8684, internalOffset = 10000) {
  const pub = { ra: base, rc: base + 1, ra2: base + 2 };
  const plan = {
    ra: { pub: pub.ra, internal: pub.ra + internalOffset },
    rc: { pub: pub.rc, internal: pub.rc + internalOffset },
    ra2: { pub: pub.ra2, internal: pub.ra2 + internalOffset },
    control: base + 5,
  };
  const all = [plan.ra.pub, plan.ra.internal, plan.rc.pub, plan.rc.internal, plan.ra2.pub, plan.ra2.internal, plan.control];
  for (const p of all) {
    if (!Number.isInteger(p) || p < 1024 || p > 65535) throw new Error(`port ${p} out of range`);
    if (RESERVED_PORTS.includes(p)) throw new Error(`port ${p} is reserved (stub / user relay)`);
  }
  if (new Set(all).size !== all.length) throw new Error(`port plan collides with itself: ${all.join(',')}`);
  return plan;
}

/**
 * Did a second relay that was pointed at an occupied port FAIL LOUDLY? Loud = the process exited
 * non-zero on its own, and its output names the port problem. A relay still running when the
 * harness came to look is the silent collision (traffic split between two stores); an exit with
 * no port message is a different failure and must not be scored as the guard working.
 */
export function collisionVerdict({ exited, code, output }) {
  const text = String(output || '');
  if (!exited) return { ok: false, why: 'second relay is STILL RUNNING on an occupied port — silent collision' };
  if (code === 0) return { ok: false, why: 'second relay exited 0 — it neither served nor complained' };
  if (/already (served|in use)|Address already in use|os error 48|os error 98|EADDRINUSE/i.test(text)) {
    return { ok: true, why: (text.match(/^.*(already|in use).*$/mi) || [''])[0].trim().slice(0, 200) };
  }
  return { ok: false, why: `exited ${code} without naming the port: ${text.trim().split('\n').slice(-1)[0]?.slice(0, 160)}` };
}

// ── relay store layout ───────────────────────────────────────────────────────────────────────

/** Reverse of the relay's on-disk component escaping (`%3A` → `:`, then `%25` → `%`). */
export function decodeComp(name) {
  return String(name).replace(/%3A/g, ':').replace(/%25/g, '%');
}

/** What a store key IS: {ns, circle?, account?, rest}. Mirrors blobstore.rs' namespaces. */
export function classifyKey(key) {
  const k = String(key || '');
  const parts = k.split('/');
  if (parts[0] !== 'haven') return { ns: 'other', rest: k };
  switch (parts[1]) {
    case 'mailbox': return { ns: 'mailbox', circle: parts[2] || '', rest: parts.slice(3).join('/') };
    case 'media': return { ns: 'media', ref: parts.slice(2).join('/'), rest: parts.slice(2).join('/') };
    case 'self': return { ns: 'self', account: parts[2] || '', rest: parts.slice(3).join('/') };
    case 'devroster': return { ns: 'devroster', account: parts[2] || '', rest: '' };
    case 'relay': return { ns: 'relay', rest: parts.slice(2).join('/') };
    case 'disc': return { ns: 'disc', rest: parts.slice(2).join('/') };
    case 'invite': case 'invites': return { ns: 'invite', rest: parts.slice(2).join('/') };
    default: return { ns: 'other', rest: k };
  }
}

/** A circle's EVENT envelopes: `haven/mailbox/<circle>/<64-hex sha256>` exactly — not the
 *  per-node `__live__` / `__relay__` / `__hello__` lanes, which come and go by design. */
export function isEventKey(key, circle) {
  const c = classifyKey(key);
  return c.ns === 'mailbox' && (circle === undefined || c.circle === circle) && /^[0-9a-f]{64}$/.test(c.rest);
}

export function eventKeys(keys, circle) {
  return keys.filter((k) => isEventKey(k, circle)).sort();
}

/** Circles that have ANY mailbox key on this store. */
export function mailboxCircles(keys) {
  const out = new Set();
  for (const k of keys) {
    const c = classifyKey(k);
    if (c.ns === 'mailbox' && c.circle) out.add(c.circle);
  }
  return out;
}

/** Media blob keys for a ref, including its chunk keys (`haven/media/<ref>` and `…/<ref>/…`). */
export function holdsMedia(keys, ref) {
  const base = `haven/media/${ref}`;
  return keys.some((k) => k === base || k.startsWith(`${base}/`) || k.startsWith(`${base}.`));
}

/**
 * Separation: every relay holds mailbox content ONLY for circles someone configured it for.
 * `forbidden` maps relay → circles that must never appear there. Returns [{relay, circle, keys}].
 */
export function misplacedCircles(keysByRelay, forbidden) {
  const out = [];
  for (const [relay, circles] of Object.entries(forbidden || {})) {
    const keys = keysByRelay[relay] || [];
    for (const circle of circles || []) {
      const hits = keys.filter((k) => classifyKey(k).ns === 'mailbox' && classifyKey(k).circle === circle);
      if (hits.length) out.push({ relay, circle, keys: hits.length });
    }
  }
  return out;
}

/** Symmetric difference of two key lists (mesh convergence: both relays hold the same set). */
export function keyDiff(a, b) {
  const A = new Set(a), B = new Set(b);
  return { onlyA: [...A].filter((k) => !B.has(k)).sort(), onlyB: [...B].filter((k) => !A.has(k)).sort() };
}

/** LIST stability: over a quiet window, a circle's event-key count may not GROW (a re-seal that
 *  mints a new key per pass is the regrowth this catches). Series of counts, oldest first. */
export function stableCounts(series) {
  if (!series.length) return { ok: false, why: 'no samples' };
  for (let i = 1; i < series.length; i++) {
    if (series[i] > series[i - 1]) return { ok: false, why: `grew ${series[i - 1]} → ${series[i]} with nothing posted` };
  }
  return { ok: true, why: series.join(' → ') };
}

// ── clients' relay lists (`relay_stats`) ─────────────────────────────────────────────────────

/** First 12 hex of SHA-256(token) — the dump's `tokenFp` (Apple SharedStore / Android HavenNet). */
export function tokenFingerprint(token) {
  if (!token) return '';
  return createHash('sha256').update(String(token), 'utf8').digest('hex').slice(0, 12);
}

/** The port an http URL names (explicit or scheme default). */
export function urlPort(u) {
  try { const x = new URL(u); return Number(x.port || (x.protocol === 'https:' ? 443 : 80)); } catch { return null; }
}

/**
 * Attribution: in a client's `relay_stats`, every row for a relay the harness knows must carry
 * THAT relay's token fingerprint and only URLs on that relay's ports — an announce of one relay
 * must never overwrite another's entry. `truth` = {hex: {tokenFp, ports:[…]}}. Rows for relays
 * the harness doesn't know are ignored. Returns a list of problems (empty = attributed correctly).
 */
export function attributionProblems(rows, truth) {
  const problems = [];
  const owners = new Map();
  for (const [hex, t] of Object.entries(truth)) for (const p of t.ports || []) owners.set(p, hex);
  for (const r of rows || []) {
    const hex = String(r.relay || '').toLowerCase();
    const t = truth[hex];
    if (!t) continue;
    if (r.tokenFp && t.tokenFp && r.tokenFp !== t.tokenFp) problems.push(`${hex.slice(0, 8)}: token of another relay (${r.tokenFp})`);
    for (const u of r.urls || []) {
      const owner = owners.get(urlPort(u));
      if (owner && owner !== hex) problems.push(`${hex.slice(0, 8)}: url ${u} belongs to ${owner.slice(0, 8)}`);
    }
  }
  return problems;
}

/** The row for `hex` in a dump's `relay_stats` (or null). */
export function statsRow(dump, hex) {
  const h = String(hex || '').toLowerCase();
  return (dump?.relay_stats || []).find((r) => String(r.relay || '').toLowerCase() === h) || null;
}

/** Sum of one counter over the rows for `hex` (0 when absent). */
export function statsCounter(dump, hex, key) {
  const r = statsRow(dump, hex);
  return typeof r?.[key] === 'number' ? r[key] : 0;
}

/** Does this client hold `hex` with a URL on `port` (it learned that front door)? */
export function knowsUrlPort(dump, hex, port) {
  return (statsRow(dump, hex)?.urls || []).some((u) => urlPort(u) === port);
}

// ── the counting proxy's log (no relay logs anything — see docs/QA.md ▸ multirelay) ──────────

/** Requests the proxy saw on `port` in [fromMs, toMs). `hits` = [{port, t, status}] or the proxy's
 *  per-port `times` arrays. */
export function hitsBetween(times, fromMs, toMs) {
  return (times || []).filter((t) => t >= fromMs && t < toMs).length;
}

/**
 * No thundering herd: while a relay is DOWN, the whole fleet's request rate against it must stay
 * bounded and must not climb. `times` are request timestamps against the dead relay, the window is
 * [downAt, upAt). The first `settleMs` are excluded (in-flight work failing over is not a storm).
 * Returns {ok, perMin, firstHalf, secondHalf, why}.
 */
export function herdVerdict(times, { downAt, upAt, settleMs = 15_000, maxPerMin = 60 }) {
  const from = downAt + settleMs;
  const span = upAt - from;
  if (span < 20_000) return { ok: false, perMin: 0, firstHalf: 0, secondHalf: 0, why: `window too short (${span} ms)` };
  const n = hitsBetween(times, from, upAt);
  const mid = from + span / 2;
  const firstHalf = hitsBetween(times, from, mid), secondHalf = hitsBetween(times, mid, upAt);
  const perMin = Math.round((n / span) * 60_000 * 10) / 10;
  // "Not climbing" with slack: a backoff that is working holds flat or decays; a storm doubles. A
  // climb only counts once the second half is running at half the cap or more — a fleet going
  // from 9 to 27 requests over two minutes is readers failing over one by one, not a stampede.
  const secondPerMin = (secondHalf / (span / 2)) * 60_000;
  const climbing = secondHalf > Math.max(firstHalf * 2, firstHalf + 10) && secondPerMin >= maxPerMin / 2;
  const ok = perMin <= maxPerMin && !climbing;
  return { ok, perMin, firstHalf, secondHalf,
    why: `${n} request(s) in ${(span / 1000).toFixed(0)}s = ${perMin}/min (max ${maxPerMin}); halves ${firstHalf} → ${secondHalf}${climbing ? ' CLIMBING' : ''}` };
}

// ── strangers (enrollment isolation) ─────────────────────────────────────────────────────────

/** blake3 of the empty body — every GET / HEAD / LIST signs this digest (httprelay.rs `body_digest`). */
export const BLAKE3_EMPTY = 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262';

/** A throwaway Ed25519 identity: {nodeHex, privateKey}. Its node id is in no circle anywhere. */
export function strangerIdentity(seed) {
  let privateKey;
  if (seed) {
    // PKCS#8 wrapper for a raw 32-byte Ed25519 seed (RFC 8410).
    const der = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.from(seed, 'hex')]);
    privateKey = createPrivateKey({ key: der, format: 'der', type: 'pkcs8' });
  } else {
    privateKey = generateKeyPairSync('ed25519').privateKey;
  }
  const jwk = privateKey.export({ format: 'jwk' });
  const nodeHex = Buffer.from(jwk.x, 'base64url').toString('hex');
  return { nodeHex, privateKey };
}

/**
 * `Authorization: Haven <node>.<ts>.<nonce>.<digest>.<sig>` for a BODYLESS request, signed exactly
 * as httprelay.rs `auth_header` does (domain ‖ token ‖ method ‖ key ‖ ts ‖ nonce ‖ digest). Used
 * with the relay's REAL token: the signature then verifies, and what the relay decides is purely
 * whether this node id is a member — which it never is.
 */
export function strangerAuth(identity, token, method, key, { ts = Math.floor(Date.now() / 1000), nonce } = {}) {
  const n = nonce || createHash('sha256').update(`${Math.random()}${Date.now()}`).digest('hex').slice(0, 32);
  const transcript = `haven-httprelay-v1\n${token}\n${method}\n${key}\n${ts}\n${n}\n${BLAKE3_EMPTY}`;
  const sig = edSign(null, Buffer.from(transcript, 'utf8'), identity.privateKey).toString('hex');
  return `Haven ${identity.nodeHex}.${ts}.${n}.${BLAKE3_EMPTY}.${sig}`;
}

/** The isolation matrix one relay must satisfy: [{name, expect: [codes…]}] keyed by probe. */
export function isolationVerdict(results) {
  const bad = results.filter((r) => !r.expect.includes(r.status));
  return { ok: bad.length === 0, bad: bad.map((r) => `${r.name}: got ${r.status}, want ${r.expect.join('/')}`) };
}

// ── progress while a relay dies mid-transfer ─────────────────────────────────────────────────

/** Fold the reader's media_transfers for `ref` into a got-series; true once it has been SEEN
 *  mid-transfer (0 < got < total). */
export function midTransfer(dump, ref) {
  const t = (dump?.media_transfers || []).find((x) => x.ref === ref);
  return !!t && t.total > 0 && t.got > 0 && t.got < t.total;
}

/** GETs the counting proxy has IN FLIGHT on `pub` for media `ref` (a reader mid-download). */
export function inflightMedia(proxyStats, pub, ref) {
  const p = proxyStats?.ports?.[pub] || proxyStats?.ports?.[String(pub)];
  return (p?.inflight || []).filter((f) => f.method === 'GET' && String(f.path || '').includes(`/haven/media/${ref}`));
}

/**
 * Resurrection after a real GC sweep. The swept relay sweeps every few seconds, so any key it holds
 * that is OLDER than its TTL (+ a slack covering one sweep interval) was not left there by the sweep
 * — a sibling's mesh pull handed it back, back-dated to its idle age, which is exactly the
 * never-resurrect rule being broken. A key a CLIENT re-PUTs (refresh-repair) is stamped now and is
 * legitimate. `observations` = [{key, ageMs}] sampled over the watch window.
 */
export function resurrected(observations, { ttlS, slackS = 10 }) {
  return observations.filter((o) => o.ageMs >= (ttlS + slackS) * 1000);
}
