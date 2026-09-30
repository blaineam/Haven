package com.blaineam.haven.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The feed reader under a version storm (launch backlog: a bump every 50 ms, a read that takes
 * 400 ms). The old restart-per-key reader published NOTHING until the storm ended and ran every
 * abandoned read to completion anyway; this one must publish while the storm is still going, never
 * run two reads at once, and finish on the newest key.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ConflatedReadsTest {

    @Test
    fun publishesDuringAStormWithOneReadAtATime() = runTest {
        val keys = MutableStateFlow(0)
        var inFlight = 0
        var maxInFlight = 0
        var reads = 0
        val published = ArrayList<Pair<Int, Long>>()   // (key, virtual time)
        val job = launch {
            conflatedReads(keys, read = { k ->
                inFlight++; maxInFlight = maxOf(maxInFlight, inFlight); reads++
                delay(400)
                inFlight--
                "feed@$k"
            }, publish = { k, r -> assertEquals("feed@$k", r); published += k to testScheduler.currentTime })
        }
        for (i in 1..100) { delay(50); keys.value = i }   // 5 s of bumps
        advanceUntilIdle()
        job.cancel()

        assertEquals("never two feed decodes at once", 1, maxInFlight)
        assertTrue("first read published mid-storm, not after it: $published", published.first().second <= 450)
        assertEquals("ends on the newest key", 100, published.last().first)
        assertTrue("bumps collapse — far fewer reads than bumps ($reads)", reads <= 15)
    }

    @Test
    fun anUnchangedKeyDoesNotReRead() = runTest {
        val keys = MutableStateFlow("a")
        var reads = 0
        val job = launch { conflatedReads(keys, read = { reads++; it }, publish = { _, _ -> }) }
        advanceUntilIdle()
        keys.value = "a"
        advanceUntilIdle()
        keys.value = "b"
        advanceUntilIdle()
        job.cancel()
        assertEquals(2, reads)
    }
}
