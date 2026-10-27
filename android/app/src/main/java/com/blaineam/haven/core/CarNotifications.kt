package com.blaineam.haven.core

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.LocusIdCompat
import androidx.core.graphics.drawable.IconCompat
import com.blaineam.haven.R

/**
 * Builds the conversation notification Android Auto (and Assistant) read — see [CarMessaging] for
 * WHEN one may exist and docs/ANDROID-AUTO.md for the platform contract:
 *
 *  * `MessagingStyle` with a `Person` per sender, a conversation title only for groups;
 *  * `CATEGORY_MESSAGE`;
 *  * a REPLY semantic action with a `RemoteInput` (mutable PendingIntent — the system fills the
 *    typed / spoken text into it) and a MARK_AS_READ semantic action, both
 *    `setShowsUserInterface(false)` and both broadcasts to [CarActionReceiver];
 *  * the shortcut id of the conversation's sharing shortcut, so Assistant can resolve "reply to Maya".
 *
 * Uses the existing "haven.activity" channel, so the user's channel settings still govern it.
 */
object CarNotifications {
    private const val CHANNEL = "haven.activity"

    fun post(context: Context, plan: CarMessaging.Plan.Messaging, deepLink: String?) {
        Notifications.ensureChannel(context)
        val shortcutOk = ShareShortcuts.ensure(context, plan.circleId)
        val me = Person.Builder().setName(context.getString(R.string.you_default_name)).build()
        val style = NotificationCompat.MessagingStyle(me)
        if (plan.isGroup) {
            style.isGroupConversation = true
            plan.title?.let { style.conversationTitle = it }
        } else {
            style.isGroupConversation = false
        }
        for (m in plan.messages) {
            val person = Person.Builder()
                .setName(m.senderName.ifBlank { "Someone" })
                .setKey(m.senderKey)
                .apply { AvatarStore.bitmap(m.senderKey)?.let { b ->
                    runCatching { IconCompat.createWithAdaptiveBitmap(b) }.getOrNull()?.let { setIcon(it) }
                } }
                .build()
            style.addMessage(NotificationCompat.MessagingStyle.Message(m.text, m.timestampMs, person))
        }

        val id = plan.notificationId
        val open = PendingIntent.getActivity(
            context, id, openIntent(context, deepLink),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val replyInput = RemoteInput.Builder(CarMessaging.KEY_REPLY_TEXT)
            .setLabel(context.getString(R.string.car_reply_label))
            .build()
        val reply = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send, context.getString(R.string.car_reply_label),
            actionIntent(context, CarMessaging.ACTION_REPLY, plan.circleId, id, mutable = true),
        )
            .addRemoteInput(replyInput)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .setAllowGeneratedReplies(false)   // no canned smart-replies spoken on a driver's behalf
            .build()
        val markRead = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_view, context.getString(R.string.car_mark_read_label),
            actionIntent(context, CarMessaging.ACTION_MARK_READ, plan.circleId, id, mutable = false),
        )
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
            .setShowsUserInterface(false)
            .build()

        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(open)
            .setLocusId(LocusIdCompat(plan.circleId))
            .addAction(reply)
            .addAction(markRead)
            .apply { if (shortcutOk) setShortcutId(plan.circleId) }
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(id, n) }
    }

    fun cancel(context: Context, circleId: String) {
        runCatching { NotificationManagerCompat.from(context).cancel(CarMessaging.notificationId(circleId)) }
    }

    private fun openIntent(context: Context, deepLink: String?): Intent =
        if (deepLink != null) {
            Intent(Intent.ACTION_VIEW, Uri.parse(deepLink)).setPackage(context.packageName)
                .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP) }
        } else {
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.apply { addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP) } ?: Intent()
        }

    /** An EXPLICIT broadcast to our own receiver. Reply must be mutable (the system adds the
     *  RemoteInput result to it); mark-read stays immutable. */
    private fun actionIntent(context: Context, action: String, circleId: String, id: Int, mutable: Boolean): PendingIntent {
        val i = Intent(action).setClass(context, CarActionReceiver::class.java)
            .putExtra(CarMessaging.EXTRA_CIRCLE_ID, circleId)
        // Distinct request code per (action, conversation): a shared one would let FLAG_UPDATE_CURRENT
        // retarget another conversation's still-posted reply.
        val code = id xor (if (mutable) 0x1 else 0x2)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (mutable) { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0 }
            else PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, code, i, flags)
    }
}
