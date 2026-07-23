package com.blaineam.haven.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Holds text shared into Haven from another app (e.g. a YouTube or web link via the system share
 * sheet). The composer picks it up and prefills the draft, then clears it.
 */
object ShareInbox {
    var pending by mutableStateOf<String?>(null)
        private set
    // Media refs (already staged into LocalMedia) shared in from another app — the composer attaches
    // them to the next post.
    var pendingMedia by mutableStateOf<List<String>>(emptyList())
        private set

    fun offer(text: String?) {
        if (!text.isNullOrBlank()) pending = text.trim()
    }

    fun offerMedia(refs: List<String>) {
        if (refs.isNotEmpty()) pendingMedia = pendingMedia + refs
    }

    fun take(): String? {
        val t = pending
        pending = null
        return t
    }

    fun takeMedia(): List<String> {
        val m = pendingMedia
        pendingMedia = emptyList()
        return m
    }
}

/// A haven:// (or https invite-page) link the app was OPENED with — parity with iOS's
/// incomingLink → ConnectView flow. RootScreen observes it, opens the Connect screen with the
/// link prefilled, and clears it.
object InviteInbox {
    var pending by mutableStateOf<String?>(null)
        private set
    fun offer(uri: String?) {
        val u = uri?.trim().orEmpty()
        // A POST link rides the same domain and the same #fragment as an invite, so shape can't tell
        // them apart — only grammar can. Reject it here as well as at the MainActivity fork, so a
        // future caller can't silently re-route posts into Connect (where they fail).
        if (DeepLink.parsePost(u) != null) return
        // Only invite-shaped links (payload rides the #fragment). Anything else is a plain share.
        if (u.contains('#') && (u.startsWith("haven://") || u.contains("wemiller.com"))) pending = u
    }
    fun consume(): String? = pending.also { pending = null }
}

/// A post deep link the app was OPENED with (`https://…/#p/<c>.<p>` or legacy `haven://p/<c>/<p>`).
/// RootScreen observes it, presents the post, and clears it — the [InviteInbox] of post links.
object PostLinkInbox {
    var pending by mutableStateOf<DeepLink.Post?>(null)
        private set
    fun offer(post: DeepLink.Post?) { if (post != null) pending = post }
    fun consume(): DeepLink.Post? = pending.also { pending = null }
}

/// A bare circle deep link (`haven://c/<circleId>`, e.g. a notification that only names the
/// circle). RootScreen observes it, switches to that circle's feed (honoring the circle lock the
/// same way the post path does), and clears it.
object CircleLinkInbox {
    var pending by mutableStateOf<DeepLink.Circle?>(null)
        private set
    fun offer(circle: DeepLink.Circle?) { if (circle != null) pending = circle }
    fun consume(): DeepLink.Circle? = pending.also { pending = null }
}
