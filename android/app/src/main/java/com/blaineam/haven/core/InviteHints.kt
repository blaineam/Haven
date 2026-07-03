package com.blaineam.haven.core

/**
 * Device-id dial hints riding invite links.
 *
 * Under the device-seed transport a friend's ACCOUNT id resolves to no node, and their signed
 * device roster (frame 27) can only arrive over a path that itself needs a device id — so a
 * freshly-added internet friend would be unreachable until some other transport worked (the
 * roster-bootstrap deadlock). The invite link therefore carries the inviter's device node id(s)
 * as a `d=` query placed BEFORE the `#` fragment, so an old parser — which reads only the
 * fragment — still accepts the link unchanged. The scanner dials the hints until the real
 * signed roster arrives and supersedes them. Format parity with iOS + desktop.
 */
object InviteHints {
    const val MAX_HINTS = 4
    private val HEX64 = Regex("^[0-9a-f]{64}$")

    /** Insert `?d=<id1>,<id2>` before the link's `#` fragment (unchanged when nothing to embed). */
    fun embed(link: String, deviceIds: List<String>): String {
        val ids = deviceIds.filter { it.length == 64 }.take(MAX_HINTS)
        val hash = link.indexOf('#')
        if (ids.isEmpty() || hash < 0 || link.contains('?')) return link
        return link.substring(0, hash) + "?d=" + ids.joinToString(",") + link.substring(hash)
    }

    /** The `d=` device ids from a pasted/scanned link (empty when absent). Only 64-hex ids pass. */
    fun extract(link: String): List<String> {
        val qStart = link.indexOf('?')
        if (qStart < 0) return emptyList()
        val end = link.indexOf('#').let { if (it in 0..qStart) return emptyList() else if (it < 0) link.length else it }
        for (pair in link.substring(qStart + 1, end).split('&')) {
            val kv = pair.split('=', limit = 2)
            if (kv.size != 2 || kv[0] != "d") continue
            return kv[1].split(',').map { it.lowercase() }.filter { HEX64.matches(it) }.take(MAX_HINTS)
        }
        return emptyList()
    }
}
