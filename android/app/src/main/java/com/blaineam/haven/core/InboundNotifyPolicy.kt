package com.blaineam.haven.core

/**
 * How long after a message was SENT it may still raise an inbound banner. A circle post that old is
 * history (a backfill, a reinstall catching up); a direct message is a conversation — on a fresh
 * install or after a long offline stretch a DM routinely lands well after its send time, and
 * dropping its notification also keeps it out of Android Auto, which only reads notifications.
 * One notification per thread is ever posted (the newest unseen inbound), and `markNotified`
 * dedupes, so a wider DM window cannot spam a backfill.
 */
object InboundNotifyPolicy {
    const val CIRCLE_MAX_AGE_MS = 600_000L          // 10 min
    const val DM_MAX_AGE_MS = 24L * 60 * 60 * 1000  // 24 h

    fun maxAgeMs(circleId: String): Long =
        if (circleId.startsWith("dm:")) DM_MAX_AGE_MS else CIRCLE_MAX_AGE_MS

    /** True when a message sent at [createdAtMs] is too old to raise a banner at [nowMs]. */
    fun isStale(circleId: String, createdAtMs: Long, nowMs: Long): Boolean =
        nowMs - createdAtMs > maxAgeMs(circleId)
}
