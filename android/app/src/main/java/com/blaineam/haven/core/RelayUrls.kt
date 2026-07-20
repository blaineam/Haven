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
}
