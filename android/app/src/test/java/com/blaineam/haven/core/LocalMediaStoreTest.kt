package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/** The on-disk media store: key scheme, legacy adoption, deletion, sweeps, and chunk reassembly. */
class LocalMediaStoreTest {
    private lateinit var ctx: FakeContext
    private lateinit var media: File
    private lateinit var plain: File
    private val hash = "9f".repeat(32)
    private val hour = 3_600_000L
    private val day = 24 * hour

    @Before fun setUp() {
        ctx = FakeContext()
        LocalMedia.init(ctx)
        media = File(ctx.filesDir, "media"); plain = File(ctx.filesDir, "media-plain")
    }

    @After fun tearDown() { ctx.filesDir.deleteRecursively() }

    private fun blob(name: String, bytes: Int = 10, ageMs: Long = 0, dir: File = media): File =
        File(dir, name).also {
            it.writeBytes(ByteArray(bytes) { 7 })
            it.setLastModified(System.currentTimeMillis() - ageMs)
        }

    // ---- ref classification & keys ------------------------------------------------------------

    @Test fun ref_kinds_come_from_the_prefix() {
        assertTrue(LocalMedia.isVideo("vid_x")); assertTrue(LocalMedia.isVideo("v:x"))
        assertTrue(LocalMedia.isAudio("aud_x")); assertTrue(LocalMedia.isFile("file_x"))
        assertFalse(LocalMedia.isVideo("img_x"))
    }

    @Test fun synthetic_refs_have_a_multichar_scheme() {
        assertTrue(LocalMedia.isSynthetic("geo:1.0,2.0,Home"))
        assertFalse("legacy v:/i: refs stay fetchable", LocalMedia.isSynthetic("v:abc"))
        assertFalse(LocalMedia.isSynthetic("img_abc"))
    }

    @Test fun bare_id_strips_every_known_kind_prefix() {
        for (p in listOf("img_", "vid_", "aud_", "file_", "v:", "i:")) assertEquals(hash, LocalMedia.bareId(p + hash))
        assertEquals(hash, LocalMedia.bareId(hash))
    }

    @Test fun kind_qualifies_the_key_so_a_photo_and_a_video_never_share_a_file() {
        assertEquals(setOf("img_$hash", hash), LocalMedia.normalizedKeys("img_$hash"))
        assertEquals(setOf("vid_$hash", hash), LocalMedia.normalizedKeys("v:$hash"))
        assertEquals(setOf("img_$hash", hash), LocalMedia.normalizedKeys("i:$hash"))
        assertEquals(setOf("aud_$hash", hash), LocalMedia.normalizedKeys("aud_$hash"))
        assertEquals(setOf("file_$hash", hash), LocalMedia.normalizedKeys("file_$hash"))
        assertEquals("a kindless legacy ref keeps its bare key", setOf(hash), LocalMedia.normalizedKeys(hash))
    }

    // ---- raw blobs -----------------------------------------------------------------------------

    @Test fun a_written_blob_is_found_sized_and_read_back_verbatim() {
        assertFalse(LocalMedia.has("img_$hash")); assertEquals(0L, LocalMedia.sizeOf("img_$hash"))
        assertNull(LocalMedia.rawSealed("img_$hash"))
        assertTrue(LocalMedia.writeRawSealed("img_$hash", "sealed-bytes".toByteArray()))
        assertTrue(LocalMedia.has("img_$hash"))
        assertEquals(12L, LocalMedia.sizeOf("img_$hash"))
        assertEquals(12L, LocalMedia.sealedSize("img_$hash"))
        assertArrayEquals("sealed-bytes".toByteArray(), LocalMedia.rawSealed("img_$hash"))
        assertTrue(LocalMedia.fitsInMemory("img_$hash"))
        assertEquals(-1L, LocalMedia.sealedSize("img_nothere")); assertFalse(LocalMedia.fitsInMemory("img_nothere"))
    }

    @Test fun an_empty_body_is_a_miss_not_a_stored_copy() {
        assertFalse(LocalMedia.writeRawSealed("img_$hash", ByteArray(0)))
        assertFalse(LocalMedia.has("img_$hash"))
    }

    @Test fun overwriting_replaces_the_whole_blob() {
        LocalMedia.writeRawSealed("img_$hash", "first version, longer".toByteArray())
        LocalMedia.writeRawSealed("img_$hash", "second".toByteArray())
        assertArrayEquals("second".toByteArray(), LocalMedia.rawSealed("img_$hash"))
        assertEquals("no scratch left behind", listOf("img_$hash"), media.list()!!.toList())
    }

    @Test fun a_legacy_bare_key_file_is_adopted_under_the_kind_qualified_key() {
        blob(hash, bytes = 5)
        assertTrue(LocalMedia.has("img_$hash"))
        assertTrue(File(media, "img_$hash").exists())
        assertFalse("renamed, not copied", File(media, hash).exists())
        assertFalse("the other kind must not be handed the photo's bytes", LocalMedia.has("vid_$hash"))
    }

    // ---- deletion ------------------------------------------------------------------------------

    @Test fun delete_removes_the_blob_and_every_decrypted_cache_and_reports_bytes() {
        blob("vid_$hash", 100)
        blob("vid_$hash.mp4", 40, dir = plain)
        blob("vid_$hash.mp4", 25, dir = ctx.filesDir)   // legacy loose cache
        assertEquals(165L, LocalMedia.delete("vid_$hash"))
        assertFalse(LocalMedia.has("vid_$hash"))
        assertFalse(File(plain, "vid_$hash.mp4").exists()); assertFalse(File(ctx.filesDir, "vid_$hash.mp4").exists())
        assertEquals(0L, LocalMedia.delete("vid_$hash"))
    }

    @Test fun delete_leaves_synthetic_refs_alone() {
        assertEquals(0L, LocalMedia.delete("geo:1,2,x"))
    }

    // ---- inventory ----------------------------------------------------------------------------

    @Test fun stored_blobs_skip_scratch_and_hidden_files() {
        blob("img_a", 30); blob("vid_b", 50)
        blob("incoming_img_c_1.part", 5); blob("x.plain.tmp", 5); blob(".hidden", 5)
        File(media, "subdir").mkdirs()
        val got = LocalMedia.storedBlobs().associate { it.key to it.bytes }
        assertEquals(mapOf("img_a" to 30L, "vid_b" to 50L), got)
    }

    // ---- limit sweep (the "Manage media" age/size caps) -------------------------------------------

    @Test fun limit_sweep_with_no_caps_does_nothing() {
        blob("img_a", 10, ageMs = 400 * day)
        assertEquals(Triple(0L, 0, emptyMap<String, Long>()), LocalMedia.performLimitSweep(0, 0, emptySet(), emptySet()))
        assertTrue(File(media, "img_a").exists())
    }

    @Test fun age_cap_evicts_old_blobs_but_spares_pinned_fresh_and_scratch() {
        blob("img_old", 10, ageMs = 40 * day)
        blob("img_pinned", 20, ageMs = 40 * day)
        blob("img_fresh", 30, ageMs = 1 * hour)               // inside the 48h grace window
        blob("incoming_img_x_1.part", 40, ageMs = 40 * day)   // in-flight scratch
        val (freed, files, evict) = LocalMedia.performLimitSweep(30, 0, pinnedKeys = setOf("img_pinned"), inUse = setOf("img_old"))
        assertEquals(10L, freed); assertEquals(1, files)
        assertEquals("a referenced blob is recorded as evicted, with its size", mapOf("img_old" to 10L), evict)
        assertFalse(File(media, "img_old").exists())
        for (kept in listOf("img_pinned", "img_fresh", "incoming_img_x_1.part")) assertTrue(kept, File(media, kept).exists())
    }

    @Test fun an_unreferenced_evicted_blob_is_not_recorded_for_refetch() {
        blob("img_old", 10, ageMs = 40 * day)
        val (_, files, evict) = LocalMedia.performLimitSweep(30, 0, emptySet(), inUse = emptySet())
        assertEquals(1, files); assertTrue(evict.isEmpty())
    }

    private fun sparse(name: String, bytes: Long, ageMs: Long): File = File(media, name).also {
        java.io.RandomAccessFile(it, "rw").use { raf -> raf.setLength(bytes) }   // sparse: no real disk
        it.setLastModified(System.currentTimeMillis() - ageMs)
    }

    @Test fun size_cap_evicts_oldest_first_until_under_it() {
        sparse("img_oldest", 600_000_000L, 30 * day)
        sparse("img_middle", 600_000_000L, 20 * day)
        sparse("img_newest", 600_000_000L, 10 * day)
        val (freed, files, _) = LocalMedia.performLimitSweep(0, 1, emptySet(), emptySet())   // 1 GB cap, 1.8 GB held
        assertEquals(2, files); assertEquals(1_200_000_000L, freed)
        assertFalse(File(media, "img_oldest").exists()); assertFalse(File(media, "img_middle").exists())
        assertTrue(File(media, "img_newest").exists())
    }

    @Test fun pinned_bytes_count_toward_the_cap_but_are_never_evicted() {
        sparse("img_pinned", 900_000_000L, 30 * day)
        sparse("img_other", 300_000_000L, 20 * day)
        val (_, files, _) = LocalMedia.performLimitSweep(0, 1, setOf("img_pinned"), emptySet())
        assertEquals(1, files)
        assertTrue(File(media, "img_pinned").exists()); assertFalse(File(media, "img_other").exists())
    }

    // ---- orphan sweep ---------------------------------------------------------------------------

    @Test fun orphan_sweep_removes_old_unreferenced_files_in_all_three_places() {
        blob("img_keep", 10, ageMs = 5 * day); blob("img_orphan", 20, ageMs = 5 * day)
        blob("img_new_orphan", 30, ageMs = 1 * hour)             // inside the grace window
        blob("vid_orphan.mp4", 40, ageMs = 5 * day, dir = plain)
        blob("vid_keep.mp4", 50, ageMs = 5 * day, dir = plain)
        blob("vid_${hash}.mp4", 60, ageMs = 5 * day, dir = ctx.filesDir)   // legacy loose cache, media-shaped
        blob("settings.json", 70, ageMs = 5 * day, dir = ctx.filesDir)     // app state: never touched
        blob("random.mp4", 80, ageMs = 5 * day, dir = ctx.filesDir)        // not a media key shape
        val (bytes, files) = LocalMedia.sweepOrphans(setOf("img_keep", "vid_keep"))
        assertEquals(20L + 40 + 60, bytes); assertEquals(3, files)
        assertTrue(File(media, "img_keep").exists()); assertTrue(File(media, "img_new_orphan").exists())
        assertTrue(File(plain, "vid_keep.mp4").exists())
        assertTrue(File(ctx.filesDir, "settings.json").exists()); assertTrue(File(ctx.filesDir, "random.mp4").exists())
        assertFalse(File(media, "img_orphan").exists()); assertFalse(File(plain, "vid_orphan.mp4").exists())
    }

    @Test fun orphan_sweep_spares_a_live_resumable_partial_but_not_an_abandoned_one() {
        val live = blob("incoming_vid_a_1.part", 10, ageMs = 5 * day)
        val dead = blob("incoming_vid_b_2.part", 10, ageMs = 5 * day)
        val now = System.currentTimeMillis()
        val (_, files) = LocalMedia.sweepOrphans(emptySet(), liveParts = mapOf(
            live.name to now - hour,                              // progressed an hour ago
            dead.name to now - 2 * ReassemblyStore.EXPIRY_MS,     // abandoned
        ))
        assertEquals(1, files)
        assertTrue(live.exists()); assertFalse(dead.exists())
    }

    @Test fun clear_removes_every_media_file_and_loose_cache_but_not_app_state() {
        blob("img_a"); blob("vid_b.mp4", dir = plain); blob("vid_${hash}.mp4", dir = ctx.filesDir)
        blob("settings.json", dir = ctx.filesDir)
        LocalMedia.clear()
        assertEquals(0, media.list()!!.size); assertEquals(0, plain.list()!!.size)
        assertFalse(File(ctx.filesDir, "vid_${hash}.mp4").exists())
        assertTrue(File(ctx.filesDir, "settings.json").exists())
    }

    // ---- chunked reassembly ---------------------------------------------------------------------

    @Test fun a_sealed_part_is_assembled_by_appending_and_adopted_under_its_ref() {
        val part = LocalMedia.newSealedPart("vid_$hash")
        assertTrue(part.name.startsWith("incoming_vid_$hash") && part.name.endsWith(".part"))
        assertTrue(LocalMedia.appendSealedPart(part, "AAAA".toByteArray()))
        assertTrue(LocalMedia.appendSealedPart(part, "BB".toByteArray()))
        assertFalse("a partial is never mistaken for the blob", LocalMedia.has("vid_$hash"))
        assertEquals("a partial is not an inventory entry", 0, LocalMedia.storedBlobs().size)
        assertTrue(LocalMedia.adoptSealedPart("vid_$hash", part))
        assertArrayEquals("AAAABB".toByteArray(), LocalMedia.rawSealed("vid_$hash"))
        assertFalse(part.exists())
    }

    @Test fun an_empty_reassembly_is_not_adopted() {
        val part = LocalMedia.newSealedPart("img_$hash")
        assertFalse(LocalMedia.adoptSealedPart("img_$hash", part))
        assertFalse(LocalMedia.has("img_$hash"))
    }

    @Test fun positional_writes_fill_holes_out_of_order() {
        val part = LocalMedia.newPlainPart("vid_$hash")
        assertTrue(LocalMedia.writePartAt(part, 4, "WXYZ".toByteArray()))
        assertTrue(LocalMedia.writePartAt(part, 0, "abcd".toByteArray()))
        assertEquals("abcdWXYZ", part.readText())
        assertEquals(part, LocalMedia.partFile(part.name))
    }

    @Test fun a_part_that_does_not_account_for_its_content_address_is_rejected_and_deleted() {
        val part = LocalMedia.newPlainPart("img_$hash")
        part.writeBytes("not the bytes that hash to this ref".toByteArray())
        assertFalse(LocalMedia.adoptPlainPart("circ", "img_$hash", part))
        assertFalse(part.exists()); assertFalse(LocalMedia.has("img_$hash"))
    }

    // ---- ultra-constrained link policy & companions ---------------------------------------------

    @Test fun a_preview_ref_or_a_tiny_blob_may_cross_a_satellite_link_but_a_big_one_may_not() {
        ctx.prefs("haven.media.thumbs").data["pr|img_preview"] = true
        assertTrue(LocalMedia.isPreviewRef("img_preview"))
        assertTrue(LocalMedia.maySendOnUltraConstrained("img_preview"))
        LocalMedia.writeRawSealed("img_tiny", ByteArray(100) { 1 })
        assertTrue(LocalMedia.maySendOnUltraConstrained("img_tiny"))
        LocalMedia.writeRawSealed("img_big", ByteArray(PreviewCodec.MAX_BYTES + 1) { 1 })
        assertFalse(LocalMedia.maySendOnUltraConstrained("img_big"))
        assertFalse("not here at all", LocalMedia.maySendOnUltraConstrained("img_absent"))
    }

    @Test fun thumb_and_preview_companions_come_from_the_recorded_mapping() {
        ctx.prefs("haven.media.thumbs").data["t|img_a"] = "img_a_thumb"
        ctx.prefs("haven.media.thumbs").data["p|img_a"] = "img_a_prev"
        assertEquals("img_a_thumb", LocalMedia.thumbCompanion("img_a"))
        assertEquals("img_a_prev", LocalMedia.previewCompanion("img_a"))
        assertNull(LocalMedia.thumbCompanion("img_none"))
    }

    // ---- remembered pixel sizes -----------------------------------------------------------------

    @Test fun recorded_sizes_answer_without_touching_the_media_and_ignore_nonsense() {
        LocalMedia.recordPixelSize("img_sized", 400, 300)
        assertEquals(400 to 300, LocalMedia.cachedPixelSize("img_sized"))
        assertEquals(4f / 3f, LocalMedia.cachedAspect("img_sized")!!, 0.0001f)
        LocalMedia.recordPixelSize("img_bad", 0, 100); LocalMedia.recordPixelSize("img_bad", 100, -1)
        assertNull(LocalMedia.cachedPixelSize("img_bad")); assertNull(LocalMedia.cachedAspect("img_bad"))
        assertEquals(400 to 300, LocalMedia.pixelSize("circ", "img_sized"))
    }
}
