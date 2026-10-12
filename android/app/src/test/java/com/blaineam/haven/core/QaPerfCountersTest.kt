package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The `perf` object of the QA dump: persist-export ring, inbound-change ring, reset, schema. */
class QaPerfCountersTest {
    @Before @After fun clean() { QaPerf.reset() }

    @Test fun persist_exports_are_counted_and_the_last_ones_kept_in_order() {
        QaPerf.notePersistExport(startedAtMs = 111, reason = "hello")
        QaPerf.notePersistExport(startedAtMs = 222)
        val s = QaPerf.snapshot()
        assertEquals(2, s.getInt("persistExportCount"))
        assertTrue(s.getLong("lastPersistExportAtMs") > 0)
        val recent = s.getJSONArray("recentExports")
        assertEquals("111 hello", recent.getString(0))
        assertEquals("222 persist", recent.getString(1))
    }

    @Test fun rings_cap_at_forty_dropping_the_oldest() {
        repeat(45) { QaPerf.notePersistExport(startedAtMs = it.toLong(), reason = "r") }
        val recent = QaPerf.snapshot().getJSONArray("recentExports")
        assertEquals(40, recent.length())
        assertEquals("5 r", recent.getString(0))
        assertEquals("44 r", recent.getString(39))
        assertEquals("the count is not capped", 45, QaPerf.snapshot().getInt("persistExportCount"))
    }

    @Test fun inbound_changes_record_their_source() {
        QaPerf.noteInboundChange("hello"); QaPerf.noteInboundChange("event")
        val changed = QaPerf.snapshot().getJSONArray("recentChanged")
        assertEquals(2, changed.length())
        assertTrue(changed.getString(0).endsWith(" hello"))
        assertTrue(changed.getString(1).endsWith(" event"))
    }

    @Test fun reset_clears_everything() {
        QaPerf.notePersistExport(); QaPerf.noteInboundChange("x")
        QaPerf.reset()
        val s = QaPerf.snapshot()
        assertEquals(0, s.getInt("persistExportCount"))
        assertEquals(0, s.getJSONArray("recentExports").length())
        assertEquals(0, s.getJSONArray("recentChanged").length())
        assertEquals(0, s.getInt("cpuSampleTicks"))
    }

    @Test fun the_apple_only_keys_stay_in_the_schema_as_zeros() {
        val s = QaPerf.snapshot()
        for (k in listOf("engineUserWaitP95Ms", "engineUserWaitMaxMs", "refreshCount", "mediaStoreOnMainCount",
            "heldRefSetSize", "mainStallCount", "mainStallMaxMs")) assertEquals(k, 0.0, s.getDouble(k), 0.0)
    }

    @Test fun runtime_threads_are_never_sampled_but_app_threads_are() {
        for (t in listOf("main", "Signal Catcher", "HeapTaskDaemon", "Jit thread pool")) assertFalse(t, QaPerf.sampleable(t))
        assertTrue(QaPerf.sampleable("haven-author"))
    }
}
