package com.blaineam.haven.core

import kotlinx.coroutines.withTimeoutOrNull

/**
 * Bound on the iroh fallback of a relay MEDIA fetch.
 *
 * The media queue is SERIALIZED — restores and backups share one lane, one blob at a time — and the
 * iroh `RelayClient.get` it falls back to (for a relay with no usable HTTP front door) has no
 * deadline of its own. One wedged dial held the whole lane for 124 s (e2e gate-7, `node=401f6cda
 * got=-1` after two minutes), so a satellite post's full photo that was ALREADY on the default
 * relay sat behind it and missed its "completes on return" budget in both directions — the
 * returning author's held uploads queue on the same lane. A miss here only moves on to the next
 * relay (or the peer ask); it never loses anything.
 */
object RelayDialBound {
    /** A manifest/head GET over a working iroh path is well under a second; 20 s is generous. */
    const val MEDIA_HEAD_TIMEOUT_MS = 20_000L

    /** [block] or null if it did not finish within [timeoutMs] (or threw). */
    suspend fun <T> bounded(timeoutMs: Long = MEDIA_HEAD_TIMEOUT_MS, block: suspend () -> T?): T? =
        withTimeoutOrNull(timeoutMs) { runCatching { block() }.getOrNull() }
}
