package com.blaineam.haven.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import com.blaineam.haven.core.HistoryHandoffWire as HW

/** Android as the SOURCE of the history hand-off (D26), over an in-memory account lane. */
class HistoryHandoffTest {
    @get:Rule val tmp = TemporaryFolder()

    private val job = Job()
    private val scope = CoroutineScope(job + Dispatchers.Default)
    private var clock = 1_764_000_000_000L
    private var shown = HistoryHandoff.Status()
    private val host by lazy {
        FakeHandoffHost(tmp.newFolder("sealed")).apply {
            history["fam"] = listOf(
                30L to listOf("img_a", "thumb:img_a:img_t"), 20L to emptyList(), 10L to listOf("img_gone"))
            history["dm"] = listOf(25L to emptyList())
            local["img_a"] = ByteArray(10) { 7 }
            local["img_t"] = ByteArray(3) { 8 }
        }
    }
    private val dir by lazy { tmp.newFolder("state") }

    private fun sender() = HistoryHandoff(host, dir, scope, { clock }, { shown = it })
    private fun HistoryHandoff.pass() = runBlocking { tick(60_000) }
    private fun settle() = runBlocking { job.children.toList().joinAll() }

    @After fun tearDown() { job.cancel() }

    @Test fun a_request_is_answered_newest_first_one_circle_at_a_time() {
        val h = sender()
        host.ask(at = 100)
        assertTrue(h.pass())
        val m = host.manifest()!!
        assertTrue(m.complete)
        assertEquals(100L, m.forRequest)
        assertEquals(3, m.pages)
        assertEquals(4L, m.totalEvents)
        assertEquals(4L, m.servedEvents)
        // fam's newest two, then dm, then fam's older one.
        assertEquals(listOf("fam", "dm", "fam"), (0 until 3).map { host.page(m.run, it)!!.circleId })
        val first = host.page(m.run, 0)!!
        assertEquals(2, first.envelopes.size)
        assertEquals(listOf(HW.MediaItem("img_a", 10), HW.MediaItem("img_t", 3)), first.media)
        assertEquals("media this phone does not hold is not named", emptyList<HW.MediaItem>(), host.page(m.run, 2)!!.media)
        assertEquals(listOf(host.browser), h.handoffTargets)
        assertEquals(HistoryHandoff.Phase.SENDING, shown.phase)
        assertEquals(4L, shown.done)
        assertEquals("a browser takes its photos from the relay", 0, shown.mediaTotal)
        // Nothing more to say two minutes on; the run stays until the other device is done.
        clock += HW.SENDING_LINGER_MS
        h.refresh()
        assertEquals(HistoryHandoff.Phase.IDLE, shown.phase)
        assertFalse(h.pass())
        host.ask(at = 100, done = true)
        h.pass()
        assertTrue(h.handoffTargets.isEmpty())
    }

    @Test fun only_a_device_holding_the_account_key_serves() {
        host.seed = false
        host.ask(at = 100)
        host.askKeys(at = 100)
        host.refs = listOf("fam" to "img_a")
        assertFalse(sender().pass())
        assertTrue(host.puts.isEmpty())
        assertTrue(host.lookups.isEmpty())
    }

    @Test fun a_hot_phone_or_a_dead_engine_waits() {
        host.ask(at = 100)
        host.hot = true
        assertFalse(sender().pass())
        host.hot = false
        host.engineUp = false
        assertFalse(sender().pass())
        assertTrue(host.puts.isEmpty())
    }

    @Test fun a_device_the_signed_roster_does_not_list_is_never_served() {
        host.devices = mutableListOf(host.me)
        host.ask(at = 100)
        assertFalse(sender().pass())
        assertTrue(host.puts.isEmpty())
        // Its account-signed roster arrives with the request and is taken in first.
        host.ask(at = 101, roster = java.util.Base64.getEncoder().encodeToString(byteArrayOf(9, 9)))
        assertTrue(sender().pass())
        assertArrayEquals(byteArrayOf(9, 9), host.ingested.single())
    }

    @Test fun another_source_already_answering_is_left_to_it() {
        host.ask(at = 100)
        val other = "e3".repeat(32)
        host.lane[HW.manifestKey(host.account, host.browser, other)] =
            HW.Manifest("1", other, 100, 1, false, clock - 1_000).encode()
        assertFalse(sender().pass())
        assertNull(host.manifest())
        clock += HW.STALE_SOURCE_MS
        assertTrue("it went quiet", sender().pass())
    }

    @Test fun an_unreachable_relay_keeps_the_cursor_and_a_relaunch_resumes() {
        host.ask(at = 100)
        var taken = 0
        // The first page and its manifest land, then the relay goes away.
        host.onPut = { if (++taken == 2) host.offline = true }
        sender().pass()
        host.onPut = null
        val run = host.manifest()!!.run
        assertNull(host.page(run, 1))
        host.offline = false
        clock += 1_000
        val again = sender()   // a new process reads the persisted run
        assertTrue(again.pass())
        val m = host.manifest()!!
        assertEquals(run, m.run)
        assertTrue(m.complete)
        assertEquals(3, m.pages)
        assertEquals("page 0 was not sent twice", 1, host.puts.count { it == HW.pageKey(host.account, host.browser, host.me, run, 0) })
    }

    @Test fun a_phone_that_asks_for_a_pages_media_gets_it_through_the_relay() {
        val h = sender()
        host.ask(at = 100)
        h.pass()
        val run = host.manifest()!!.run
        host.lane[HW.needPrefix(host.account, host.browser, host.me, run) + "0"] = "1".toByteArray()
        // A withdrawn need (empty body) uploads nothing.
        host.lane[HW.needPrefix(host.account, host.browser, host.me, run) + "2"] = ByteArray(0)
        clock += 1_000
        assertTrue(h.pass())
        val chunk = host.lane[HW.mediaChunkKey(host.account, host.browser, host.me, run, "img_a", 0)]!!
        assertArrayEquals("fam:".toByteArray() + ByteArray(10) { 7 }, chunk)
        val ready = org.json.JSONObject(String(host.lane[HW.mediaReadyKey(host.account, host.browser, host.me, run, 0)]!!))
        assertTrue(ready.getBoolean("complete"))
        assertEquals(2, ready.getJSONArray("items").length())
        assertNull(host.lane[HW.mediaReadyKey(host.account, host.browser, host.me, run, 2)])
        assertEquals(2, shown.mediaDone)
        assertEquals(2, shown.mediaTotal)
        // A direct serve during the hand-off counts toward the same bar; one outside it does not.
        h.noteSending("img_a")
        assertEquals(2, shown.mediaDone)
        // Cancelling blanks what was parked on the relay.
        h.cancelTransfer()
        settle()
        assertEquals(0, host.lane[HW.mediaChunkKey(host.account, host.browser, host.me, run, "img_a", 0)]!!.size)
    }

    @Test fun kept_stories_media_goes_as_one_extra_page() {
        host.kept = listOf("img_t")
        host.ask(at = 100)
        sender().pass()
        val m = host.manifest()!!
        assertEquals(4, m.pages)
        val extra = host.page(m.run, 3)!!
        assertEquals("default", extra.circleId)
        assertTrue(extra.envelopes.isEmpty())
        assertEquals(listOf(HW.MediaItem("img_t", 3)), extra.media)
    }

    @Test fun cancel_here_stops_tells_the_other_device_and_never_resumes() {
        host.pageSize = 1
        host.ask(at = 100)
        var h: HistoryHandoff? = null
        // The relay goes away right after the first page: the run is unfinished.
        host.onPut = { if (it.contains("/history-m/")) host.offline = true }
        h = sender()
        h.pass()
        host.onPut = null
        assertEquals(HistoryHandoff.Phase.SENDING, shown.phase)
        h.cancelTransfer()   // still offline: the stop waits
        settle()
        assertEquals(HistoryHandoff.Phase.CANCELLED, shown.phase)
        assertFalse(shown.cancelledRemotely)
        assertEquals(0, host.nudges)
        host.offline = false
        val before = host.puts.size
        assertFalse(sender().pass())   // a relaunch publishes the stop and serves nothing
        assertEquals(true, host.manifest()!!.cancelled)
        assertEquals(before + 1, host.puts.size)
        assertEquals(1, host.nudges)
        assertFalse(sender().pass())
        // A fresh ask starts over, and the banner goes.
        host.ask(at = 200)
        val fresh = sender()
        assertTrue(fresh.pass())
        assertEquals(200L, host.manifest()!!.forRequest)
        assertEquals(HistoryHandoff.Phase.SENDING, shown.phase)
    }

    @Test fun cancel_on_the_other_device_stops_this_one_and_can_be_dismissed() {
        val h = sender()
        host.ask(at = 100)
        h.pass()
        host.ask(at = 100, cancelled = true)
        h.pass()
        assertTrue(h.handoffTargets.isEmpty())
        assertEquals(HistoryHandoff.Phase.CANCELLED, shown.phase)
        assertTrue(shown.cancelledRemotely)
        h.dismiss()
        assertEquals(HistoryHandoff.Phase.IDLE, shown.phase)
    }

    @Test fun cancel_while_a_page_is_going_up_leaves_no_run_behind() {
        host.pageSize = 1
        host.ask(at = 100)
        val h = sender()
        host.onPut = { if (it.endsWith("/0") && it.contains("/history/")) h.cancelTransfer() }
        h.pass()
        host.onPut = null
        settle()
        assertTrue(h.handoffTargets.isEmpty())
        assertEquals("the stop is the last word", true, host.manifest()!!.cancelled)
        assertFalse(h.pass())
    }

    @Test fun an_abandoned_run_and_another_accounts_run_are_dropped() {
        val h = sender()
        host.ask(at = 100)
        h.pass()
        host.lane.clear()
        clock += HW.ABANDONED_MS + 1
        h.pass()
        assertTrue(h.handoffTargets.isEmpty())
        host.ask(at = 100)
        h.pass()
        h.reset()
        assertTrue(h.handoffTargets.isEmpty())
        assertEquals(HistoryHandoff.Phase.IDLE, shown.phase)
        assertTrue(sender().handoffTargets.isEmpty())
    }

    @Test fun the_drive_loop_runs_a_pass_and_both_senders_share_the_banner() {
        host.refs = (0 until 3).map { "fam" to "img_$it" }
        host.askKeys(at = 100)
        val h = sender()
        h.poke()
        runBlocking {
            kotlinx.coroutines.withTimeout(10_000) {
                while (host.keysManifest()?.complete != true) kotlinx.coroutines.delay(10)
            }
        }
        // Keys only: the bar counts photos and videos.
        assertEquals(HistoryHandoff.Phase.SENDING, h.status().phase)
        assertEquals(0L, h.status().total)
    }
}
