package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Locks the wire format to the iOS FeedStore byte layout. If any of these change, Android ↔
 * iPhone interop is broken — so a failure here is a real regression, not a flaky test.
 */
class WireTest {

    @Test fun frame_prepends_type_byte() {
        val f = Wire.frame(Wire.EVENT, byteArrayOf(9, 8, 7))
        assertArrayEquals(byteArrayOf(1, 9, 8, 7), f)
    }

    @Test fun lp_is_u16_little_endian() {
        val out = ArrayList<Byte>()
        Wire.lpAppend(out, byteArrayOf(0xAA.toByte(), 0xBB.toByte()))
        // len=2 → 0x02 0x00 (LE), then the two bytes.
        assertArrayEquals(byteArrayOf(0x02, 0x00, 0xAA.toByte(), 0xBB.toByte()), out.toByteArray())
    }

    @Test fun lp_roundtrip_multi_field() {
        val out = ArrayList<Byte>()
        Wire.lpAppend(out, "hello".toByteArray())
        Wire.lpAppend(out, "world!!".toByteArray())
        val r = Wire.Reader(out.toByteArray())
        assertEquals("hello", String(r.lp()!!))
        assertEquals("world!!", String(r.lp()!!))
        assertNull(r.lp())
    }

    @Test fun hello_exact_bytes_match_ios_layout() {
        // circleId="default", circleName="My Circle", bundle=32 zero bytes, profile="P"
        val bundle = ByteArray(32) { 0 }
        val payload = Wire.helloPayload("default", "My Circle", bundle, "P".toByteArray())
        val expected = ArrayList<Byte>().apply {
            // [u16 LE 7]["default"]
            add(7); add(0); addAll("default".toByteArray().toList())
            // [u16 LE 9]["My Circle"]
            add(9); add(0); addAll("My Circle".toByteArray().toList())
            // [u16 LE 32][32 x 0x00]
            add(32); add(0); repeat(32) { add(0) }
            // signed profile (raw, no LP)
            add('P'.code.toByte())
        }.toByteArray()
        assertArrayEquals(expected, payload)
    }

    @Test fun hello_roundtrip() {
        val bundle = ByteArray(40) { (it + 1).toByte() }
        val profile = byteArrayOf(1, 2, 3, 4, 5)
        val payload = Wire.helloPayload("dm:abc", "Chat", bundle, profile)
        val h = Wire.parseHello(payload)!!
        assertEquals("dm:abc", h.circleId)
        assertEquals("Chat", h.circleName)
        assertArrayEquals(bundle, h.bundle)
        assertArrayEquals(profile, h.signedProfile)
    }

    @Test fun hello_rejects_short_bundle() {
        // A bundle under 32 bytes must be rejected (iOS guards `bundle.count >= 32`).
        val payload = Wire.helloPayload("default", "c", ByteArray(10), ByteArray(0))
        assertNull(Wire.parseHello(payload))
    }

    @Test fun event_roundtrip() {
        val env = ByteArray(100) { (it % 7).toByte() }
        val payload = Wire.eventPayload("default", env)
        val e = Wire.parseEvent(payload)!!
        assertEquals("default", e.circleId)
        assertArrayEquals(env, e.envelope)
    }

    @Test fun truncated_lp_returns_null() {
        // claims len 5 but only 2 bytes follow
        val bad = byteArrayOf(5, 0, 1, 2)
        assertNull(Wire.Reader(bad).lp())
    }

    @Test fun frame_type_constants_match_ios() {
        // Guard against accidental renumbering.
        assertEquals(0, Wire.HELLO)
        assertEquals(1, Wire.EVENT)
        assertEquals(9, Wire.RELAY)
        assertEquals(16, Wire.SDP_OFFER)
        assertEquals(17, Wire.SDP_ANSWER)
        assertEquals(18, Wire.ICE)
        // The web client's two frames: the same numbers on the desktop (core `wire.rs`) and iOS.
        assertEquals(37, Wire.RELAY_INTERFACE)
        assertEquals(38, Wire.PAIR_OFFER)
        assertTrue(true)
    }
}
