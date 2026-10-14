package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.FeedItemFfi
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The receive dispatcher: one frame in from the wire (direct, nearby, or unwrapped from a frame-9 relay hop), routed by
 * its type byte. Blocked senders are dropped before anything runs; call frames go to the call router; events go to
 * the engine and, when new, fan out to my other devices.
 */
class HavenNetInboundTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)
    private val dest2 = "d4".repeat(32)

    @Before fun setUp() {
        env.up()
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u))
        env.social.receiveFn = { _, _ -> true }
        env.social.exported = byteArrayOf(1)
        HavenNet.contacts.add(Contact(peer, "Pat", "v"))
        RosterEcho.clear()
    }
    @After fun tearDown() { env.down(); RosterEcho.clear() }

    private fun until(cond: () -> Boolean) = runBlocking { withTimeout(15_000) { while (!cond()) yield() } }
    private fun eventFrame(env: ByteArray, circle: String = "default") = Wire.frame(Wire.EVENT, Wire.eventPayload(circle, env))
    private fun pushes() = env.relay.hits.filter { it.method == "POST" && it.path == "/notify" }.map { JSONObject(String(it.body)) }
    private fun router(): CopyOnWriteArrayList<Pair<Int, List<Byte>>> {
        val got = CopyOnWriteArrayList<Pair<Int, List<Byte>>>()
        HavenNet.callRouter = { t, b -> got += t to b.toList() }
        return got
    }

    // ---- dispatch -----------------------------------------------------------------------------------

    @Test fun an_event_frame_reaches_the_engine_and_a_new_one_is_pushed_to_my_other_devices() {
        HavenNet.onInbound(eventFrame("live-event".toByteArray()), viaNearby = false)
        until { env.social.received.size == 1 }
        assertEquals("default", env.social.received[0].first)
        assertArrayEquals("live-event".toByteArray(), env.social.received[0].second)
        until { pushes().any { it.optString("nodeId") == env.me && it.optBoolean("silent") } }
    }

    @Test fun an_event_the_engine_already_had_changes_nothing_further() {
        env.social.receiveFn = { _, _ -> false }
        NetEnv.call("handleEvent", Wire.eventPayload("default", "dup".toByteArray()), null, false)
        assertEquals(1, env.social.received.size)
        assertTrue(env.relay.hits.isEmpty())
    }

    @Test fun a_roster_repeat_is_not_fanned_out_but_a_first_roster_is() {
        val roster = byteArrayOf(0x04, 1, 2, 3)
        val b64 = { b: ByteArray -> java.util.Base64.getEncoder().encodeToString(b) }
        NetEnv.call("handleEvent", Wire.eventPayload("default", roster), null, false)
        until { pushes().any { it.optString("event") == b64(roster) } }
        NetEnv.call("handleEvent", Wire.eventPayload("default", roster), null, false)   // the repeat
        NetEnv.call("handleEvent", Wire.eventPayload("default", "next".toByteArray()), null, false)
        until { pushes().any { it.optString("event") == b64("next".toByteArray()) } }
        assertEquals("the repeat was handled by the engine but pushed nowhere", 1, pushes().count { it.optString("event") == b64(roster) })
        assertEquals(3, env.social.received.size)
    }

    @Test fun a_malformed_event_is_dropped() {
        NetEnv.call("handleEvent", ByteArray(1), null, false)
        assertTrue(env.social.received.isEmpty())
    }

    @Test fun a_blocked_sender_is_dropped_before_any_work_and_an_empty_frame_is_ignored() {
        val got = router()
        HavenNet.blocked.add(peer)
        HavenNet.onInbound(Wire.frame(CallWire.INVITE, peer.toByteArray() + "Pat".toByteArray()), viaNearby = false)
        HavenNet.onInbound(ByteArray(0), viaNearby = false)
        HavenNet.blocked.clear()
        HavenNet.onInbound(Wire.frame(CallWire.INVITE, peer.toByteArray() + "Pat".toByteArray()), viaNearby = false)
        until { got.size == 1 }
        assertEquals("only the unblocked sender's frame was routed", 1, got.size)
    }

    @Test fun every_call_frame_type_goes_to_the_call_router() {
        val got = router()
        val types = listOf(CallWire.INVITE, CallWire.ACCEPT, CallWire.HANGUP, CallWire.OFFER, CallWire.ANSWER, CallWire.ICE,
            CallWire.GROUP_INVITE, CallWire.HANDLED_ELSEWHERE, CallWire.ENDED_ELSEWHERE, CallWire.CAMERA)
        for (t in types) HavenNet.onInbound(Wire.frame(t, peer.toByteArray() + byteArrayOf(1)), viaNearby = false)
        until { got.size == types.size }
        assertEquals(types.toSet(), got.map { it.first }.toSet())
    }

    @Test fun an_unknown_frame_type_is_ignored_without_harm() {
        HavenNet.onInbound(byteArrayOf(99, 1, 2), viaNearby = false)
        HavenNet.onInbound(eventFrame("after-unknown".toByteArray()), viaNearby = false)
        until { env.social.received.size == 1 }
    }

    // ---- frame 9: relay-forwarded frames -------------------------------------------------------------------

    private fun relayBody(msgId: Byte, ttl: Int, dests: List<String>, inner: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(ByteArray(16) { msgId }); out.write(ttl); out.write(dests.size)
        for (d in dests) out.write(HavenKeys.hexToBytes32(d)!!)
        out.write(inner)
        return out.toByteArray()
    }

    @Test fun a_forwarded_frame_addressed_to_me_is_unwrapped_and_handled_once() {
        val body = relayBody(1, 4, listOf(env.me, dest2), eventFrame("via-relay".toByteArray()))
        HavenNet.onInbound(Wire.frame(Wire.RELAY, body), viaNearby = false)
        until { env.social.received.size == 1 }
        HavenNet.onInbound(Wire.frame(Wire.RELAY, body), viaNearby = false)
        HavenNet.onInbound(eventFrame("sentinel".toByteArray()), viaNearby = false)
        until { env.social.received.size == 2 }
        assertEquals("the second copy of the same message id is loop protection, not new work",
            listOf("via-relay", "sentinel"), env.social.received.map { String(it.second) })
    }

    @Test fun a_forwarded_frame_addressed_to_my_device_id_is_handled_too() {
        HavenNet.onInbound(Wire.frame(Wire.RELAY, relayBody(2, 0, listOf(env.device), eventFrame("to-device".toByteArray()))), viaNearby = true)
        until { env.social.received.size == 1 }
    }

    @Test fun malformed_forwarded_frames_are_dropped() {
        HavenNet.onInbound(Wire.frame(Wire.RELAY, ByteArray(10)), viaNearby = false)
        val truncated = relayBody(3, 2, listOf(env.me), ByteArray(0)).copyOf(30)
        HavenNet.onInbound(Wire.frame(Wire.RELAY, truncated), viaNearby = false)
        HavenNet.onInbound(Wire.frame(Wire.RELAY, relayBody(4, 2, listOf(env.me), ByteArray(0))), viaNearby = false)
        HavenNet.onInbound(eventFrame("sentinel".toByteArray()), viaNearby = false)
        until { env.social.received.size == 1 }
        assertEquals("sentinel", String(env.social.received[0].second))
    }

    // ---- notifying -----------------------------------------------------------------------------------------

    private fun item(id: String, at: Long, mine: Boolean = false) =
        FeedItemFfi(id, peer.take(8), mine, at.toULong(), "body", emptyList(), null, false, false, false, false, emptyList(), emptyList(), null)

    @Test fun the_foreground_app_posts_no_notification() {
        env.social.feeds["default"] = listOf(item("n1", System.currentTimeMillis()))
        HavenNet.isForeground = true
        NetEnv.call("notifyInbound", "default")
        assertTrue("nothing was recorded, so the first real notification can still fire", NetEnv.call("markNotified", "default:n1") as Boolean)
    }

    @Test fun nothing_old_or_my_own_is_worth_a_banner_and_each_message_is_notified_once() {
        HavenNet.isForeground = false
        env.social.feeds["default"] = listOf(item("old", System.currentTimeMillis() - 3_600_000))
        NetEnv.call("notifyInbound", "default")
        assertTrue("an old message resurfacing is not news: nothing was recorded", NetEnv.call("markNotified", "default:old") as Boolean)
        env.social.feeds["default"] = listOf(item("mine", System.currentTimeMillis(), mine = true))
        NetEnv.call("notifyInbound", "default")
        assertTrue("my own message is not news either", NetEnv.call("markNotified", "default:mine") as Boolean)
        assertFalse("and the dedupe key is remembered", NetEnv.call("markNotified", "default:mine") as Boolean)
    }
}
