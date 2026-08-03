package com.blaineam.haven.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Content shared into Haven from another app via the system share sheet — text, links, photos,
 * videos, and documents. [RootScreen] raises the share routing sheet on this, which is where the
 * user chooses a post, a story, or a conversation (Apple `ShareRouter` parity).
 *
 * The media/file refs are already staged into [LocalMedia] by the time they land here: an
 * `EXTRA_STREAM` content URI is only readable for the life of the intent, so MainActivity copies
 * the bytes out before anything else can look at them.
 */
object ShareInbox {
    /**
     * One share, ready to route.
     *
     * [targetCircleId] is set only when the user tapped one of Haven's conversations in the share
     * sheet's Direct Share row — it's the `dm:` circle id we published as a sharing shortcut (see
     * [ShareShortcuts]), and it means the destination is already chosen.
     */
    data class Payload(
        val text: String = "",
        val media: List<String> = emptyList(),
        val targetCircleId: String? = null,
    ) {
        val isEmpty: Boolean get() = text.isBlank() && media.isEmpty()
    }

    var pending by mutableStateOf<Payload?>(null)
        private set

    /** MainActivity hands over a complete share. Merges into anything not yet consumed, so a share
     *  that arrives while the sheet is still open adds to it rather than replacing it. */
    fun offer(payload: Payload) {
        if (payload.isEmpty && payload.targetCircleId == null) return
        val prior = pending
        pending = if (prior == null) payload else Payload(
            text = listOf(prior.text, payload.text).filter { it.isNotBlank() }.joinToString("\n"),
            media = prior.media + payload.media,
            targetCircleId = payload.targetCircleId ?: prior.targetCircleId,
        )
    }

    fun consume(): Payload? = pending.also { pending = null }

    /** Drop an un-consumed share (the routing sheet was cancelled). */
    fun clear() { pending = null }
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
