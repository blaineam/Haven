// node --test Scripts/lib/dump-freshness.test.mjs   (soren suite: `qa-harness`)
//
// The freshness decision is the one piece of the e2e harness that can INVENT a failure, so it is
// the one piece that gets unit tests. Every case below is a scenario that actually happened (or
// that the check must be immune to), named as such.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { judgeDump, ChannelFreshness, fmtDuration, FRESHNESS_DEFAULTS } from './dump-freshness.mjs';

const T0 = 1_700_000_000_000;   // an arbitrary fixed "now"

// ── judgeDump: the pure decision ────────────────────────────────────────────────────────────

test('a dump written after the command is fresh', () => {
  const r = judgeDump({ issuedAt: T0, dumpTsMs: T0 + 1200 });
  assert.equal(r.verdict, 'fresh');
  assert.equal(r.lagMs, -1200);           // negative lag = written after we asked
});

test('a dump one converge cycle behind the command is still fresh (slow dump build, healthy leg)', () => {
  // The harness reads 2.5s after writing the command; a leg whose dump takes longer hands back
  // the previous one. Desktop logs 19s heartbeat dumps under load — none of that is a dead channel.
  for (const behind of [2_500, 4_000, 19_000, 45_000, 59_999]) {
    assert.equal(judgeDump({ issuedAt: T0, dumpTsMs: T0 - behind }).verdict, 'fresh', `${behind}ms behind`);
  }
});

test('a dump minutes older than the command is stale', () => {
  const r = judgeDump({ issuedAt: T0, dumpTsMs: T0 - 252_000 });
  assert.equal(r.verdict, 'stale');
  assert.equal(r.lagMs, 252_000);
  assert.match(r.reason, /4m12s/);        // the phrasing the operator sees
});

test('clock skew is subtracted, not assumed away', () => {
  // The emulator's clock runs BEHIND the host (measured: -782ms on haven_phone, and an AVD that
  // has been suspended can be minutes out). A dump written *right now* on a clock 5 minutes slow
  // looks 5 minutes stale unless the skew is applied.
  const skewMs = -300_000;
  const dumpTsMs = T0 + skewMs;           // written now, stamped on the slow clock
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs, skewMs: 0 }).verdict, 'stale');
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs, skewMs }).verdict, 'fresh');
});

test('a clock ahead of the host is never called stale, but says the skew is suspect', () => {
  const r = judgeDump({ issuedAt: T0, dumpTsMs: T0 + 600_000 });
  assert.equal(r.verdict, 'fresh');
  assert.match(r.reason, /ahead of the host/);
});

test('no dump at all is unreadable; a dump with no ts_ms is unknown and never judged', () => {
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs: null }).verdict, 'unreadable');
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs: undefined }).verdict, 'unknown');
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs: NaN }).verdict, 'unknown');
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs: 'nope' }).verdict, 'unknown');
});

test('the tolerance boundary is inclusive', () => {
  const t = FRESHNESS_DEFAULTS.toleranceMs;
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs: T0 - t }).verdict, 'fresh');
  assert.equal(judgeDump({ issuedAt: T0, dumpTsMs: T0 - t - 1 }).verdict, 'stale');
});

test('freshness never looks at dump CONTENT — an unchanged dump with a new ts is fresh', () => {
  // "Nothing happened, so the posts are identical" must not read as stale. The decision takes no
  // content at all; this pins that by passing the same payload twice with a moving timestamp.
  const ch = new ChannelFreshness('ios');
  const payload = { posts: [{ id: 'a', body: 'unchanged' }] };
  let condemned = false;
  for (let i = 0; i < 40; i++) {
    const now = T0 + i * 4_000;
    const r = ch.observe({ issuedAt: now, dumpTsMs: now - 500, now, dump: payload });
    condemned ||= r.condemned;
    assert.equal(r.verdict, 'fresh');
  }
  assert.equal(condemned, false);
});

// ── ChannelFreshness: the sustained decision ────────────────────────────────────────────────

/** Drive the tracker with a leg whose dump froze at `frozenAt`, reading every 4s. */
function runFrozen(ch, { frozenAt = T0, reads = 60, stepMs = 4_000, skewMs = 0 } = {}) {
  const seen = [];
  for (let i = 0; i < reads; i++) {
    const now = T0 + i * stepMs;
    seen.push(ch.observe({ issuedAt: now, dumpTsMs: frozenAt, skewMs, now }));
  }
  return seen;
}

test('one stale read does not condemn — nor does a whole minute of them', () => {
  const ch = new ChannelFreshness('android');
  // 60s of reads against a file frozen 61s ago: over tolerance, but not yet over the grace window.
  const seen = runFrozen(ch, { frozenAt: T0 - 61_000, reads: 15, stepMs: 4_000 });
  assert.equal(seen.some((r) => r.condemned), false);
});

test('a channel frozen for the whole grace window IS condemned', () => {
  const ch = new ChannelFreshness('android');
  const seen = runFrozen(ch, { frozenAt: T0 - 61_000, reads: 60, stepMs: 4_000 });
  const first = seen.findIndex((r) => r.condemned);
  assert.ok(first > 0, 'expected a condemnation');
  assert.ok(seen[first].observations >= FRESHNESS_DEFAULTS.minObservations);
  assert.ok(seen[first].frozenForMs >= FRESHNESS_DEFAULTS.graceMs);
  assert.equal(seen[first].verdict, 'stale');
});

test('a SLOW leg is never condemned — lagging, but its timestamp keeps advancing', () => {
  // This is the false failure the frozen-ts requirement exists to prevent: a leg whose dump is
  // consistently 90s behind the command (over tolerance) but is being rewritten every time.
  const ch = new ChannelFreshness('desktop');
  for (let i = 0; i < 200; i++) {
    const now = T0 + i * 4_000;
    const r = ch.observe({ issuedAt: now, dumpTsMs: now - 90_000, now });
    assert.equal(r.verdict, 'stale');
    assert.equal(r.advancing, true);
    assert.equal(r.condemned, false, `condemned a live-but-slow leg at read ${i}`);
  }
});

test('a mismeasured skew alone cannot condemn a live leg', () => {
  // Pretend the skew probe was 4 minutes wrong. Every read looks stale — but the file is alive,
  // so its ts advances and the leg is never condemned.
  const ch = new ChannelFreshness('android');
  for (let i = 0; i < 200; i++) {
    const now = T0 + i * 4_000;
    const r = ch.observe({ issuedAt: now, dumpTsMs: now - 240_000, skewMs: 0, now });
    assert.equal(r.condemned, false);
  }
});

test('one fresh read clears the streak, so blips cannot accumulate across a run', () => {
  const ch = new ChannelFreshness('android');
  for (let round = 0; round < 5; round++) {
    const base = T0 + round * 200_000;
    // 40s of stale reads…
    for (let i = 0; i < 10; i++) {
      const now = base + i * 4_000;
      assert.equal(ch.observe({ issuedAt: now, dumpTsMs: base - 70_000, now }).condemned, false);
    }
    // …then the leg answers.
    const now = base + 44_000;
    assert.equal(ch.observe({ issuedAt: now, dumpTsMs: now, now }).verdict, 'fresh');
    assert.equal(ch.staleCount, 0);
  }
});

test('an unreadable dump counts against the channel and is condemned when it persists', () => {
  const ch = new ChannelFreshness('android');
  let condemned = false;
  for (let i = 0; i < 60; i++) {
    const now = T0 + i * 4_000;
    condemned ||= ch.observe({ issuedAt: now, dumpTsMs: null, now }).condemned;
  }
  assert.equal(condemned, true);
});

test('a leg that emits no ts_ms is never condemned (unjudgeable, not broken)', () => {
  const ch = new ChannelFreshness('legacy');
  for (let i = 0; i < 200; i++) {
    const now = T0 + i * 4_000;
    const r = ch.observe({ issuedAt: now, dumpTsMs: undefined, now });
    assert.equal(r.verdict, 'unknown');
    assert.equal(r.condemned, false);
  }
});

test('reset() clears the streak — the deliberate app kill in invite_offline', () => {
  // The suite terminates the iOS app on purpose and reads it again after a relaunch. Its pre-kill
  // dump is stale by construction; condemning that would be a fabricated failure.
  const ch = new ChannelFreshness('ios');
  runFrozen(ch, { frozenAt: T0 - 61_000, reads: 30 });
  ch.reset('ios relaunched by invite_offline');
  assert.equal(ch.staleCount, 0);
  assert.equal(ch.frozenSince, null);
  const now = T0 + 200_000;
  assert.equal(ch.observe({ issuedAt: now, dumpTsMs: now - 1_000, now }).condemned, false);
});

test('recovery is one shot per leg and its own reads cannot re-trip the detector', () => {
  const ch = new ChannelFreshness('android');
  assert.equal(ch.recoveryAttempted, false);
  ch.markRecoveryAttempted().suspend();
  assert.equal(ch.recoveryAttempted, true);
  assert.equal(ch.suspended, true);
  ch.resume();
  assert.equal(ch.suspended, false);
});

test('a tighter grace window can be configured without touching the tolerance', () => {
  const ch = new ChannelFreshness('android', { graceMs: 10_000, minObservations: 2 });
  const seen = runFrozen(ch, { frozenAt: T0 - 61_000, reads: 10, stepMs: 4_000 });
  assert.ok(seen.some((r) => r.condemned));
});

// ── message formatting ──────────────────────────────────────────────────────────────────────

test('fmtDuration reads like prose', () => {
  assert.equal(fmtDuration(820), '820ms');
  assert.equal(fmtDuration(37_000), '37.0s');
  assert.equal(fmtDuration(252_000), '4m12s');
  assert.equal(fmtDuration(3_600_000), '60m00s');
  assert.equal(fmtDuration(-1_500), '-1.5s');
  assert.equal(fmtDuration(null), 'unknown');
});

test('judgeDump refuses a nonsense issuedAt rather than guessing', () => {
  assert.throws(() => judgeDump({ issuedAt: undefined, dumpTsMs: T0 }), TypeError);
});
