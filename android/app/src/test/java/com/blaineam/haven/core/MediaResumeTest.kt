package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Locks the frame-33 (media RESUME request) wire format to the iOS byte layout
 * (apple/HavenApp/MediaReassembly.swift). A mismatch here doesn't fail loudly on the wire — it makes
 * a cross-platform resume ask for the WRONG chunks — so a failure here is a real regression.
 *
 * The hostile cases matter as much as the round-trips: every field in this frame is chosen by a peer,
 * and the frame is plaintext, so the parse is the only thing standing between a stranger and an
 * allocation sized by them.
 */
class MediaResumeTest {

    private val hex = "a".repeat(64)

    // ---- Bitmap ------------------------------------------------------------------------------

    @Test fun bitmap_bit_layout_is_ios_compatible() {
        // Bit i of byte i/8, LSB first: chunk 0 → 0x01, chunk 7 → 0x80, chunk 8 → next byte's 0x01.
        assertArrayEquals(byteArrayOf(0x01), MediaResume.bitmap(setOf(0), 1))
        assertArrayEquals(byteArrayOf(0x80.toByte()), MediaResume.bitmap(setOf(7), 8))
        assertArrayEquals(byteArrayOf(0x00, 0x01), MediaResume.bitmap(setOf(8), 9))
    }

    @Test fun bitmap_roundtrips_at_byte_boundaries() {
        for (total in intArrayOf(1, 7, 8, 9, 63, 64, 65, 1600, 1601)) {
            val got = (0 until total).filter { it % 3 == 0 }.toSet()
            val bits = MediaResume.bitmap(got, total)
            assertEquals("size for total=$total", (total + 7) / 8, bits.size)
            assertEquals("roundtrip for total=$total", got, MediaResume.indices(bits, total))
        }
    }

    @Test fun bitmap_ignores_out_of_range_indices() {
        // A bogus index must not throw or bleed into a neighbouring chunk's bit.
        assertArrayEquals(byteArrayOf(0x01), MediaResume.bitmap(setOf(-5, 0, 99), 1))
    }

    @Test fun bitmap_of_the_99_percent_case_asks_for_exactly_one_chunk() {
        // The failure this whole feature exists for: 1,599 of 1,600 chunks landed.
        val total = 1600
        val got = (0 until 1599).toSet()
        val decoded = MediaResume.decode(MediaResume.encode(hex, "vid_x", total, got))!!
        val missing = (0 until total).filterNot { it in MediaResume.indices(decoded.bitmap, total) }
        assertEquals(listOf(1599), missing)
    }

    // ---- Frame 33 round-trip -----------------------------------------------------------------

    @Test fun encode_matches_the_documented_byte_layout() {
        val body = MediaResume.encode(hex, "ab", 9, setOf(0, 8))
        assertEquals(64 + 2 + 2 + 4 + 2, body.size)
        assertEquals(hex, String(body.copyOfRange(0, 64)))
        assertArrayEquals(byteArrayOf(0x02, 0x00), body.copyOfRange(64, 66))   // u16 LE refLen
        assertEquals("ab", String(body.copyOfRange(66, 68)))
        assertArrayEquals(byteArrayOf(0x09, 0x00, 0x00, 0x00), body.copyOfRange(68, 72))   // u32 LE total
        assertArrayEquals(byteArrayOf(0x01, 0x01), body.copyOfRange(72, 74))   // bits 0 and 8
    }

    @Test fun decode_roundtrips_encode() {
        val got = setOf(0, 1, 5, 63, 64, 1599)
        val r = MediaResume.decode(MediaResume.encode(hex, "img_ref", 1600, got))!!
        assertEquals(hex, r.requesterHex)
        assertEquals("img_ref", r.ref)
        assertEquals(1600, r.total)
        assertEquals(got, MediaResume.indices(r.bitmap, r.total))
    }

    @Test fun decode_accepts_an_empty_bitmap() {
        // Legal on the wire even though the requester wouldn't normally send one.
        val r = MediaResume.decode(MediaResume.encode(hex, "r", 16, emptySet()))!!
        assertEquals(emptySet<Int>(), MediaResume.indices(r.bitmap, r.total))
    }

    // ---- Hostile input -----------------------------------------------------------------------

    @Test fun decode_rejects_empty_and_short_frames() {
        assertNull(MediaResume.decode(ByteArray(0)))
        assertNull(MediaResume.decode(ByteArray(65)))
        assertNull(MediaResume.decode(ByteArray(64 + 2)))   // header only, no ref/total
    }

    @Test fun decode_rejects_a_short_requester_hex() {
        val body = MediaResume.encode("b".repeat(32), "r", 8, setOf(0))
        assertNull(MediaResume.decode(body))
    }

    @Test fun decode_rejects_an_empty_ref() {
        assertNull(MediaResume.decode(MediaResume.encode(hex, "", 8, setOf(0))))
    }

    @Test fun decode_rejects_a_ref_length_overrunning_the_buffer() {
        val body = MediaResume.encode(hex, "r", 8, setOf(0))
        body[64] = 0xFF.toByte(); body[65] = 0xFF.toByte()   // claims a 65,535-byte ref
        assertNull(MediaResume.decode(body))
    }

    @Test fun decode_rejects_a_zero_total() {
        assertNull(MediaResume.decode(MediaResume.encode(hex, "r", 0, emptySet())))
    }

    @Test fun decode_rejects_an_absurd_total_without_allocating_for_it() {
        // 4.2 BILLION chunks. Kotlin reads that u32 into a NEGATIVE Int, so a naive `total <= MAX`
        // check would pass it straight through to a bitmap-sized allocation. It must be refused.
        val body = MediaResume.encode(hex, "r", 8, setOf(0))
        val head = body.copyOfRange(0, body.size - 1)   // drop the bitmap byte
        head[head.size - 4] = 0xFF.toByte(); head[head.size - 3] = 0xFF.toByte()
        head[head.size - 2] = 0xFF.toByte(); head[head.size - 1] = 0xFF.toByte()
        assertNull(MediaResume.decode(head))
        // And one just over the documented cap, where the sign bit isn't doing the work for us.
        val over = MediaResume.MAX_CHUNKS + 1
        val big = ByteArray(64 + 2 + 1 + 4 + (over + 7) / 8)
        hex.toByteArray().copyInto(big, 0)
        big[64] = 1; big[66] = 'r'.code.toByte()
        big[67] = (over and 0xFF).toByte(); big[68] = ((over ushr 8) and 0xFF).toByte()
        big[69] = ((over ushr 16) and 0xFF).toByte(); big[70] = ((over ushr 24) and 0xFF).toByte()
        assertNull(MediaResume.decode(big))
    }

    @Test fun decode_rejects_a_truncated_bitmap() {
        val body = MediaResume.encode(hex, "r", 1600, setOf(0))   // needs 200 bitmap bytes
        assertNull(MediaResume.decode(body.copyOfRange(0, body.size - 1)))
    }

    @Test fun decode_rejects_an_over_long_bitmap() {
        // Trailing junk is not tolerated: the bitmap must be EXACTLY the size the total implies, or a
        // peer can pad a small declared total with megabytes we'd otherwise hold.
        val body = MediaResume.encode(hex, "r", 8, setOf(0))
        assertNull(MediaResume.decode(body + ByteArray(1)))
        assertNull(MediaResume.decode(body + ByteArray(4096)))
    }

    @Test fun decode_rejects_a_bitmap_missing_entirely() {
        val body = MediaResume.encode(hex, "r", 8, setOf(0))
        assertNull(MediaResume.decode(body.copyOfRange(0, 64 + 2 + 1 + 4)))
    }

    @Test fun decode_accepts_the_maximum_declared_total() {
        // The cap itself must still parse — the bound is a ceiling, not an off-by-one rejection.
        val total = MediaResume.MAX_CHUNKS
        val body = MediaResume.encode(hex, "r", total, setOf(0, total - 1))
        val r = MediaResume.decode(body)
        assertNotNull(r)
        assertEquals(setOf(0, total - 1), MediaResume.indices(r!!.bitmap, total))
    }

    @Test fun resume_frame_type_is_33() {
        // The numbering MUST stay identical across Apple/Android/desktop.
        assertEquals(33, Wire.MEDIA_RESUME_REQ)
    }

    /**
     * A near-MAX_CHUNKS frame must decode to the RAW bitmap, never a pre-expanded index set — the
     * whole point of the raw return. Expanding 4M indices into boxed Integers here would be hundreds
     * of megabytes on a phone, spent on a ~500 KB frame, before we had checked we hold the ref at all.
     */
    @Test
    fun decodeDoesNotExpandAHugeBitmap() {
        val total = MediaResume.MAX_CHUNKS
        val body = MediaResume.encode("b".repeat(64), "vid_x", total, setOf(0, total - 1))
        val r = MediaResume.decode(body)
        assertNotNull(r)
        assertEquals(total, r!!.total)
        assertEquals(MediaResume.bitmapSize(total), r.bitmap.size)
    }
}
