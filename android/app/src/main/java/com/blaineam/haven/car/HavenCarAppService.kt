package com.blaineam.haven.car

import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/**
 * Haven's Android Auto car app (category CALLING): a Recents / Contacts screen on the head unit where
 * tapping a person calls them. Messaging stays notification-based ([com.blaineam.haven.core.CarMessaging]).
 * See docs/ANDROID-CALLS.md.
 */
class HavenCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        CarHosts.validator(this, (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)

    override fun onCreateSession(): Session = HavenCarSession()
}
