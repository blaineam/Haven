package com.blaineam.haven.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The honest-progress decisions (SyncProgress.kt) — Apple SyncProgressTests parity. Field report:
 * the sync pill and media spinners "never progress at all and just disappear after a bit".
 */
class SyncProgressTest {
    private val c = "circle-a"

    private fun derive(p: UploadProgress, relay: Boolean = true, hosts: Boolean = false,
                       nearby: Boolean = false, online: Boolean = true) =
        SyncBadgeState.derive(p, c, hostsRelay = hosts, hasRelay = relay, nearbyConnected = nearby, online = online)

    @Test fun nothing_pending_is_synced() {
        assertEquals(SyncBadgeState.Synced, derive(UploadProgress()))
    }

    @Test fun pending_uploads_show_sent_of_total_for_the_burst() {
        val p = UploadProgress(pendingByCircle = mapOf(c to 3), sessionTotalByCircle = mapOf(c to 5),
            sessionDoneByCircle = mapOf(c to 2))
        assertEquals(SyncBadgeState.Sending(2, 5), derive(p))
    }

    @Test fun total_never_reads_below_what_is_pending() {
        val p = UploadProgress(pendingByCircle = mapOf(c to 4), sessionTotalByCircle = mapOf(c to 1))
        assertEquals(SyncBadgeState.Sending(0, 4), derive(p))
    }

    @Test fun every_pending_item_in_backoff_is_retrying_with_the_count() {
        val p = UploadProgress(pendingByCircle = mapOf(c to 2), retryingByCircle = mapOf(c to 2),
            sessionTotalByCircle = mapOf(c to 2))
        assertEquals(SyncBadgeState.Retrying(2), derive(p))
        // one still actively trying → still sending
        val q = p.copy(retryingByCircle = mapOf(c to 1))
        assertEquals(SyncBadgeState.Sending(0, 2), derive(q))
    }

    @Test fun another_circles_uploads_do_not_move_this_pill() {
        val p = UploadProgress(pendingByCircle = mapOf("other" to 3), sessionTotalByCircle = mapOf("other" to 3))
        assertEquals(SyncBadgeState.Synced, derive(p))
    }

    @Test fun offline_with_pending_is_local() {
        val p = UploadProgress(pendingByCircle = mapOf(c to 1), sessionTotalByCircle = mapOf(c to 1))
        assertEquals(SyncBadgeState.Local, derive(p, online = false))
        assertEquals(SyncBadgeState.Sending(0, 1), derive(p, online = false, nearby = true))
    }

    @Test fun no_relay_ignores_the_queue_and_hosting_is_synced() {
        val p = UploadProgress(pendingByCircle = mapOf(c to 1))
        assertEquals(SyncBadgeState.Synced, derive(p, relay = false))
        assertEquals(SyncBadgeState.Local, derive(p, relay = false, online = false))
        assertEquals(SyncBadgeState.Synced, derive(p, hosts = true, online = false))
    }

    @Test fun watchdog_stalls_only_after_the_no_progress_window() {
        val w = TransferStallWatch(3, 1_000)
        assertFalse(w.observe(3, 1_000 + 44_999))
        assertTrue(w.observe(3, 1_000 + 45_000))
    }

    @Test fun new_bytes_and_busy_restores_reset_the_clock() {
        val w = TransferStallWatch(0, 0)
        assertFalse(w.observe(1, 40_000))
        assertFalse(w.observe(1, 80_000, busy = true))
        assertFalse(w.observe(1, 120_000))
        assertTrue(w.observe(1, 125_000))
    }

    @Test fun a_shrinking_mark_is_not_progress() {
        val w = TransferStallWatch(10, 0)
        assertFalse(w.observe(2, 10_000))
        assertTrue(w.observe(2, 45_000))
    }

    @Test fun wanted_set_is_stable_across_partial_scans_and_never_double_counts() {
        val s = MediaWantedSet()
        s.discover(listOf("a", "b"))
        s.discover(listOf("a", "c"))
        assertEquals(3, s.count)
        assertTrue(s.arrived("b"))
        assertFalse(s.arrived("b"))
        s.gaveUp("c")
        assertEquals(setOf("a"), s.snapshot())
        s.discover(listOf("x", "y"))
        s.prune { it == "x" }
        assertEquals(setOf("a", "y"), s.snapshot())
    }

    @Test fun wanted_set_is_bounded() {
        val s = MediaWantedSet()
        s.discover((0 until MediaWantedSet.CAP + 50).map { "r$it" })
        assertEquals(MediaWantedSet.CAP, s.count)
    }
}
