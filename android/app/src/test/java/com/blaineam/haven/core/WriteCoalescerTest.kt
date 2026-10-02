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

    @Test fun aStructuralWriteDisarmsThePendingDeferredOne() {
        val c = WriteCoalescer(60_000)
        c.wrote(0)
        assertEquals(50_000L, c.request(10_000)); val gen = c.armedGeneration()
        c.wrote(20_000)   // structural save carried the stamp
        assertTrue("orphaned deferred write must skip", !c.takeDeferred(gen))
    }

    @Test fun orphanChainsNeverMultiplyTheRate() {
        // Three relays stamping on their own minute phases + a burst of structural writes at the
        // start (the gate-8 verify shape). Deferred tasks run at their due time and honour takeDeferred.
        val c = WriteCoalescer(60_000)
        data class Pending(val at: Long, val gen: Long)
        val pending = mutableListOf<Pending>()
        var writes = 0
        for (t in listOf(0L, 5L, 10L)) { c.wrote(t); writes++ }   // startup structural burst
        var t = 0L
        while (t < 3_600_000L) {
            pending.filter { it.at <= t }.forEach { p -> pending.remove(p); if (c.takeDeferred(p.gen)) { c.wrote(t); writes++ } }
            if (t % 60_000 in setOf(2_000L, 24_000L, 42_000L)) {
                when (val d = c.request(t)) {
                    0L -> { c.wrote(t); writes++ }
                    WriteCoalescer.ALREADY_ARMED -> Unit
                    else -> pending += Pending(t + d, c.armedGeneration())
                }
                if (t % 600_000 == 24_000L) { c.wrote(t); writes++ }   // an occasional structural save
            }
            t += 1_000
        }
        assertTrue("$writes writes in an hour", writes <= 3 + 60 + 6 + 2)
    }
}
