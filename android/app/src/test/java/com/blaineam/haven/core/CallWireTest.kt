package com.blaineam.haven.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Locks the call-signaling frame layout to iOS CallManager so Android <-> iPhone calls negotiate. */
class CallWireTest {
    private val hexA = "a".repeat(64)
    private val hexB = "b".repeat(64)

    @Test fun group_invite_roundtrip() {
        val frame = CallWire.groupInvite(hexA, "sess-1", "Family", "$hexA,$hexB", sentAtSecs = 1_770_000_000L)
        val g = CallWire.parseGroupInvite(frame)!!
        assertEquals(hexA, g.from)
        assertEquals("sess-1", g.sessionId)
        assertEquals("Family", g.groupName)
        assertEquals(listOf(hexA, hexB), g.roster)
        assertEquals(1_770_000_000L, g.sentAt)
    }

    @Test fun group_invite_tolerates_trailing_timestamp_field() {
        // Senders append a 4th LP field (unix-seconds send time) so receivers can refuse stale
        // replayed invites. The builder now emits it itself; the parser must surface it, and any
        // FUTURE unknown 5th field must still be ignored, not break Android <-> iPhone calls.
        val frame = CallWire.groupInvite(hexA, "sess-1", "Family", hexB, sentAtSecs = 1_770_000_000L)
        val extra = "future-field".toByteArray()
        val withExtra = frame + byteArrayOf((extra.size and 0xff).toByte(), (extra.size shr 8).toByte()) + extra
        val g = CallWire.parseGroupInvite(withExtra)!!
        assertEquals("sess-1", g.sessionId)
        assertEquals(listOf(hexB), g.roster)
        assertEquals(1_770_000_000L, g.sentAt)
    }

    @Test fun group_invite_without_timestamp_parses_with_null_sent_at() {
        // A frame from an OLDER sender (3 fields, no timestamp) must still parse; sentAt is null
        // so the receiver never treats it as stale.
        val out = ArrayList<Byte>()
        hexA.toByteArray().forEach { out.add(it) }
        Wire.lpAppend(out, "sess-1".toByteArray())
        Wire.lpAppend(out, "Family".toByteArray())
        Wire.lpAppend(out, hexB.toByteArray())
        val g = CallWire.parseGroupInvite(out.toByteArray())!!
        assertEquals("sess-1", g.sessionId)
        assertNull(g.sentAt)
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

    // A hangup NAMES its session now (frame 12 took the shape of accept), because a retransmitted or
    // relay-delayed BYE from a call that already ended used to tear down whatever call was running.
    // parseHangup still reads only the leading hex, so an old reader is unaffected — assert both:
    // the sender survives the round-trip, and the session really is on the wire.
    @Test fun hangup_carries_sender_and_session() {
        val frame = CallWire.hangup(hexB, "sid")
        assertEquals(hexB, CallWire.parseHangup(frame))
        assertEquals("sid", CallWire.parseAccept(frame)!!.sessionId)
    }

    // A BYE from a call that ALREADY ENDED must not touch the call running now. Hangups are
    // retransmitted and relays replay them, so the previous call's BYE routinely lands a second or
    // two into the next one — on the QA fleet it killed a fresh incoming ring 0.9s in, tombstoned
    // that session, and every invite retransmit after it was dropped: the phone simply never rang.
    @Test fun stale_hangup_does_not_apply_to_the_live_session() {
        val bye = CallWire.hangup(hexB, "ended-session")
        assertFalse(CallWire.hangupAppliesTo(bye, "live-session"))
        // The trap that hid this: a hangup body has no JSON after the session id, so parseSignal
        // always takes its legacy branch and hands back the FALLBACK — our own live session. A gate
        // built on that compares the live session with itself and lets every stale frame through.
        assertEquals("live-session", CallWire.parseSignal(bye, "live-session")!!.sessionId)
    }

    @Test fun hangup_for_the_live_session_applies() {
        assertTrue(CallWire.hangupAppliesTo(CallWire.hangup(hexB, "live-session"), "live-session"))
    }

    @Test fun legacy_hangup_without_a_session_still_applies() {
        // Senders that predate the session id send the bare hex — gating must not silence them.
        assertTrue(CallWire.hangupAppliesTo(hexB.toByteArray(), "live-session"))
        assertFalse(CallWire.hangupAppliesTo(ByteArray(63), "live-session"))   // not even a sender
    }

    @Test fun hangup_applies_to_nothing_when_we_are_in_no_call() {
        assertFalse(CallWire.hangupAppliesTo(CallWire.hangup(hexB, "some-session"), ""))
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
