package com.blaineam.haven.core

import android.content.Context

/**
 * The Android side of [CarCalls]: reads the live contact state and returns the callable people — the
 * same rule as [AssistantLaunch.callCandidates] (1:1 contacts, never yourself, a blocked contact or a
 * biometric-locked conversation). Blocking: boots the engine on a cold start and decodes each
 * conversation's last activity, so it runs on a background thread, never the car's main thread.
 */
object CarCallSource {
    /** Everyone Haven may call, with the time of their latest conversation activity (0 = none). */
    fun people(context: Context): List<CarCalls.Person>? {
        val app = context.applicationContext
        if (!ProfileStore.get(app).onboarded) return null   // no account yet — the phone has to finish setup
        HavenNet.init(app)
        val me = HavenNet.nodeIdHex
        return HavenNet.contacts.toList()
            .filter { !it.idHex.equals(me, true) && !HavenNet.blocked.contains(it.idHex) }
            .mapNotNull { c ->
                val circleId = HavenNet.dmCircleId(c.idHex)
                if (CircleLock.isLocked(circleId)) null
                else CarCalls.Person(circleId, c.idHex, c.name, runCatching { HavenNet.lastActivity(circleId).toLong() }.getOrDefault(0L))
            }
    }
}
