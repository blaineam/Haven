package com.blaineam.haven.core

import android.net.Uri

/**
 * Deep links pointing at a specific post — parity with `apple/HavenApp/DeepLink.swift`:
 *   • `https://wemiller.com/apps/haven/#p/<circleId>.<postId>`  — web-routed, shareable anywhere
 *   • `haven://p/<circleId>/<postId>`                            — legacy; accepted forever
 *
 * ⚠️ THE FRAGMENT IS NOT COSMETIC — DO NOT "TIDY" IT INTO A PATH. ⚠️
 * A browser never sends `#…` to the server, so wemiller.com's logs (and every CDN/proxy between)
 * see only `/apps/haven/` — never *which* post. A path form would hand the host a readership map:
 * reader IP × circle × post. That map is exactly what Haven exists not to create. See
 * `docs/LINK-SYSTEM.md`.
 *
 * The link is a **pointer, not a capability** — it carries no key. Only a device already in the
 * circle can decrypt the post; everyone else gets "post not found", and a locked circle stays
 * locked.
 */
object DeepLink {
    private const val HOST = "wemiller.com"
    private const val PATH_PREFIX = "/apps/haven"

    /** Fragment-safe token charset: unreserved characters *minus* `.` and `/`, so those two stay
     *  unambiguous as our delimiters no matter what an id carries. Must stay byte-identical to
     *  `fragmentToken` in `apple/HavenApp/DeepLink.swift` — a link one platform emits has to split
     *  the same way on the other. */
    private const val TOKEN_SAFE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~"
    private const val HEX = "0123456789ABCDEF"

    data class Post(val circleId: String, val postId: String)

    /**
     * The link a post's share sheet hands out — web-routed so it crosses to iOS/Android and
     * survives being pasted anywhere. Inverse of [webPost]; null for empty ids.
     *
     * ⚠️ The payload goes AFTER the `#` on purpose — see this file's header before "fixing" it.
     * Moving `p/<circle>.<post>` into the path would ship every reader's IP × circle × post to
     * wemiller.com's access logs. Keep it in the fragment.
     */
    fun postUrl(circleId: String, postId: String): String? {
        if (circleId.isEmpty() || postId.isEmpty()) return null
        return "https://$HOST$PATH_PREFIX/#p/${encodeToken(circleId)}.${encodeToken(postId)}"
    }

    /** Not `Uri.encode` — its unreserved set keeps `.` literal, which would let a `dm:<a>-<b>`
     *  style id slide the split and hand our own parser the wrong circle. */
    private fun encodeToken(s: String): String = buildString {
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val i = b.toInt() and 0xFF
            val c = i.toChar()
            if (i < 0x80 && TOKEN_SAFE.indexOf(c) >= 0) append(c)
            else append('%').append(HEX[i shr 4]).append(HEX[i and 0xF])
        }
    }

    /** Both link generations normalize to this one route, so links shared years ago keep working. */
    fun parsePost(raw: String?): Post? {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return null
        val uri = runCatching { Uri.parse(text) }.getOrNull() ?: return null
        return webPost(uri) ?: legacyPost(uri)
    }

    /** Pull `p/<circle>.<post>` out of an https link's fragment. An invite's bare `<id>.<verify>`
     *  (and a plain visit to the site) returns null and falls through to the invite path. */
    private fun webPost(uri: Uri): Post? {
        if (!uri.scheme.equals("https", ignoreCase = true)) return null
        if (!uri.host.equals(HOST, ignoreCase = true)) return null
        if (uri.path?.startsWith(PATH_PREFIX) != true) return null
        // encodedFragment, not fragment — split on the delimiters FIRST and decode exactly once
        // after, so an id carrying an escaped '.' or '/' can never move the split.
        val frag = uri.encodedFragment ?: return null
        if (!frag.startsWith("p/")) return null
        val body = frag.removePrefix("p/")
        val dot = body.indexOf('.')
        if (dot <= 0) return null
        return post(decode(body.substring(0, dot)), decode(body.substring(dot + 1)))
    }

    /** `haven://p/<circle>/<post>` — the pre-web form. Uri already percent-decodes path segments. */
    private fun legacyPost(uri: Uri): Post? {
        if (!uri.scheme.equals("haven", ignoreCase = true)) return null
        if (!uri.host.equals("p", ignoreCase = true)) return null
        val parts = uri.pathSegments ?: return null
        if (parts.size < 2) return null
        return post(parts[0], parts[1])
    }

    private fun decode(s: String): String? = runCatching { Uri.decode(s) }.getOrNull()

    private fun post(circleId: String?, postId: String?): Post? =
        if (!circleId.isNullOrEmpty() && !postId.isNullOrEmpty()) Post(circleId, postId) else null
}
