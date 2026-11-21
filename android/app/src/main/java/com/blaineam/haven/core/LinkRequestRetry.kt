package com.blaineam.haven.core

/**
 * When a device that is linking asks again. Its request, or the grant that answers it, can be
 * lost in transit; asking once left it waiting until the person scanned a second time.
 *
 * Every [EVERY_MS] for as long as the ticket could still be honoured (ten minutes from when it
 * was issued), and never past that: a request under a dead ticket is only noise.
 */
object LinkRequestRetry {
    const val EVERY_MS = 20_000L
    const val TICKET_TTL_SECS = 600L

    /** The waits between sends, starting after the first send at [nowSecs]. */
    fun waitsMs(issuedAtSecs: Long, nowSecs: Long): List<Long> {
        val leftMs = (issuedAtSecs + TICKET_TTL_SECS - nowSecs) * 1000
        if (leftMs <= 0) return emptyList()
        return List((leftMs / EVERY_MS).toInt().coerceAtMost(30)) { EVERY_MS }
    }
}
