package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The hairpin media bridge's decisions that need no codec: which inbound relay frames count as "heard from" a peer, how long
 * a relayed peer has been silent, and the shallow jitter buffer that reorders audio. The microphone, speaker and the video
 * codecs are Android hardware and are not reachable from a JVM test.
 */
class CallMediaBridgeLogicTest {
    private val bridge = CallMediaBridge::class.java
    private val peer = "c3".repeat(32)

    private fun field(n: String) = bridge.getDeclaredField(n).apply { isAccessible = true }
    @Suppress("UNCHECKED_CAST") private val active get() = field("activePeers").get(CallMediaBridge) as MutableSet<String>
    @Suppress("UNCHECKED_CAST") private val lastInbound get() = field("lastInboundAt").get(CallMediaBridge) as MutableMap<String, Long>
    private fun ingest(remote: String, frame: ByteArray) {
        val m = bridge.getDeclaredMethod("ingest", String::class.java, ByteArray::class.java).apply { isAccessible = true }
        try { m.invoke(CallMediaBridge, remote, frame) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }

    @Before fun setUp() { active.clear(); lastInbound.clear() }
    @After fun tearDown() { active.clear(); lastInbound.clear() }

    // ---- who is being relayed ---------------------------------------------------------------------

    @Test fun nobody_is_relayed_until_a_peer_is_activated() {
        assertFalse(CallMediaBridge.anyRelaying())
        assertFalse(CallMediaBridge.isRelaying(peer))
        assertNull(CallMediaBridge.silenceSecs(peer))
        assertNull(CallMediaBridge.remoteVideoTrack(peer))
        active.add(peer)
        assertTrue(CallMediaBridge.anyRelaying())
        assertTrue(CallMediaBridge.isRelaying(peer))
    }

    @Test fun silence_is_only_reported_for_a_relayed_peer_we_have_heard_from() {
        assertNull("not relayed", CallMediaBridge.silenceSecs(peer))
        active.add(peer)
        assertNull("relayed but never heard", CallMediaBridge.silenceSecs(peer))
        lastInbound[peer] = System.currentTimeMillis() - 25_000
        val s = CallMediaBridge.silenceSecs(peer)!!
        assertTrue("about 25 s of silence, got $s", s in 24..27)
        active.clear()
        assertNull(CallMediaBridge.silenceSecs(peer))
    }

    // ---- inbound frames ---------------------------------------------------------------------------

    private fun audio(seq: Int) = HairpinFrame.pack(HairpinFrame.TYPE_AUDIO, seq, 0, ByteArray(640))

    @Test fun an_audio_frame_from_a_relayed_peer_stamps_its_liveness() {
        active.add(peer)
        ingest(peer, audio(1))
        assertTrue(System.currentTimeMillis() - lastInbound.getValue(peer) < 5_000)
        assertEquals(0L, CallMediaBridge.silenceSecs(peer))
    }

    @Test fun a_frame_from_a_peer_that_is_not_relayed_is_ignored() {
        ingest(peer, audio(1))
        assertTrue(lastInbound.isEmpty())
    }

    @Test fun a_frame_that_is_not_ours_is_dropped_without_stamping_liveness() {
        active.add(peer)
        ingest(peer, ByteArray(3))
        ingest(peer, byteArrayOf(0x55, 0, 1, 0, 0, 0, 0, 9))   // unknown type byte: bare PCM looks like this
        assertTrue(lastInbound.isEmpty())
    }

    @Test fun video_frames_are_accepted_but_wait_for_a_decoder() {
        active.add(peer)
        ingest(peer, HairpinFrame.pack(HairpinFrame.TYPE_VIDEO_KEY, 1, 40, byteArrayOf(0, 0, 0, 1, 0x65)))
        ingest(peer, HairpinFrame.pack(HairpinFrame.TYPE_VIDEO_DELTA, 2, 80, byteArrayOf(0, 0, 0, 1, 0x41)))
        assertTrue("both counted as the peer being alive", lastInbound.containsKey(peer))
        assertNull("no decoder was ever created for it", CallMediaBridge.remoteVideoTrack(peer))
    }

    @Test fun stopping_with_nothing_relayed_is_a_safe_no_op_and_clears_the_hook() {
        CallHairpin.onBinary = { _, _ -> }
        CallMediaBridge.stopAll()
        assertNull(CallHairpin.onBinary)
        CallMediaBridge.deactivate(peer)   // never activated: nothing to undo
        assertFalse(CallMediaBridge.anyRelaying())
    }

    // ---- mute holds on the relayed path ---------------------------------------------------------------

    @Test fun a_muted_microphone_sends_no_audio_over_the_relay_and_an_open_one_sends_the_packed_frame() {
        val payload = ByteArray(640) { 3 }
        assertNull("muting has to hold where the audio never touches WebRTC", CallMediaBridge.micFrame(7, payload, micOn = false))
        val frame = CallMediaBridge.micFrame(7, payload, micOn = true)!!
        val (type, seq, body) = HairpinFrame.unpack(frame)!!
        assertEquals(HairpinFrame.TYPE_AUDIO, type); assertEquals(7, seq); assertTrue(body.contentEquals(payload))
    }

    // ---- the jitter buffer ----------------------------------------------------------------------------

    private fun jitter(): Any {
        val c = Class.forName("com.blaineam.haven.core.CallMediaBridge\$JitterBuffer")
        return c.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
    }
    @Suppress("UNCHECKED_CAST")
    private fun Any.push(seq: Int, tag: Int): List<Int> {
        val m = javaClass.getDeclaredMethod("push", Int::class.javaPrimitiveType, ByteArray::class.java).apply { isAccessible = true }
        return (m.invoke(this, seq, byteArrayOf(tag.toByte())) as List<ByteArray>).map { it[0].toInt() }
    }
    private fun Any.reset() { javaClass.getDeclaredMethod("reset").apply { isAccessible = true }.invoke(this) }

    @Test fun the_jitter_buffer_waits_for_a_small_window_then_plays_in_order() {
        val j = jitter()
        assertEquals(emptyList<Int>(), j.push(10, 10))
        assertEquals(emptyList<Int>(), j.push(12, 12))
        assertEquals("the third frame fills the window and the run plays out in sequence", listOf(10, 11, 12), j.push(11, 11))
    }

    @Test fun late_frames_are_reordered_before_playout() {
        val j = jitter()
        j.push(1, 1); j.push(3, 3)
        val out = j.push(2, 2)
        assertEquals(listOf(1, 2, 3), out)
        assertEquals("then it streams one at a time", listOf(4), j.push(4, 4))
    }

    @Test fun the_sequence_wraps_at_16_bits_mid_stream() {
        val j = jitter()
        j.push(0xFFFD, 1); j.push(0xFFFE, 2)
        assertEquals(listOf(1, 2, 3), j.push(0xFFFF, 3))
        assertEquals("65535 is followed by 0, not stuck behind it", listOf(4), j.push(0, 4))
        assertEquals(listOf(5), j.push(1, 5))
    }

    @Test fun playout_that_starts_just_before_the_16_bit_wrap_begins_at_the_oldest_frame_not_the_smallest_number() {
        val j = jitter()
        j.push(0xFFFE, 1); j.push(0xFFFF, 2)
        // The window fills as the counter wraps. Frames 65534 and 65535 are OLDER than 0; starting at the
        // numerically smallest key would play 0 first and strand those two behind it for good.
        assertEquals(listOf(1, 2, 3), j.push(0, 3))
        assertEquals(listOf(4), j.push(1, 4))
    }

    @Test fun a_gap_that_never_fills_does_not_stall_playout_forever() {
        val j = jitter()
        j.push(1, 1); j.push(2, 2)
        assertEquals(listOf(1, 2, 3), j.push(3, 3))   // streaming; next is 4, which is lost along with 5
        for (s in 6..12) assertEquals("held while it might still fill: $s", emptyList<Int>(), j.push(s, s))
        // Past twice the window the buffer gives up on 4 and 5 and skips to the oldest frame it holds.
        assertEquals((6..13).toList(), j.push(13, 13))
    }

    @Test fun resetting_drops_everything_held() {
        val j = jitter()
        j.push(5, 5); j.push(6, 6)
        j.reset()
        assertEquals("a fresh start waits for its own window", emptyList<Int>(), j.push(100, 1))
    }
}
