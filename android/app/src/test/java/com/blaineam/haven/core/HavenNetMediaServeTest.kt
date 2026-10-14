package com.blaineam.haven.core

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import uniffi.haven_ffi.CircleInfoFfi
import uniffi.haven_ffi.FeedItemFfi
import uniffi.haven_ffi.LinkConstraint
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/**
 * Answering a friend who asks this device for media (frames 3 / 33): the relay is the media path, so a friend is pointed at
 * a relay that holds the blob (or told when our pending upload lands) instead of being streamed sealed chunks from a phone.
 * Streaming happens only when no relay can carry it. The decision itself is [HeavyWorkPolicy]'s; what is asserted is what
 * this device then does about it.
 */
class HavenNetMediaServeTest {
    private val env = NetEnv()
    private val peer = "c3".repeat(32)
    private val plain = ByteArray(70_000) { (it * 17 % 251).toByte() }   // three 32 KB chunks
    private val tag = "HVE1".toByteArray()
    private lateinit var ref: String

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
    private fun until(cond: () -> Boolean) = runBlocking { withTimeout(15_000) { while (!cond()) yield() } }
    private fun lane() { (CallManager::class.java.getDeclaredField("sendLane").apply { isAccessible = true }.get(CallManager) as ExecutorService).submit {}.get(10, TimeUnit.SECONDS) }
    private fun sealedTypes() = env.social.sealedCalls.map { it.second.toInt() to it.first }
    private fun request(requester: String = peer, r: String = ref) =
        NetEnv.call("handleMediaRequest", requester.toByteArray() + r.toByteArray())

    private fun setUp(withRelay: Boolean) {
        env.up(withRelay)
        env.social.circleList = listOf(CircleInfoFfi("default", "Home", 2u))
        env.social.members["default"] = listOf(peer)
        env.social.sealMedia = { _, d -> tag + d }
        env.social.sealCall = { _, _, d -> byteArrayOf(9) + d }
        env.social.sealPeer = { _, d -> byteArrayOf(7) + d }
        env.social.openFile = { _, s, o ->
            val b = File(s).readBytes()
            if (b.size >= 4 && b.copyOf(4).contentEquals(tag)) { File(o).writeBytes(b.copyOfRange(4, b.size)); true } else false
        }
        ref = "img_" + sha(plain)
        env.social.feeds["default"] = listOf(
            FeedItemFfi("p1", "aaaaaaaa", true, 1uL, "hi", listOf(ref), null, false, false, false, false, emptyList(), emptyList(), null))
        HavenNet.contacts.add(Contact(peer, "Pat", "v"))
        assertTrue(LocalMedia.writeRawSealed(ref, tag + plain))
    }
    @After fun tearDown() { LowDataMonitor.debugForced = null; env.down() }

    @Test fun a_friend_asking_for_a_blob_a_relay_holds_is_pointed_at_the_relay_not_streamed_to() {
        setUp(withRelay = true)
        NetEnv.call("markBackedUp", env.relayHex, ref)
        request()
        until { sealedTypes().contains(Wire.MEDIA_AVAILABLE to peer) }
        assertTrue("nothing was streamed", env.social.sealedPeer.isEmpty())
    }

    @Test fun a_friend_asking_when_our_upload_is_still_pending_is_told_when_it_lands() {
        setUp(withRelay = true)
        env.relay.forceStatus = 500   // the pending upload cannot land on its own while the test inspects the wait list
        NetEnv.call("addPendingBackup", ref, "default")
        request()
        until { (NetEnv.field("hintOnUpload").get(HavenNet) as Map<*, *>).containsKey(ref) }
        assertTrue(env.social.sealedPeer.isEmpty())
        NetEnv.call("mediaBackupLanded", ref, "default")
        lane()
        assertTrue("answered the moment the upload lands", sealedTypes().contains(Wire.MEDIA_AVAILABLE to peer))
    }

    @Test fun with_no_relay_for_the_circle_the_blob_is_streamed_in_chunks() {
        setUp(withRelay = false)
        request()
        until { env.social.sealedPeer.size == 3 }
        assertEquals(listOf(32 * 1024, 32 * 1024, 70_000 - 64 * 1024), env.social.sealedPeer.map { it.second })
        assertTrue(env.social.sealedPeer.all { it.first == peer })
    }

    @Test fun a_second_ask_during_the_same_window_does_not_start_another_serve() {
        setUp(withRelay = false)
        request()
        until { env.social.sealedPeer.size == 3 }
        assertFalse("the 25 s per-ref limit: a waiting requester re-asks every cycle and must not stack serves",
            NetEnv.call("shouldServeNearby", ref) as Boolean)
        request()
        lane()
    }

    @Test fun a_resume_request_streams_only_the_chunks_the_requester_still_lacks() {
        setUp(withRelay = false)
        val body = MediaResume.encode(peer, ref, 3, setOf(0, 2))
        NetEnv.call("handleMediaResumeRequest", body)
        until { env.social.sealedPeer.isNotEmpty() }
        assertEquals("only the hole at index 1", listOf(32 * 1024), env.social.sealedPeer.map { it.second })
    }

    @Test fun a_resume_request_that_has_every_chunk_streams_nothing() {
        setUp(withRelay = false)
        NetEnv.call("handleMediaResumeRequest", MediaResume.encode(peer, ref, 3, setOf(0, 1, 2)))
        lane()
        assertTrue(env.social.sealedPeer.isEmpty())
    }

    @Test fun a_resume_for_a_different_total_is_answered_with_everything() {
        setUp(withRelay = false)
        NetEnv.call("handleMediaResumeRequest", MediaResume.encode(peer, ref, 9, setOf(0)))
        until { env.social.sealedPeer.size == 3 }
    }

    @Test fun asks_for_media_we_do_not_hold_or_with_malformed_bodies_are_ignored() {
        setUp(withRelay = false)
        request(r = "img_" + "ee".repeat(32))
        request(requester = "short")
        NetEnv.call("handleMediaRequest", ByteArray(10))
        NetEnv.call("handleMediaResumeRequest", ByteArray(5))
        NetEnv.call("handleMediaResumeRequest", MediaResume.encode(peer, "img_" + "ee".repeat(32), 3, emptySet()))
        lane()
        assertTrue(env.social.sealedPeer.isEmpty())
        assertTrue(env.social.sealedCalls.isEmpty())
    }

    @Test fun an_ultra_constrained_link_refuses_to_serve_anything_that_may_not_cross_it() {
        setUp(withRelay = false)
        LowDataMonitor.debugForced = LinkConstraint.ULTRA
        request()
        NetEnv.call("handleMediaResumeRequest", MediaResume.encode(peer, ref, 3, emptySet()))
        lane()
        assertTrue(env.social.sealedPeer.isEmpty())
        assertFalse(LocalMedia.maySendOnUltraConstrained(ref))
    }

    @Test fun a_ref_asked_about_is_resolved_to_its_circle_once_and_remembered() {
        setUp(withRelay = true)
        assertEquals("default", NetEnv.call("circleOfRef", ref))
        env.social.feeds["default"] = emptyList()
        assertEquals("answered from the cache, not a second feed walk", "default", NetEnv.call("circleOfRef", ref))
        assertNull(NetEnv.call("circleOfRef", "img_" + "dd".repeat(32)))
    }
}
