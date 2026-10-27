package com.blaineam.haven.core

import android.content.Context
import android.util.Log

/**
 * The real side effects behind a reply / mark-as-read from the car: shared by the notification actions
 * ([CarActionReceiver]) and the head-unit conversation screen (`car/CarMessagesList`), so both go through
 * the SAME [CarMessaging.execute] rules (lock + switch re-checked at the moment of sending) and the same
 * [HavenNet.sendDm] the in-app composer uses.
 */
object CarHandlers {
    fun real(app: Context) = object : CarMessaging.Handlers {
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
