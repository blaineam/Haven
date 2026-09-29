package com.blaineam.haven.core

/**
 * Relays adopted from a friend-invite ticket answer 403 to our writes until the inviter approves us
 * and enrolls our ids there. That refusal is EXPECTED and short-lived, so it must not feed the long
 * backoffs built for dead or hostile relays (refusal stand-down 30 s → 10 min, relay-health backoff)
 * — the new friend's first photos would wait them out. While a relay is "pending enrollment"
 * (adopted from a ticket, no authorized write confirmed yet, within [WINDOW_MS] of adoption) a 403
 * from it means "retry soon", nothing else. iOS `PendingEnrollment` parity. Not thread-safe; the
 * caller synchronizes.
 */
class PendingEnrollment {
    companion object {
        const val WINDOW_MS = 300_000L      // treat 403 as "not yet" for ~5 min after adoption
        const val RETRY_GAP_MS = 12_000L    // …retrying on this short, FLAT gap (no escalation)

        /**
         * Which relays to treat as pending enrollment when a ticket is accepted: every ticket relay
         * (not only newly-added ones — an already-known one refuses us just the same until the
         * inviter enrolls us) plus the inviter's own node id when it is one of our relays (a host's
         * relay id is its node id, behind the same membership gate). iOS parity.
         */
        fun relaysToTrack(ticketRelays: List<String>, inviterHex: String, knownRelays: Collection<String>): List<String> {
            val known = knownRelays.map { it.lowercase() }.toSet()
            val out = ArrayList<String>()
            for (h in ticketRelays.map { it.trim().lowercase() }) if (h.length == 64 && h !in out) out.add(h)
            val inviter = inviterHex.lowercase()
            if (inviter.length == 64 && inviter in known && inviter !in out) out.add(inviter)
            return out
        }
    }

    sealed class Decision {
        data class RetrySoon(val afterMs: Long) : Decision()
        object BackOff : Decision()
    }

    private val adoptedAtMs = HashMap<String, Long>()
    /** Per-relay "don't touch it before" after a pending refusal. The flat gap must be a property of
     *  the RELAY, not of one retry loop: every lane (mailbox put/list, hello, media, self-sync, the
     *  grant/announce re-drives) re-hit the refusing relay on its own clock — the e2e fleet saw
     *  ~9,000 refusals in 9 minutes with "a flat 12s retry" nominally in force. */
    private val holdUntilMs = HashMap<String, Long>()

    fun noteAdopted(relay: String, nowMs: Long) {
        adoptedAtMs[relay.lowercase()] = nowMs
        if (adoptedAtMs.size > 64) adoptedAtMs.entries.removeAll { nowMs - it.value >= WINDOW_MS }
    }
    /** Re-open the window only for a relay still unconfirmed (a grant / announce arrived). */
    fun refresh(relay: String, nowMs: Long) {
        val k = relay.lowercase()
        if (adoptedAtMs.containsKey(k)) adoptedAtMs[k] = nowMs
    }
    /** The grant / an announce: lift the hold so the re-drive that follows reaches the relay. */
    fun releaseHold(relay: String) { holdUntilMs.remove(relay.lowercase()) }
    /** An authorized write succeeded — enrolled. True if it WAS tracked (re-drive deferred work). */
    fun confirm(relay: String): Boolean {
        holdUntilMs.remove(relay.lowercase())
        return adoptedAtMs.remove(relay.lowercase()) != null
    }
    fun isTracked(relay: String): Boolean = adoptedAtMs.containsKey(relay.lowercase())
    fun isPending(relay: String, nowMs: Long): Boolean {
        val at = adoptedAtMs[relay.lowercase()] ?: return false
        return nowMs >= at && nowMs - at < WINDOW_MS
    }
    fun anyPending(nowMs: Long): Boolean = adoptedAtMs.keys.any { isPending(it, nowMs) }
    /** Relays still inside their window, sorted (DEBUG qa dump). */
    fun pendingRelays(nowMs: Long): List<String> = adoptedAtMs.keys.filter { isPending(it, nowMs) }.sorted()

    /** Only a REFUSAL from a still-pending relay is special; an outage is not enrollment's to fix. */
    fun onFailure(relay: String, forbidden: Boolean, nowMs: Long): Decision =
        if (forbidden && isPending(relay, nowMs)) Decision.RetrySoon(RETRY_GAP_MS) else Decision.BackOff

    /** A refusal was observed: [onFailure] with forbidden=true, and a pending relay is then HELD for
     *  [RETRY_GAP_MS] — every lane skips it until the gap elapses (or the grant / an announce / a
     *  successful write lifts it). A refusal inside a running hold does not push it out. */
    fun noteRefusal(relay: String, nowMs: Long): Decision {
        val d = onFailure(relay, forbidden = true, nowMs = nowMs)
        if (d is Decision.RetrySoon && mayAttempt(relay, nowMs)) holdUntilMs[relay.lowercase()] = nowMs + d.afterMs
        return d
    }

    /** False only while a pending-enrollment hold runs; any non-pending relay is always allowed. */
    fun mayAttempt(relay: String, nowMs: Long): Boolean {
        val until = holdUntilMs[relay.lowercase()] ?: return true
        return nowMs >= until || !isPending(relay, nowMs)
    }
}
