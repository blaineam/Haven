package com.blaineam.haven.core

/**
 * Which of a relay's announced HTTP URLs are worth trying from where WE are.
 *
 * A relay hosted inside the app announces every LAN IPv4 it has, which is right for a member on the
 * same network and useless to everyone else — a `192.168.4.x` URL cannot be reached from a
 * `10.0.0.x` network, ever. Those URLs are tried FIRST (HTTP is the preferred media path), so every
 * remote member burned a connect attempt and a timeout per operation on an address that could never
 * work, then fell through to iroh in a worse state.
 *
 * Kept here as a PURE function — no network, no Android context — so the rule that decides whether a
 * media path is even attempted can be tested directly. iOS `RelayMailboxStore.urlPlausiblyReachable`.
 */
object RelayUrls {

    /** The `a.b.c` /24 prefixes of our own interfaces, from a list of dotted-quad IPv4 strings. */
    fun prefixes(ourIPv4s: List<String>): Set<String> =
        ourIPv4s.mapNotNullTo(HashSet()) { ip ->
            ip.split(".").takeIf { it.size == 4 }?.take(3)?.joinToString(".")
        }

    /**
     * Public hosts and hostnames are always worth a try; a PRIVATE address only when one of our own
     * interfaces sits on the same /24. A URL we cannot parse is not tried at all.
     */
    fun plausiblyReachable(url: String, ourPrefixes: Set<String>): Boolean {
        val host = runCatching { java.net.URI(url).host }.getOrNull() ?: return false
        val labels = host.split(".")
        val parts = labels.mapNotNull { it.toIntOrNull() }
        // A dotted quad, or something else entirely (a hostname/domain — assume routable).
        if (labels.size != 4 || parts.size != 4 || parts.any { it !in 0..255 }) return true
        val isPrivate = parts[0] == 10 ||
            (parts[0] == 172 && parts[1] in 16..31) ||
            (parts[0] == 192 && parts[1] == 168)
        if (!isPrivate) return true
        return ourPrefixes.contains(parts.take(3).joinToString("."))
    }

    /**
     * Which announced URLs may skip their failure cool-down: only NEW ones — a URL we did not hold,
     * or every URL when the token changed (a restarted / re-keyed relay). A plain re-announce of the
     * interface we already hold is not evidence the door works (members keep announcing a relay for
     * 5 min after it dies). `heldUrls == null` = a relay we never held. iOS `urlsToForgive` parity.
     */
    fun urlsToForgive(heldUrls: List<String>?, heldToken: String?, announced: List<String>, token: String): List<String> {
        if (heldUrls == null || heldUrls.isEmpty() || heldToken != token) return announced
        val old = heldUrls.toSet()
        return announced.filter { it !in old }
    }

    /** How long an interface we moved AWAY from stays a known-stale echo. Outlasts the 5-minute
     *  re-announce tail members keep up for a relay, plus mailbox replays of older frame-19s. */
    const val REVERT_GUARD_MS = 10 * 60_000L

    /** The interface (urls + token) we replaced, and when. */
    data class Replaced(val urls: List<String>, val token: String, val atMs: Long)

    /**
     * Is a frame-19 announce of [announced]/[token] just a STALE ECHO of the interface we moved off?
     *
     * Announces carry no generation, and every member re-announces whatever URLs it holds — and the
     * mailbox re-delivers older frame-19 copies — so for a while after a relay moves its door the
     * old and new interfaces arrive interleaved. Adopting whichever spoke last flip-flopped a member
     * between them (gate-8: Android "learned" R_A's interface 7 times in 8 s and kept hitting the
     * abandoned port). Only an exact revert to the set we replaced, inside [REVERT_GUARD_MS], is
     * refused; the relay's own self-published interface doc (fetched over iroh when the current
     * door fails) is authoritative and bypasses this, so a relay that really did move back heals.
     */
    fun isStaleRevert(replaced: Replaced?, announced: List<String>, token: String, nowMs: Long): Boolean {
        if (replaced == null) return false
        if (nowMs < replaced.atMs || nowMs - replaced.atMs >= REVERT_GUARD_MS) return false
        return replaced.token == token && replaced.urls.toSet() == announced.toSet()
    }
}
