package com.blaineam.haven.core

import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC as DATA_SYNC
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION as PROJECTION
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE as MIC
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING as REMOTE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ForegroundTypesTest {
    @Test
    fun idleStayConnectedIsDataSyncBelowAndroid14() {
        for (sdk in 29..33) assertEquals("sdk $sdk", DATA_SYNC, ForegroundTypes.forState(sdk, micWanted = false, projection = false))
    }

    @Test
    fun idleStayConnectedIsRemoteMessagingFromAndroid14() {
        // No time budget: the process must survive all day on low-RAM phones with no push.
        for (sdk in 34..36) assertEquals("sdk $sdk", REMOTE, ForegroundTypes.forState(sdk, micWanted = false, projection = false))
    }

    @Test
    fun belowApi29ThereIsNoTypedStartForeground() {
        assertEquals(0, ForegroundTypes.forState(28, micWanted = true, projection = true))
    }

    @Test
    fun aCallOnAndroid15NeverDependsOnTheDataSyncBudget() {
        // The budget runs out after ~6 h/day; a call's mic must not go with it.
        assertEquals(MIC, ForegroundTypes.forState(35, micWanted = true, projection = false))
        assertEquals(MIC or PROJECTION, ForegroundTypes.forState(36, micWanted = true, projection = true))
        assertEquals(PROJECTION, ForegroundTypes.forState(35, micWanted = false, projection = true))
    }

    @Test
    fun beforeAndroid15ACallKeepsDataSyncAsBefore() {
        assertEquals(REMOTE or MIC, ForegroundTypes.forState(34, micWanted = true, projection = false))
        assertEquals(DATA_SYNC or PROJECTION, ForegroundTypes.forState(33, micWanted = true, projection = true))
        assertEquals(REMOTE or PROJECTION, ForegroundTypes.forState(34, micWanted = false, projection = true))
        // No microphone type before 34: the call still needs SOME type to stay foreground.
        assertEquals(DATA_SYNC, ForegroundTypes.forState(30, micWanted = true, projection = false))
    }

    @Test
    fun aTimeoutWhileIdleStopsTheService() {
        assertNull(ForegroundTypes.afterTimeout(35, micWanted = false, projection = false))
    }

    @Test
    fun aTimeoutMidCallKeepsOnlyTheCallsTypes() {
        assertEquals(MIC, ForegroundTypes.afterTimeout(35, micWanted = true, projection = false))
        assertEquals(MIC or PROJECTION, ForegroundTypes.afterTimeout(36, micWanted = true, projection = true))
        assertEquals(PROJECTION, ForegroundTypes.afterTimeout(35, micWanted = false, projection = true))
    }
}
