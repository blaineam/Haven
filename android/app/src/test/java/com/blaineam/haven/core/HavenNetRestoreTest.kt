package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

@OptIn(ExperimentalCoroutinesApi::class)
/** Relay restore of chunked media: resumable, one-seal-only, and never adopting a hole. */
class HavenNetRestoreTest {
    private lateinit var ctx: FakeContext
    private val ref = "vid_" + "ab".repeat(32)

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        HavenNet::class.java.getDeclaredField("appContext").apply { isAccessible = true }.set(HavenNet, ctx)
        LocalMedia.init(ctx)
        // sweepRestorePartsOnce would run once per process on a background thread and delete parts mid-test
        HavenNet::class.java.getDeclaredField("sweptRestoreParts").apply { isAccessible = true }.setBoolean(HavenNet, true)
    }
    @After fun tearDown() { ctx.filesDir.deleteRecursively(); Dispatchers.resetMain() }

    private fun chunks(n: Int) = List(n) { i -> ByteArray(8) { (i * 16 + it).toByte() } }
    private fun whole(c: List<ByteArray>) = c.fold(ByteArray(0)) { a, b -> a + b }
    private fun manifest(c: List<ByteArray>) = HavenKeys.makeManifest(c.map { it.size })
    private val partsDir get() = File(ctx.filesDir, "relay-parts")

    private fun restore(head: ByteArray, getChunk: (Int) -> ByteArray?): Boolean =
        runBlocking { HavenNet.reassembleInto(ref, head) { getChunk(it) } }

    @Test fun a_small_unchunked_blob_is_stored_as_is() {
        assertTrue(restore("plain sealed blob".toByteArray()) { error("no chunks expected") })
        assertArrayEquals("plain sealed blob".toByteArray(), LocalMedia.rawSealed(ref))
    }

    @Test fun an_empty_body_is_a_miss_not_a_stored_copy() {
        assertFalse(restore(ByteArray(0)) { null })
        assertFalse(LocalMedia.has(ref))
    }

    @Test fun every_chunk_is_fetched_in_order_and_adopted_whole() {
        val c = chunks(5); val order = ArrayList<Int>()
        assertTrue(restore(manifest(c)) { i -> order.add(i); c[i] })
        assertEquals(listOf(0, 1, 2, 3, 4), order)
        assertArrayEquals(whole(c), LocalMedia.rawSealed(ref))
        assertTrue("no scratch left behind", partsDir.listFiles().orEmpty().isEmpty())
    }

    @Test fun a_missing_chunk_fails_the_attempt_and_keeps_the_partial() {
        val c = chunks(4)
        assertFalse(restore(manifest(c)) { i -> if (i < 2) c[i] else null })
        assertFalse("a hole is never adopted", LocalMedia.has(ref))
        assertEquals("partial + sidecar kept for resume", 2, partsDir.listFiles().orEmpty().size)
    }

    @Test fun a_retry_resumes_after_the_chunks_already_held() {
        val c = chunks(4)
        restore(manifest(c)) { i -> if (i < 2) c[i] else null }
        val asked = ArrayList<Int>()
        assertTrue(restore(manifest(c)) { i -> asked.add(i); c[i] })
        assertEquals("only the missing chunks are fetched", listOf(2, 3), asked)
        assertArrayEquals(whole(c), LocalMedia.rawSealed(ref))
    }

    @Test fun an_empty_chunk_counts_as_missing() {
        val c = chunks(2)
        assertFalse(restore(manifest(c)) { i -> if (i == 0) c[0] else ByteArray(0) })
        assertFalse(LocalMedia.has(ref))
    }

    @Test fun a_different_seal_with_the_same_chunk_count_restarts_instead_of_splicing() {
        val first = chunks(3)
        restore(manifest(first)) { i -> if (i < 2) first[i] else null }          // 2 of 3 held from seal #1
        val second = List(3) { i -> ByteArray(8) { (200 + i).toByte() } }          // a second seal: same count...
        val secondManifest = HavenKeys.makeManifest(listOf(8, 8, 9))               // ...but its manifest differs
        val asked = ArrayList<Int>()
        val seal2 = listOf(second[0], second[1], ByteArray(9) { 77 })
        assertTrue(restore(secondManifest) { i -> asked.add(i); seal2[i] })
        assertEquals("restarted from chunk 0", listOf(0, 1, 2), asked)
        assertArrayEquals(whole(seal2), LocalMedia.rawSealed(ref))
    }

    @Test fun a_chunk_count_change_also_restarts() {
        val c = chunks(4)
        restore(manifest(c)) { i -> if (i < 3) c[i] else null }
        val shorter = chunks(2)
        val asked = ArrayList<Int>()
        assertTrue(restore(manifest(shorter)) { i -> asked.add(i); shorter[i] })
        assertEquals(listOf(0, 1), asked)
        assertArrayEquals(whole(shorter), LocalMedia.rawSealed(ref))
    }
}
