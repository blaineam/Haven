package com.blaineam.haven.car

import android.content.pm.ApplicationInfo
import androidx.car.app.CarAppService
import androidx.car.app.Session
import androidx.car.app.validation.HostValidator

/**
 * Haven's SECOND Android Auto entry — "Haven Messages" (category MESSAGING): the conversation list, built
 * from the Car App Library's messaging models. The head unit reads unread messages aloud on a tap, hides
 * message text while the car moves, and routes a spoken reply back ([HavenConversationCallback]). It sits
 * next to "Haven Calls" ([HavenCarAppService]); both are the same app process and the same data sources.
 * Host validation is the calls service's ([CarHosts]). See docs/CAR-PARITY.md and docs/ANDROID-AUTO.md.
 */
class HavenMessagesCarAppService : CarAppService() {
    override fun createHostValidator(): HostValidator =
        CarHosts.validator(this, (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0)

    override fun onCreateSession(): Session = HavenMessagesSession()
}
