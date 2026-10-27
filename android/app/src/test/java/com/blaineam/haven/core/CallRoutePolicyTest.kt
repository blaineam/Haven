package com.blaineam.haven.core

import android.media.AudioDeviceInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallRoutePolicyTest {
    @Test fun phoneOwnOutputsAreNotExternal() {
        assertFalse(CallRoutePolicy.isExternal(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertFalse(CallRoutePolicy.isExternal(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        assertFalse(CallRoutePolicy.hasExternalOutput(emptyList()))
    }

    @Test fun carHeadsetAndBluetoothAreExternal() {
        for (t in listOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_HEARING_AID,
        )) assertTrue("type $t", CallRoutePolicy.hasExternalOutput(listOf(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, t)))
    }

    @Test fun speakerIsDefaultOnlyWhenNothingExternal() {
        assertTrue(CallRoutePolicy.wantsSpeaker(null, externalActive = false))
        assertFalse(CallRoutePolicy.wantsSpeaker(null, externalActive = true))
    }

    @Test fun explicitTapAlwaysWins() {
        assertTrue(CallRoutePolicy.wantsSpeaker(true, externalActive = true))
        assertFalse(CallRoutePolicy.wantsSpeaker(false, externalActive = false))
    }
}
