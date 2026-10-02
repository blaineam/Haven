package com.blaineam.haven.core

/**
 * When a relay's persisted "last seen" stamp is worth rewriting.
 *
 * Every successful relay op (each 2 s `__live__` LIST of every circle × relay × lane, every
 * call-frame PUT) used to stamp `lastSeenMs` and re-save the whole relay table to the
 * `haven.contacts` SharedPreferences: thousands of `apply()` fsyncs per hour during a call
 * (e2e gate-7: ~1,700 slow fsyncs of haven.contacts.xml, some > 16 s). Every pending `apply()`
 * is drained ON MAIN by `QueuedWork.waitToFinish()` when an activity stops or a service's
 * `onStartCommand` runs — exactly what the screen-share consent activity and the
 * mediaProjection FGS promotion do — so the share path froze on disk and ANR'd
 * ("ScreenShareConsentActivity — Input dispatching timed out").
 *
 * The stamp only feeds the 7-day stale-relay purge and a "last seen" label, so minute-level
 * precision is plenty: restamp only when the stored value is at least [MIN_INTERVAL_MS] old
 * (or in the future — a clock jump must not freeze it).
 */
object RelaySeenStamp {
    const val MIN_INTERVAL_MS = 60_000L

    fun shouldRestamp(storedMs: Long, nowMs: Long): Boolean =
        nowMs < storedMs || nowMs - storedMs >= MIN_INTERVAL_MS
}
