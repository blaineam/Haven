package com.blaineam.haven.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Answer / Decline straight from the incoming-call notification.
 *
 * Without this the notification could only OPEN the app, which means a call can be picked up only
 * by unlocking, waiting for Haven to come up, and finding the button — long enough that the caller
 * has usually given up. Both actions run against the live [CallManager], the same one the in-app
 * buttons drive, so there is exactly one place that decides what answering means.
 */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        runCatching { Notifications.clearIncomingCall(app) }
        when (intent.action) {
            // ANSWER is no longer routed here: it is an activity-start PendingIntent on the
            // notification itself, because Android 10+ refuses a background activity start from a
            // receiver — accepting here connected the call with no UI at all. MainActivity performs
            // the accept once it is on screen. Kept only for older notifications still in the tray.
            Notifications.ACTION_ANSWER -> runCatching { CallManager.accept() }
            Notifications.ACTION_DECLINE -> runCatching { CallManager.hangup() }
        }
    }
}
