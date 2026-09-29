// node --test Scripts/lib/multirelay.test.mjs   (soren suite `qa-harness`)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPublicKey, verify as edVerify } from 'node:crypto';
import {
  RESERVED_PORTS, portPlan, collisionVerdict, decodeComp, classifyKey, isEventKey, eventKeys, mailboxCircles,
  holdsMedia, misplacedCircles, keyDiff, stableCounts, tokenFingerprint, urlPort, attributionProblems,
  statsRow, statsCounter, knowsUrlPort, hitsBetween, herdVerdict, BLAKE3_EMPTY, strangerIdentity, strangerAuth,
  isolationVerdict, midTransfer,
} from './multirelay.mjs';

const H = (c) => c.repeat(64);

test('portPlan: distinct, never a reserved port, rejects a plan that would collide', () => {
  const p = portPlan(8684);
  const all = [p.ra.pub, p.ra.internal, p.rc.pub, p.rc.internal, p.ra2.pub, p.ra2.internal, p.control];
  assert.equal(new Set(all).size, all.length);
  for (const r of RESERVED_PORTS) assert.ok(!all.includes(r));
  assert.throws(() => portPlan(8673), /reserved/);          // 8673+1 = 8674 (the stub)
  assert.throws(() => portPlan(8684, 1), /collides/);       // internal == next relay's public
  assert.throws(() => portPlan(70000), /range/);
});

test('collisionVerdict: loud exit passes, a survivor or a mute exit does not', () => {
  assert.equal(collisionVerdict({ exited: true, code: 1, output: 'Error: start http blob interface: http bind 127.0.0.1:18684: port 18684 is already served by another listener on 0.0.0.0:18684' }).ok, true);
  assert.equal(collisionVerdict({ exited: true, code: 1, output: 'http bind 0.0.0.0:1: Address already in use (os error 48)' }).ok, true);
  assert.match(collisionVerdict({ exited: false, code: null, output: '✓ http media interface live' }).why, /STILL RUNNING/);
  assert.equal(collisionVerdict({ exited: true, code: 0, output: '' }).ok, false);
  assert.equal(collisionVerdict({ exited: true, code: 1, output: 'no saved link' }).ok, false);
});

test('store keys: decode + classify every namespace', () => {
  assert.equal(decodeComp('dm%3Aab-cd'), 'dm:ab-cd');
  assert.equal(decodeComp('a%253A'), 'a%3A');
  assert.deepEqual(classifyKey(`haven/mailbox/c1X/${H('a')}`), { ns: 'mailbox', circle: 'c1X', rest: H('a') });
  assert.equal(classifyKey('haven/media/r1/0').ns, 'media');
  assert.equal(classifyKey(`haven/self/${H('b')}/state/x`).account, H('b'));
  assert.equal(classifyKey('haven/relay/__interface__').ns, 'relay');
  assert.equal(classifyKey('elsewhere/x').ns, 'other');
});

test('event keys exclude the per-node lanes', () => {
  const keys = [`haven/mailbox/c/${H('a')}`, `haven/mailbox/c/__live__/${H('b')}/${H('c')}`,
    `haven/mailbox/c/__hello__/x/y/z`, `haven/mailbox/d/${H('d')}`, 'haven/media/q'];
  assert.deepEqual(eventKeys(keys, 'c'), [`haven/mailbox/c/${H('a')}`]);
  assert.equal(isEventKey(`haven/mailbox/c/${H('a')}`), true);
  assert.deepEqual([...mailboxCircles(keys)].sort(), ['c', 'd']);
});

test('holdsMedia sees the manifest and its chunks, not a prefix-sibling ref', () => {
  assert.equal(holdsMedia(['haven/media/abc'], 'abc'), true);
  assert.equal(holdsMedia(['haven/media/abc/3'], 'abc'), true);
  assert.equal(holdsMedia(['haven/media/abcd'], 'abc'), false);
});

test('misplacedCircles names every forbidden circle a relay holds', () => {
  const keysByRelay = { ra: [`haven/mailbox/cb/${H('1')}`, `haven/mailbox/cs/${H('2')}`], rc: [`haven/mailbox/cs/${H('3')}`] };
  assert.deepEqual(misplacedCircles(keysByRelay, { ra: ['cb'], rc: ['ca', 'cb'] }), [{ relay: 'ra', circle: 'cb', keys: 1 }]);
  assert.deepEqual(misplacedCircles(keysByRelay, { rc: ['ca'] }), []);
});

test('freshMints: late mesh arrivals are not mints, new keys are', async () => {
  const { freshMints } = await import('./multirelay.mjs');
  assert.deepEqual(freshMints(['a', 'b', 'c'], ['a', 'c']), []);
  assert.deepEqual(freshMints(['a', 'b'], ['a', 'b', 'x']), ['x']);
});

test('keyDiff + stableCounts', () => {
  assert.deepEqual(keyDiff(['a', 'b'], ['b', 'c']), { onlyA: ['a'], onlyB: ['c'] });
  assert.equal(stableCounts([5, 5, 5]).ok, true);
  assert.equal(stableCounts([6, 5, 5]).ok, true);   // GC / dedupe may shrink it
  assert.match(stableCounts([5, 5, 7]).why, /grew 5 → 7/);
  assert.equal(stableCounts([]).ok, false);
});

test('tokenFingerprint matches the apps (first 12 hex of sha256)', () => {
  assert.equal(tokenFingerprint('abc'), 'ba7816bf8f01');   // sha256("abc") = ba7816bf8f01…
  assert.equal(tokenFingerprint(''), '');
});

test('attributionProblems: a URL or token of another relay on a row is caught', () => {
  const truth = { [H('a')]: { tokenFp: 'aaa', ports: [8684, 8686] }, [H('b')]: { tokenFp: 'bbb', ports: [8674] } };
  const good = [{ relay: H('a'), tokenFp: 'aaa', urls: ['http://127.0.0.1:8684', 'http://10.0.0.1:18684'] },
    { relay: H('b'), tokenFp: 'bbb', urls: ['http://127.0.0.1:8674'] }, { relay: H('f'), tokenFp: 'zzz', urls: ['http://x:8674'] }];
  assert.deepEqual(attributionProblems(good, truth), []);
  const bad = [{ relay: H('a'), tokenFp: 'bbb', urls: ['http://127.0.0.1:8674'] }];
  const p = attributionProblems(bad, truth);
  assert.equal(p.length, 2);
  assert.equal(urlPort('https://x'), 443);
  assert.equal(urlPort('nope'), null);
});

test('statsRow / statsCounter / knowsUrlPort', () => {
  const d = { relay_stats: [{ relay: H('A').toLowerCase(), putOk: 3, urls: ['http://127.0.0.1:8686'] }] };
  assert.equal(statsRow(d, H('a'))?.putOk, 3);
  assert.equal(statsCounter(d, H('a'), 'putOk'), 3);
  assert.equal(statsCounter(d, H('a'), 'getOk'), 0);
  assert.equal(statsCounter(null, H('a'), 'putOk'), 0);
  assert.equal(knowsUrlPort(d, H('a'), 8686), true);
  assert.equal(knowsUrlPort(d, H('a'), 8684), false);
});

test('herdVerdict: bounded + flat passes, a storm or a climb fails, a short window refuses to judge', () => {
  const at = (from, n, every) => Array.from({ length: n }, (_, i) => from + i * every);
  const downAt = 0, upAt = 135_000;
  assert.equal(hitsBetween([1, 2, 3], 2, 3), 1);
  const calm = at(20_000, 20, 5_000);                            // one every 5s = 12/min
  assert.equal(herdVerdict(calm, { downAt, upAt }).ok, true);
  const storm = at(15_000, 2000, 60);                            // ~1000/min
  assert.equal(herdVerdict(storm, { downAt, upAt }).ok, false);
  // 3 hits in the first half, 40 in the second (~42/min): under the 60/min cap overall, but climbing
  // past half of it — a backoff that is getting worse, not better.
  const climb = [...at(20_000, 3, 10_000), ...at(80_000, 40, 1_000)];
  const cv = herdVerdict(climb, { downAt, upAt, maxPerMin: 60 });
  assert.equal(cv.ok, false);
  assert.match(cv.why, /CLIMBING/);
  // Readers failing over one by one (9 → 27 over ~2.5 min, measured on the fleet) is not a storm.
  const trickle = [...at(20_000, 9, 7_000), ...at(78_000, 27, 2_500)];
  assert.equal(herdVerdict(trickle, { downAt, upAt, maxPerMin: 60 }).ok, true, herdVerdict(trickle, { downAt, upAt, maxPerMin: 60 }).why);
  assert.match(herdVerdict(calm, { downAt, upAt: 30_000 }).why, /too short/);
});

test('strangerAuth signs exactly the relay transcript (verifiable with the stranger key)', () => {
  const id = strangerIdentity('11'.repeat(32));
  assert.equal(id.nodeHex.length, 64);
  assert.equal(strangerIdentity('11'.repeat(32)).nodeHex, id.nodeHex, 'deterministic from a seed');
  const h = strangerAuth(id, 'tok', 'GET', 'haven/media/x', { ts: 1700000000, nonce: 'ab'.repeat(16) });
  const [node, ts, nonce, digest, sig] = h.replace(/^Haven /, '').split('.');
  assert.equal(node, id.nodeHex); assert.equal(ts, '1700000000'); assert.equal(nonce, 'ab'.repeat(16));
  assert.equal(digest, BLAKE3_EMPTY);
  const pub = createPublicKey(id.privateKey);
  const transcript = `haven-httprelay-v1\ntok\nGET\nhaven/media/x\n1700000000\n${'ab'.repeat(16)}\n${BLAKE3_EMPTY}`;
  assert.equal(edVerify(null, Buffer.from(transcript), pub, Buffer.from(sig, 'hex')), true);
  assert.equal(edVerify(null, Buffer.from(transcript.replace('GET', 'PUT')), pub, Buffer.from(sig, 'hex')), false);
});

test('isolationVerdict + midTransfer', () => {
  assert.equal(isolationVerdict([{ name: 'a', status: 401, expect: [401] }]).ok, true);
  assert.deepEqual(isolationVerdict([{ name: 'b', status: 200, expect: [403] }]).bad, ['b: got 200, want 403']);
  assert.equal(midTransfer({ media_transfers: [{ ref: 'r', got: 3, total: 10 }] }, 'r'), true);
  assert.equal(midTransfer({ media_transfers: [{ ref: 'r', got: 0, total: 10 }] }, 'r'), false);
  assert.equal(midTransfer({ media_transfers: [{ ref: 'r', got: 10, total: 10 }] }, 'r'), false);
  assert.equal(midTransfer({}, 'r'), false);
});

test('inflightMedia + resurrected', async () => {
  const { inflightMedia, resurrected } = await import('./multirelay.mjs');
  const stats = { ports: { 8684: { inflight: [{ method: 'GET', path: '/k/haven/media/abc/2' }, { method: 'PUT', path: '/k/haven/media/abc' }] } } };
  assert.equal(inflightMedia(stats, 8684, 'abc').length, 1);
  assert.equal(inflightMedia(stats, 8685, 'abc').length, 0);
  // TTL 60s: a key 5s old is a fresh client re-PUT; 65s is inside one sweep interval; 90s is a
  // sibling handing back an expired key.
  const obs = [{ key: 'a', ageMs: 5_000 }, { key: 'b', ageMs: 65_000 }, { key: 'c', ageMs: 90_000 }];
  assert.deepEqual(resurrected(obs, { ttlS: 60 }).map((k) => k.key), ['c']);
});
