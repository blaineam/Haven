package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.OpenedCircleBlobFfi
import java.io.File

/**
 * The store-and-forward receive side: a mailbox poll over the relay's signed-HTTP lane, routing each
 * blob to the hello handler, the relay-announce handler or the engine, and marking a key seen only once
 * it has been consumed. The relay is an in-process server; the engine is [FakeSocial].
 */
class HavenNetMailboxPollTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)

    @Before fun setUp() {
        env.up()
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 1u))
        env.social.receiveFn = { _, _ -> true }
    }
    @After fun tearDown() { env.down() }

    private fun poll() = runBlocking { HavenNet.pollMailbox() }
    private fun put(circle: String, body: ByteArray): String =
        HavenKeys.mailboxKey(circle, body).also { env.relay.store[it] = body }
    private fun gets() = env.relay.hits.filter { it.method == "GET" && it.path.startsWith("/k/") }.map { java.net.URLDecoder.decode(it.path.removePrefix("/k/"), "UTF-8") }
    private val stateFile get() = File(env.ctx.filesDir, "haven_social_state_${env.me}.bin")

    // ---- content ----------------------------------------------------------------------------------

    @Test fun a_new_envelope_is_ingested_marked_seen_and_the_engine_state_is_saved() {
        env.social.exported = byteArrayOf(7, 7, 7)
        val body = "event-1".toByteArray()
        val key = put("default", body)
        poll()
        assertEquals(1, env.social.received.size)
        assertEquals("default", env.social.received[0].first)
        assertArrayEquals(body, env.social.received[0].second)
        assertTrue("seen only after the ingest landed", env.seen().contains(key))
        assertArrayEquals("the engine state is saved after an ingest, before the key is trusted", byteArrayOf(7, 7, 7), stateFile.readBytes())
    }

    @Test fun a_seen_key_is_not_fetched_again() {
        val key = put("default", "event-2".toByteArray())
        poll()
        env.relay.hits.clear()
        poll()
        assertFalse(gets().contains(key))
        assertEquals(1, env.social.received.size)
    }

    @Test fun a_duplicate_is_still_marked_seen_and_the_buffered_state_is_still_saved() {
        env.social.receiveFn = { _, _ -> false }   // the engine already has it / buffered it ahead of its key commit
        env.social.exported = byteArrayOf(9)
        val key = put("default", "dup".toByteArray())
        poll()
        assertTrue("re-fetching the same bytes forever is the failure this prevents", env.seen().contains(key))
        assertArrayEquals("an envelope buffered in pending_epoch must survive process death", byteArrayOf(9), stateFile.readBytes())
    }

    @Test fun a_broken_engine_does_not_stop_the_sweep() {
        env.social.receiveFn = { _, _ -> error("engine down") }
        val key = put("default", "boom".toByteArray())
        poll()
        assertTrue(env.seen().contains(key))
    }

    @Test fun live_call_frames_and_other_ids_hello_slots_are_left_alone() {
        env.relay.store["haven/mailbox/default/__live__/${env.me}/f1"] = byteArrayOf(CallWire.INVITE.toByte(), 1)
        val foreign = HavenKeys.helloMailboxKey("default", peer, env.me, byteArrayOf(1))
        env.relay.store[foreign] = byteArrayOf(1)
        poll()
        assertTrue("a hello for another id is not ours to claim, fetch or burn", gets().none { it == foreign })
        assertFalse(env.seen().contains(foreign))
        assertTrue(env.social.received.isEmpty())
    }

    @Test fun control_plane_keys_are_fetched_before_content() {
        val content = put("default", "content".toByteArray())
        val hello = HavenKeys.helloMailboxKey("default", env.me, peer, byteArrayOf(2)).also { env.relay.store[it] = byteArrayOf(2) }
        val relayKey = "haven/mailbox/default/__relay__/r1".also { env.relay.store[it] = byteArrayOf(3) }
        poll()
        val order = gets().filter { it == content || it == hello || it == relayKey }
        assertEquals(listOf(hello, relayKey, content), order)
    }

    @Test fun every_circle_the_engine_holds_is_read_from_every_active_relay() {
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 1u), CircleInfoFfi("c1other", "Family", 2u))
        put("c1other", "family-event".toByteArray())
        poll()
        assertEquals(listOf("c1other"), env.social.received.map { it.first })
    }

    @Test fun a_circle_bound_to_a_relay_is_read_from_it() {
        env.bindCircleRelay("c1bound")
        put("c1bound", "bound-event".toByteArray())
        poll()
        assertEquals(listOf("c1bound"), env.social.received.map { it.first })
    }

    @Test fun nothing_happens_before_the_engine_is_ready() {
        NetEnv.field("ready").setBoolean(HavenNet, false)
        put("default", "x".toByteArray())
        poll()
        assertTrue(env.relay.hits.isEmpty())
    }

    @Test fun concurrent_polls_coalesce_into_one_follow_up_sweep() {
        NetEnv.field("pollMailboxInFlight").let { (it.get(HavenNet) as java.util.concurrent.atomic.AtomicBoolean).set(true) }
        poll()
        assertTrue("a poll arriving mid-sweep is queued, not run", env.relay.hits.isEmpty())
        assertTrue((NetEnv.field("pollMailboxQueued").get(HavenNet) as java.util.concurrent.atomic.AtomicBoolean).get())
    }

    @Test fun a_moved_epoch_is_drained_from_the_engine() {
        env.social.epochMoved = listOf("default")
        poll()
        assertEquals("consumed, so it fires once per advance", emptyList<String>(), env.social.epochMoved)
    }

    @Test fun my_epoch_heads_are_published_once_per_launch() {
        env.social.epochHeads["default"] = listOf("head-1".toByteArray())
        poll()
        val key = HavenKeys.mailboxKey("default", "head-1".toByteArray())
        assertNotNull("the head went to the relay's mailbox", env.relay.store[key])
        env.relay.hits.clear()
        poll()
        assertTrue("and is not re-offered on the next sweep", env.relay.puts().isEmpty())
    }

    @Test fun a_relay_that_refuses_the_list_ends_that_circles_read_quietly() {
        env.relay.forceStatus = 403
        put("default", "x".toByteArray())
        poll()
        assertTrue(env.social.received.isEmpty())
    }

    @Test fun an_unreachable_relay_url_is_backed_off() {
        env.relay.forceStatus = 500
        poll()
        assertTrue((NetEnv.field("httpUrlBad").get(HavenNet) as Map<*, *>).containsKey(env.relay.base))
    }

    // ---- hello routing ----------------------------------------------------------------------------

    @Test fun a_malformed_hello_addressed_to_me_is_consumed_and_marked_seen() {
        val key = HavenKeys.helloMailboxKey("default", env.me, peer, byteArrayOf(1)).also { env.relay.store[it] = byteArrayOf(1) }
        poll()
        assertTrue(env.seen().contains(key))
    }

    @Test fun a_hello_addressed_to_my_device_id_is_claimed_too() {
        val key = HavenKeys.helloMailboxKey("default", env.device, peer, byteArrayOf(1)).also { env.relay.store[it] = byteArrayOf(1) }
        poll()
        assertTrue(env.seen().contains(key))
    }

    @Test fun a_stranger_hello_is_held_for_approval_and_its_slot_survives() {
        val bundle = ByteArray(40) { 0x21 }
        env.social.verifyHex = { "feed" }
        env.social.profileName = "Pat"
        val payload = Wire.helloPayload("default", "Home", bundle, byteArrayOf(5))
        val key = HavenKeys.helloMailboxKey("default", env.me, peer, payload).also { env.relay.store[it] = payload }
        poll()
        assertFalse("a held hello keeps its mailbox slot so the grant riding it is not lost", env.seen().contains(key))
        assertEquals(listOf(nodeHex(bundle)), HavenNet.pending.map { it.idHex })
        poll()
        assertTrue("and the next poll retries it", gets().count { it == key } == 2)
    }

    // ---- relay announces over the mailbox -------------------------------------------------------------

    @Test fun a_relay_announce_in_the_mailbox_teaches_the_relay_and_is_marked_seen() {
        val newRelay = "ee".repeat(32)
        env.social.openBlob = { _, sealed -> OpenedCircleBlobFfi(peer, sealed) }
        val body = Wire.eventPayload("default", newRelay.toByteArray())
        val key = "haven/mailbox/default/__relay__/ann".also { env.relay.store[it] = body }
        poll()
        assertTrue(env.seen().contains(key))
        assertTrue(env.entries().containsKey(newRelay))
    }
}
