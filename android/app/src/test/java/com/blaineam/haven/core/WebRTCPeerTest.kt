package com.blaineam.haven.core

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
import org.webrtc.VideoTrack

/**
 * One pairwise WebRTC connection's negotiation logic (perfect negotiation, as on Apple): who offers, what happens on glare,
 * how an answer that raced its offer or a candidate that raced its description is held, and how the screen-share and remote
 * track routing behave. The peer connection itself is a fake that models only the signalling state machine, so every
 * ordering below is one a real signalling thread can produce.
 */
class WebRTCPeerTest {
    private val factory = FakePeerConnectionFactory.make()
    private val sdps = ArrayList<Pair<String, String>>()
    private val ice = ArrayList<Triple<String, Int, String?>>()
    private var cameraTrack: VideoTrack? = null
    private var screenTrack: VideoTrack? = null
    private var screenEnded = 0
    private val iceStates = ArrayList<PeerConnection.IceConnectionState>()

    private fun peer(polite: Boolean = false, localVideo: VideoTrack? = null): WebRTCPeer =
        WebRTCPeer(
            peerHex = "c3".repeat(32), factory = factory, iceServers = emptyList(), localAudio = null, localVideo = localVideo,
            onLocalSdp = { t, s -> sdps += t to s },
            onLocalIce = { c, i, m -> ice += Triple(c, i, m) },
            onRemoteVideo = { cameraTrack = it },
            onRemoteScreen = { screenTrack = it },
            onRemoteScreenEnded = { screenEnded++ },
            onIceState = { iceStates += it },
            polite = polite,
        )
    private val pc: FakePeerConnection get() = factory.made.last()

    @Before fun setUp() { sdps.clear(); ice.clear() }

    // ---- offering ---------------------------------------------------------------------------------

    @Test fun making_an_offer_creates_applies_and_reports_it() {
        val p = peer()
        p.makeOffer()
        assertEquals(listOf("createOffer", "setLocal OFFER"), pc.log)
        assertEquals(listOf("offer" to "offer-sdp-1"), sdps)
        assertEquals(PeerConnection.SignalingState.HAVE_LOCAL_OFFER, pc.state)
    }

    @Test fun an_answer_completes_the_exchange_and_flushes_candidates_that_arrived_early() {
        val p = peer()
        p.addRemoteCandidate("cand-1", 0, "0")
        p.addRemoteCandidate("cand-2", 1, null)
        assertTrue("held until a remote description exists", pc.candidates.isEmpty())
        p.makeOffer()
        p.onRemoteAnswer("remote-answer")
        assertTrue(p.remoteSet)
        assertEquals(PeerConnection.SignalingState.STABLE, pc.state)
        assertEquals(listOf("cand-1", "cand-2"), pc.candidates.map { it.sdp })
        p.addRemoteCandidate("cand-3", 0, "0")
        assertEquals("and later ones go straight in", 3, pc.candidates.size)
    }

    @Test fun an_answer_that_races_the_local_offer_is_queued_until_the_offer_is_set() {
        val p = peer()
        pc.autoRun = false
        p.makeOffer()                        // createOffer in flight
        p.onRemoteAnswer("early-answer")     // arrives before setLocalDescription(offer) finished
        assertFalse("not applied yet: that would be a wrong-state call", pc.log.any { it.startsWith("setRemote") })
        pc.pump()                            // create -> set local -> (queued answer applies)
        assertTrue(pc.log.any { it == "setRemote ANSWER early-answer" })
        assertEquals(PeerConnection.SignalingState.STABLE, pc.state)
    }

    @Test fun a_stale_answer_redelivered_while_stable_is_ignored() {
        val p = peer()
        p.onRemoteAnswer("stale")
        assertTrue(pc.log.none { it.startsWith("setRemote") })
        assertFalse(p.remoteSet)
    }

    @Test fun a_second_offer_is_deferred_while_one_is_being_made_and_runs_after() {
        val p = peer()
        pc.autoRun = false
        p.makeOffer()
        p.makeOffer()
        assertEquals("the second waited", 1, pc.log.count { it == "createOffer" })
        pc.pump()
        p.onRemoteAnswer("answer")
        pc.pump()
        assertEquals("and ran once signalling was stable again", 2, pc.log.count { it == "createOffer" })
    }

    // ---- being offered ----------------------------------------------------------------------------------

    @Test fun a_remote_offer_is_answered_and_the_answer_reported() {
        val p = peer()
        p.onRemoteOffer("their-offer")
        assertEquals(listOf("setRemote OFFER their-offer", "createAnswer", "setLocal ANSWER"), pc.log)
        assertEquals(listOf("answer" to "answer-sdp-1"), sdps)
        assertTrue(p.remoteSet)
        assertEquals(PeerConnection.SignalingState.STABLE, pc.state)
    }

    @Test fun glare_makes_the_impolite_side_keep_its_offer() {
        val p = peer(polite = false)
        p.makeOffer()
        p.onRemoteOffer("colliding")
        assertTrue(pc.log.none { it.startsWith("setRemote OFFER") })
        assertEquals(PeerConnection.SignalingState.HAVE_LOCAL_OFFER, pc.state)
    }

    @Test fun glare_makes_the_polite_side_roll_back_answer_and_re_offer() {
        val p = peer(polite = true)
        p.makeOffer()
        p.onRemoteOffer("colliding")
        assertTrue(pc.log.contains("setLocal ROLLBACK"))
        assertTrue("it answers theirs", pc.log.contains("setRemote OFFER colliding"))
        assertEquals("answer" to "answer-sdp-2", sdps.last())
        assertEquals("and then re-offers what it wanted to announce", 2, pc.log.count { it == "createOffer" })
    }

    @Test fun an_offer_wanted_while_answering_waits_for_stable() {
        val p = peer()
        pc.autoRun = false
        p.onRemoteOffer("their-offer")
        pc.pumpOne()                         // remote offer applied: HAVE_REMOTE_OFFER
        p.makeOffer()
        assertEquals("deferred: setLocal(offer) now would orphan the answer", 0, pc.log.count { it == "createOffer" })
        pc.pump()
        assertEquals(1, pc.log.count { it == "createOffer" })
    }

    // ---- candidates out ----------------------------------------------------------------------------------

    @Test fun local_candidates_and_ice_state_changes_are_passed_up() {
        peer()
        pc.observer.onIceCandidate(IceCandidate("0", 0, "candidate:1"))
        assertEquals(Triple("candidate:1", 0, "0" as String?), ice.single())
        pc.observer.onIceConnectionChange(PeerConnection.IceConnectionState.FAILED)
        pc.observer.onIceConnectionChange(PeerConnection.IceConnectionState.CONNECTED)
        pc.observer.onConnectionChange(PeerConnection.PeerConnectionState.CONNECTED)
        assertEquals(listOf(PeerConnection.IceConnectionState.FAILED, PeerConnection.IceConnectionState.CONNECTED), iceStates)
    }

    // ---- remote tracks ------------------------------------------------------------------------------------

    @Test fun a_remote_camera_track_and_a_remote_screen_track_land_in_different_tiles() {
        peer()
        val cam = FakeRtp.videoTrack("camera0")
        pc.observer.onAddTrack(FakeRtp.receiver("r1", cam), FakeRtp.streams("haven"))
        assertSame(cam, cameraTrack)
        val screen = FakeRtp.videoTrack(WebRTCPeer.SCREEN_TRACK_ID)
        pc.observer.onAddTrack(FakeRtp.receiver("r2", screen), FakeRtp.streams(ScreenSharePolicy.STREAM_ID))
        assertSame(screen, screenTrack)
        pc.observer.onAddTrack(FakeRtp.receiver("r3", null), FakeRtp.streams("haven"))   // audio / no video track: nothing to route
        assertSame(cam, cameraTrack)
    }

    @Test fun removing_the_screen_receiver_clears_the_screen_tile_but_removing_the_camera_does_not() {
        peer()
        val screen = FakeRtp.videoTrack(WebRTCPeer.SCREEN_TRACK_ID)
        val rs = FakeRtp.receiver("r2", screen)
        pc.observer.onAddTrack(rs, FakeRtp.streams(ScreenSharePolicy.STREAM_ID))
        val cam = FakeRtp.videoTrack("camera0")
        val rc = FakeRtp.receiver("r1", cam)
        pc.observer.onAddTrack(rc, FakeRtp.streams("haven"))
        pc.observer.onRemoveTrack(rc)
        assertEquals(0, screenEnded)
        pc.observer.onRemoveTrack(rs)
        assertEquals(1, screenEnded)
        pc.observer.onRemoveTrack(FakeRtp.receiver("gone", null))   // a track-less removal is a screen ending too
        assertEquals(2, screenEnded)
    }

    // ---- screen share --------------------------------------------------------------------------------------

    @Test fun sharing_my_screen_adds_a_capped_sender_once_and_renegotiates() {
        val p = peer()
        pc.nextSender = FakeRtp.sender()
        val screen = FakeRtp.videoTrack(WebRTCPeer.SCREEN_TRACK_ID)
        p.addScreenTrack(screen)
        assertTrue(pc.log.any { it.startsWith("addTrack ${WebRTCPeer.SCREEN_TRACK_ID}") })
        val enc = (pc.nextSender.parameters).encodings.single()
        assertEquals(ScreenSharePolicy.MAX_BITRATE_BPS, enc.maxBitrateBps)
        assertEquals(ScreenSharePolicy.FPS, enc.maxFramerate)
        assertEquals("a renegotiation offer went out", 1, pc.log.count { it == "createOffer" })
        p.addScreenTrack(screen)
        assertEquals("a second share while sharing is ignored", 1, pc.log.count { it.startsWith("addTrack") })
    }

    @Test fun a_screen_track_added_without_renegotiating_rides_the_next_negotiation() {
        val p = peer()
        pc.nextSender = FakeRtp.sender()
        p.addScreenTrack(FakeRtp.videoTrack(WebRTCPeer.SCREEN_TRACK_ID), renegotiate = false)
        assertEquals(0, pc.log.count { it == "createOffer" })
        p.onRemoteOffer("their-offer")
        assertEquals("answered, then re-offered with the screen on it", 1, pc.log.count { it == "createOffer" })
    }

    @Test fun a_sender_the_engine_refuses_to_cap_is_still_shared() {
        val p = peer()
        pc.nextSender = FakeRtp.sender().also { it.accepted = false }
        p.addScreenTrack(FakeRtp.videoTrack(WebRTCPeer.SCREEN_TRACK_ID))
        assertNotNull(QaStats.shareSenderParamsOk)
        assertFalse(QaStats.shareSenderParamsOk!!)
        QaStats.shareSenderParamsOk = null
    }

    @Test fun when_the_engine_gives_no_sender_nothing_is_shared() {
        val p = peer()
        pc.nextSender = null
        p.addScreenTrack(FakeRtp.videoTrack(WebRTCPeer.SCREEN_TRACK_ID))
        assertEquals(0, pc.log.count { it == "createOffer" })
    }

    @Test fun stopping_the_share_removes_the_sender_and_renegotiates() {
        val p = peer()
        p.removeScreenTrack()                                  // not sharing: nothing
        assertEquals(0, pc.log.count { it == "removeTrack" })
        pc.nextSender = FakeRtp.sender()
        p.addScreenTrack(FakeRtp.videoTrack(WebRTCPeer.SCREEN_TRACK_ID))
        p.onRemoteAnswer("a")
        p.removeScreenTrack()
        assertEquals(1, pc.log.count { it == "removeTrack" })
        assertEquals(2, pc.log.count { it == "createOffer" })
    }

    @Test fun local_tracks_are_added_with_the_haven_stream_id() {
        peer(localVideo = FakeRtp.videoTrack("camera0"))
        assertEquals(listOf("addTrack camera0 [haven]"), pc.log)
    }

    // ---- stats and lifetime ---------------------------------------------------------------------------------

    @Test fun audio_levels_are_the_loudest_inbound_and_outbound_audio_stats() {
        val p = peer()
        fun stat(type: String, kind: String, level: Double?) =
            RTCStats(0, type, "$type-$kind-$level", HashMap<String, Any>().apply { put("kind", kind); level?.let { put("audioLevel", it) } })
        pc.stats = RTCStatsReport(0, mapOf(
            "a" to stat("inbound-rtp", "audio", 0.2), "b" to stat("inbound-rtp", "audio", 0.6),
            "c" to stat("media-source", "audio", 0.4), "d" to stat("inbound-rtp", "video", 0.9),
            "e" to stat("inbound-rtp", "audio", null), "f" to stat("codec", "audio", 0.99),
        ))
        var got: Pair<Double, Double>? = null
        p.audioLevels { i, o -> got = i to o }
        assertEquals(0.6 to 0.4, got)
    }

    @Test fun an_unavailable_stats_report_reads_as_silence() {
        val p = peer()
        pc.failStats = true
        var got: Pair<Double, Double>? = null
        p.audioLevels { i, o -> got = i to o }
        assertEquals(0.0 to 0.0, got)
    }

    @Test fun a_peer_whose_connection_could_not_be_created_is_inert() {
        factory.refuse = true
        val p = peer()
        p.makeOffer(); p.onRemoteOffer("x"); p.onRemoteAnswer("y"); p.addRemoteCandidate("c", 0, null); p.removeScreenTrack()
        var got: Pair<Double, Double>? = null
        p.audioLevels { i, o -> got = i to o }
        assertEquals(0.0 to 0.0, got)
        assertNull(factory.made.lastOrNull())
        p.close()
    }

    @Test fun closing_twice_disposes_the_native_connection_once() {
        val p = peer()
        p.close(); p.close()
        assertEquals(1, pc.disposeCount)
    }
}
