package com.blaineam.haven.core

import android.util.Base64

/**
 * What goes to the push worker's `/notify`, and how often.
 *
 * The worker inlines an event into an APNs payload only when `payload + event` stays under ~3900 characters
 * (push/worker.js); anything larger is logged "ev dropped" and the push is sent without it. A re-sealed or
 * hybrid-signed envelope is 9-88 KB, so inlining one could never work — it only burned upload bytes and, during a
 * catch-up, a stream of `/notify` calls per second (the worker's per-IP limit then drops the useful ones too).
 *
 *  * [inline] returns the base64 event only when it fits; otherwise null and the push is a plain wake — the woken
 *    device pulls the real envelope from its mailbox.
 *  * [allowSelfSync] bounds the "my other devices, catch up" push: a short burst is fine, a catch-up stream is
 *    coalesced into the next mailbox poll.
 */
internal object PushPolicy {
    /** Base64 length the worker will inline (it budgets 3900 for payload + event; keep headroom for the banner). */
    const val INLINE_MAX_B64 = 3_000

    /** At most [SELF_SYNC_BURST] self-sync pushes per [SELF_SYNC_WINDOW_MS]. */
    const val SELF_SYNC_BURST = 4
    const val SELF_SYNC_WINDOW_MS = 10_000L

    fun inline(env: ByteArray): String? {
        // base64 grows by 4/3: skip encoding what cannot fit.
        if ((env.size + 2) / 3 * 4 > INLINE_MAX_B64) return null
        return Base64.encodeToString(env, Base64.NO_WRAP)
    }

    private val sent = ArrayDeque<Long>()
    @Volatile internal var now: () -> Long = { System.currentTimeMillis() }

    @Synchronized fun allowSelfSync(): Boolean {
        val t = now()
        while (sent.isNotEmpty() && t - sent.first() >= SELF_SYNC_WINDOW_MS) sent.removeFirst()
        if (sent.size >= SELF_SYNC_BURST) return false
        sent.addLast(t)
        return true
    }

    @Synchronized internal fun reset() = sent.clear()
}
