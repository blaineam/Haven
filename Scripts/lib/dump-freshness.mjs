// Dump-channel freshness for the cross-device QA harness (Scripts/qa-e2e-full.mjs).
//
// THE FAILURE THIS EXISTS TO CATCH
// --------------------------------
// The harness drives four clients by writing a command file and reading a JSON dump back. On
// Android that dump travels through `/sdcard/Download/qa-dump-<pkg>.json` and MediaStore, and a
// reinstall can orphan the provider's row for it: every `renameTo` the driver does then fails
// ("MediaProvider: Database update failed while renaming"), the app keeps running perfectly, and
// the harness reads the SAME FROZEN FILE forever. Nothing in the JSON says so — it parses, it has
// posts in it, it looks like a healthy device that simply received nothing.
//
// That has cost two investigations. In August it turned healthy android legs into 7x perf
// "regressions" and then into legs that "never" converged, and very nearly convicted a shipped
// codec bump of a regression that did not exist. On 2026-09-02 the same signature was present
// again while the real bug was somewhere else entirely. Until now the harness had no freshness
// check at all: it trusted whatever JSON it could parse.
//
// WHAT "FRESH" MEANS HERE — AND WHAT IT DOES NOT
// ----------------------------------------------
// Freshness is about the dump being REGENERATED after the command that asked for it. It is NOT
// about the contents changing. A dump whose posts are byte-identical to the last one because
// nothing happened is perfectly fresh, and this module never looks at content — only at `ts_ms`.
// That distinction is the whole reason this can be turned on without inventing a new class of
// false failure.
//
// THE ORDERING, WHICH IS WHY THE TOLERANCE IS SECONDS AND NOT MILLISECONDS
// -----------------------------------------------------------------------
//     harness writes qa-cmd  →  leg notices (poke, or a <=1.5s poll tick)  →  op runs  →
//     leg rewrites qa-dump with a NEW ts_ms  →  harness reads the file
//
// The harness waits ~2.5s between writing the command and reading. A leg whose dump takes longer
// than that to build hands back the PREVIOUS dump — which is one command old, not stale. Desktop's
// own driver logs 19s heartbeat dumps under load, and one converge iteration is ~4s, so in a
// perfectly healthy fleet an observed lag of tens of seconds is normal. Hence a 60s tolerance.
//
// AND THE PART THAT MAKES IT SAFE: THE FROZEN-TIMESTAMP REQUIREMENT
// -----------------------------------------------------------------
// A big lag alone is never enough to condemn a leg. The dump's `ts_ms` must ALSO have failed to
// advance by even a millisecond across the whole window. A slow-but-alive leg rewrites its dump
// constantly, so its ts climbs even while it lags; only a channel that has actually stopped
// delivering freezes. That single extra condition is what makes the check robust to everything
// that would otherwise fake a lag: a mismeasured clock skew, an emulator NTP jump, a leg that was
// not polled for two minutes while another leg converged. All of those shift the lag by a
// constant; none of them can make a live file's timestamp stand still.
//
// Ports: the Android leg emits `ts_ms` but no `dump_seq`; Apple (ios + the mac stub) and desktop
// emit both. This module deliberately depends only on `ts_ms`, the field every leg already has.

/** Defaults, deliberately generous — see the ordering note above. */
export const FRESHNESS_DEFAULTS = Object.freeze({
  /** A dump may predate its command by this much and still be considered fresh. */
  toleranceMs: 60_000,
  /** How long a leg must be CONTINUOUSLY stale-and-frozen before it is condemned. */
  graceMs: 75_000,
  /** …and how many observations must land inside that window. */
  minObservations: 5,
});

/** "4m12s" / "37s" / "820ms" — used in the operator-facing messages, so it must read like prose. */
export function fmtDuration(ms) {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return 'unknown';
  const neg = ms < 0;
  const a = Math.abs(ms);
  let s;
  if (a < 1000) s = `${Math.round(a)}ms`;
  else if (a < 60_000) s = `${(a / 1000).toFixed(1)}s`;
  else s = `${Math.floor(a / 60_000)}m${String(Math.round((a % 60_000) / 1000)).padStart(2, '0')}s`;
  return neg ? `-${s}` : s;
}

/**
 * The pure decision: was this dump regenerated after the command that asked for it?
 *
 * @param {object}  o
 * @param {number}  o.issuedAt   host clock (ms) at the moment the command was written
 * @param {number|null|undefined} o.dumpTsMs
 *        the dump's own `ts_ms`, on the LEG's clock. `null` = no dump could be read at all
 *        (counts against the channel); `undefined`/non-finite = a dump was read but carries no
 *        usable timestamp, which is unjudgeable and must never condemn anything.
 * @param {number}  [o.skewMs]   leg clock minus host clock, as measured. Emulators drift; the
 *                               `haven_phone` AVD was 782ms behind the host when this was written.
 * @param {number}  [o.toleranceMs]
 * @returns {{verdict:'fresh'|'stale'|'unreadable'|'unknown', lagMs:number|null,
 *            hostTsMs:number|null, reason:string}}
 */
export function judgeDump({ issuedAt, dumpTsMs, skewMs = 0, toleranceMs = FRESHNESS_DEFAULTS.toleranceMs }) {
  if (!Number.isFinite(issuedAt)) throw new TypeError('judgeDump: issuedAt must be a finite number');
  if (!Number.isFinite(skewMs)) skewMs = 0;
  if (dumpTsMs === null) {
    return { verdict: 'unreadable', lagMs: null, hostTsMs: null, reason: 'no dump could be read' };
  }
  if (!Number.isFinite(dumpTsMs)) {
    return { verdict: 'unknown', lagMs: null, hostTsMs: null, reason: 'dump carries no ts_ms — not judgeable' };
  }
  const hostTsMs = dumpTsMs - skewMs;
  const lagMs = issuedAt - hostTsMs;
  if (lagMs > toleranceMs) {
    return { verdict: 'stale', lagMs, hostTsMs, reason: `dump predates its command by ${fmtDuration(lagMs)}` };
  }
  // A dump from the FUTURE beyond tolerance cannot be a stale channel (it was written after the
  // command by definition), but it does mean the skew number is wrong — say so rather than
  // silently trusting it.
  const reason = lagMs < -toleranceMs
    ? `dump timestamp is ${fmtDuration(-lagMs)} ahead of the host — the measured skew is suspect`
    : '';
  return { verdict: 'fresh', lagMs, hostTsMs, reason };
}

/**
 * Per-leg accumulator over `judgeDump`. Condemnation needs THREE things at once, so no single
 * hiccup can produce one:
 *
 *   1. the lag is over tolerance,
 *   2. it has been over tolerance continuously for `graceMs`, across `minObservations` reads, and
 *   3. the dump's `ts_ms` has not advanced at all in that time (the file is frozen).
 *
 * A leg that is merely slow satisfies 1 and 2 but never 3 — it is reported as slow (`advancing`)
 * and never condemned.
 */
export class ChannelFreshness {
  constructor(label, opts = {}) {
    this.label = label;
    this.toleranceMs = opts.toleranceMs ?? FRESHNESS_DEFAULTS.toleranceMs;
    this.graceMs = opts.graceMs ?? FRESHNESS_DEFAULTS.graceMs;
    this.minObservations = opts.minObservations ?? FRESHNESS_DEFAULTS.minObservations;
    /** One recovery attempt per leg per run — a repeatedly stale channel is not papered over. */
    this.recoveryAttempted = false;
    /** Set while a recovery is in flight so its own reads cannot re-trip the detector. */
    this.suspended = false;
    this.reset('init');
  }

  /**
   * Drop all accumulated state. Call it whenever the harness KNOWINGLY made the leg stop dumping —
   * the `invite_offline` step terminates the iOS app on purpose, and its pre-kill dump is stale by
   * construction for as long as the app is dead. Condemning that would be a false failure.
   */
  reset(why = '') {
    this.staleSince = null;
    this.staleCount = 0;
    this.lastTs = undefined;
    this.frozenSince = null;
    this.lastVerdict = null;
    this.lastLagMs = null;
    this.lastResetWhy = why;
    return this;
  }

  suspend() { this.suspended = true; return this; }
  resume() { this.suspended = false; return this; }
  markRecoveryAttempted() { this.recoveryAttempted = true; return this; }

  /**
   * Record one read.
   * @returns {{verdict:string, lagMs:number|null, reason:string, staleForMs:number,
   *            frozenForMs:number, observations:number, advancing:boolean, condemned:boolean}}
   */
  observe({ issuedAt, dumpTsMs, skewMs = 0, now = Date.now() }) {
    const j = judgeDump({ issuedAt, dumpTsMs, skewMs, toleranceMs: this.toleranceMs });
    const prevTs = this.lastTs;
    // An unreadable dump has no timestamp to advance, so it can never count as movement.
    const advanced = Number.isFinite(dumpTsMs) && dumpTsMs !== prevTs;
    this.lastVerdict = j.verdict;
    this.lastLagMs = j.lagMs;

    // `unknown` is not evidence of anything — a leg with no ts_ms simply cannot be judged, and
    // must not be able to fail the run. It does not even break a streak.
    if (j.verdict === 'unknown') {
      return { ...j, staleForMs: 0, frozenForMs: 0, observations: this.staleCount, advancing: false, condemned: false };
    }

    if (j.verdict === 'fresh') {
      this.staleSince = null;
      this.staleCount = 0;
      this.frozenSince = null;
      this.lastTs = dumpTsMs;
      return { ...j, staleForMs: 0, frozenForMs: 0, observations: 0, advancing: advanced, condemned: false };
    }

    // stale | unreadable
    this.staleSince ??= now;
    this.staleCount += 1;
    if (advanced || this.frozenSince === null) this.frozenSince = now;
    if (Number.isFinite(dumpTsMs)) this.lastTs = dumpTsMs;

    const staleForMs = now - this.staleSince;
    const frozenForMs = now - this.frozenSince;
    const condemned = this.staleCount >= this.minObservations
      && staleForMs >= this.graceMs
      && frozenForMs >= this.graceMs;

    return {
      ...j,
      staleForMs,
      frozenForMs,
      observations: this.staleCount,
      // Lagging but still being rewritten: a slow leg, not a dead channel.
      advancing: advanced,
      condemned,
    };
  }
}
