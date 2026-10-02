package com.blaineam.haven.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The iroh fallback of a media fetch must never hold the serialized media lane indefinitely. */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayDialBoundTest {
    @Test fun a_wedged_dial_gives_up_at_the_bound() = runTest {
        val got: ByteArray? = RelayDialBound.bounded { awaitCancellation() }
        assertNull(got)
        assertEquals(RelayDialBound.MEDIA_HEAD_TIMEOUT_MS, currentTime)
    }

    @Test fun a_prompt_answer_passes_through() = runTest {
        val got = RelayDialBound.bounded { byteArrayOf(1, 2, 3) }
        assertTrue(got!!.contentEquals(byteArrayOf(1, 2, 3)))
    }

    @Test fun a_failure_is_a_miss_not_a_crash() = runTest {
        val got: ByteArray? = RelayDialBound.bounded { throw IllegalStateException("dial failed") }
        assertNull(got)
    }

    @Test fun the_bound_is_well_under_the_lane_stall_that_was_observed() {
        assertTrue(RelayDialBound.MEDIA_HEAD_TIMEOUT_MS <= 30_000L)
    }
}
