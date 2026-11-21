package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A linking device keeps asking while its ticket is alive, and stops when it is not. */
class LinkRequestRetryTest {
    @Test fun a_fresh_ticket_is_asked_about_for_its_whole_life_and_no_longer() {
        val waits = LinkRequestRetry.waitsMs(issuedAtSecs = 1_000, nowSecs = 1_000)
        assertEquals(30, waits.size)
        assertTrue(waits.all { it == LinkRequestRetry.EVERY_MS })
        assertTrue(waits.sum() <= LinkRequestRetry.TICKET_TTL_SECS * 1000)
    }

    @Test fun a_ticket_scanned_late_is_asked_about_only_for_what_is_left() {
        assertEquals(3, LinkRequestRetry.waitsMs(issuedAtSecs = 1_000, nowSecs = 1_000 + 600 - 70).size)
        assertEquals(0, LinkRequestRetry.waitsMs(issuedAtSecs = 1_000, nowSecs = 1_000 + 600 - 10).size)
    }

    @Test fun a_dead_ticket_is_not_asked_about_at_all() {
        assertTrue(LinkRequestRetry.waitsMs(issuedAtSecs = 1_000, nowSecs = 1_600).isEmpty())
        assertTrue(LinkRequestRetry.waitsMs(issuedAtSecs = 1_000, nowSecs = 9_999).isEmpty())
    }
}
