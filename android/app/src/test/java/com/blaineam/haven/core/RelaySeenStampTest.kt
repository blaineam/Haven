package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The relay "last seen" stamp must not re-save the relay table on every relay op. */
class RelaySeenStampTest {
    @Test fun a_burst_of_successful_ops_restamps_at_most_once_a_minute() {
        val t0 = 1_790_000_000_000L
        var stored = t0
        var saves = 0
        // A call's worth of relay ops: one every 100 ms for ten minutes.
        for (i in 1..6_000) {
            val now = t0 + i * 100L
            if (RelaySeenStamp.shouldRestamp(stored, now)) { stored = now; saves++ }
        }
        assertEquals(10, saves)
    }

    @Test fun restamps_once_the_interval_has_passed() {
        assertFalse(RelaySeenStamp.shouldRestamp(1_000L, 1_000L))
        assertFalse(RelaySeenStamp.shouldRestamp(1_000L, 1_000L + RelaySeenStamp.MIN_INTERVAL_MS - 1))
        assertTrue(RelaySeenStamp.shouldRestamp(1_000L, 1_000L + RelaySeenStamp.MIN_INTERVAL_MS))
    }

    @Test fun a_stamp_from_the_future_is_corrected_not_frozen() {
        assertTrue(RelaySeenStamp.shouldRestamp(10_000_000L, 5_000L))
    }
}
