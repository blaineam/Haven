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

    /** MATCHING prefix — every link form ever emitted starts here, including the pre-`/open` ones
     *  already pasted into people's chat histories. Keep it wide: narrowing it would orphan them. */
    private const val PATH_PREFIX = "/apps/haven"

    /** EMITTING path — the dedicated deep-link landing page, and the ONLY path this app claims as an
     *  App Link (see AndroidManifest.xml). Android App Links match on scheme/host/path and CANNOT see
     *  a fragment, so claiming the whole `/apps/haven` subtree meant every marketing and docs page
     *  offered to open Haven. A constant sub-path is the fix; the payload stays in the fragment, so
     *  the host still learns nothing about which post or circle. See docs/LINK-SYSTEM.md. */
    private const val LINK_PATH = "$PATH_PREFIX/open"

    /** Fragment-safe token charset: unreserved characters *minus* `.` and `/`, so those two stay
     *  unambiguous as our delimiters no matter what an id carries. Must stay byte-identical to
     *  `fragmentToken` in `apple/HavenApp/DeepLink.swift` — a link one platform emits has to split
     *  the same way on the other. */
    private const val TOKEN_SAFE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~"
    private const val HEX = "0123456789ABCDEF"

    data class Post(val circleId: String, val postId: String)

    /** A story pointer — same privacy rules as [Post] (`#s/<circle>.<post>` / `haven://s/…`). */
    data class Story(val circleId: String, val postId: String)

    /** A DM thread link (`haven://m/<dm-circle>[/<msgId>]`). [messageId] is optional — today it
     *  only disambiguates which message the notification was about; the thread opens either way. */
    data class Dm(val circleId: String, val messageId: String?)

    /** A bare circle link (`haven://c/<circleId>`) — switch to that circle's feed. */
    data class Circle(val circleId: String)

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
        return "https://$HOST$LINK_PATH/#p/${encodeToken(circleId)}.${encodeToken(postId)}"
    }

    /**
     * Shareable story pointer for a DM story-reply — web-routed like [postUrl], payload in the
     * `#` fragment as `s/<circle>.<post>`. Inverse of [parseStory].
     */
    fun storyUrl(circleId: String, postId: String): String? {
        if (circleId.isEmpty() || postId.isEmpty()) return null
        return "https://$HOST$LINK_PATH/#s/${encodeToken(circleId)}.${encodeToken(postId)}"
    }

    /** On-device form for notifications / activity (`haven://s/<circle>/<post>`). */
    fun internalStoryUrl(circleId: String, postId: String): String? {
        if (circleId.isEmpty() || postId.isEmpty()) return null
        return "haven://s/${Uri.encode(circleId)}/${Uri.encode(postId)}"
    }

    /**
     * The ON-DEVICE form, for a link Haven hands to itself (today: a notification's tap intent).
     * Deliberately the `haven://` scheme rather than [postUrl]'s web form — this one never leaves the
     * device, so routing it through wemiller.com's landing page would be a pointless round trip, and
     * the custom scheme resolves without depending on App Link verification. Parsed by [legacyPost].
     */
    fun internalPostUrl(circleId: String, postId: String): String? {
        if (circleId.isEmpty() || postId.isEmpty()) return null
        return "haven://p/${Uri.encode(circleId)}/${Uri.encode(postId)}"
    }

    /** `haven://m/<dm-circle>[/<msgId>]` — a notification tap opens the Messages THREAD, not the
     *  feed. Encoded with [encodeToken] (the shared TOKEN_SAFE charset) so a `dm:<a>-<b>` circle id
     *  survives URL parsing byte-identically to Apple `DeepLink.interactionLink`. */
    fun dmUrl(circleId: String, messageId: String? = null): String? {
        if (circleId.isEmpty()) return null
        val base = "haven://m/${encodeToken(circleId)}"
        return if (messageId.isNullOrEmpty()) base else "$base/${encodeToken(messageId)}"
    }

    /** `haven://c/<circleId>` — switch to a circle's feed (used when only the circle is known). */
    fun circleUrl(circleId: String): String? {
        if (circleId.isEmpty()) return null
        return "haven://c/${encodeToken(circleId)}"
    }

    /** Tap-target for a notification, mirroring Apple `DeepLink.interactionLink`: DMs open the
     *  Messages thread (`m/`), circle posts open the post (`p/`), and a bare circle falls back to
     *  the circle feed (`c/`). */
    fun interactionLink(circleId: String, postId: String? = null): String? {
        if (circleId.isEmpty()) return null
        if (circleId.startsWith("dm:")) return dmUrl(circleId, postId)
        if (!postId.isNullOrEmpty()) return internalPostUrl(circleId, postId)
        return circleUrl(circleId)
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

    /** → [Story] for either story form (`haven://s/…` or web `#s/…`), else null. */
    fun parseStory(raw: String?): Story? {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return null
        val uri = runCatching { Uri.parse(text) }.getOrNull() ?: return null
        return webStory(uri) ?: legacyStory(uri)
    }

    /** First story pointer embedded in free-form body text (a story reply is `"words\nhttps://…#s/…"`). */
    fun firstStoryIn(text: String): Pair<Story, String>? {
        for (token in text.split(Regex("\\s+"))) {
            val s = parseStory(token) ?: continue
            return s to token
        }
        // Mid-string paste without clean whitespace.
        val https = Regex("""https?://[^\s]+""").find(text)?.value
        if (https != null) parseStory(https)?.let { return it to https }
        val haven = Regex("""haven://s/[^\s]+""").find(text)?.value
        if (haven != null) parseStory(haven)?.let { return it to haven }
        return null
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

    /** Pull `s/<circle>.<post>` out of an https fragment — mirror of [webPost]. */
    private fun webStory(uri: Uri): Story? {
        if (!uri.scheme.equals("https", ignoreCase = true)) return null
        if (!uri.host.equals(HOST, ignoreCase = true)) return null
        if (uri.path?.startsWith(PATH_PREFIX) != true) return null
        val frag = uri.encodedFragment ?: return null
        if (!frag.startsWith("s/")) return null
        val body = frag.removePrefix("s/")
        val dot = body.indexOf('.')
        if (dot <= 0) return null
        val c = decode(body.substring(0, dot))
        val p = decode(body.substring(dot + 1))
        return if (!c.isNullOrEmpty() && !p.isNullOrEmpty()) Story(c, p) else null
    }

    /** `haven://p/<circle>/<post>` — the pre-web form. Uri already percent-decodes path segments. */
    private fun legacyPost(uri: Uri): Post? {
        if (!uri.scheme.equals("haven", ignoreCase = true)) return null
        if (!uri.host.equals("p", ignoreCase = true)) return null
        val parts = uri.pathSegments ?: return null
        if (parts.size < 2) return null
        return post(parts[0], parts[1])
    }

    /** `haven://s/<circle>/<post>`. */
    private fun legacyStory(uri: Uri): Story? {
        if (!uri.scheme.equals("haven", ignoreCase = true)) return null
        if (!uri.host.equals("s", ignoreCase = true)) return null
        val parts = uri.pathSegments ?: return null
        if (parts.size < 2) return null
        val c = parts[0]; val p = parts[1]
        return if (c.isNotEmpty() && p.isNotEmpty()) Story(c, p) else null
    }

    /** `haven://m/<dm-circle>[/<msgId>]` — Uri already percent-decodes path segments. */
    fun parseDm(raw: String?): Dm? {
        val uri = havenUri(raw, "m") ?: return null
        val parts = uri.pathSegments ?: return null
        val cid = parts.getOrNull(0) ?: return null
        if (!cid.startsWith("dm:")) return null
        return Dm(cid, parts.getOrNull(1)?.takeIf { it.isNotEmpty() })
    }

    /** `haven://c/<circleId>`. */
    fun parseCircle(raw: String?): Circle? {
        val uri = havenUri(raw, "c") ?: return null
        val cid = uri.pathSegments?.getOrNull(0) ?: return null
        if (cid.isEmpty()) return null
        return Circle(cid)
    }

    /** A parsed `haven://<host>/…` uri, or null when [raw] isn't one. */
    private fun havenUri(raw: String?, host: String): Uri? {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty()) return null
        val uri = runCatching { Uri.parse(text) }.getOrNull() ?: return null
        if (!uri.scheme.equals("haven", ignoreCase = true)) return null
        if (!uri.host.equals(host, ignoreCase = true)) return null
        return uri
    }

    private fun decode(s: String): String? = runCatching { Uri.decode(s) }.getOrNull()

    private fun post(circleId: String?, postId: String?): Post? =
        if (!circleId.isNullOrEmpty() && !postId.isNullOrEmpty()) Post(circleId, postId) else null

    // ── Story reply resolution (explicit link + legacy media attach) ─────────────────

    /**
     * Which story a DM message is about: deep link first, then retroactive inference for
     * pre-1.4.5 replies that resealed story media without a pointer.
     *
     * [messageIsMe] / [messageAuthorShort] / [createdAtMs] / [media] describe the DM event.
     * [dmPeerHex] is the other 1:1 participant (null for groups → weaker peer match).
     */
    fun storyReplyTarget(
        body: String,
        media: List<String>,
        messageIsMe: Boolean,
        messageAuthorShort: String,
        createdAtMs: Long,
        dmPeerHex: String?,
        unsent: Boolean,
        liveStories: List<Triple<String, String, LiveStory>>, // circleId, postId, meta
        keptMine: List<Pair<String, Long>>, // id, createdAt — only used when reply was to my story
    ): Story? {
        if (unsent) return null
        firstStoryIn(body)?.first?.let { return it }
        return inferLegacyStoryReply(
            media, messageIsMe, createdAtMs, dmPeerHex, liveStories, keptMine,
        )
    }

    data class LiveStory(
        val authorShort: String,
        val isMe: Boolean,
        val createdAtMs: Long,
        val hasMedia: Boolean,
    )

    private fun inferLegacyStoryReply(
        media: List<String>,
        messageIsMe: Boolean,
        replyAtMs: Long,
        dmPeerHex: String?,
        liveStories: List<Triple<String, String, LiveStory>>,
        keptMine: List<Pair<String, Long>>,
    ): Story? {
        val visual = media.filter {
            !it.startsWith("thumb:") && !it.startsWith("poster:") && !it.startsWith("orig:") &&
                !it.startsWith("geo:") &&
                (LocalMedia.isVideo(it) || (!LocalMedia.isAudio(it) && !LocalMedia.isFile(it)))
        }.let { refs ->
            // displayRefs-ish: drop markers already filtered; one visual only
            refs.filter { r ->
                MediaVariants.parsePoster(r) == null &&
                    MediaVariants.parseOriginal(r) == null &&
                    MediaVariants.parseThumb(r) == null
            }
        }
        // Prefer MediaVariants.displayRefs when available
        val display = try {
            MediaVariants.displayRefs(media).filter {
                !LocalMedia.isAudio(it) && !LocalMedia.isFile(it) && !it.startsWith("geo:")
            }
        } catch (_: Throwable) { visual }
        if (display.size != 1) return null

        val dayMs = 24L * 60 * 60 * 1000
        val lookingForMine = !messageIsMe
        val peer = dmPeerHex?.lowercase()
        val peerShort = peer?.take(12)

        data class Cand(val circleId: String, val id: String, val createdAt: Long)
        val cands = ArrayList<Cand>()

        for ((cid, pid, s) in liveStories) {
            if (!s.hasMedia) continue
            if (s.createdAtMs > replyAtMs) continue
            if (replyAtMs - s.createdAtMs > dayMs) continue
            if (lookingForMine) {
                if (!s.isMe) continue
            } else {
                val a = s.authorShort.lowercase()
                val ok = when {
                    peerShort != null && (a.startsWith(peerShort) || peerShort.startsWith(a)) -> true
                    peer != null && (peer.startsWith(a) || a.startsWith(peer.take(a.length))) -> true
                    else -> false
                }
                if (!ok) continue
            }
            cands.add(Cand(cid, pid, s.createdAtMs))
        }
        if (lookingForMine) {
            for ((id, created) in keptMine) {
                if (created > replyAtMs) continue
                if (replyAtMs - created > dayMs * 7) continue
                cands.add(Cand(DEFAULT_CIRCLE, id, created))
            }
        }
        val best = cands.maxByOrNull { it.createdAt } ?: return null
        return Story(best.circleId, best.id)
    }
}
