package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pure rules behind Haven's Android Auto Calls screen ([CarCalls]) — see docs/ANDROID-CALLS.md. */
class CarCallsTest {
    private fun p(name: String, last: Long = 0, hex: String = name.lowercase().replace(" ", "") + "0".repeat(8)) =
        CarCalls.Person("dm:$hex", hex, name, last)

    private val people = listOf(
        p("Tracy Miller", 300), p("Troy", 100), p("Blaine", 900), p("Zoe", 0), p("Álvaro", 500), p("Trey", 0),
    )

    // ------------------------------------------------------------------ recents

    @Test fun `recents are newest conversation first and skip people with no activity`() {
        assertEquals(listOf("Blaine", "Álvaro", "Tracy Miller", "Troy"), CarCalls.recents(people, 10).map { it.name })
    }

    @Test fun `recents are cut to the host limit`() {
        assertEquals(listOf("Blaine", "Álvaro"), CarCalls.recents(people, 2).map { it.name })
    }

    @Test fun `recents with equal activity fall back to the name so the order is stable`() {
        val tie = listOf(p("Mia", 5), p("Ada", 5), p("Zed", 5))
        assertEquals(listOf("Ada", "Mia", "Zed"), CarCalls.recents(tie, 10).map { it.name })
        assertEquals(CarCalls.recents(tie, 10), CarCalls.recents(tie.reversed(), 10))
    }

    @Test fun `the same account never shows twice`() {
        val dup = listOf(p("Blaine", 9, hex = "AB" + "0".repeat(62)), p("Blaine again", 10, hex = "ab" + "0".repeat(62)))
        assertEquals(1, CarCalls.recents(dup, 10).size)
        assertEquals(1, CarCalls.contacts(dup, 10).size)
    }

    @Test fun `no one is recent when nothing has happened`() {
        assertTrue(CarCalls.recents(listOf(p("Zoe", 0)), 10).isEmpty())
    }

    // ------------------------------------------------------------------ contacts

    @Test fun `contacts are A to Z ignoring case and accents`() {
        assertEquals(listOf("Álvaro", "Blaine", "Tracy Miller", "Trey", "Troy", "Zoe"), CarCalls.contacts(people, 10).map { it.name })
    }

    @Test fun `contacts are cut to the limit and report truncation`() {
        assertEquals(3, CarCalls.contacts(people, 3).size)
        assertTrue(CarCalls.truncated(people, 3))
        assertFalse(CarCalls.truncated(people, 6))
        assertFalse(CarCalls.truncated(people, 50))
    }

    @Test fun `an absurd or non positive limit is clamped, never a crash`() {
        assertEquals(1, CarCalls.contacts(people, 0).size)
        assertEquals(1, CarCalls.contacts(people, -5).size)
        assertEquals(6, CarCalls.contacts(people, 10_000).size)
    }

    @Test fun `a blank name still gets a row`() {
        assertEquals("Friend", CarCalls.contacts(listOf(p("  ")), 5).single().name)
    }

    @Test fun `a row carries the circle and the account the call dials`() {
        val e = CarCalls.contacts(listOf(p("Blaine", hex = "ab".repeat(32))), 5).single()
        assertEquals("ab".repeat(32), e.hex)
        assertEquals("dm:" + "ab".repeat(32), e.circleId)
    }

    // ------------------------------------------------------------------ search

    @Test fun `a blank search is the A to Z list`() {
        assertEquals(CarCalls.contacts(people, 10), CarCalls.search(people, "  ", 10))
    }

    @Test fun `searching Tracy finds Tracy and never offers Troy or Trey`() {
        assertEquals(listOf("Tracy Miller"), CarCalls.search(people, "Tracy", 10).map { it.name })
    }

    @Test fun `a prefix finds the contact`() {
        assertTrue(CarCalls.search(people, "bla", 10).map { it.name }.contains("Blaine"))
    }

    @Test fun `nothing matching is an empty list`() {
        assertTrue(CarCalls.search(people, "Qwxzy", 10).isEmpty())
    }

    @Test fun `search results respect the limit`() {
        val many = (1..20).map { p("Sam $it", 1) }
        assertTrue(CarCalls.search(many, "Sam", 4).size <= 4)
    }

    // ------------------------------------------------------------------ initials

    @Test fun `initials are the first letters of the first and last word`() {
        assertEquals("TM", CarCalls.initials("Tracy Miller"))
        assertEquals("TM", CarCalls.initials("  tracy   van   miller "))
        assertEquals("B", CarCalls.initials("Blaine"))
        assertEquals("AB", CarCalls.initials("ana beatriz"))
    }

    @Test fun `an empty name has a placeholder`() {
        assertEquals("?", CarCalls.initials("   "))
    }

    // ------------------------------------------------------------------ placing a call

    @Test fun `a live call blocks a second one`() {
        assertEquals(CarCalls.Gate.BUSY, CarCalls.gate(callActive = true, micGranted = true))
        assertEquals(CarCalls.Gate.BUSY, CarCalls.gate(callActive = true, micGranted = false))
    }

    @Test fun `a missing microphone grant is asked for before dialing`() {
        assertEquals(CarCalls.Gate.NEEDS_MIC, CarCalls.gate(callActive = false, micGranted = false))
    }

    @Test fun `otherwise a tap dials`() {
        assertEquals(CarCalls.Gate.DIAL, CarCalls.gate(callActive = false, micGranted = true))
    }

    // ------------------------------------------------------------------ in-call screen phase

    @Test fun `ringing or connecting reads as calling`() {
        assertEquals(CarCalls.Phase.CALLING, CarCalls.phase(true, false, false, true, 1_000))
        assertEquals(CarCalls.Phase.CALLING, CarCalls.phase(false, true, false, true, 1_000))
    }

    @Test fun `an established call reads as on a call`() {
        assertEquals(CarCalls.Phase.ON_CALL, CarCalls.phase(false, false, true, true, 60_000))
    }

    @Test fun `a call that was live and is not any more has ended`() {
        assertEquals(CarCalls.Phase.ENDED, CarCalls.phase(false, false, false, true, 10_000))
    }

    @Test fun `a call not yet started is still calling inside the grace period`() {
        assertEquals(CarCalls.Phase.CALLING, CarCalls.phase(false, false, false, false, CarCalls.CALL_START_GRACE_MS - 1))
    }

    @Test fun `a call that never showed life gives up after the grace period`() {
        assertEquals(CarCalls.Phase.ENDED, CarCalls.phase(false, false, false, false, CarCalls.CALL_START_GRACE_MS))
    }

    @Test fun `the grace period is long enough for a cold start but short enough to not strand the driver`() {
        assertTrue(CarCalls.CALL_START_GRACE_MS in 5_000L..30_000L)
    }
}
