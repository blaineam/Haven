package com.blaineam.haven.core

/**
 * Cross-platform banner copy for local notifications (and sealed APNs payloads when used).
 * Parity with Apple `PushBanner.swift` and `haven_p2p::pushbanner` — a reaction must never
 * say "Posted in your circle" on any client.
 */
object PushBanner {
    data class Copy(
        val kind: String,
        val body: String,
        val privateBody: String,
        val emoji: String? = null,
        /** The authored/PARENT post id (wire field `p`) — the recipient's tap opens the exact
         *  post/thread entry instead of the legacy circle route. Best-effort; null keeps legacy. */
        val postId: String? = null,
    )

    fun clip(text: String?, limit: Int = 80): String? {
        var s = text?.trim().orEmpty()
        if (s.isEmpty()) return null
        if (s.startsWith('\u0002')) return "🔒 Secret message"
        s = s.split(Regex("\\s+")).joinToString(" ")
        if (s.length > limit) s = s.take(limit).trimEnd() + "…"
        return s
    }

    private fun isSynthetic(ref: String): Boolean {
        val i = ref.indexOf(':')
        return i > 1
    }

    private fun isAudio(ref: String) = ref.startsWith("aud_") || ref.startsWith("a:")

    // Each factory takes the authored/PARENT post id when the caller has it (a reaction/comment
    // always does — it's their target; a post reads its own id back via lastAuthoredEventId), so
    // the recipient's tap opens the exact post. A nil id keeps the old circle/thread route.
    // Parity with Apple PushBanner's `tagged` wrapper.

    fun forPost(
        circleId: String,
        circleName: String,
        body: String,
        media: List<String>,
        story: Boolean,
        postId: String? = null,
    ): Copy = tag(innerForPost(circleId, circleName, body, media, story), postId)

    private fun innerForPost(
        circleId: String,
        circleName: String,
        body: String,
        media: List<String>,
        story: Boolean,
    ): Copy {
        if (story) {
            return Copy("story", "Shared a story in $circleName", "Shared a story")
        }
        val real = media.filter { !isSynthetic(it) }
        if (circleId.startsWith("dm:")) {
            clip(body)?.let {
                return Copy("dm", it, "Sent you a message")
            }
            val hasAudio = real.any { isAudio(it) }
            val hasMedia = real.isNotEmpty()
            return when {
                hasAudio -> Copy("dm", "Sent a voice note", "Sent a voice note")
                hasMedia -> Copy("dm", "Sent a photo", "Sent a photo")
                else -> Copy("dm", "Sent you a message", "Sent you a message")
            }
        }
        val hasMedia = real.isNotEmpty()
        clip(body)?.let {
            return Copy(
                "post",
                "$circleName: $it",
                if (hasMedia) "Shared a photo" else "Posted in your circle",
            )
        }
        return if (hasMedia) {
            Copy("post", "Shared a photo in $circleName", "Shared a photo")
        } else {
            Copy("post", "Posted in $circleName", "Posted in your circle")
        }
    }

    fun forReaction(emoji: String, circleId: String, postId: String? = null): Copy {
        val isDm = circleId.startsWith("dm:")
        val e = emoji.ifEmpty { "👍" }
        return tag(
            Copy(
                "react",
                if (isDm) "Reacted $e to your message" else "Reacted $e to your post",
                if (isDm) "Reacted to your message" else "Reacted to your post",
                e,
            ),
            postId,
        )
    }

    fun forComment(body: String, circleId: String, circleName: String, postId: String? = null): Copy {
        val isDm = circleId.startsWith("dm:")
        clip(body)?.let {
            return tag(
                Copy(
                    "comment",
                    if (isDm) "Replied: $it" else "Commented in $circleName: $it",
                    if (isDm) "Replied to your message" else "Left a comment",
                ),
                postId,
            )
        }
        return tag(
            Copy(
                "comment",
                if (isDm) "Replied to your message" else "Commented in $circleName",
                if (isDm) "Replied to your message" else "Left a comment",
            ),
            postId,
        )
    }

    private fun tag(copy: Copy, postId: String?): Copy =
        if (postId.isNullOrEmpty()) copy else copy.copy(postId = postId)

    /** `detail`: full | private | minimal */
    fun displayBody(full: String, privateBody: String?, kind: String?, detail: String): Pair<Boolean, String> {
        return when (detail) {
            "minimal" -> false to "New activity"
            "private" -> true to (privateBody?.takeIf { it.isNotEmpty() } ?: fallbackPrivate(kind))
            else -> true to full
        }
    }

    private fun fallbackPrivate(kind: String?) = when (kind) {
        "story" -> "Shared a story"
        "react" -> "Reacted to your post"
        "comment" -> "Left a comment"
        "dm" -> "Sent you a message"
        "post" -> "Shared something"
        else -> "New activity"
    }
}
