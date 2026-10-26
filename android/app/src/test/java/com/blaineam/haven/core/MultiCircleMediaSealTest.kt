package com.blaineam.haven.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * A media post into several circles seals each attachment ONCE for every chosen circle (one blob, one
 * upload) instead of locking it to the circle it was staged in. The engine is a deterministic fake whose
 * "seal" is a readable header naming the circles that can open it, so the tests assert real openability,
 * not just call shapes. No clocks, sleeps or threads — everything runs inline.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MultiCircleMediaSealTest {
    private lateinit var ctx: FakeContext
    private lateinit var social: FakeSocial
    private val net = HavenNet::class.java

    // Fake codec: "HVE1|<ids>|<plain>". Opens only for a circle named in the header.
    private fun envelope(ids: List<String>, plain: ByteArray) = "HVE1|${ids.joinToString(",")}|".toByteArray() + plain
    private fun open(circle: String, sealed: ByteArray): ByteArray? {
        val text = String(sealed, Charsets.ISO_8859_1)
        if (!text.startsWith("HVE1|")) return null
        val second = text.indexOf('|', 5)
        val ids = text.substring(5, second).split(',')
        return if (circle in ids) sealed.copyOfRange(second + 1, sealed.size) else null
    }
    private fun idsOf(sealed: ByteArray): List<String> =
        String(sealed, Charsets.ISO_8859_1).let { it.substring(5, it.indexOf('|', 5)).split(',') }

    @Before fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        ctx = FakeContext()
        net.getDeclaredField("appContext").apply { isAccessible = true }.set(HavenNet, ctx)
        LocalMedia.init(ctx)
        social = FakeSocial().apply {
            sealMedia = { c, d -> envelope(listOf(c), d) }
            sealMulti = { ids, d -> envelope(ids, d) }
            openMedia = { c, s -> open(c, s) }
            sealFile = { c, i, o -> File(o).writeBytes(envelope(listOf(c), File(i).readBytes())); true }
            sealFileMulti = { ids, i, o -> File(o).writeBytes(envelope(ids, File(i).readBytes())); true }
            openFile = { c, i, o -> open(c, File(i).readBytes())?.let { File(o).writeBytes(it); true } ?: false }
        }
        net.getDeclaredField("social").apply { isAccessible = true }.set(HavenNet, social)
    }
    @After fun tearDown() { Dispatchers.resetMain(); ctx.filesDir.deleteRecursively() }

    private fun stage(circle: String, size: Int = 64, seed: Int = 1, video: Boolean = true): Pair<String, ByteArray> {
        val bytes = ByteArray(size) { (it * 31 + seed).toByte() }
        return LocalMedia.store(circle, bytes, isVideo = video) to bytes
    }

    @Test fun a_blob_staged_for_one_circle_is_resealed_for_every_selected_circle() {
        val (ref, plain) = stage("a")
        assertEquals(setOf("a"), LocalMedia.sealedCircles(ref))
        assertEquals(LocalMedia.Sealed.RESEALED, LocalMedia.ensureSealedFor(ref, listOf("a", "b", "c")))
        assertEquals(listOf(listOf("a", "b", "c")), social.multiSeals.toList())
        assertEquals(setOf("a", "b", "c"), LocalMedia.sealedCircles(ref))
        for (c in listOf("a", "b", "c")) assertArrayEquals("opens in $c", plain, LocalMedia.load(c, ref))
        assertEquals(null, LocalMedia.load("zzz", ref))
    }

    @Test fun a_blob_that_already_covers_the_set_is_not_resealed() {
        val (ref, _) = stage("a")
        LocalMedia.ensureSealedFor(ref, listOf("a", "b"))
        social.multiSeals.clear()
        assertEquals(LocalMedia.Sealed.ALREADY, LocalMedia.ensureSealedFor(ref, listOf("b", "a")))
        assertEquals(LocalMedia.Sealed.ALREADY, LocalMedia.ensureSealedFor(ref, listOf("b")))
        assertTrue(social.multiSeals.isEmpty())
    }

    @Test fun a_seal_made_for_fewer_circles_is_resealed_when_the_set_grows_and_keeps_the_old_ones() {
        val (ref, plain) = stage("a")
        LocalMedia.ensureSealedFor(ref, listOf("a", "b"))
        social.multiSeals.clear()
        assertEquals(LocalMedia.Sealed.RESEALED, LocalMedia.ensureSealedFor(ref, listOf("c")))
        // Primary = the circle being posted to now; the earlier circles stay readable.
        assertEquals(listOf(listOf("c", "a", "b")), social.multiSeals.toList())
        for (c in listOf("a", "b", "c")) assertArrayEquals(plain, LocalMedia.load(c, ref))
        assertEquals(listOf("c", "a", "b"), idsOf(LocalMedia.rawSealed(ref)!!))
    }

    @Test fun a_blob_of_unknown_provenance_is_always_resealed_before_it_is_trusted() {
        val (ref, plain) = stage("a")
        LocalMedia.writeRawSealed(ref, envelope(listOf("a"), plain))   // e.g. fetched from a relay: no record
        assertEquals(emptySet<String>(), LocalMedia.sealedCircles(ref))
        assertEquals(LocalMedia.Sealed.RESEALED, LocalMedia.ensureSealedFor(ref, listOf("a", "b")))
        assertArrayEquals(plain, LocalMedia.load("b", ref))
    }

    @Test fun large_blobs_are_resealed_file_to_file() {
        val (ref, plain) = stage("a", size = 5 * 1024 * 1024)
        assertEquals(LocalMedia.Sealed.RESEALED, LocalMedia.ensureSealedFor(ref, listOf("a", "b")))
        assertEquals(listOf(listOf("a", "b")), social.multiSeals.toList())
        assertArrayEquals(plain, LocalMedia.load("b", ref))
        val leftovers = File(ctx.filesDir, "media").list { _, n -> n.endsWith(".tmp") || n.contains("seal") }.orEmpty()
        assertTrue("scratch files cleaned up: ${leftovers.toList()}", leftovers.isEmpty())
    }

    @Test fun a_failed_multi_seal_keeps_the_previous_valid_seal_and_reports_failure() {
        val (ref, plain) = stage("a")
        val before = LocalMedia.rawSealed(ref)!!
        social.sealMulti = { _, _ -> throw IllegalStateException("unknown circle") }
        assertEquals(LocalMedia.Sealed.FAILED, LocalMedia.ensureSealedFor(ref, listOf("a", "gone")))
        assertArrayEquals(before, LocalMedia.rawSealed(ref))
        assertEquals(setOf("a"), LocalMedia.sealedCircles(ref))
        assertArrayEquals(plain, LocalMedia.load("a", ref))
    }

    @Test fun a_repair_reseal_for_one_circle_keeps_the_others_that_share_the_blob() {
        val (ref, plain) = stage("a")
        LocalMedia.ensureSealedFor(ref, listOf("a", "b"))
        val fresh = LocalMedia.resealInPlace("b", ref, plain)
        assertNotNull(fresh)
        assertEquals(listOf("b", "a"), idsOf(fresh!!))
        assertArrayEquals(plain, LocalMedia.load("a", ref))
    }

    @Test fun deleting_a_blob_forgets_which_circles_it_was_sealed_for() {
        val (ref, _) = stage("a")
        LocalMedia.ensureSealedFor(ref, listOf("a", "b"))
        LocalMedia.delete(ref)
        assertEquals(emptySet<String>(), LocalMedia.sealedCircles(ref))
    }

    // ---- HavenNet: the whole post ---------------------------------------------------------------

    @Test fun a_multi_circle_post_seals_every_attachment_for_all_circles_before_authoring_in_any() {
        val (photo, plain) = stage("a", seed = 3)
        val (clip, plain2) = stage("a", seed = 4)
        val sealsWhenAuthored = ArrayList<Int>()
        social.onAuthor = { sealsWhenAuthored += social.multiSeals.size }
        HavenNet.postToCircles(listOf("a", "b", "c"), "hi", listOf(photo, clip))
        assertEquals(listOf("a", "b", "c"), social.authored.map { it.circleId })
        assertTrue(social.authored.all { it.media == listOf(photo, clip) && it.body == "hi" })
        assertEquals("one multi seal per attachment, each with ALL ids, primary first",
            listOf(listOf("a", "b", "c"), listOf("a", "b", "c")), social.multiSeals.toList())
        assertEquals("every seal landed before the first post was authored", listOf(2, 2, 2), sealsWhenAuthored)
        for (c in listOf("a", "b", "c")) {
            assertArrayEquals(plain, LocalMedia.load(c, photo)); assertArrayEquals(plain2, LocalMedia.load(c, clip))
        }
    }

    @Test fun a_text_only_or_single_circle_post_never_touches_the_blob_seal() {
        HavenNet.postToCircles(listOf("a", "b"), "just words")
        assertEquals(listOf("a", "b"), social.authored.map { it.circleId })
        assertTrue(social.multiSeals.isEmpty())
        val (photo, _) = stage("a")
        HavenNet.postToCircles(listOf("a"), "one", listOf(photo))
        assertTrue("one circle keeps the staged seal", social.multiSeals.isEmpty())
    }

    @Test fun companions_named_by_markers_are_sealed_for_the_whole_set_too() {
        val (photo, _) = stage("a", seed = 5, video = false)
        val (thumb, thumbPlain) = stage("a", seed = 6, video = false)
        ctx.prefs("haven.media.thumbs").data["t|$photo"] = thumb
        HavenNet.postToCircles(listOf("a", "b"), "pic", listOf(photo))
        assertEquals(setOf(setOf("a", "b")), social.multiSeals.map { it.toSet() }.toSet())
        assertEquals("content + thumb", 2, social.multiSeals.size)
        assertArrayEquals(thumbPlain, LocalMedia.load("b", thumb))
    }

    @Test fun an_empty_post_or_no_circles_authors_nothing() {
        HavenNet.postToCircles(emptyList(), "x")
        HavenNet.postToCircles(listOf("a", "b"), "  ")
        assertTrue(social.authored.isEmpty())
    }
}
