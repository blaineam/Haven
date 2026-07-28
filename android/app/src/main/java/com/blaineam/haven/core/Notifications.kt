package com.blaineam.haven.core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Local-only notifications — no server, no third party (parity with the iOS local-notification
 * design). Posted when new content arrives while the app isn't in the foreground.
 */
object Notifications {
    private const val CHANNEL = "haven.activity"
    /** Calls get their OWN channel: ringtone + vibrate + a full-screen intent, none of which belong
     *  on ordinary activity. A user who mutes post notifications must still be reachable by phone. */
    private const val CALL_CHANNEL = "haven.call"
    private const val CALL_NOTIF_ID = 424242
    private var nextId = 1000

    const val ACTION_ANSWER = "com.blaineam.haven.ANSWER_CALL"
    const val ACTION_DECLINE = "com.blaineam.haven.DECLINE_CALL"
    /** Set on the launch intent when the user answered from the notification. */
    const val EXTRA_ANSWER_CALL = "haven.answer_call"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL, "Activity", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "New posts, messages and reactions from your circle"
            }
            context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(ch)
        }
    }

    fun ensureCallChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = context.getSystemService(NotificationManager::class.java) ?: return
        if (mgr.getNotificationChannel(CALL_CHANNEL) != null) return
        val ch = NotificationChannel(CALL_CHANNEL, "Calls", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Incoming Haven calls"
            setSound(
                android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE),
                android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 1000, 1000)
            lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
        }
        mgr.createNotificationChannel(ch)
    }

    /**
     * Ring for an incoming call while the app is BACKGROUNDED.
     *
     * Haven has no FCM by design — [ConnectionService] keeps the node alive instead — but the call
     * still only ever surfaced as in-app UI ([CallUI]'s `IncomingCall`). So a call arrived, the
     * process knew about it, and the phone said nothing: the callee saw it only if they happened to
     * already be looking at Haven. A call nobody can hear is a call that did not arrive.
     *
     * A full-screen intent is what makes the OS raise the call UI over the lock screen the way a
     * phone call does; where it is not permitted the notification degrades to a heads-up banner with
     * the same two actions, which is still reachable.
     */
    fun showIncomingCall(context: Context, callerName: String) {
        ensureCallChannel(context)
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP) }
            ?: Intent()
        val full = PendingIntent.getActivity(
            context, 1, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // ANSWER launches the ACTIVITY directly, carrying an extra. It must not be a broadcast:
        // Android 10+ blocks background activity starts, so a receiver could accept the call but
        // never bring up a screen — the call connected with no UI, no way to hang up, and the user
        // had to open Haven by hand to find it (often behind whatever screen was already there).
        // A notification action that IS an activity start is exempt, so the call and its UI arrive
        // together. DECLINE stays a broadcast: it needs no screen.
        val answerIntent = (context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent()).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or
                     Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            putExtra(EXTRA_ANSWER_CALL, true)
        }
        val answerPi = PendingIntent.getActivity(
            context, 2, answerIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        fun action(act: String, code: Int) = PendingIntent.getBroadcast(
            context, code, Intent(act).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val who = callerName.ifBlank { "Someone" }
        val n = NotificationCompat.Builder(context, CALL_CHANNEL)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle("Incoming Haven call")
            .setContentText(who)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)          // not swipe-dismissable: decline it, don't lose it
            .setAutoCancel(false)
            .setFullScreenIntent(full, true)
            .setContentIntent(full)
            .addAction(android.R.drawable.sym_call_incoming, "Answer", answerPi)
            .addAction(android.R.drawable.sym_call_missed, "Decline", action(ACTION_DECLINE, 3))
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(CALL_NOTIF_ID, n) }
    }

    /** Clear the ringing notification — answered, declined, or the caller gave up. */
    fun clearIncomingCall(context: Context) {
        runCatching { NotificationManagerCompat.from(context).cancel(CALL_NOTIF_ID) }
    }

    /**
     * [deepLink] (a `haven://…` or `https://…` post URL) makes the notification OPEN what it's about
     * when tapped instead of just raising the app. It's delivered as an ordinary ACTION_VIEW, so it
     * lands in `MainActivity.handleShare` and routes through the SAME `DeepLink` parser as a pasted
     * or shared link — one route table, one set of rules about what a link may open.
     */
    fun notify(context: Context, title: String, body: String, deepLink: String? = null) {
        ensureChannel(context)
        val id = nextId++
        val intent = if (deepLink != null) {
            Intent(Intent.ACTION_VIEW, android.net.Uri.parse(deepLink))
                .setPackage(context.packageName)
                .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP) }
        } else {
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.apply { addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP) }
        }
        // The request code must be UNIQUE per notification: with a shared code, FLAG_UPDATE_CURRENT
        // rewrites the one PendingIntent every other posted notification is still holding, so every
        // pending tap would open whichever post notified last.
        val pi = PendingIntent.getActivity(
            context, id, intent ?: Intent(),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(id, n) }
    }
}
