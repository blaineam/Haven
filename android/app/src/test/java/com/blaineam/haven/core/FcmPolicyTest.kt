package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FcmPolicyTest {
    @Test
    fun registrationMaterialIsPrefixedSoItCannotBeReplayedAsAnotherSignature() {
        assertEquals("fcm-v1:abc", FcmPolicy.registrationMaterial("abc"))
        assertFalse(FcmPolicy.registrationMaterial("abc").startsWith("flag-v1:"))
    }

    @Test
    fun firebaseRunsOnlyWhenOptedInConfiguredAndPlayServicesExist() {
        assertTrue(FcmPolicy.shouldRun(optedIn = true, configured = true, playServices = true))
        assertFalse("off by default", FcmPolicy.shouldRun(false, true, true))
        assertFalse("no firebase values in the build", FcmPolicy.shouldRun(true, false, true))
        assertFalse("de-Googled phone must never touch Firebase", FcmPolicy.shouldRun(true, true, false))
    }

    @Test
    fun aBuildIsConfiguredOnlyWithEveryFirebaseValue() {
        assertTrue(FcmPolicy.configured("p", "a", "k", "s"))
        assertFalse(FcmPolicy.configured("", "a", "k", "s"))
        assertFalse(FcmPolicy.configured("p", " ", "k", "s"))
        assertFalse(FcmPolicy.configured("p", "a", "k", ""))
    }

    @Test
    fun onlyTheWakeFlagTriggersAPull() {
        assertTrue(FcmPolicy.isWake(mapOf("w" to "1")))
        assertFalse(FcmPolicy.isWake(emptyMap()))
        assertFalse(FcmPolicy.isWake(mapOf("w" to "0", "body" to "hi")))
        assertTrue(FcmPolicy.isCall(mapOf("w" to "1", "c" to "1")))
        assertFalse(FcmPolicy.isCall(mapOf("w" to "1")))
    }
}
