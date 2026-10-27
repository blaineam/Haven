package com.blaineam.haven.core

/**
 * Relay announces (frame 19) that arrived BEFORE this device held the circle's key.
 *
 * A relay announce is sealed to the circle, so a freshly (re)installed device that has not yet
 * received the circle's key material cannot open it — and `handleRelayNode` used to `return`,
 * dropping it for good. That is the only way a new device ever learns its FIRST relay (an invite
 * link carries device ids, not a relay, and self-sync needs a transport), so a device whose first
 * announce raced its key ran relay-less indefinitely: `circle=default relays=[]`, "no transport
 * (no relay, no S3)", every photo "Waiting for sender…".
 *
 * Park them (bounded, expiring, de-duplicated) and re-process when keys may have landed. Pure and
 * clock-injected so the rules are unit-testable.
 */
class RelayAnnounceParking(
    private val capacity: Int = 64,
    private val ttlMs: Long = 60 * 60_000L,
    private val minRetryGapMs: Long = 5_000L,
) {
    class Parked(val circleId: String, val sealed: ByteArray, val parkedAtMs: Long)

    private val items = LinkedHashMap<String, Parked>()
    private var drained = false
    private var lastDrainMs = 0L

    /** Park an announce; the same sealed bytes are kept once. Oldest are evicted past [capacity]. */
    @Synchronized fun park(circleId: String, sealed: ByteArray, nowMs: Long) {
        val key = circleId + "|" + java.security.MessageDigest.getInstance("SHA-256").digest(sealed)
            .joinToString("") { "%02x".format(it) }.take(24)
        items.remove(key)                       // re-park refreshes recency
        items[key] = Parked(circleId, sealed, nowMs)
        while (items.size > capacity) items.remove(items.keys.first())
    }

    /**
     * The parked announces to re-process now: none until [minRetryGapMs] has passed since the last
     * drain, expired ones are dropped, and the returned ones are REMOVED (a still-unopenable one is
     * simply parked again by the caller, keeping its place in the bounded queue).
     */
    @Synchronized fun drain(nowMs: Long): List<Parked> {
        if (items.isEmpty() || (drained && nowMs - lastDrainMs < minRetryGapMs)) return emptyList()
        drained = true
        lastDrainMs = nowMs
        val it = items.entries.iterator()
        val out = ArrayList<Parked>()
        while (it.hasNext()) {
            val p = it.next().value
            it.remove()
            if (nowMs - p.parkedAtMs <= ttlMs) out.add(p)
        }
        return out
    }

    @Synchronized fun size(): Int = items.size
}
