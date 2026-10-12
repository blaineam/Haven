package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.LinkConstraint

/** The "Load history from your relays" driver's guard rails — what it refuses to start on, and how it resets. */
class RelayHistoryResyncStateTest {
    @Before fun setUp() {
        RelayHistoryResync.progress.value = RelayHistoryProgress()
        LowDataMonitor.effective.value = LinkConstraint.NORMAL
        HavenNet::class.java.getDeclaredField("appContext").apply { isAccessible = true }.set(HavenNet, FakeContext())
    }
    @After fun tearDown() { LowDataMonitor.effective.value = LinkConstraint.NORMAL }

    @Test fun without_a_booted_engine_there_is_nothing_to_read_from() {
        assertEquals("norelay", RelayHistoryResync.unavailableReason())
    }

    @Test fun a_satellite_link_refuses_a_history_backfill_before_anything_else() {
        LowDataMonitor.effective.value = LinkConstraint.ULTRA
        assertEquals("satellite", RelayHistoryResync.unavailableReason())
    }

    @Test fun start_does_nothing_while_unavailable() {
        RelayHistoryResync.start()
        assertEquals(RelayHistoryProgress(), RelayHistoryResync.progress.value)
    }

    @Test fun dismiss_clears_a_finished_run_but_never_a_running_one() {
        RelayHistoryResync.progress.value = RelayHistoryProgress(phase = RelayHistoryProgress.Phase.DONE, postsAdded = 4)
        RelayHistoryResync.dismiss()
        assertEquals(RelayHistoryProgress(), RelayHistoryResync.progress.value)
        val running = RelayHistoryProgress(phase = RelayHistoryProgress.Phase.SCANNING, entriesFound = 3)
        RelayHistoryResync.progress.value = running
        RelayHistoryResync.dismiss()
        assertEquals(running, RelayHistoryResync.progress.value)
    }

    @Test fun resetting_the_journal_also_resets_the_progress() {
        RelayHistoryResync.progress.value = RelayHistoryProgress(phase = RelayHistoryProgress.Phase.DONE, postsAdded = 4)
        RelayHistoryResync.resetJournal()
        assertEquals(RelayHistoryProgress(), RelayHistoryResync.progress.value)
    }

    @Test fun the_qa_snapshot_reports_every_counter_the_e2e_reads() {
        RelayHistoryResync.progress.value = RelayHistoryProgress(
            phase = RelayHistoryProgress.Phase.DONE, circlesDone = 2, circlesTotal = 3, entriesFound = 10, entriesChecked = 9,
            postsAdded = 4, unreadable = 1, waiting = 2, mediaDone = 5, mediaTotal = 6, mediaMissing = 1, relayErrors = 1,
            startedAtMs = 100, finishedAtMs = 200)
        val o = RelayHistoryResync.qaSnapshot()
        assertEquals("done", o.getString("state"))
        assertEquals(2, o.getInt("circles_done")); assertEquals(3, o.getInt("circles_total"))
        assertEquals(10, o.getInt("entries_found")); assertEquals(9, o.getInt("entries_checked"))
        assertEquals(4, o.getInt("posts_added")); assertEquals(1, o.getInt("unreadable")); assertEquals(2, o.getInt("waiting"))
        assertEquals(5, o.getInt("media_done")); assertEquals(6, o.getInt("media_total")); assertEquals(1, o.getInt("media_missing"))
        assertEquals(1, o.getInt("relay_errors")); assertEquals(100L, o.getLong("started_ms")); assertEquals(200L, o.getLong("finished_ms"))
        assertEquals("the journal is native; without it the count reads 0", 0L, o.getLong("journal_keys"))
    }
}
