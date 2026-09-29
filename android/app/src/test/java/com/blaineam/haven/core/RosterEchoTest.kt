package com.blaineam.haven.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Apple RosterEchoTests parity: an identical roster re-delivery is "nothing new". */
class RosterEchoTest {
    private val roster = byteArrayOf(0x04) + ByteArray(64) { 7 }

    @Before fun reset() = RosterEcho.clear()

    @Test fun first_copy_is_new_repeats_are_not() {
        assertFalse(RosterEcho.isRepeat(roster))
        assertTrue(RosterEcho.isRepeat(roster))
        val resigned = roster.copyOf().also { it[5] = 9 }
        assertFalse("a re-signed roster is new bytes", RosterEcho.isRepeat(resigned))
    }

    @Test fun forget_lets_a_refused_copy_be_retried() {
        assertFalse(RosterEcho.isRepeat(roster))
        RosterEcho.forget(roster)
        assertFalse(RosterEcho.isRepeat(roster))
    }

    @Test fun bounded_oldest_forgotten_first() {
        val first = byteArrayOf(0x04, 0, 0, 0)
        assertFalse(RosterEcho.isRepeat(first))
        for (i in 0 until RosterEcho.CAP) assertFalse(RosterEcho.isRepeat(byteArrayOf(0x04, 1, (i and 0xff).toByte(), (i shr 8).toByte())))
        assertFalse(RosterEcho.isRepeat(first))
    }
}
