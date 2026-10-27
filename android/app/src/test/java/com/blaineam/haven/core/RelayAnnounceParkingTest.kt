package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayAnnounceParkingTest {
    private fun b(s: String) = s.toByteArray()

    @Test fun anAnnounceParkedBeforeItsKeyIsReturnedOnTheNextDrain() {
        val p = RelayAnnounceParking(minRetryGapMs = 0)
        p.park("default", b("sealed-1"), 1_000)
        val got = p.drain(2_000)
        assertEquals(1, got.size)
        assertEquals("default", got[0].circleId)
        assertTrue(got[0].sealed.contentEquals(b("sealed-1")))
        assertEquals(0, p.size())   // handed over; the caller re-parks it if it is STILL unopenable
    }

    @Test fun theSameAnnounceIsKeptOnce() {
        val p = RelayAnnounceParking(minRetryGapMs = 0)
        repeat(5) { p.park("default", b("same"), it.toLong()) }
        assertEquals(1, p.size())
    }

    @Test fun differentCirclesAreDistinct() {
        val p = RelayAnnounceParking(minRetryGapMs = 0)
        p.park("a", b("x"), 1); p.park("b", b("x"), 1)
        assertEquals(2, p.size())
    }

    @Test fun theQueueIsBoundedAndKeepsTheNewest() {
        val p = RelayAnnounceParking(capacity = 3, minRetryGapMs = 0)
        for (i in 1..6) p.park("c", b("s$i"), i.toLong())
        assertEquals(3, p.size())
        val kept = p.drain(10).map { String(it.sealed) }.toSet()
        assertEquals(setOf("s4", "s5", "s6"), kept)
    }

    @Test fun expiredAnnouncesAreDropped() {
        val p = RelayAnnounceParking(ttlMs = 1_000, minRetryGapMs = 0)
        p.park("c", b("old"), 0)
        p.park("c", b("new"), 5_000)
        val got = p.drain(5_500)
        assertEquals(listOf("new"), got.map { String(it.sealed) })
    }

    @Test fun drainsAreRateLimitedSoABurstOfFramesDoesNotSpin() {
        val p = RelayAnnounceParking(minRetryGapMs = 5_000)
        p.park("c", b("one"), 0)
        assertEquals(1, p.drain(10_000).size)
        p.park("c", b("two"), 10_001)
        assertTrue(p.drain(12_000).isEmpty())          // too soon after the last drain
        assertEquals(1, p.drain(15_000).size)          // gap elapsed
    }

    @Test fun anUnopenableOneParkedAgainKeepsGettingRetried() {
        val p = RelayAnnounceParking(minRetryGapMs = 0)
        p.park("c", b("later"), 0)
        val first = p.drain(1).single()
        p.park(first.circleId, first.sealed, 1)          // the key has not landed yet
        assertEquals(1, p.drain(2).size)                 // still there for the next attempt
    }
}
