package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** A roster repeat must not fan out / push again; other envelopes are never "repeats". */
class RosterEchoTest {
    private val roster = byteArrayOf(0x04) + ByteArray(64) { 7 }

    @Before fun reset() = RosterEcho.clear()

    @Test fun second_identical_roster_is_a_repeat() {
        assertFalse(RosterEcho.isRepeatRoster(roster))
        assertTrue(RosterEcho.isRepeatRoster(roster))
        assertFalse(RosterEcho.isRepeatRoster(roster.copyOf().also { it[3] = 1 }))
    }

    @Test fun non_roster_envelopes_always_fan_out() {
        val post = byteArrayOf(0x02, 1, 2, 3)
        assertFalse(RosterEcho.isRepeatRoster(post))
        assertFalse(RosterEcho.isRepeatRoster(post))
    }

    @Test fun bounded() {
        val first = byteArrayOf(0x04, 0, 0, 0)
        assertFalse(RosterEcho.isRepeatRoster(first))
        for (i in 0 until RosterEcho.CAP) RosterEcho.isRepeatRoster(byteArrayOf(0x04, 1, (i and 0xff).toByte(), (i shr 8).toByte()))
        assertFalse(RosterEcho.isRepeatRoster(first))
    }
}
