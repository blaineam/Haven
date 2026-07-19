package com.blaineam.haven.ui

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URL

/**
 * The guard rail between a link somebody ELSE chose and this device's network stack.
 *
 * A link preview is the one place in Haven where a peer's message body decides what our socket
 * connects to. That makes it an SSRF-shaped primitive unless the destination is checked: a circle
 * member could name `http://192.168.1.1/…` or `http://169.254.169.254/…` and have the recipient's
 * phone probe its own LAN, or point at an endless response to exhaust its memory. None of that
 * needs the sender to be malicious in any sophisticated way — it needs one URL in one message.
 *
 * So everything here is deliberately conservative and, more importantly, PURE: the address
 * predicates take an [InetAddress] rather than doing their own DNS, so they can be unit tested
 * without touching the network. [openVetted] is the impure part that resolves, checks, and streams.
 */
object LinkSafety {
    /** Hard ceiling on the HTML we will buffer while looking for Open Graph tags. */
    const val MAX_HTML_BYTES = 256 * 1024

    /** Hard ceiling on a poster image. Generous for a real og:image, tiny next to a decompression bomb. */
    const val MAX_IMAGE_BYTES = 2 * 1024 * 1024

    /** A public host redirecting once or twice is normal; a redirect chain is not. */
    const val MAX_REDIRECTS = 3

    private const val CONNECT_TIMEOUT_MS = 6_000
    private const val READ_TIMEOUT_MS = 6_000

    /**
     * True if [addr] is a destination on the public internet.
     *
     * Written as an allow-nothing-by-default list of REJECTIONS because the failure mode of missing
     * a range is that we happily probe it. The ranges Java models directly (loopback, link-local,
     * site-local, any-local, multicast) are cheap; the ones it does not — CGNAT, IPv6 ULA, 0/8,
     * 192.0.0.0/24, benchmarking — are spelled out.
     */
    fun isPubliclyRoutable(addr: InetAddress): Boolean {
        if (addr.isLoopbackAddress) return false     // 127/8, ::1
        if (addr.isLinkLocalAddress) return false    // 169.254/16, fe80::/10  (incl. cloud metadata)
        if (addr.isSiteLocalAddress) return false    // 10/8, 172.16/12, 192.168/16, fec0::/10
        if (addr.isAnyLocalAddress) return false     // 0.0.0.0, ::
        if (addr.isMulticastAddress) return false

        val b = addr.address
        when (addr) {
            is Inet4Address -> {
                val a0 = b[0].toInt() and 0xFF
                val a1 = b[1].toInt() and 0xFF
                if (a0 == 0) return false                                 // 0.0.0.0/8 "this network"
                if (a0 == 100 && a1 in 64..127) return false              // 100.64/10 CGNAT
                if (a0 == 192 && a1 == 0 && (b[2].toInt() and 0xFF) == 0) return false  // 192.0.0.0/24
                if (a0 == 198 && (a1 == 18 || a1 == 19)) return false     // 198.18/15 benchmarking
                if (a0 >= 240) return false                               // 240/4 reserved + 255.255.255.255
            }
            is Inet6Address -> {
                // fc00::/7 unique-local. Java has no predicate for it, and it is the v6 equivalent
                // of the RFC1918 space we already reject.
                if ((b[0].toInt() and 0xFE) == 0xFC) return false
                // ::ffff:a.b.c.d — Java normally hands these back as Inet4Address, but a literal in
                // a URL can arrive as a v6 object, and unwrapped it would skip every check above.
                if (addr.isIPv4CompatibleAddress) return false
            }
        }
        return true
    }

    /**
     * Parse [raw] and accept it only if it is an http(s) URL with a host. Does NOT resolve — this is
     * the cheap syntactic gate, [resolvesPublicly] is the expensive one.
     */
    fun vetSyntax(raw: String): URL? {
        val url = runCatching { URL(raw) }.getOrNull() ?: return null
        val scheme = url.protocol?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        if (url.host.isNullOrBlank()) return null
        return url
    }

    /**
     * Resolve [url]'s host and require EVERY address it answers with to be publicly routable.
     *
     * Every, not any: a host that returns one public and one private A record would otherwise pass
     * the check and then be free to connect to the private one.
     *
     * Residual risk, stated honestly rather than papered over: this is a resolve-then-connect
     * sequence, so a DNS rebind with a very short TTL could still swap the answer between our check
     * and the connection. Closing that completely means dialing the vetted IP directly and carrying
     * the original Host header, which `HttpURLConnection` will not do. The practical exposure is
     * small (the attacker needs to win a sub-second race to reach a LAN address they still cannot
     * read the response from, since we only surface title/description), and the tap-to-load gate
     * means it cannot happen without the recipient asking for this specific link.
     */
    fun resolvesPublicly(url: URL): Boolean {
        val addrs = runCatching { InetAddress.getAllByName(url.host) }.getOrNull() ?: return false
        return addrs.isNotEmpty() && addrs.all { isPubliclyRoutable(it) }
    }

    /**
     * Fetch [raw] and return at most [maxBytes] of the body, or null if anything about the
     * destination or the trip disqualifies it.
     *
     * Redirects are followed BY HAND. `instanceFollowRedirects = true` is the whole vulnerability in
     * one flag: it lets a perfectly public host answer 302 to 169.254.169.254 and the platform
     * chases it without ever consulting us. Each hop is re-vetted as if it were the original link.
     */
    fun openVetted(raw: String, maxBytes: Int, accept: String): ByteArray? {
        var current = vetSyntax(raw) ?: return null
        var hops = 0
        while (true) {
            if (!resolvesPublicly(current)) return null
            val conn = (runCatching { current.openConnection() }.getOrNull() as? HttpURLConnection) ?: return null
            conn.instanceFollowRedirects = false
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.useCaches = false
            conn.setRequestProperty("User-Agent", "Mozilla/5.0 (Haven)")
            conn.setRequestProperty("Accept", accept)
            // Never carry ambient credentials to a destination a peer picked.
            conn.setRequestProperty("Cookie", "")

            val code = runCatching { conn.responseCode }.getOrElse { conn.disconnect(); return null }
            if (code in 300..399) {
                val location = conn.getHeaderField("Location")
                conn.disconnect()
                if (location.isNullOrBlank() || ++hops > MAX_REDIRECTS) return null
                // Relative redirects are legal, so resolve against the hop we are on.
                current = runCatching { URL(current, location) }.getOrNull()?.let { vetSyntax(it.toString()) } ?: return null
                continue
            }
            if (code !in 200..299) { conn.disconnect(); return null }
            return try {
                conn.inputStream.use { readCapped(it, maxBytes) }
            } catch (_: Throwable) {
                null
            } finally {
                conn.disconnect()
            }
        }
    }

    /**
     * Read at most [max] bytes, and stop reading the socket there.
     *
     * The bug this replaces was `readBytes().copyOf(max)`: `readBytes()` drains the WHOLE response
     * into memory and only then truncates, so the cap described the result and not the transfer, and
     * an endless body was an OOM waiting to be pointed at somebody.
     */
    fun readCapped(stream: InputStream, max: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(minOf(max, 32 * 1024))
        val buf = ByteArray(16 * 1024)
        var total = 0
        while (total < max) {
            val n = stream.read(buf, 0, minOf(buf.size, max - total))
            if (n < 0) break
            out.write(buf, 0, n)
            total += n
        }
        return out.toByteArray()
    }
}
