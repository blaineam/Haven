package com.blaineam.haven.core

import java.security.MessageDigest

/**
 * Device-roster envelopes (tag 0x04) this process already fed to the engine, by content (Apple
 * `RosterEcho` parity). The core's `receive` reports a roster as applied whenever it verifies — an
 * already-held one included — and every hello reply carries the sender's roster verbatim, so an idle
 * fleet re-applied identical bytes every ~30 s. Identical bytes cannot change anything the first copy
 * did not; a re-signed roster is new bytes. Bounded; pure JVM so unit tests cover it.
 */
object RosterEcho {
    const val CAP = 512
    private val order = ArrayDeque<String>()
    private val seen = HashSet<String>()

    /** True when these exact bytes were noted before; otherwise notes them and returns false. */
    @Synchronized fun isRepeat(env: ByteArray): Boolean {
        val d = digest(env)
        if (!seen.add(d)) return true
        order.addLast(d)
        if (order.size > CAP) seen.remove(order.removeFirst())
        return false
    }

    /** Forget [env] — its receive did not take, so a later copy must be tried. */
    @Synchronized fun forget(env: ByteArray) {
        val d = digest(env)
        if (seen.remove(d)) order.remove(d)
    }

    @Synchronized fun clear() { order.clear(); seen.clear() }

    private fun digest(b: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
}
