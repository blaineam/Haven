package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InboundNotifyPolicyTest {
    private val dm = "dm:" + "a".repeat(64) + "-" + "b".repeat(64)
    private val now = 1_000_000_000L

    @Test fun circlePostsKeepTheTenMinuteWindow() {
        assertEquals(600_000L, InboundNotifyPolicy.maxAgeMs("default"))
        assertFalse(InboundNotifyPolicy.isStale("default", now - 599_000, now))
        assertTrue(InboundNotifyPolicy.isStale("default", now - 601_000, now))
    }

    @Test fun aLateDirectMessageStillNotifies() {
        // 2 h old on arrival (fresh install catching up): the old 10-minute rule dropped it, so it
        // never reached the notification shade or Android Auto.
        assertFalse(InboundNotifyPolicy.isStale(dm, now - 2 * 60 * 60 * 1000, now))
        assertFalse(InboundNotifyPolicy.isStale(dm, now - 23 * 60 * 60 * 1000, now))
    }

    @Test fun aDayOldDirectMessageIsHistoryNotABanner() {
        assertTrue(InboundNotifyPolicy.isStale(dm, now - 25 * 60 * 60 * 1000, now))
    }

    @Test fun groupDmsAreTreatedAsDms() {
        assertEquals(InboundNotifyPolicy.DM_MAX_AGE_MS, InboundNotifyPolicy.maxAgeMs("dm:x-y-z"))
    }
}
