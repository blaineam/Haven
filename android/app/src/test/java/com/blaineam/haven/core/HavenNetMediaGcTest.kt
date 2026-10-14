package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.FeedItemFfi
import java.io.File

/**
 * Local storage management: the size-sorted "Manage media" inventory joined to the posts that reference each blob,
 * deleting rows (a referenced blob becomes an evicted placeholder, not a re-download), the orphan sweep, the age cap, and
 * the purge of expired events. Every deletion rule has a grace window, so the tests age the files they mean to reap.
 */
class HavenNetMediaGcTest {
    private val env = NetEnv()
    private val old = System.currentTimeMillis() - 10L * 24 * 3600 * 1000

    @Before fun setUp() {
        env.up()
        MediaLimits.init(env.ctx)
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 1u), CircleInfoFfi("dm:x-y", "dm", 2u))
    }
    @After fun tearDown() {
        MediaLimits.maxDaysState.intValue = 0; MediaLimits.maxGBState.intValue = 0
        env.down()
    }

    private fun until(cond: () -> Boolean) = runBlocking { withTimeout(15_000) { while (!cond()) yield() } }
    private fun blob(seed: Int, size: Int, aged: Boolean = true): String {
        val ref = LocalMedia.store("default", ByteArray(size) { ((it + seed) % 251).toByte() })
        if (aged) File(env.ctx.filesDir, "media").listFiles()!!.filter { it.name.endsWith(ref.removePrefix("img_")) }.forEach { it.setLastModified(old) }
        return ref
    }
    private fun post(id: String, media: List<String>, body: String = "caption") =
        FeedItemFfi(id, "aaaaaaaa", true, 1uL, body, media, null, false, false, false, false, emptyList(), emptyList(), null)

    // ---- inventory ---------------------------------------------------------------------------------

    @Test fun the_inventory_joins_each_blob_to_its_post_and_sorts_largest_first() {
        val big = blob(1, 5000); val small = blob(2, 800); val dmBlob = blob(3, 2000); val orphan = blob(4, 100)
        env.social.feeds["default"] = listOf(post("p1", listOf(big, small), "holiday"))
        env.social.feeds["dm:x-y"] = listOf(post("m1", listOf(dmBlob), "see this"))
        PinnedMediaStore.pin(listOf(small))
        val rows = HavenNet.mediaInventory()
        assertEquals("largest first", rows.map { it.bytes }.sortedDescending(), rows.map { it.bytes })
        val byKey = rows.associateBy { it.key }
        val bigRow = byKey.values.first { it.key.endsWith(big.removePrefix("img_")) }
        assertEquals("Home", bigRow.circleName); assertEquals("holiday", bigRow.snippet); assertFalse(bigRow.orphan)
        val dmRow = byKey.values.first { it.key.endsWith(dmBlob.removePrefix("img_")) }
        assertEquals("Direct message", dmRow.circleName)
        val orphanRow = byKey.values.first { it.key.endsWith(orphan.removePrefix("img_")) }
        assertEquals("Unused", orphanRow.circleName); assertTrue(orphanRow.orphan); assertNull(orphanRow.circleId); assertNull(orphanRow.snippet)
        assertTrue(byKey.values.first { it.key.endsWith(small.removePrefix("img_")) }.pinned)
    }

    @Test fun nothing_is_listed_before_the_engine_is_ready() {
        NetEnv.field("ready").setBoolean(HavenNet, false)
        assertTrue(HavenNet.mediaInventory().isEmpty())
        assertEquals(0L, HavenNet.deleteSelectedMedia(emptyList()))
        assertEquals(0L to 0, HavenNet.cleanupUnusedMedia())
    }

    // ---- deleting rows -------------------------------------------------------------------------------

    @Test fun deleting_a_row_frees_the_bytes_and_a_referenced_one_becomes_an_evicted_placeholder() {
        val used = blob(5, 3000); val unused = blob(6, 1000); val pinned = blob(7, 500)
        env.social.feeds["default"] = listOf(post("p1", listOf(used)))
        PinnedMediaStore.pin(listOf(pinned))
        val rows = HavenNet.mediaInventory()
        val freed = HavenNet.deleteSelectedMedia(rows)
        assertTrue(freed > 0)
        assertFalse(LocalMedia.has(used)); assertFalse(LocalMedia.has(unused))
        assertTrue("a pinned blob is skipped", LocalMedia.has(pinned))
        assertTrue("the post still references it: shown as 'Download', never silently refetched", EvictedMediaStore.contains(used))
        assertFalse("an unused blob leaves no placeholder", EvictedMediaStore.contains(unused))
    }

    // ---- sweeps ------------------------------------------------------------------------------------------

    @Test fun the_orphan_sweep_removes_old_unreferenced_blobs_and_spares_the_rest() {
        val used = blob(8, 400); val orphan = blob(9, 400); val fresh = blob(10, 400, aged = false)
        env.social.feeds["default"] = listOf(post("p1", listOf(used)))
        val (bytes, files) = HavenNet.cleanupUnusedMedia()
        assertEquals(1, files); assertTrue(bytes > 0)
        assertTrue(LocalMedia.has(used))
        assertFalse(LocalMedia.has(orphan))
        assertTrue("inside the 48 h grace window: it may be an upload in progress", LocalMedia.has(fresh))
    }

    @Test fun the_age_cap_evicts_old_blobs_oldest_first_and_marks_the_ones_a_post_still_names() {
        val used = blob(11, 600); val orphan = blob(12, 600)
        env.social.feeds["default"] = listOf(post("p1", listOf(used)))
        MediaLimits.setMaxDays(1)   // changing the cap runs an enforcement pass at once
        until { !LocalMedia.has(used) && !LocalMedia.has(orphan) }
        until { EvictedMediaStore.contains(used) }
        assertFalse(EvictedMediaStore.contains(orphan))
    }

    @Test fun with_both_caps_off_nothing_is_evicted() {
        val b = blob(13, 600)
        HavenNet.enforceLocalLimits(force = true)
        env.settle()
        assertTrue(LocalMedia.has(b))
    }

    @Test fun the_weekly_sweep_runs_once_and_stamps_itself() {
        val orphan = blob(14, 300)
        val prefs = env.ctx.prefs("haven.mediagc")
        NetEnv.call("maybeWeeklyMediaSweep")
        until { prefs.getLong("lastSweep", 0L) > 0L }
        assertFalse(LocalMedia.has(orphan))
        val stamp = prefs.getLong("lastSweep", 0L)
        NetEnv.call("maybeWeeklyMediaSweep")
        assertEquals("not again inside the week", stamp, prefs.getLong("lastSweep", 0L))
    }

    // ---- purging expired events -----------------------------------------------------------------------------

    @Test fun purging_expired_events_deletes_the_media_nothing_else_uses() {
        val gone = blob(15, 700); val shared = blob(16, 700)
        env.social.feeds["default"] = listOf(post("keeps-shared", listOf(shared)))
        env.social.purged["default"] = listOf(gone, shared, "geo:1,2,pin")
        env.social.exported = byteArrayOf(1)
        HavenNet.maybePurgeExpiredMedia("default")
        until { !LocalMedia.has(gone) }
        assertTrue("another live post still uses it", LocalMedia.has(shared))
    }

    @Test fun purging_runs_once_per_circle_per_session_and_not_before_ready() {
        env.social.purged["default"] = listOf(blob(17, 300))
        NetEnv.field("ready").setBoolean(HavenNet, false)
        HavenNet.maybePurgeExpiredMedia("default")
        assertTrue((NetEnv.field("purgedMediaCircles").get(HavenNet) as Set<*>).isEmpty())
        NetEnv.field("ready").setBoolean(HavenNet, true)
        HavenNet.maybePurgeExpiredMedia("default")
        HavenNet.maybePurgeExpiredMedia("default")
        assertEquals(1, (NetEnv.field("purgedMediaCircles").get(HavenNet) as Set<*>).size)
    }
}
