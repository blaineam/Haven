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
    private var nextId = 1000

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(CHANNEL, "Activity", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "New posts, messages and reactions from your circle"
            }
            context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(ch)
        }
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
