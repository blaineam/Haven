package com.blaineam.haven.core

/**
 * The pure rules behind the Messages tab of Haven's Android Auto CAR APP — the conversation list the
 * head unit draws with the Car App Library's messaging models (`ConversationItem` / `CarMessage`), the
 * Android sibling of CarPlay's Messages tab (docs/CAR-PARITY.md). No Android types, so every decision is
 * a plain JVM test; `car/CarMessagesList` only turns [Row]s into templates.
 *
 * What the host does with a [Row]: it lists the conversation, reads the unread messages aloud on a tap
 * and offers a spoken reply — the head unit (not Haven) hides message text while the car is moving, which
 * is what `ConversationItem` exists for. Haven's job is to decide WHAT may be handed to the host at all,
 * and those rules mirror [CarMessaging] (the notification path) and iOS `MessagingPrivacy`:
 *
 *  * only a DM thread (1:1 or group) — never a circle post, story, reaction or comment;
 *  * only while the "Android Auto messages" switch is on;
 *  * a biometric-LOCKED conversation is omitted entirely (CarPlay shows a non-tappable "Locked" row; a
 *    `ConversationItem` has no inert state, so nothing about the thread — not even its name — is offered);
 *  * only at the **Full** notification-preview level do real message texts reach the host; at *private*
 *    and *minimal* the thread is listed by name with ONE generic message (so the host still reads
 *    "New message" and offers a reply) and the real texts never leave Haven.
 */
object CarConversations {
    const val TAB_MESSAGES = "messages"

    /** `ConversationItem` / `CarMessage` need Car App API level 7 (an older host gets no Messages tab). */
    const val MESSAGES_API_LEVEL = 7

    /** Docs recommend 5–10 conversations with at most the 5 most recent messages each. */
    const val MAX_THREADS = 10
    const val MAX_MESSAGES = 5

    /** One message of a thread, as read from the engine. */
    data class Msg(
        val senderKey: String,
        val senderName: String,
        val text: String,
        val timestampMs: Long,
        val fromMe: Boolean,
        /** True once it is at or before the thread's read watermark (my own messages are always read). */
        val read: Boolean,
    )

    /** A DM conversation as the engine knows it (unfiltered). */
    data class Thread(
        val circleId: String,
        val title: String,
        /** The partner's account id for a 1:1 thread (avatar key); null for a group. */
        val partnerHex: String?,
        val isGroup: Boolean,
        val locked: Boolean,
        /** Oldest first. */
        val messages: List<Msg>,
    )

    /** One conversation row, already redacted per the privacy level. */
    data class Row(
        val circleId: String,
        val title: String,
        val partnerHex: String?,
        val isGroup: Boolean,
        val unread: Int,
        /** Oldest first; never empty (the library rejects an empty list). */
        val messages: List<Msg>,
        /** True when [messages] carry the generic placeholder instead of the real texts. */
        val redacted: Boolean,
    )

    /**
     * Where the conversation list lives. Haven ships it as its OWN Android Auto entry ("Haven Messages",
     * `HavenMessagesCarAppService`, category MESSAGING) next to "Haven Calls" — the documented shape, a plain
     * `ListTemplate` of `ConversationItem`s. The Calls service can ALSO carry a Messages tab (set this to
     * true and add the MESSAGING category to its intent filter — docs/CAR-PARITY.md "Fallback"); that is the
     * fallback if a head unit shows one Haven entry per package instead of two. Off by default so a driver
     * does not see the same conversations twice.
     */
    const val TAB_IN_CALLS_SERVICE = false

    /** What the Messages list needs to render. */
    sealed interface Snapshot {
        data object Loading : Snapshot
        /** The switch is off, or this host is too old for conversation items: no Messages tab at all. */
        data object Hidden : Snapshot
        /** The "Android Auto messages" switch is off (the standalone entry says so instead of showing nothing). */
        data object Off : Snapshot
        /** No account yet — the phone has to finish setup. */
        data object NeedsSetup : Snapshot
        data class Ready(val rows: List<Row>) : Snapshot
    }

    fun isDmThread(circleId: String) = CarMessaging.isDm(circleId)

    /**
     * The rows to hand to the host. [detail] is the user's notification-preview level ("full" | "private" |
     * "minimal"), [genericBody] the localized stand-in text for the redacted levels, [max] the host's list
     * limit. Newest conversation first.
     */
    fun rows(threads: List<Thread>, detail: String, carEnabled: Boolean, genericBody: String, max: Int): List<Row> {
        if (!carEnabled) return emptyList()
        val full = detail == "full"
        return threads.asSequence()
            .filter { isDmThread(it.circleId) && !it.locked }
            .distinctBy { it.circleId }
            .mapNotNull { row(it, full, genericBody) }
            .sortedWith(compareByDescending<Row> { it.messages.last().timestampMs }.thenBy { it.title.lowercase() }.thenBy { it.circleId })
            .take(max.coerceIn(1, MAX_THREADS))
            .toList()
    }

    private fun row(t: Thread, full: Boolean, genericBody: String): Row? {
        val real = t.messages.filter { it.text.isNotBlank() }.sortedBy { it.timestampMs }.takeLast(MAX_MESSAGES)
        if (real.isEmpty()) return null
        val unread = real.count { !it.fromMe && !it.read }
        if (full) return Row(t.circleId, t.title, t.partnerHex, t.isGroup, unread, real, redacted = false)
        // private / minimal: the real texts (and sender names inside a group) stay in Haven.
        val newest = real.last()
        val generic = Msg(
            senderKey = if (t.isGroup) t.circleId else (t.partnerHex ?: t.circleId),
            senderName = t.title,
            text = genericBody,
            timestampMs = newest.timestampMs,
            fromMe = false,
            read = unread == 0,
        )
        return Row(t.circleId, t.title, t.partnerHex, t.isGroup, unread, listOf(generic), redacted = true)
    }

    /** Whether the Messages tab exists for this host / setting. */
    fun tabVisible(carApiLevel: Int, carEnabled: Boolean): Boolean = carEnabled && carApiLevel >= MESSAGES_API_LEVEL
}
