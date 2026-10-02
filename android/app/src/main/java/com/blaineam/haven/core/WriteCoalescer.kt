package com.blaineam.haven.core

/**
 * At most ONE durable write per [minIntervalMs] for state that changes far more often than it is
 * worth persisting.
 *
 * Every SharedPreferences `apply()` rewrites (and fsyncs) the WHOLE file, and every write still in
 * flight is drained ON MAIN by `QueuedWork.waitToFinish()` whenever a service starts or an activity
 * stops. The relay table lives in `haven.contacts` next to the contacts, invites and notification
 * dedupe set; [RelaySeenStamp] limited each relay to one restamp a minute, but N relays restamping
 * on their own clocks is still N whole-file fsyncs a minute (gate-8: 101 fsyncs of
 * haven.contacts.xml in 18 min, some over 4 s, on an emulator whose service start then ANR'd).
 *
 * [request] answers how long to wait before writing: 0 = write now, > 0 = arm ONE deferred write
 * for then, [ALREADY_ARMED] = one is already armed and will pick this change up. [wrote] records a
 * write from ANY path (a structural save flushes pending stamps too), so a deferred write that finds
 * nothing older than the last write simply re-saves identical content — a no-op for
 * SharedPreferences, which skips the disk when nothing changed.
 */
class WriteCoalescer(private val minIntervalMs: Long) {
    private var lastWriteMs: Long? = null
    private var armedForMs: Long? = null

    @Synchronized
    fun request(nowMs: Long): Long {
        if (armedForMs != null) return ALREADY_ARMED
        val last = lastWriteMs
        // Never written, or the clock went backwards (a jump must not freeze persistence).
        if (last == null || nowMs < last || nowMs - last >= minIntervalMs) return 0L
        val due = last + minIntervalMs
        armedForMs = due
        return due - nowMs
    }

    /** A write happened (deferred or not, from this path or a structural save). */
    @Synchronized
    fun wrote(nowMs: Long) {
        lastWriteMs = nowMs
        armedForMs = null
    }

    companion object {
        const val ALREADY_ARMED = -1L
    }
}
