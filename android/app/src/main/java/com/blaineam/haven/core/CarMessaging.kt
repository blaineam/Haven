package com.blaineam.haven.core

/**
 * The pure rules behind Haven's Android Auto messaging (docs/ANDROID-AUTO.md) — no Android types, so
 * every decision here is covered by a plain JVM test.
 *
 * Android Auto has no data channel of its own for a messaging app: it mirrors the phone's
 * notifications, and reads out / offers a voice reply on the ones that are `MessagingStyle` with a
 * REPLY and a MARK_AS_READ semantic action. So "what is shown on the car" is exactly "which inbound
 * notifications we build as MessagingStyle", and the privacy rules are exactly the rules for that
 * choice. They mirror the iOS CarPlay/Siri rules (`MessagingPrivacy`, `SharedNotificationPrivacy`,
 * docs/CARPLAY.md):
 *
 *  * only a plain inbound DM becomes a car notification — never a call, reaction, comment, story,
 *    edit or circle post;
 *  * only at the **Full** notification-preview level (private / minimal show no text on the car, as
 *    `Name and type only` and `Minimal` show none on CarPlay);
 *  * never for a biometric-locked circle, whatever the preview level — and a locked circle's phone
 *    banner drops to the generic "New activity in a locked circle" too, so nothing about it leaks to a lock screen;
 *  * and only while the "Android Auto messages" switch is on.
 *
 * A notification that is not built as MessagingStyle is simply invisible to Android Auto.
 */
object CarMessaging {
    const val ACTION_REPLY = "com.blaineam.haven.CAR_REPLY"
    const val ACTION_MARK_READ = "com.blaineam.haven.CAR_MARK_READ"
    const val EXTRA_CIRCLE_ID = "haven.car.circle"
    /** RemoteInput result key for the spoken / typed reply. */
    const val KEY_REPLY_TEXT = "haven.car.reply_text"

    /** Messages kept on one conversation notification. Bounded so the car never reads out a backlog. */
    const val MAX_MESSAGES = 6
    /** A reply longer than this is rejected rather than sent as an unreviewed wall of text. */
    const val MAX_REPLY_CHARS = 4_000

    data class Msg(
        /** Stable id of the sender (their node hex) — becomes the `Person` key. */
        val senderKey: String,
        val senderName: String,
        val text: String,
        val timestampMs: Long,
    )

    data class Input(
        val circleId: String,
        /** `PushBanner.Copy.kind` of the newest item: "dm" | "post" | "story" | "react" | "comment". */
        val kind: String,
        val locked: Boolean,
        /** "full" | "private" | "minimal" (the user's notification-preview setting). */
        val detail: String,
        val carEnabled: Boolean,
        /** Group title (the members' names); ignored for a 1:1 thread. */
        val title: String,
        /** Oldest first. */
        val messages: List<Msg>,
    )

    sealed interface Plan {
        /** Build this as a MessagingStyle conversation notification (visible to Android Auto). */
        data class Messaging(
            val circleId: String,
            val notificationId: Int,
            val isGroup: Boolean,
            val title: String?,
            val messages: List<Msg>,
        ) : Plan

        /** Build the ordinary banner — Android Auto does not surface it. */
        data object Plain : Plan
    }

    fun isDm(circleId: String) = circleId.startsWith("dm:")

    /** Phone banner body for a biometric-locked circle (iOS `redactIfLocked` copy), under title "Haven". */
    const val LOCKED_BODY = "New activity in a locked circle"

    fun plan(input: Input): Plan {
        if (!input.carEnabled) return Plan.Plain
        if (!isDm(input.circleId)) return Plan.Plain
        if (input.kind != "dm") return Plan.Plain
        if (input.locked) return Plan.Plain
        if (input.detail != "full") return Plan.Plain
        val msgs = input.messages
            .filter { it.text.isNotBlank() }
            .sortedBy { it.timestampMs }
            .takeLast(MAX_MESSAGES)
        if (msgs.isEmpty()) return Plan.Plain
        val group = PushBanner.isGroupDm(input.circleId)
        return Plan.Messaging(
            circleId = input.circleId,
            notificationId = notificationId(input.circleId),
            isGroup = group,
            // A 1:1 thread is titled by its sender; only a group needs a conversation title.
            title = if (group) input.title.ifBlank { null } else null,
            messages = msgs,
        )
    }

    /** One stable notification per conversation, so a new message updates it instead of stacking. */
    fun notificationId(circleId: String): Int = 0x4A000000 or (circleId.hashCode() and 0x00FFFFFF)

    sealed interface Reply {
        data class Send(val circleId: String, val text: String) : Reply
        data class Reject(val reason: String) : Reply
    }

    /**
     * Decide what a RemoteInput reply from the car may do. Re-checks the lock and the switch at the
     * moment of sending — they may have changed since the notification was posted.
     */
    fun routeReply(circleId: String?, text: CharSequence?, locked: Boolean, carEnabled: Boolean): Reply {
        if (!carEnabled) return Reply.Reject("disabled")
        if (circleId.isNullOrEmpty() || !isDm(circleId)) return Reply.Reject("not-a-dm")
        if (locked) return Reply.Reject("locked")
        val body = text?.toString()?.trim().orEmpty()
        if (body.isEmpty()) return Reply.Reject("empty")
        if (body.length > MAX_REPLY_CHARS) return Reply.Reject("too-long")
        return Reply.Send(circleId, body)
    }

    /** Mark-as-read may run for any DM that is not locked; a locked thread is never touched from the car. */
    fun routeMarkRead(circleId: String?, locked: Boolean, carEnabled: Boolean): String? =
        if (carEnabled && !locked && !circleId.isNullOrEmpty() && isDm(circleId)) circleId else null

    /** Side effects of a car action, injected so the routing runs on the JVM without a device. */
    interface Handlers {
        fun enabled(): Boolean
        fun locked(circleId: String): Boolean
        fun send(circleId: String, text: String)
        fun markRead(circleId: String)
        fun cancel(circleId: String)
        fun log(message: String)
    }

    /** Run one reply / mark-as-read action against [h]. See [CarActionReceiver] for the contract. */
    fun execute(action: String?, circleId: String?, text: CharSequence?, h: Handlers) {
        val isLocked = !circleId.isNullOrEmpty() && h.locked(circleId)
        when (action) {
            ACTION_REPLY -> when (val route = routeReply(circleId, text, isLocked, h.enabled())) {
                is Reply.Send -> {
                    val sent = runCatching { h.send(route.circleId, route.text) }
                        .onFailure { h.log("car reply failed: ${it.javaClass.simpleName}") }.isSuccess
                    if (sent) {
                        // Replying implies the thread was read; cancelling clears the car's spinner.
                        runCatching { h.markRead(route.circleId) }
                        h.cancel(route.circleId)
                    }
                }
                is Reply.Reject -> {
                    h.log("car reply rejected: ${route.reason}")
                    // Locked / switched off: take the notification down so the car stops offering it.
                    if (!circleId.isNullOrEmpty() && (route.reason == "locked" || route.reason == "disabled")) h.cancel(circleId)
                }
            }
            ACTION_MARK_READ -> {
                val id = routeMarkRead(circleId, isLocked, h.enabled())
                if (id != null) runCatching { h.markRead(id) }
                if (!circleId.isNullOrEmpty()) h.cancel(circleId)
            }
        }
    }
}
