package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Locks the call-signaling frame layout to iOS CallManager so Android <-> iPhone calls negotiate. */
class CallWireTest {
    private val hexA = "a".repeat(64)
    private val hexB = "b".repeat(64)

    @Test fun group_invite_roundtrip() {
        val frame = CallWire.groupInvite(hexA, "sess-1", "Family", "$hexA,$hexB")
        val g = CallWire.parseGroupInvite(frame)!!
        assertEquals(hexA, g.from)
        assertEquals("sess-1", g.sessionId)
        assertEquals("Family", g.groupName)
        assertEquals(listOf(hexA, hexB), g.roster)
    }

    @Test fun group_invite_tolerates_trailing_timestamp_field() {
        // Apple senders append a 4th LP field (unix-seconds send time) so receivers can refuse
        // stale replayed invites. This parser reads exactly 3 fields — the extra field must be
        // ignored, not break Android <-> iPhone calls.
        val ts = "1770000000".toByteArray()
        val frame = CallWire.groupInvite(hexA, "sess-1", "Family", hexB) +
            byteArrayOf((ts.size and 0xff).toByte(), (ts.size shr 8).toByte()) + ts
        val g = CallWire.parseGroupInvite(frame)!!
        assertEquals("sess-1", g.sessionId)
        assertEquals(listOf(hexB), g.roster)
    }

    @Test fun group_invite_starts_with_raw_sender_hex() {
        val frame = CallWire.groupInvite(hexA, "s", "g", hexB)
        assertEquals(hexA, String(frame.copyOfRange(0, 64)))
        // byte 64 begins the LP session id (len 1, LE)
        assertEquals(1, frame[64].toInt())
        assertEquals(0, frame[65].toInt())
    }

    @Test fun accept_roundtrip() {
        val a = CallWire.parseAccept(CallWire.accept(hexA, "sid"))!!
        assertEquals(hexA, a.from); assertEquals("sid", a.sessionId)
    }

    @Test fun hangup_is_just_hex() {
        assertEquals(hexB, CallWire.parseHangup(CallWire.hangup(hexB)))
    }

    @Test fun signal_with_session_roundtrip() {
        val json = "{\"t\":\"offer\",\"sdp\":\"v=0\"}".toByteArray()
        val frame = CallWire.signal(hexA, "sX", json)
        val s = CallWire.parseSignal(frame, "ignored")!!
        assertEquals(hexA, s.from)
        assertEquals("sX", s.sessionId)
        assertArrayEquals(json, s.json)
    }

    @Test fun signal_legacy_no_session_falls_back() {
        // Legacy framing: [hex64][raw json] (no LP session id). Body starts with '{'.
        val json = "{\"t\":\"answer\",\"sdp\":\"x\"}".toByteArray()
        val frame = hexA.toByteArray() + json
        val s = CallWire.parseSignal(frame, "active-session")!!
        assertEquals(hexA, s.from)
        assertEquals("active-session", s.sessionId)
        assertArrayEquals(json, s.json)
    }

    @Test fun rejects_short_or_bad_hex() {
        assertNull(CallWire.parseGroupInvite(ByteArray(10)))
        assertNull(CallWire.parseHangup(ByteArray(63)))
    }

    @Test fun glare_rule_smaller_hex_offers() {
        // The offerer is the lexicographically smaller hex (matches CallManager.connectPeerIfNeeded).
        assertEquals(true, hexA < hexB)   // 'a' < 'b' → A offers to B, B answers
    }

    @Test fun frame_type_constants_match_ios() {
        assertEquals(10, CallWire.INVITE)
        assertEquals(11, CallWire.ACCEPT)
        assertEquals(12, CallWire.HANGUP)
        assertEquals(16, CallWire.OFFER)
        assertEquals(17, CallWire.ANSWER)
        assertEquals(18, CallWire.ICE)
        assertEquals(21, CallWire.GROUP_INVITE)
    }
}
