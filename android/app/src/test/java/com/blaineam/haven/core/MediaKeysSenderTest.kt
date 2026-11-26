package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import com.blaineam.haven.core.HistoryHandoffWire as HW

/** Android as the sender of per-item media keys (D27). */
class MediaKeysSenderTest {
    @get:Rule val tmp = TemporaryFolder()

    private var clock = 1_764_000_000_000L
    private val host by lazy {
        FakeHandoffHost(tmp.newFolder("sealed")).apply {
            history["default"] = emptyList()
            refs = (0 until 90).map { "default" to "img_%03d".format(it) }
        }
    }
    private val file by lazy { File(tmp.newFolder("keys"), "media-keys.json") }
    private fun sender() = MediaKeysSender(host, file, { clock })
    private fun MediaKeysSender.pass() = runBlocking { serve(clock + 60_000) }
    private fun batch(run: String, n: Int) =
        host.lane[HW.keysBatchKey(host.account, host.browser, host.me, run, n)]?.let { String(it) }

    @Test fun every_blob_goes_out_in_batches_newest_first() {
        host.kept = listOf("img_kept", "img_000")
        host.lookup = { if (it == "img_050") ItemKeyResult.Missing else ItemKeyResult.Found(it.toByteArray()) }
        host.askKeys(at = 100)
        val s = sender()
        assertTrue(s.pass())
        val m = host.keysManifest()!!
        assertTrue(m.complete)
        assertEquals(100L, m.forRequest)
        assertEquals(91, m.total)   // the kept story's own blob once, the already-named one not again
        assertEquals(91, m.done)
        assertEquals(1, m.missing)
        assertEquals(3, m.batches)
        assertEquals(listOf(40, 39, 11), host.sealedBatches.map { it.second.size })
        assertEquals("img_000", host.sealedBatches[0].second.first())
        assertEquals("img_kept", host.sealedBatches[2].second.last())
        assertTrue(batch(m.run, 0)!!.startsWith("grant:img_000,"))
        assertTrue(host.sealedBatches.all { it.first == host.browser })
        assertFalse(s.hasJobs())
        assertNull(s.progress())
        // A sent job is not sent again, and the browser's "done" forgets it.
        assertFalse(s.pass())
        host.askKeys(at = 100, done = true)
        assertFalse(s.pass())
        assertFalse(file.readText().contains(host.browser + "\",\"requestAt"))
    }

    @Test fun a_blob_nobody_answers_for_is_set_aside_and_the_rest_go() {
        host.lookup = {
            if (it == "img_000") ItemKeyResult.Unreachable else ItemKeyResult.Found(it.toByteArray())
        }
        host.askKeys(at = 100)
        val s = sender()
        s.pass()
        val m = host.keysManifest()!!
        assertFalse(m.complete)
        assertEquals("everything behind the newest blob still went", 89, m.done)
        assertEquals(0, m.missing)
        assertEquals(3, m.batches)
        assertTrue(s.hasJobs())
        assertEquals(89 to 90, s.progress())
        repeat(5) { assertFalse(sender().pass()) }   // across relaunches too
        assertEquals(89, host.keysManifest()!!.done)
        assertEquals("no empty batches", 3, host.keysManifest()!!.batches)
        // The relay is back: the same run sends the one that waited.
        host.lookup = { ItemKeyResult.Found(it.toByteArray()) }
        assertTrue(sender().pass())
        val done = host.keysManifest()!!
        assertEquals(m.run, done.run)
        assertTrue(done.complete)
        assertEquals(0, done.missing)
        assertEquals("grant:img_000", batch(done.run, 3))
    }

    @Test fun a_blob_is_given_up_only_after_days_without_an_answer() {
        host.lookup = {
            if (it == "img_000") ItemKeyResult.Unreachable else ItemKeyResult.Found(it.toByteArray())
        }
        host.askKeys(at = 100)
        sender().pass()
        val run = host.keysManifest()!!.run
        clock += MediaKeysSender.GIVE_UP_AFTER_MS - 1
        assertFalse(sender().pass())
        assertFalse(host.keysManifest()!!.complete)
        clock += 1
        assertTrue(sender().pass())
        val m = host.keysManifest()!!
        assertEquals("the same run: a job still asked for is never started over", run, m.run)
        assertTrue(m.complete)
        assertEquals(1, m.missing)
        assertEquals(90, m.done)
    }

    @Test fun a_slow_batch_sends_what_it_has() {
        host.refs = (0 until 12).map { "default" to "img_$it" }
        host.lookup = { clock += 30_000; ItemKeyResult.Found(it.toByteArray()) }
        host.askKeys(at = 100)
        val s = sender()
        runBlocking { s.serve(clock + 3_600_000) }
        assertTrue(host.keysManifest()!!.complete)
        assertEquals(listOf(4, 4, 4), host.sealedBatches.map { it.second.size })
    }

    @Test fun retrying_a_held_batch_is_not_progress() {
        // The blob nobody can answer for sits deep in the batch: the groups before it answer each time.
        host.lookup = {
            if (it == "img_030") ItemKeyResult.Unreachable else ItemKeyResult.Found(it.toByteArray())
        }
        host.askKeys(at = 100)
        var progress = 0
        val s = MediaKeysSender(host, file, { clock }) { progress++ }
        s.pass()
        val afterFirst = progress
        repeat(5) { s.pass() }
        assertEquals("a stuck batch must not keep the screen on", afterFirst, progress)
        host.lookup = { ItemKeyResult.Found(it.toByteArray()) }
        s.pass()
        assertTrue(progress > afterFirst)
        assertTrue(host.keysManifest()!!.complete)
    }

    @Test fun a_batch_no_relay_takes_is_kept() {
        host.askKeys(at = 100)
        val s = sender()
        host.offline = true
        s.pass()
        assertEquals("nothing counts as done until a relay has its keys", 0 to 90, s.progress())
        assertTrue(s.hasJobs())
        host.onPut = null
        host.offline = false
        s.pass()
        assertTrue(host.keysManifest()!!.complete)
    }

    @Test fun one_pass_works_through_a_few_batches_only() {
        host.refs = (0 until 450).map { "default" to "img_$it" }
        host.askKeys(at = 100)
        val s = sender()
        s.pass()
        assertEquals(200, host.keysManifest()!!.done)
        s.pass()
        s.pass()
        assertTrue(host.keysManifest()!!.complete)
    }

    @Test fun cancel_stops_this_request_for_good_but_not_a_new_one() {
        host.lookup = { ItemKeyResult.Unreachable }
        host.askKeys(at = 100)
        val s = sender()
        s.pass()
        s.cancel()
        assertFalse(s.hasJobs())
        host.lane.keys.removeAll { it.contains("media-keys-m") }
        host.lookup = { ItemKeyResult.Found(it.toByteArray()) }
        assertFalse(sender().pass())
        assertNull(host.keysManifest())
        host.askKeys(at = 101)
        assertTrue(sender().pass())
    }

    @Test fun cancel_while_looking_a_key_up_sends_nothing_more() {
        host.askKeys(at = 100)
        val s = sender()
        host.lookup = { s.cancel(); ItemKeyResult.Found(it.toByteArray()) }
        assertFalse(s.pass())
        assertTrue(host.sealedBatches.isEmpty())
        assertTrue(host.puts.isEmpty())
    }

    @Test fun only_a_seed_holder_answers_and_only_a_listed_device() {
        host.askKeys(at = 100)
        host.seed = false
        assertFalse(sender().pass())
        host.seed = true
        host.devices = mutableListOf(host.me)
        assertFalse(sender().pass())
        assertTrue(host.lookups.isEmpty())
        assertTrue(host.puts.isEmpty())
    }

    @Test fun another_live_source_is_left_to_it() {
        host.askKeys(at = 100)
        val other = "e3".repeat(32)
        host.lane[HW.keysManifestKey(host.account, host.browser, other)] =
            HW.KeysManifest("1", other, 100, 0, false, clock - 1_000, 5, 0, 0).encode()
        assertFalse(sender().pass())
        clock += HW.STALE_SOURCE_MS
        assertTrue(sender().pass())
    }

    @Test fun an_abandoned_job_is_dropped_and_reset_forgets_everything() {
        host.lookup = { ItemKeyResult.Unreachable }
        host.askKeys(at = 100)
        val s = sender()
        s.pass()
        host.lane.clear()
        clock += HW.ABANDONED_MS + 1
        s.pass()
        assertFalse(s.hasJobs())
        s.reset()
        assertFalse(file.exists())
    }
}
