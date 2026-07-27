package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the `/webrtc/hairpin` media frame format.
 *
 * This is a CROSS-PLATFORM CONTRACT, not an implementation detail: Apple, Android and desktop all
 * relay through the same proxy socket, and the proxy bipipes bytes without interpreting them. If any
 * one platform's framing drifts, media between it and the others silently fails to decode — which is
 * exactly what happened to desktop, which shipped BARE PCM for its whole life. Apple's unpack
 * rejected every desktop frame as malformed while desktop played Apple's 7 header bytes as audio
 * samples, so the fallback that exists to rescue a call when ICE cannot pair worked only between two
 * desktops, and nobody noticed because both failures are silent.
 *
 * The expected byte layouts below are written out literally rather than derived from `pack`, so this
 * test fails if the format changes even if pack and unpack change together and stay self-consistent.
 */
class HairpinFrameTest {

    @Test
    fun packsTheSevenByteHeaderExactly() {
        val payload = byteArrayOf(0x11, 0x22, 0x33)
        val frame = HairpinFrame.pack(HairpinFrame.TYPE_AUDIO, seq = 0x0102, ptsMs = 0x03040506, payload = payload)
        assertArrayEquals(
            byteArrayOf(
                1,                    // type
                0x01, 0x02,           // seq, big-endian
                0x03, 0x04, 0x05, 0x06, // ptsMs, big-endian
                0x11, 0x22, 0x33,     // payload
            ),
            frame,
        )
    }

    @Test
    fun roundTripsTypeSeqAndPayload() {
        for (type in listOf(HairpinFrame.TYPE_AUDIO, HairpinFrame.TYPE_VIDEO_KEY, HairpinFrame.TYPE_VIDEO_DELTA)) {
            val payload = ByteArray(64) { (it * 3).toByte() }
            val (t, seq, out) = HairpinFrame.unpack(HairpinFrame.pack(type, 4242, 7, payload))!!
            assertEquals(type, t)
            assertEquals(4242, seq)
            assertArrayEquals(payload, out)
        }
    }

    /** Sequence numbers wrap at 16 bits on every platform; 0xFFFF must survive the round trip. */
    @Test
    fun carriesTheFullSixteenBitSequence() {
        val (_, seq, _) = HairpinFrame.unpack(
            HairpinFrame.pack(HairpinFrame.TYPE_AUDIO, 0xFFFF, 0, ByteArray(2)))!!
        assertEquals(0xFFFF, seq)
    }

    /** An empty payload is legal framing — a header-only frame must not be mistaken for a short read. */
    @Test
    fun acceptsAHeaderOnlyFrame() {
        val parsed = HairpinFrame.unpack(HairpinFrame.pack(HairpinFrame.TYPE_AUDIO, 1, 0, ByteArray(0)))
        assertEquals(0, parsed!!.third.size)
    }

    @Test
    fun rejectsAShortRead() {
        assertNull(HairpinFrame.unpack(ByteArray(HairpinFrame.HEADER_BYTES - 1) { 1 }))
    }

    /**
     * The desktop regression, encoded. Raw 16-bit PCM starts with a sample byte, not a frame type,
     * so it must be REJECTED rather than parsed as audio — otherwise a peer on an older build feeds
     * us samples that we hand to the decoder as if they were a header plus payload.
     */
    @Test
    fun rejectsBarePcm() {
        // A quiet-ish PCM run: no byte here is a valid type (1, 2 or 3).
        val pcm = byteArrayOf(0x40, 0x1F, 0x50, 0x2F, 0x60, 0x3F, 0x70, 0x4F)
        assertNull(HairpinFrame.unpack(pcm))
    }

    @Test
    fun rejectsAnUnknownType() {
        val frame = HairpinFrame.pack(HairpinFrame.TYPE_AUDIO, 1, 0, ByteArray(4))
        frame[0] = 9
        assertNull(HairpinFrame.unpack(frame))
    }
}
