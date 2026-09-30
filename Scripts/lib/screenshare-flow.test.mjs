// node --test Scripts/lib/screenshare-flow.test.mjs   (soren suite: `qa-harness`)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { judgeShareFlow, SHARE_FLOW } from './screenshare-flow.mjs';

test('a perturbed share that reaches the peer is flowing', () => {
  const r = judgeShareFlow({ capturedStart: 21, capturedEnd: 71, decodedStart: 6, decodedEnd: 40 });
  assert.equal(r.verdict, 'flowing');
  assert.equal(r.ok, true);
  assert.equal(r.captured, 50);
  assert.equal(r.decoded, 34);
});

test('the gate run: peer 6 → 6 while the sender kept capturing is NOT DELIVERED, not a static screen', () => {
  const r = judgeShareFlow({ capturedStart: 21, capturedEnd: 60, decodedStart: 6, decodedEnd: 6 });
  assert.equal(r.verdict, 'not delivered');
  assert.equal(r.ok, false);
});

test('the sender making no frames despite the counter is CAPTURE STALLED — never a skip', () => {
  const r = judgeShareFlow({ capturedStart: 21, capturedEnd: 21, decodedStart: 6, decodedEnd: 6 });
  assert.equal(r.verdict, 'capture stalled');
  assert.equal(r.ok, false);
  assert.equal(judgeShareFlow({ capturedStart: 21, capturedEnd: 21 + SHARE_FLOW.minCaptured - 1, decodedStart: 0, decodedEnd: 99 }).verdict,
    'capture stalled', 'peer growth cannot excuse a stalled sender');
});

test('encoder drops up to half the captured frames are tolerated', () => {
  assert.equal(judgeShareFlow({ capturedStart: 0, capturedEnd: 40, decodedStart: 0, decodedEnd: 20 }).verdict, 'flowing');
  assert.equal(judgeShareFlow({ capturedStart: 0, capturedEnd: 40, decodedStart: 0, decodedEnd: 19 }).verdict, 'not delivered');
});

test('the minimum capture still needs at least one decoded frame', () => {
  const r = judgeShareFlow({ capturedStart: 0, capturedEnd: SHARE_FLOW.minCaptured, decodedStart: 3, decodedEnd: 3 });
  assert.equal(r.verdict, 'not delivered');
  assert.ok(r.need >= 1);
});

test('missing or non-numeric samples count as zero, and a restarted counter counts from zero', () => {
  assert.equal(judgeShareFlow({}).verdict, 'capture stalled');
  const r = judgeShareFlow({ capturedStart: 80, capturedEnd: 30, decodedStart: 50, decodedEnd: 20 });
  assert.equal(r.captured, 30);
  assert.equal(r.decoded, 20);
  assert.equal(r.verdict, 'flowing');
});

test('the [again] crash: a sender whose process restarted is SENDER DIED, not a capture stall', () => {
  const r = judgeShareFlow({ capturedStart: 34, capturedEnd: 0, decodedStart: 3, decodedEnd: 71, senderPidStart: '4132', senderPidEnd: '5939' });
  assert.equal(r.verdict, 'sender died');
  assert.equal(r.ok, false);
  assert.match(r.detail, /4132 → 5939/);
  assert.equal(judgeShareFlow({ capturedStart: 34, capturedEnd: 90, decodedStart: 3, decodedEnd: 71, senderPidStart: '4132', senderPidEnd: '' }).verdict, 'sender died');
  assert.equal(judgeShareFlow({ capturedStart: 34, capturedEnd: 90, decodedStart: 3, decodedEnd: 71, senderPidStart: '4132', senderPidEnd: '4132' }).verdict, 'flowing');
});
