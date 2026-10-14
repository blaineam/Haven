package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import java.io.File
import java.security.MessageDigest

/**
 * The at-rest media store against a fake engine that "seals" by prefixing a recognisable envelope tag: store, the
 * file-to-file path for big blobs, reassembled-part adoption, serving a blob to a peer, and the checks that stop a
 * substituted blob being rendered or re-served. Bitmap decoding, thumbnails and video transcoding are Android-only.
 */
class LocalMediaFilesTest {
    private val env = NetEnv()
    private val tag = "HVE1".toByteArray()
    private val plain = ByteArray(1500) { (it * 13 % 251).toByte() }
    private lateinit var ref: String

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    @Before fun setUp() {
        env.up()
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 1u))
        env.social.sealMedia = { _, d -> tag + d }
        env.social.openMedia = { _, s -> if (s.size >= 4 && s.copyOf(4).contentEquals(tag)) s.copyOfRange(4, s.size) else null }
        env.social.sealFile = { _, i, o -> File(o).writeBytes(tag + File(i).readBytes()); true }
        env.social.openFile = { _, s, o ->
            val b = File(s).readBytes()
            if (b.size >= 4 && b.copyOf(4).contentEquals(tag)) { File(o).writeBytes(b.copyOfRange(4, b.size)); true } else false
        }
        ref = "img_" + sha(plain)
    }
    @After fun tearDown() { env.down() }

    // ---- store / load ---------------------------------------------------------------------------

    @Test fun a_stored_blob_is_sealed_at_rest_and_opens_back_to_the_same_bytes() {
        assertEquals(ref, LocalMedia.store("default", plain))
        assertArrayEquals(tag + plain, LocalMedia.rawSealed(ref))
        assertArrayEquals(plain, LocalMedia.load("default", ref))
        assertArrayEquals(plain, LocalMedia.loadAnyCircle(ref))
        assertEquals((tag + plain).size.toLong(), LocalMedia.sealedSize(ref))
        assertTrue(LocalMedia.fitsInMemory(ref))
        assertTrue(LocalMedia.has(ref))
    }

    @Test fun a_blob_over_the_threshold_is_sealed_file_to_file_off_the_heap() {
        val big = ByteArray(4 * 1024 * 1024 + 7) { (it % 253).toByte() }
        val bigRef = LocalMedia.store("default", big)
        val onDisk = File(env.ctx.filesDir, "media").listFiles()!!.single { it.length() > 4_000_000 }
        assertTrue("sealed by the native file path (tag first)", onDisk.readBytes().copyOf(4).contentEquals(tag))
        assertTrue(bigRef.startsWith("img_"))
        assertTrue("and the plain scratch copy is gone", File(env.ctx.filesDir, "media").listFiles()!!.none { it.name.endsWith(".plain.tmp") })
    }

    @Test fun when_the_file_seal_fails_a_big_blob_falls_back_to_the_in_memory_seal() {
        env.social.sealFile = { _, _, _ -> false }
        val big = ByteArray(4 * 1024 * 1024 + 9) { (it % 241).toByte() }
        val r = LocalMedia.store("default", big)
        assertArrayEquals(tag, LocalMedia.rawSealed(r)!!.copyOf(4))
    }

    @Test fun a_blob_that_does_not_account_for_its_ref_is_never_rendered_or_re_served() {
        // The relay swapped a different (validly sealed) blob under this ref.
        val other = ByteArray(1500) { 9 }
        assertTrue(LocalMedia.writeRawSealed(ref, tag + other))
        assertNull(LocalMedia.load("default", ref))
        assertNull(LocalMedia.loadAnyCircle(ref))
    }

    @Test fun a_sealed_blob_that_will_not_open_is_reported_as_unopenable_not_as_tampered() {
        env.social.openMedia = { _, _ -> null }
        assertTrue(LocalMedia.writeRawSealed(ref, tag + plain))
        assertNull(LocalMedia.load("default", ref))
    }

    @Test fun a_legacy_unsealed_blob_still_reads_if_it_verifies() {
        assertTrue(LocalMedia.writeRawSealed(ref, plain))
        assertArrayEquals(plain, LocalMedia.load("default", ref))
        assertArrayEquals(plain, LocalMedia.loadAnyCircle(ref))
    }

    @Test fun a_missing_blob_loads_as_null_everywhere() {
        assertNull(LocalMedia.load("default", ref))
        assertNull(LocalMedia.loadAnyCircle(ref))
        assertNull(LocalMedia.rawSealed(ref))
        assertEquals(-1L, LocalMedia.sealedSize(ref))
        assertFalse(LocalMedia.fitsInMemory(ref))
        assertNull(LocalMedia.opensForAnyCircle(ref))
        assertNull(LocalMedia.openForServing(ref))
    }

    @Test fun a_files_blob_is_stored_under_its_own_kind() {
        val r = LocalMedia.storeFile("default", plain)
        assertEquals("file_" + sha(plain), r)
        assertArrayEquals(plain, LocalMedia.load("default", r))
    }

    // ---- does it open? ----------------------------------------------------------------------------------

    @Test fun a_held_blob_is_judged_by_whether_any_circle_can_open_it() {
        assertTrue(LocalMedia.writeRawSealed(ref, tag + plain))
        assertEquals(true, LocalMedia.opensForAnyCircle(ref))
        env.social.openMedia = { _, _ -> null }
        assertEquals(false, LocalMedia.opensForAnyCircle(ref))
        env.social.circleList = emptyList()
        assertNull("no circles yet: cannot judge, must not condemn", LocalMedia.opensForAnyCircle(ref))
    }

    // ---- serving a blob to a peer -----------------------------------------------------------------------

    @Test fun serving_decrypts_to_a_scratch_file_that_release_removes() {
        assertTrue(LocalMedia.writeRawSealed(ref, tag + plain))
        val s = LocalMedia.openForServing(ref)!!
        assertArrayEquals(plain, s.file.readBytes())
        assertTrue(s.file.exists())
        s.release()
        assertFalse("the scratch copy is deleted when the serve ends", s.file.exists())
    }

    @Test fun serving_refuses_a_blob_whose_plaintext_is_not_what_the_ref_names() {
        assertTrue(LocalMedia.writeRawSealed(ref, tag + ByteArray(1500) { 4 }))
        assertNull(LocalMedia.openForServing(ref))
        assertTrue("and leaves no plaintext behind", File(env.ctx.filesDir, "media-plain").listFiles().orEmpty().none { it.name.startsWith("serve-") })
    }

    @Test fun serving_a_legacy_unsealed_blob_reads_it_in_place_but_never_a_sealed_one_that_will_not_open() {
        assertTrue(LocalMedia.writeRawSealed(ref, plain))
        val s = LocalMedia.openForServing(ref)!!
        assertEquals(LocalMedia.rawSealed(ref)!!.size, s.file.readBytes().size)
        s.release()
        assertTrue("an in-place serve is not the store's file to delete", LocalMedia.has(ref))
        env.social.openFile = { _, _, _ -> false }
        assertTrue(LocalMedia.writeRawSealed(ref, tag + plain))
        assertNull(LocalMedia.openForServing(ref))
    }

    // ---- adopting a reassembled transfer -----------------------------------------------------------------

    private fun part(bytes: ByteArray) = File(env.ctx.filesDir, "incoming_x.part").apply { writeBytes(bytes) }

    @Test fun a_reassembled_plain_part_that_verifies_is_sealed_into_place() {
        val p = part(plain)
        assertTrue(LocalMedia.adoptPlainPart("default", ref, p))
        assertArrayEquals(tag + plain, LocalMedia.rawSealed(ref))
        assertFalse(p.exists())
    }

    @Test fun a_reassembled_part_that_does_not_account_for_the_ref_is_dropped_at_the_door() {
        val p = part(ByteArray(1500) { 1 })
        assertFalse(LocalMedia.adoptPlainPart("default", ref, p))
        assertFalse(LocalMedia.has(ref))
        assertFalse(p.exists())
    }

    @Test fun a_part_that_cannot_be_sealed_is_kept_as_verified_plaintext_rather_than_discarded() {
        env.social.sealFile = { _, _, _ -> false }
        assertTrue(LocalMedia.adoptPlainPart("default", ref, part(plain)))
        assertArrayEquals(plain, LocalMedia.rawSealed(ref))
    }

    @Test fun a_sealed_part_is_moved_into_place_and_an_empty_one_is_a_miss() {
        val sealed = File(env.ctx.filesDir, "incoming_s.part").apply { writeBytes(tag + plain) }
        assertTrue(LocalMedia.adoptSealedPart(ref, sealed))
        assertArrayEquals(tag + plain, LocalMedia.rawSealed(ref))
        assertFalse(LocalMedia.adoptSealedPart("img_" + "ff".repeat(32), File(env.ctx.filesDir, "empty.part").apply { writeBytes(ByteArray(0)) }))
    }

    @Test fun parts_are_written_by_position_so_nothing_but_one_chunk_is_in_ram() {
        val f = File(env.ctx.filesDir, "incoming_pos.part")
        assertTrue(LocalMedia.writePartAt(f, 4, byteArrayOf(9, 9)))
        assertTrue(LocalMedia.writePartAt(f, 0, byteArrayOf(1, 2, 3, 4)))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 9, 9), f.readBytes())
        assertFalse(LocalMedia.writePartAt(File("/nonexistent-dir/x.part"), 0, byteArrayOf(1)))
    }

    // ---- inventory ---------------------------------------------------------------------------------------

    @Test fun the_inventory_lists_stored_blobs_and_skips_in_flight_scratch() {
        LocalMedia.store("default", plain)
        val media = File(env.ctx.filesDir, "media")
        File(media, "incoming_a.part").writeBytes(byteArrayOf(1))
        File(media, "x.plain.tmp").writeBytes(byteArrayOf(1))
        File(media, ".hidden").writeBytes(byteArrayOf(1))
        val blobs = LocalMedia.storedBlobs()
        assertEquals("one stored blob, none of the scratch", 1, blobs.size)
        assertTrue(blobs.single().key.endsWith(sha(plain)))
        assertTrue(blobs.single().bytes > 0)
    }

    // ---- remembered pixel sizes --------------------------------------------------------------------------

    @Test fun pixel_sizes_banked_on_a_previous_run_answer_without_touching_the_media() {
        val sizeCache = LocalMedia::class.java.getDeclaredField("sizeCache").apply { isAccessible = true }.get(LocalMedia) as MutableMap<*, *>
        sizeCache.clear()
        LocalMedia::class.java.getDeclaredField("sizeMapLoaded").apply { isAccessible = true }.setBoolean(LocalMedia, false)
        File(env.ctx.filesDir, "media-sizes.txt").writeText("img_aa 640 480\nbad line\nimg_bb 0 10\nimg_cc 100 x\n")
        assertEquals(640 to 480, LocalMedia.cachedPixelSize("img_aa"))
        assertEquals(640f / 480f, LocalMedia.cachedAspect("img_aa")!!, 0.0001f)
        assertNull("a zero dimension is not a size", LocalMedia.cachedPixelSize("img_bb"))
        assertNull(LocalMedia.cachedPixelSize("img_cc"))
        assertEquals(640 to 480, LocalMedia.pixelSize("default", "img_aa"))
        LocalMedia.recordPixelSize("img_dd", 0, 5)
        assertNull("a bad probe cannot poison the map", LocalMedia.cachedPixelSize("img_dd"))
        sizeCache.clear()
    }
}
