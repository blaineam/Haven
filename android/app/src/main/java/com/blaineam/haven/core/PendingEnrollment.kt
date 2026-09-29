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
    }

    sealed class Decision {
        data class RetrySoon(val afterMs: Long) : Decision()
        object BackOff : Decision()
    }

    private val adoptedAtMs = HashMap<String, Long>()

    fun noteAdopted(relay: String, nowMs: Long) {
        adoptedAtMs[relay.lowercase()] = nowMs
        if (adoptedAtMs.size > 64) adoptedAtMs.entries.removeAll { nowMs - it.value >= WINDOW_MS }
    }
    /** Re-open the window only for a relay still unconfirmed (a grant / announce arrived). */
    fun refresh(relay: String, nowMs: Long) {
        val k = relay.lowercase()
        if (adoptedAtMs.containsKey(k)) adoptedAtMs[k] = nowMs
    }
    /** An authorized write succeeded — enrolled. True if it WAS tracked (re-drive deferred work). */
    fun confirm(relay: String): Boolean = adoptedAtMs.remove(relay.lowercase()) != null
    fun isTracked(relay: String): Boolean = adoptedAtMs.containsKey(relay.lowercase())
    fun isPending(relay: String, nowMs: Long): Boolean {
        val at = adoptedAtMs[relay.lowercase()] ?: return false
        return nowMs >= at && nowMs - at < WINDOW_MS
    }
    fun anyPending(nowMs: Long): Boolean = adoptedAtMs.keys.any { isPending(it, nowMs) }

    /** Only a REFUSAL from a still-pending relay is special; an outage is not enrollment's to fix. */
    fun onFailure(relay: String, forbidden: Boolean, nowMs: Long): Decision =
        if (forbidden && isPending(relay, nowMs)) Decision.RetrySoon(RETRY_GAP_MS) else Decision.BackOff
}
