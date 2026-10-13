package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import uniffi.haven_ffi.CircleInfoFfi

/**
 * The relay's `__live__` lane: call frames parked as `haven/mailbox/<circle>/__live__/<dest>/<hash>` when
 * the direct dial cannot reach the far end, and polled back out by the destination. Against the in-process
 * relay, so what is asserted is what actually crossed the HTTP wire.
 */
class HavenNetLiveLaneTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)
    private val peerDevice = "c4".repeat(32)

    @Before fun setUp() { env.up() }
    @After fun tearDown() { env.down() }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
    private fun upload(dests: List<String>, frame: ByteArray) = NetEnv.call("uploadLiveCallFrame", dests, frame)
    private fun poll() = NetEnv.call("pollLiveCallFrames") as Boolean
    private fun frame(type: Int, vararg body: Int) = byteArrayOf(type.toByte(), *body.map { it.toByte() }.toByteArray())

    // ---- upload ---------------------------------------------------------------------------------

    @Test fun a_frame_is_parked_under_the_default_circle_and_every_dm_for_each_destination() {
        env.social.circleList = listOf(CircleInfoFfi("dm:x-y", "dm", 2u), CircleInfoFfi("c1group", "Family", 3u))
        val f = frame(CallWire.INVITE, 1, 2, 3)
        upload(listOf(peer, peerDevice), f)
        val h = sha(f)
        val keys = env.relay.store.keys.toSet()
        assertEquals(setOf(
            "haven/mailbox/default/__live__/$peer/$h", "haven/mailbox/default/__live__/$peerDevice/$h",
            "haven/mailbox/dm:x-y/__live__/$peer/$h", "haven/mailbox/dm:x-y/__live__/$peerDevice/$h",
        ), keys)
        assertTrue("a group circle is not a call lane", keys.none { it.contains("c1group") })
        assertArrayEquals(f, env.relay.store["haven/mailbox/default/__live__/$peer/$h"])
    }

    @Test fun destinations_are_lowercased_deduplicated_and_must_be_full_node_ids() {
        val f = frame(CallWire.ACCEPT, 9)
        upload(listOf(peer.uppercase(), peer, "short", ""), f)
        assertEquals(listOf("haven/mailbox/default/__live__/$peer/${sha(f)}"), env.relay.store.keys.toList())
    }

    @Test fun nothing_is_sent_for_an_empty_frame_no_destination_or_a_not_ready_engine() {
        upload(listOf(peer), ByteArray(0))
        upload(emptyList(), frame(CallWire.INVITE, 1))
        upload(listOf("short"), frame(CallWire.INVITE, 1))
        NetEnv.field("ready").setBoolean(HavenNet, false)
        upload(listOf(peer), frame(CallWire.INVITE, 1))
        assertTrue(env.relay.hits.isEmpty())
    }

    @Test fun a_relay_that_refuses_us_is_noted_but_not_marked_unreachable() {
        env.relay.forceStatus = 403
        upload(listOf(peer), frame(CallWire.INVITE, 1))
        assertTrue(env.relay.store.isEmpty())
        val bad = NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>
        assertTrue("reachable and healthy, it just does not know us yet", bad.isEmpty())
    }

    @Test fun a_broken_relay_has_its_url_backed_off() {
        env.relay.forceStatus = 500
        upload(listOf(peer), frame(CallWire.INVITE, 1))
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
    }

    @Test fun a_relay_with_no_http_interface_is_skipped() {
        env.entries()[env.relayHex] = env.entries().getValue(env.relayHex).copy(httpToken = "")
        upload(listOf(peer), frame(CallWire.INVITE, 1))
        assertTrue(env.relay.hits.isEmpty())
    }

    @Test fun sending_a_call_frame_also_parks_it_on_the_relay_for_the_account_and_its_devices() {
        env.social.deviceIds[peer] = listOf(peerDevice)
        val latch = env.relay.latchForPuts(2)
        HavenNet.sendCallFrame(CallWire.OFFER, byteArrayOf(5, 6), peer)
        assertTrue(env.relay.awaitPuts(latch))
        val wire = Wire.frame(CallWire.OFFER, byteArrayOf(5, 6))
        assertEquals(setOf("haven/mailbox/default/__live__/$peer/${sha(wire)}", "haven/mailbox/default/__live__/$peerDevice/${sha(wire)}"),
            env.relay.store.keys.toSet())
    }

    // ---- poll -----------------------------------------------------------------------------------

    private fun park(who: String, type: Int, vararg body: Int, name: String = "k${env.relay.store.size}"): String {
        val key = "haven/mailbox/default/__live__/$who/$name"
        env.relay.store[key] = frame(type, *body)
        return key
    }

    private fun router(): CopyOnWriteArrayList<Pair<Int, List<Byte>>> {
        val got = CopyOnWriteArrayList<Pair<Int, List<Byte>>>()
        HavenNet.callRouter = { type, body -> got += type to body.toList() }
        return got
    }

    @Test fun frames_parked_for_my_account_and_my_device_are_handed_to_the_call_router_once() {
        val got = router()
        park(env.me, CallWire.INVITE, 1, 2)
        park(env.device, CallWire.ICE, 3)
        assertTrue(poll())
        assertEquals(setOf(CallWire.INVITE to listOf<Byte>(1, 2), CallWire.ICE to listOf<Byte>(3)), got.toSet())
        got.clear()
        assertFalse("the same frames are not delivered twice", poll())
        assertTrue(got.isEmpty())
    }

    @Test fun an_unchanged_listing_is_a_bodiless_204_that_costs_no_gets() {
        router()
        park(env.me, CallWire.HANGUP, 1)
        assertTrue(poll())
        env.relay.hits.clear()
        assertFalse(poll())
        assertTrue("the digest was echoed, so the relay answered 204 and nothing was fetched", env.relay.hits.none { it.method == "GET" && it.path.startsWith("/k/") })
    }

    @Test fun a_new_frame_after_a_quiet_poll_is_picked_up() {
        val got = router()
        park(env.me, CallWire.ACCEPT, 1)
        assertTrue(poll())
        park(env.me, CallWire.HANGUP, 2)
        assertTrue(poll())
        assertEquals(listOf(CallWire.ACCEPT, CallWire.HANGUP), got.map { it.first })
    }

    @Test fun only_call_frame_types_are_dispatched() {
        val got = router()
        park(env.me, Wire.MEDIA_CHUNK, 1)
        assertFalse("claimed but not a call frame", poll())
        assertTrue(got.isEmpty())
    }

    @Test fun an_empty_or_unfetchable_frame_is_skipped_without_stopping_the_sweep() {
        val got = router()
        env.relay.store["haven/mailbox/default/__live__/${env.me}/empty"] = ByteArray(0)
        val broken = park(env.me, CallWire.INVITE, 1, name = "broken")
        env.relay.getStatus[broken] = 500
        park(env.me, CallWire.CAMERA, 7, name = "good")
        assertTrue(poll())
        assertEquals(listOf(CallWire.CAMERA), got.map { it.first })
    }

    @Test fun a_refusing_relay_ends_the_sweep_quietly() {
        val got = router()
        park(env.me, CallWire.INVITE, 1)
        env.relay.forceStatus = 403
        assertFalse(poll())
        assertTrue(got.isEmpty())
        assertTrue("a refusal is not an outage", (NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).isEmpty())
    }

    @Test fun an_unreachable_relay_is_backed_off_and_not_retried_in_the_same_sweep() {
        router()
        env.relay.forceStatus = 500
        assertFalse(poll())
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
    }

    @Test fun dm_circles_have_their_own_live_lane() {
        val got = router()
        env.social.circleList = listOf(CircleInfoFfi("dm:a-b", "dm", 2u))
        env.relay.store["haven/mailbox/dm:a-b/__live__/${env.me}/x"] = frame(CallWire.GROUP_INVITE, 4)
        assertTrue(poll())
        assertEquals(listOf(CallWire.GROUP_INVITE), got.map { it.first })
    }

    @Test fun polling_before_the_engine_is_ready_does_nothing() {
        NetEnv.field("ready").setBoolean(HavenNet, false)
        park(env.me, CallWire.INVITE, 1)
        assertFalse(poll())
        assertTrue(env.relay.hits.isEmpty())
    }
}
