package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WriteCoalescerTest {
    @Test fun theFirstWriteGoesStraightThrough() {
        assertEquals(0L, WriteCoalescer(60_000).request(1_000))
    }

    @Test fun aBurstInsideTheWindowArmsExactlyOneDeferredWrite() {
        val c = WriteCoalescer(60_000)
        assertEquals(0L, c.request(0)); c.wrote(0)
        // Three relays restamping inside the same minute: one deferred write, due at the window end.
        assertEquals(50_000L, c.request(10_000))
        assertEquals(WriteCoalescer.ALREADY_ARMED, c.request(20_000))
        assertEquals(WriteCoalescer.ALREADY_ARMED, c.request(59_999))
        c.wrote(60_000)   // the deferred write ran
        assertEquals(60_000L, c.request(60_000))
    }

    @Test fun writesPerMinuteStayAtOneUnderAContinuousStorm() {
        // Every relay op restamps (the pre-RelaySeenStamp shape): one request every 2 s for an hour.
        val c = WriteCoalescer(60_000)
        var writes = 0
        var dueAt: Long? = null
        var t = 0L
        while (t < 3_600_000L) {
            if (dueAt != null && t >= dueAt) { c.wrote(t); writes++; dueAt = null }
            when (val d = c.request(t)) {
                0L -> { c.wrote(t); writes++ }
                WriteCoalescer.ALREADY_ARMED -> Unit
                else -> dueAt = t + d
            }
            t += 2_000
        }
        assertTrue("$writes writes in an hour", writes in 59..61)
    }

    @Test fun aStructuralSaveResetsTheWindow() {
        val c = WriteCoalescer(60_000)
        c.wrote(0)
        assertEquals(30_000L, c.request(30_000))
        c.wrote(40_000)   // e.g. a relay added: the table save carried the stamp
        assertEquals(60_000L, c.request(40_000))
    }

    @Test fun aBackwardsClockNeverFreezesPersistence() {
        val c = WriteCoalescer(60_000)
        c.wrote(1_000_000)
        assertEquals(0L, c.request(5_000))
    }
}
