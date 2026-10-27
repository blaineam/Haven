package com.blaineam.haven.core

/**
 * Media for a circle this device knows NO relay for (a freshly installed device that has not yet
 * learned the circle's relay — frame 19 — or whose announce has not landed).
 *
 * Three rules, all pure so they are unit-testable:
 *
 *  1. A fetch that asked ZERO relays proved nothing. It used to fall into the same "relays answered
 *     and none holds it" branch as a real miss and paint **Waiting for sender…** over every photo
 *     for as long as the device stayed relay-less — a lie that sent the owner chasing the sender's
 *     upload when the blob was fine and this device simply had nowhere to look.
 *  2. A relay HINT (frame 32: "it's on a relay, fetch it there") is useless to a device with no
 *     relay. Without help the author hints [HeavyWorkPolicy.MAX_RELAY_HINTS] times per ref, one
 *     hint per ask, and each ask waits for the next sweep — minutes per ref, thousands of refs.
 *     A relay-less device re-asks immediately so the author reaches "hints exhausted" and streams
 *     the bytes straight over, which is the documented behaviour for a circle with no relay.
 *  3. The hint also proves the author has a relay for the circle, so nudge them to announce it
 *     (a Hello triggers the relay re-announce) — rate-limited per (author, circle).
 */
object NoRelayMediaPolicy {
    /** Re-asks one ref gets after hints while no relay is known (the author's hint budget). */
    const val MAX_REASKS_PER_REF = HeavyWorkPolicy.MAX_RELAY_HINTS
    /** Spacing between re-asks of the same ref, so a burst of hints does not become a burst of asks. */
    const val REASK_SPACING_MS = 4_000L
    /** One relay-introduction nudge per (author, circle) at most this often. */
    const val INTRO_NUDGE_EVERY_MS = 10 * 60_000L

    /** Only a fetch that actually asked at least one relay may claim "the relays answered and none holds it". */
    fun relaysAnsweredEmpty(relaysAsked: Int): Boolean = relaysAsked > 0

    /** Re-ask the author right away after a hint we cannot act on. */
    fun reAskAfterUnusableHint(hasRelay: Boolean, priorReasks: Int, lastReaskMs: Long?, nowMs: Long): Boolean {
        if (hasRelay) return false
        if (priorReasks >= MAX_REASKS_PER_REF) return false
        return lastReaskMs == null || nowMs - lastReaskMs >= REASK_SPACING_MS
    }

    /** Ask the author to (re)announce their circle relay to us. */
    fun introNudgeDue(hasRelay: Boolean, lastNudgeMs: Long?, nowMs: Long): Boolean {
        if (hasRelay) return false
        return lastNudgeMs == null || nowMs - lastNudgeMs >= INTRO_NUDGE_EVERY_MS
    }
}
