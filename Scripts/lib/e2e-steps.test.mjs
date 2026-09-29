import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  num, delta, parseUiNodes, findNode, center, CONSENT, isConsentSurface, fgsTypes, holdsMediaProjection,
  auditShareLog, longSide, remoteSlots, sharedScreen, suspendedFor, liftedFrom, missingPerfFields,
  persistExportAllowance, reactLatency, ingestedFirst, feedNotGatedOnDmWarm, PERF_FIELDS,
  nonDecreasing, recordProgress,
} from './e2e-steps.mjs';

test('num / delta treat missing and junk as zero', () => {
  assert.equal(num(undefined), 0);
  assert.equal(num('3'), 0);
  assert.equal(num(NaN), 0);
  assert.equal(delta({ a: 2 }, { a: 5 }, 'a'), 3);
  assert.equal(delta(undefined, { a: 5 }, 'a'), 5);
  assert.equal(delta({ a: 5 }, {}, 'a'), -5);
});

const CONSENT_XML = `<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">
<node index="0" text="Share your screen with Haven?" resource-id="android:id/alertTitle" class="android.widget.TextView" content-desc="" clickable="false" bounds="[63,800][1017,900]" />
<node index="1" text="A single app" resource-id="com.android.systemui:id/screen_share_mode_spinner" class="android.widget.Spinner" content-desc="" clickable="true" bounds="[63,950][1017,1050]" />
<node index="2" text="Cancel" resource-id="android:id/button2" class="android.widget.Button" content-desc="" clickable="true" bounds="[500,1200][700,1300]" />
<node index="3" text="Next" resource-id="android:id/button1" class="android.widget.Button" content-desc="" clickable="true" bounds="[750,1200][1000,1300]" />
<node index="4" text="" resource-id="" class="android.widget.FrameLayout" content-desc="Don&apos;t &amp; stop" clickable="false" bounds="[0,0][10,10]" />
</hierarchy>`;

test('parseUiNodes reads text, desc, bounds and clickability', () => {
  const nodes = parseUiNodes(CONSENT_XML);
  assert.equal(nodes.length, 5);
  assert.deepEqual(nodes[1].bounds, [63, 950, 1017, 1050]);
  assert.equal(nodes[1].clickable, true);
  assert.equal(nodes[4].desc, "Don&apos;t & stop");   // &amp; decoded; &apos; is not in uiautomator's output
});

test('consent vocabulary finds the chooser, the buttons and the surface', () => {
  const nodes = parseUiNodes(CONSENT_XML);
  assert.ok(isConsentSurface(nodes));
  assert.equal(findNode(nodes, CONSENT.single).text, 'A single app');
  assert.equal(findNode(nodes, CONSENT.cancel).text, 'Cancel');
  assert.equal(findNode(nodes, CONSENT.confirm).text, 'Next');
  assert.equal(findNode(nodes, CONSENT.entire), null);
  assert.deepEqual(center(findNode(nodes, CONSENT.confirm)), [875, 1250]);
  assert.ok(CONSENT.entire.test('Entire screen'));
  assert.ok(CONSENT.entire.test('Share entire screen'));
  assert.ok(CONSENT.single.test('Share one app'));
  assert.ok(CONSENT.confirm.test('Share screen'));
  assert.ok(CONSENT.confirm.test('Start now'));
  assert.ok(!isConsentSurface(parseUiNodes('<node text="Haven" bounds="[0,0][1,1]" />')));
});

test('fgsTypes ORs every foregroundServiceType and spots mediaProjection', () => {
  const held = 'ServiceRecord{…}\n  isForeground=true foregroundId=7 foregroundServiceType=0x00000021\n';
  const dropped = '  isForeground=true foregroundId=7 foregroundServiceType=0x00000081\n';
  assert.equal(fgsTypes(held), 0x21);
  assert.ok(holdsMediaProjection(held));
  assert.ok(!holdsMediaProjection(dropped));
  assert.ok(!holdsMediaProjection(''));
  assert.ok(holdsMediaProjection('types=dataSync|mediaProjection'));
});

test('auditShareLog demands FGS-ready before EVERY capture and flags failures', () => {
  const good = [
    'I HavenScreenShare: FGS mediaProjection ready=true after 40ms',
    'I HavenScreenShare: capture started; adding screen track to 1 peer(s)',
    'I HavenScreenShare: FGS mediaProjection ready=true after 35ms',
    'I HavenScreenShare: capture started; adding screen track to 1 peer(s)',
  ].join('\n');
  assert.deepEqual(auditShareLog(good), { captures: 2, ordered: true, failures: [] });
  const reused = [
    'I HavenScreenShare: FGS mediaProjection ready=true after 40ms',
    'I HavenScreenShare: capture started; adding screen track to 1 peer(s)',
    'I HavenScreenShare: capture started; adding screen track to 1 peer(s)',
  ].join('\n');
  assert.equal(auditShareLog(reused).ordered, false);
  const failed = 'E HavenScreenShare: screen share start failed\njava.lang.SecurityException: Media projections require a foreground service';
  assert.equal(auditShareLog(failed).failures.length, 2);
  assert.equal(auditShareLog('').captures, 0);
});

test('remote slots: a shared screen is found and kept apart from the camera', () => {
  const call = { remote_tracks: {
    aa: { camera: { track_id: 'v0', frames_decoded: 10 }, screen: null },
    bb: { camera: { track_id: 'v1' }, screen: { track_id: 's1', stream_ids: ['screen'], width: 720, height: 1280 } },
  } };
  assert.equal(remoteSlots(call).length, 2);
  const s = sharedScreen(call);
  assert.equal(s.peer, 'bb');
  assert.notEqual(s.screen.track_id, s.camera.track_id);
  assert.equal(longSide(s.screen.width, s.screen.height), 1280);
  assert.equal(sharedScreen({ remote_tracks: { aa: { camera: {}, screen: null } } }), null);
  assert.equal(sharedScreen(null), null);
});

test('gate reasons: suspended FOR a reason, and lifted from it even while still hot', () => {
  assert.ok(suspendedFor({ suspended: true, reason: 'haven-call,system-call' }, 'haven-call'));
  assert.ok(!suspendedFor({ suspended: true, reason: 'thermal=serious' }, 'haven-call'));
  assert.ok(!suspendedFor({ suspended: false, reason: '' }, 'haven-call'));
  assert.ok(liftedFrom({ suspended: false, reason: '' }, 'haven-call'));
  assert.ok(liftedFrom({ suspended: true, reason: 'thermal=serious' }, 'haven-call'));
  assert.ok(!liftedFrom({ suspended: true, reason: 'haven-call' }, 'haven-call'));
  assert.ok(!liftedFrom(null, 'haven-call'));
});

test('perf fields: absent section / partial section are reported by name', () => {
  assert.deepEqual(missingPerfFields(undefined), PERF_FIELDS);
  const full = Object.fromEntries(PERF_FIELDS.map((k) => [k, 0]));
  assert.deepEqual(missingPerfFields(full), []);
  const { heldRefSetSize, ...partial } = full;
  assert.deepEqual(missingPerfFields(partial), ['heldRefSetSize']);
  assert.equal(persistExportAllowance(0), 2);
  assert.equal(persistExportAllowance(10_000), 6);
  assert.equal(persistExportAllowance(-5), 2);
  assert.equal(reactLatency({ react_latency: { engineAppliedMs: 3.5, publishedMs: 42 } }), 42);
  assert.equal(reactLatency({ react_latency: { engineAppliedMs: 3.5, publishedMs: -1 } }), Infinity);
  assert.equal(reactLatency({ react_latency: { engineAppliedMs: 7 } }), 7);
  assert.equal(reactLatency({ react_latency: {} }), null);
  assert.equal(reactLatency({}), null);
});

test('launch: active circle ingested first, and the feed paint not gated on the DM warm', () => {
  assert.ok(ingestedFirst({ a: 100, b: 300 }, 'a'));
  assert.ok(ingestedFirst({ a: 100 }, 'a'));
  assert.ok(!ingestedFirst({ a: 400, b: 300 }, 'a'));
  assert.ok(!ingestedFirst({ b: 300 }, 'a'));
  assert.ok(feedNotGatedOnDmWarm({ first_feed_rendered_ms: 800, dm_warmup_done_ms: 1200 }));
  assert.ok(feedNotGatedOnDmWarm({ first_feed_rendered_ms: 800, dm_warmup_done_ms: null }));
  assert.ok(!feedNotGatedOnDmWarm({ first_feed_rendered_ms: 1300, dm_warmup_done_ms: 1200 }));
  assert.ok(!feedNotGatedOnDmWarm({ first_feed_rendered_ms: null }));
});

test('progress: monotonic got series and give-up detection per watched ref', () => {
  assert.ok(nonDecreasing([0, 3, 3, 10]));
  assert.ok(!nonDecreasing([0, 5, 4]));
  assert.ok(nonDecreasing([]));
  const rec = {};
  const present = new Set();
  const has = (r) => present.has(r);
  recordProgress(rec, { media_transfers: [{ ref: 'v', got: 1, total: 10, lane: 'relay' }] }, ['v', 'p'], has);
  recordProgress(rec, { media_transfers: [{ ref: 'v', got: 4, total: 10, lane: 'relay' }] }, ['v', 'p'], has);
  present.add('v');
  recordProgress(rec, { media_transfers: [] }, ['v', 'p'], has);
  assert.deepEqual(rec.v.got, [1, 4]);
  assert.equal(rec.v.total, 10);
  assert.deepEqual(rec.v.lanes, ['relay']);
  assert.ok(rec.v.present && !rec.v.gaveUp);
  assert.deepEqual(rec.p.got, []);
  const bad = {};
  recordProgress(bad, { media_transfers: [{ ref: 'x', got: 2, total: 9, lane: 'peer' }] }, ['x'], () => false);
  recordProgress(bad, { media_transfers: [{ ref: 'x', got: 5, total: 9, lane: 'peer' }], media_gave_up: ['x'] }, ['x'], () => false);
  assert.ok(bad.x.gaveUp && bad.x.gaveUpWhileReceiving);
});
