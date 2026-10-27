package com.blaineam.haven.core

/**
 * A relay that just JOINED one of our circles (adopted, announced by a member, synced from a sibling
 * device, or made the all-circles default) serves nobody until it has been introduced: it needs our
 * account-signed device roster (so it authorizes THIS device's id, not only the account id its link
 * named) and, from a member it already serves, the circle's member list (`enrollMembers`). Both ran
 * only on timers — the roster on the media-backfill tick, the enroll behind a 10-minute per-CIRCLE
 * gate a brand-new relay for an already-enrolled circle could not open — so a friend waited out the
 * tick's phase before the new relay answered them (e2e `multirelay`: 105–177 s). Now the join itself
 * schedules the introduction a beat later. iOS `RelayIntroduction` parity. Not thread-safe; the caller
 * synchronizes.
 */
class RelayIntroduction {
    companion object {
        /** Coalesce a burst (one announce adds the relay to several circles). */
        const val DEBOUNCE_MS = 1_500L
        /** A relay that keeps re-joining (announce echoes) is introduced at most this often. */
        const val REINTRODUCE_GAP_MS = 30_000L
        /** The member enroll's steady-state gate: the set changes rarely, so once per 10 min is plenty. */
        const val ENROLL_GAP_MS = 600_000L
        /** A FAILED enroll (relay unreachable, dial failed, refused) is retried this soon, not after the
         *  10-minute steady-state gate: a brand-new member stays refused ("media never loads, my DMs
         *  don't send") until the relay hears the list, so one lost attempt must not cost ten minutes. */
        const val ENROLL_RETRY_GAP_MS = 60_000L
        /** Circle id meaning "every circle" — a relay made the all-circles default joined all of them. */
        const val ALL_CIRCLES = "*"

        /**
         * The member-enroll gate. Due when forced, never enrolled, the circle's relay set gained a relay
         * since the last enroll (that relay has never heard the list), the MEMBER SET differs from the one
         * the relay last accepted ([membersChanged] — a contact or device that joined without going through
         * an approval, e.g. a linked device or a friend added from another device, is refused by the relay
         * until it is enrolled, so waiting out the steady-state gate leaves them locked out), the last
         * attempt did not land and [ENROLL_RETRY_GAP_MS] has passed, or [ENROLL_GAP_MS] has passed.
         */
        fun enrollDue(
            nowMs: Long, lastMs: Long?, lastRelays: Set<String>, relays: List<String>, force: Boolean,
            membersChanged: Boolean = false, lastLanded: Boolean = true,
        ): Boolean {
            if (force) return true
            if (lastMs == null) return true
            if (relays.any { it.lowercase() !in lastRelays }) return true
            // A relay that never answers the verb (older build, unreachable) must not be re-dialed every
            // sync tick: after a failed attempt the retry gap applies even to a changed member set.
            if (!lastLanded) return nowMs - lastMs >= ENROLL_RETRY_GAP_MS
            if (membersChanged) return true
            return nowMs - lastMs >= ENROLL_GAP_MS
        }
    }

    private val introducedAtMs = HashMap<String, Long>()   // "circle|relay" → last introduction
    private val pending = LinkedHashSet<String>()
    val pendingCircles: Set<String> get() = pending

    /**
     * [relay] joined [circleId]. True when an introduction must be scheduled (the caller debounces by
     * [DEBOUNCE_MS], then calls [drain]). The same pair inside [REINTRODUCE_GAP_MS] is ignored; an s3
     * pseudo-relay is never introduced (it has no auth map).
     */
    fun noteJoined(circleId: String, relay: String, nowMs: Long): Boolean {
        val r = relay.lowercase()
        if (r.length != 64 || r.startsWith("s3:") || circleId.isEmpty()) return false
        val key = "$circleId|$r"
        val at = introducedAtMs[key]
        if (at != null && nowMs - at < REINTRODUCE_GAP_MS) return false
        introducedAtMs[key] = nowMs
        val wasIdle = pending.isEmpty()
        pending.add(circleId)
        return wasIdle
    }

    /** The circles to introduce now ([ALL_CIRCLES] expanded against [circleIds]), clearing the queue. */
    fun drain(circleIds: List<String>): List<String> {
        val out = if (ALL_CIRCLES in pending) circleIds else circleIds.filter { it in pending }
        pending.clear()
        return out
    }
}
