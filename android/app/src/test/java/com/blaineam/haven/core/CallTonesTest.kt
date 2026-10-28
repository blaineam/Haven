package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallTonesTest {
    @Test
    fun onlyTheCallerWhileDialingHearsRingback() {
        assertTrue(CallTones.shouldPlayRingback(isCaller = true, connecting = true, inCall = false))
        assertFalse("the callee has its own ringtone", CallTones.shouldPlayRingback(false, true, false))
        assertFalse("ringback ends when the call connects", CallTones.shouldPlayRingback(true, true, true))
        assertFalse("nothing to dial", CallTones.shouldPlayRingback(true, false, false))
    }
}
