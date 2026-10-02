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
 * write from ANY path (a structural save flushes pending stamps too) and DISARMS the deferred one:
 * the deferred task must call [takeDeferred] with the generation it was armed under and skip when
 * it returns false. (Without that, every structural write left its predecessor's deferred write
 * still scheduled, and each orphan became a self-perpetuating once-a-minute chain — gate-8 verify
 * run: three relay-table writes a minute from three such chains.)
 */
class WriteCoalescer(private val minIntervalMs: Long) {
    private var lastWriteMs: Long? = null
    private var armedForMs: Long? = null
    private var generation = 0L

    @Synchronized
    fun request(nowMs: Long): Long {
        if (armedForMs != null) return ALREADY_ARMED
        val last = lastWriteMs
        // Never written, or the clock went backwards (a jump must not freeze persistence).
        if (last == null || nowMs < last || nowMs - last >= minIntervalMs) return 0L
        val due = last + minIntervalMs
        armedForMs = due
        generation++
        return due - nowMs
    }

    /** The generation the most recent positive [request] armed. Read it right after [request]
     *  (same thread, before yielding) and hand it to [takeDeferred]. */
    @Synchronized
    fun armedGeneration(): Long = generation

    /** A deferred write armed under [gen] is due: true = do it now; false = a write already
     *  happened since (and carried the change), so skip. */
    @Synchronized
    fun takeDeferred(gen: Long): Boolean {
        if (armedForMs == null || gen != generation) return false
        armedForMs = null
        return true
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
