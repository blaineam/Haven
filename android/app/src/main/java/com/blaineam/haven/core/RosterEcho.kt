package com.blaineam.haven.core

import java.security.MessageDigest

/**
 * Device-roster envelopes (tag 0x04) this process has already received, by content — used ONLY to
 * keep a repeat from fanning out to my other devices or firing a self-sync push (Apple
 * `MailboxIngest.fanOut` parity). The core's `receive` reports a roster it already holds as applied,
 * and every hello reply resends one, so each repeat used to go out again as a live delivery + push.
 * It deliberately does NOT change what counts as "changed" (persist, feed refresh, activity): the
 * roster receipt still replays parked events, and Android's launch paint depends on that.
 */
object RosterEcho {
    const val CAP = 512
    private val order = ArrayDeque<String>()
    private val seen = HashSet<String>()

    /** True for a roster envelope whose exact bytes were noted before (notes them otherwise). */
    @Synchronized fun isRepeatRoster(env: ByteArray): Boolean {
        if (env.isEmpty() || env[0] != 0x04.toByte()) return false
        val d = MessageDigest.getInstance("SHA-256").digest(env).joinToString("") { "%02x".format(it) }
        if (!seen.add(d)) return true
        order.addLast(d)
        if (order.size > CAP) seen.remove(order.removeFirst())
        return false
    }

    @Synchronized fun clear() { order.clear(); seen.clear() }
}
