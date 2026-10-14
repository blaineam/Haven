package com.blaineam.haven.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.webrtc.FakePeerConnection
import org.webrtc.FakePeerConnectionFactory
import org.webrtc.FakeRtp
import org.webrtc.IceCandidate
import org.webrtc.PeerConnection
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit

/**
 * The mesh half of the call manager, against a fake WebRTC factory: answering builds one peer connection per participant,
 * the smaller hex offers, signalling frames are sealed and sent as they are produced and routed to the right peer when they
 * arrive, ICE state moves the call between connecting and connected, and a participant dropping out ends the call only when
 * nobody is left. Camera, screen capture and the hairpin media relay need real devices and are not part of this.
 */
@Suppress("UNCHECKED_CAST")
class CallManagerMeshTest {
    private val env = NetEnv()
    private val high = "c3".repeat(32)    // larger than my hex: I offer to them
    private val low = "05".repeat(32)     // smaller than my hex: they offer to me
    private val third = "e7".repeat(32)
    private val cm = CallManager::class.java
    private val factory = FakePeerConnectionFactory.make()
    private val sid = "mesh-0001"

    private fun f(name: String) = cm.getDeclaredField(name).apply { isAccessible = true }
    private fun invoke(name: String, vararg args: Any?): Any? {
        val m = cm.declaredMethods.first { it.name == name && it.parameterCount == args.size }.apply { isAccessible = true }
        return try { m.invoke(CallManager, *args) } catch (e: java.lang.reflect.InvocationTargetException) { throw e.targetException }
    }
    private fun handle(type: Int, body: ByteArray?) = invoke("handle", type, body)
    private fun handler() = f("callHandler").get(CallManager)
    private fun drain() { handler().javaClass.getMethod("drain").invoke(handler()) }
    private fun drainAll() { handler().javaClass.getMethod("drainAll").invoke(handler()) }
    private fun lane() { (f("sendLane").get(CallManager) as ExecutorService).submit {}.get(10, TimeUnit.SECONDS) }
    private fun sent() = env.social.sealedCalls.map { it.second.toInt() to it.first }
    private fun pcs(): List<FakePeerConnection> = factory.made

    private fun invite(from: String, roster: List<String>) =
        CallWire.groupInvite(from, sid, "Mesh call", roster.joinToString(","), System.currentTimeMillis() / 1000)

    private fun ringAndAnswer(from: String = high, roster: List<String> = listOf(from, env.me)) {
        handle(CallWire.GROUP_INVITE, invite(from, roster))
        CallManager.accept()
        drain(); lane()
    }

    @Before fun setUp() {
        env.up()
        env.social.sealCall = { _, _, d -> byteArrayOf(9) + d }
        f("appContext").set(CallManager, env.ctx)
        f("myHex").set(CallManager, env.me)
        f("factory").set(CallManager, factory)
        for (h in listOf(high, low, third)) HavenNet.contacts.add(Contact(h, "P$h".take(6), "v"))
        reset()
    }
    @After fun tearDown() {
        reset()
        f("factory").set(CallManager, null)
        env.down()
    }

    private fun reset() {
        invoke("teardown")
        drainAll()
        (f("endedSessions").get(CallManager) as MutableMap<String, Long>).clear()
        f("mediaStarted").setBoolean(CallManager, false)
        f("audioTrack").set(CallManager, null)
        f("lastPeerSeenMs").setLong(CallManager, 0L)
        CallManager.micOn.value = true; CallManager.cameraOn.value = false
        env.social.sealedCalls.clear()
        factory.made.clear()
    }

    // ---- starting the mesh ---------------------------------------------------------------------------

    @Test fun answering_builds_a_peer_per_participant_and_the_smaller_hex_makes_the_offer() {
        ringAndAnswer()
        assertTrue(CallManager.inCall.value)
        assertEquals(1, pcs().size)
        assertTrue("I am the smaller hex: I offer", pcs()[0].log.contains("createOffer"))
        assertTrue(sent().contains(CallWire.OFFER to high))
        assertTrue("my camera state is announced up front so they show my avatar, not black frames", sent().contains(CallWire.CAMERA to high))
        assertTrue(sent().contains(CallWire.ACCEPT to high))
        assertEquals(listOf(high), CallManager.participants.toList())
        assertEquals(PeerConnection.SdpSemantics.UNIFIED_PLAN, pcs()[0].config.sdpSemantics)
    }

    @Test fun the_larger_hex_waits_to_be_offered_to() {
        ringAndAnswer(from = low)
        assertFalse(pcs()[0].log.contains("createOffer"))
        assertTrue(sent().none { it.first == CallWire.OFFER })
    }

    @Test fun my_mic_state_follows_the_toggle_into_the_audio_track() {
        ringAndAnswer()
        val track = f("audioTrack").get(CallManager) as FakeRtp.FakeAudioTrack
        assertTrue(track.enabled)
        CallManager.toggleMic(); drain()
        assertFalse(track.enabled)
        CallManager.setNativeAudioSuspendedForHairpin(true); drain()
        assertFalse(track.enabled)
        CallManager.toggleMic(); drain()
        assertFalse("still suspended: WebRTC's dead audio stays silent while the relay owns the mic", track.enabled)
        CallManager.setNativeAudioSuspendedForHairpin(false); drain()
        assertTrue(track.enabled)
    }

    // ---- signalling in ---------------------------------------------------------------------------------

    private fun signal(from: String, type: Int, json: ByteArray) = handle(type, CallWire.signal(from, sid, json))

    @Test fun a_remote_offer_is_answered_and_the_answer_is_sealed_back() {
        ringAndAnswer(from = low)
        signal(low, CallWire.OFFER, CallSignal.encodeSdp("offer", "v=0 remote"))
        lane()
        assertTrue(pcs()[0].log.contains("setRemote OFFER v=0 remote"))
        assertTrue(sent().contains(CallWire.ANSWER to low))
    }

    @Test fun a_remote_answer_and_candidates_reach_the_right_peers_connection() {
        ringAndAnswer()
        signal(high, CallWire.ANSWER, CallSignal.encodeSdp("answer", "v=0 answer"))
        assertTrue(pcs()[0].log.contains("setRemote ANSWER v=0 answer"))
        signal(high, CallWire.ICE, CallSignal.encodeCandidate("candidate:7", 0, "0"))
        assertEquals(listOf("candidate:7"), pcs()[0].candidates.map { it.sdp })
    }

    @Test fun my_own_candidates_are_sealed_and_sent_as_they_are_gathered() {
        ringAndAnswer()
        pcs()[0].observer.onIceCandidate(IceCandidate("0", 0, "candidate:9"))
        lane()
        assertTrue(sent().contains(CallWire.ICE to high))
    }

    @Test fun a_signal_for_an_unknown_peer_or_a_malformed_body_is_dropped() {
        ringAndAnswer()
        handle(CallWire.OFFER, byteArrayOf(1, 2, 3))
        signal(high, CallWire.OFFER, "not json".toByteArray())
        signal(high, CallWire.ANSWER, "not json".toByteArray())
        signal(high, CallWire.ICE, "not json".toByteArray())
        assertEquals(1, pcs().size)
        assertEquals(0, pcs()[0].log.count { it.startsWith("setRemote") })
    }

    // ---- ICE state -----------------------------------------------------------------------------------------

    @Test fun placing_a_call_invites_dials_and_goes_in_call_only_on_the_peers_accept() {
        CallManager.startCall(listOf(high), "Pat"); drain(); lane()
        assertTrue(CallManager.connecting.value)
        assertFalse(CallManager.inCall.value)
        assertTrue(sent().contains(CallWire.GROUP_INVITE to high))
        assertTrue("dialled at once, alongside the invite", sent().contains(CallWire.OFFER to high))
        pcs()[0].observer.onIceConnectionChange(PeerConnection.IceConnectionState.CONNECTED); drain()
        assertFalse("transport is up", CallManager.connecting.value)
        assertFalse("but nobody has answered: early media does not answer the call", CallManager.inCall.value)
        handle(CallWire.ACCEPT, CallWire.accept(high, CallManager.qaSessionId))
        assertTrue(CallManager.inCall.value)
        lane()
        assertEquals("the accept re-offers, healing a lost first offer", 2, sent().count { it == CallWire.OFFER to high })
    }

    @Test fun an_accept_from_the_wrong_session_or_a_stranger_does_not_connect_the_call() {
        CallManager.startCall(listOf(high), "Pat"); drain()
        handle(CallWire.ACCEPT, CallWire.accept(high, "another-session"))
        handle(CallWire.ACCEPT, CallWire.accept("e5".repeat(32), CallManager.qaSessionId))
        assertFalse(CallManager.inCall.value)
        assertTrue(CallManager.connecting.value)
    }

    @Test fun ice_connected_clears_connecting_and_a_failed_ice_without_a_hairpin_target_does_not_crash_the_state() {
        ringAndAnswer()
        CallManager.connecting.value = true
        pcs()[0].observer.onIceConnectionChange(PeerConnection.IceConnectionState.CONNECTED)
        drain()
        assertFalse(CallManager.connecting.value)
        assertTrue(CallManager.inCall.value)
        pcs()[0].observer.onIceConnectionChange(PeerConnection.IceConnectionState.COMPLETED)
        drain()
        assertTrue(CallManager.inCall.value)
    }

    @Test fun ice_closed_for_the_only_participant_ends_the_call() {
        ringAndAnswer()
        pcs()[0].observer.onIceConnectionChange(PeerConnection.IceConnectionState.CLOSED)
        drain()
        assertFalse(CallManager.inCall.value)
        assertEquals(1, pcs()[0].disposeCount)
    }

    @Test fun an_ice_disconnect_gets_a_grace_period_and_then_drops_the_peer() {
        ringAndAnswer()
        pcs()[0].observer.onIceConnectionChange(PeerConnection.IceConnectionState.DISCONNECTED)
        drain()
        assertTrue("a transient blip: still in the call during the grace period", CallManager.inCall.value)
        // The direct path never came up, which would also start the hairpin race; mark it as already relaying so only the
        // disconnect grace runs (the relay bridge needs real codecs).
        (f("hairpinPeers").get(CallManager) as MutableSet<String>).add(high)
        handler().javaClass.getMethod("drainDelayed").invoke(handler())
        assertFalse(CallManager.inCall.value)
    }

    @Test fun a_recovered_ice_during_the_grace_period_is_remembered_as_the_last_state() {
        ringAndAnswer()
        pcs()[0].observer.onIceConnectionChange(PeerConnection.IceConnectionState.CHECKING)
        drain()
        val lastIce = f("lastIce").get(CallManager) as Map<String, PeerConnection.IceConnectionState>
        assertEquals(PeerConnection.IceConnectionState.CHECKING, lastIce[high])
    }

    // ---- groups ---------------------------------------------------------------------------------------------

    @Test fun a_participant_joining_an_established_call_gets_a_connection_of_their_own() {
        ringAndAnswer(roster = listOf(high, env.me))
        handle(CallWire.GROUP_INVITE, invite(high, listOf(high, third, env.me)))
        drain(); lane()
        assertEquals(2, pcs().size)
        assertEquals(setOf(high, third), CallManager.participants.toSet())
        assertTrue("I am smaller than e7.. too: I offer to them", sent().contains(CallWire.OFFER to third))
    }

    @Test fun adding_someone_to_a_live_call_dials_them_and_invites_everyone() {
        ringAndAnswer()
        env.social.sealedCalls.clear()
        CallManager.addToCall(listOf(third)); drain(); lane()
        assertEquals(2, pcs().size)
        assertTrue(sent().contains(CallWire.GROUP_INVITE to high))
        assertTrue(sent().contains(CallWire.GROUP_INVITE to third))
    }

    @Test fun one_participant_leaving_a_group_call_closes_only_their_connection() {
        ringAndAnswer(roster = listOf(high, low, env.me))
        assertEquals(2, pcs().size)
        handle(CallWire.HANGUP, CallWire.hangup(high, sid))
        assertTrue(CallManager.inCall.value)
        assertEquals(listOf(low), CallManager.participants.toList())
        assertEquals(1, pcs().count { it.disposeCount == 1 })
    }

    @Test fun in_a_group_the_active_speaker_is_the_loudest_remote_after_two_consecutive_polls() {
        ringAndAnswer(roster = listOf(high, low, env.me))
        fun level(type: String, v: Double) = RTCStats(0, type, "$type-$v", hashMapOf<String, Any>("kind" to "audio", "audioLevel" to v))
        pcs()[0].stats = RTCStatsReport(0, mapOf("i" to level("inbound-rtp", 0.05)))
        pcs()[1].stats = RTCStatsReport(0, mapOf("i" to level("inbound-rtp", 0.5)))
        val loudest = (f("peers").get(CallManager) as Map<String, *>).keys.toList()
        invoke("pollAudioLevels"); drain()
        assertNull("one poll is a blip", CallManager.activeSpeaker.value)
        invoke("pollAudioLevels"); drain()
        assertNotNull(CallManager.activeSpeaker.value)
        assertTrue(loudest.contains(CallManager.activeSpeaker.value))
    }

    // ---- ending ------------------------------------------------------------------------------------------------

    @Test fun hanging_up_closes_every_connection_and_clears_the_media_state() {
        ringAndAnswer(roster = listOf(high, low, env.me))
        CallManager.hangup(); drain()
        assertFalse(CallManager.inCall.value)
        assertTrue(pcs().all { it.disposeCount == 1 })
        assertTrue(CallManager.participants.isEmpty())
        assertFalse(f("mediaStarted").getBoolean(CallManager))
        assertSame(null, CallManager.localVideo)
    }

    @Test fun the_camera_toggle_announces_my_state_to_everyone_even_when_no_camera_exists() {
        ringAndAnswer()
        env.social.sealedCalls.clear()
        CallManager.toggleCamera(); drain(); lane()
        assertTrue(CallManager.cameraOn.value)
        assertTrue("the far end swaps to my avatar instead of freezing", sent().contains(CallWire.CAMERA to high))
        CallManager.toggleCamera(); drain(); lane()
        assertFalse(CallManager.cameraOn.value)
    }
}
