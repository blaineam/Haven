package com.blaineam.haven.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.RemoteInput

/**
 * Reply / Mark-as-read from the car (and from the phone's notification shade).
 *
 * Not exported: only the PendingIntents Haven itself attached to its notifications can reach it.
 * The decision (is this allowed right now?) lives in [CarMessaging.routeReply] / [routeMarkRead],
 * re-evaluated here because the circle may have been locked, or the switch turned off, after the
 * notification was posted. The send goes through the SAME [HavenNet.sendDm] the in-app composer
 * uses, so a reply from the car is an ordinary sealed DM.
 *
 * The receiver may be the first thing to run in a cold process, so it boots the engine itself
 * (idempotent, as SyncWorker does) — on a background thread, holding `goAsync` — and only cancels
 * the notification after the message has been handed to the engine (which queues it if offline).
 * If the hand-off throws, the notification stays rather than silently swallowing the reply.
 */
class CarActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val circleId = intent.getStringExtra(CarMessaging.EXTRA_CIRCLE_ID)
        val action = intent.action
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(CarMessaging.KEY_REPLY_TEXT)
        val pending = goAsync()
        EngineBoot.background {
            try {
                CarMessaging.execute(action, circleId, text, real(app))
            } finally {
                pending.finish()
            }
        }
    }

    private fun real(app: Context) = object : CarMessaging.Handlers {
        override fun enabled() = runCatching { ProfileStore.get(app).androidAutoMessages }.getOrDefault(false)
        override fun locked(circleId: String) = CircleLock.isLocked(circleId)
        override fun send(circleId: String, text: String) {
            HavenNet.init(app)
            HavenNet.sendDm(circleId, text)
        }
        override fun markRead(circleId: String) {
            HavenNet.init(app)
            DmRead.markRead(circleId, HavenNet.lastActivity(circleId))
        }
        override fun cancel(circleId: String) = CarNotifications.cancel(app, circleId)
        override fun log(message: String) { Log.i("CarAction", message) }
    }
}
