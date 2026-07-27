package com.blaineam.haven.core

import android.util.Log
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack

/**
 * One pairwise WebRTC connection to a single mesh participant. DTLS-SRTP encrypts the media; SDP
 * and ICE are exchanged out-of-band over Haven's sealed channel (frames 16/17/18). The local
 * audio/video tracks are shared by CallManager across all peers.
 */
class WebRTCPeer(
    val peerHex: String,
    private val factory: PeerConnectionFactory,
    iceServers: List<PeerConnection.IceServer>,
    localAudio: AudioTrack?,
    localVideo: VideoTrack?,
    private val onLocalSdp: (type: String, sdp: String) -> Unit,
    private val onLocalIce: (candidate: String, mLineIndex: Int, mid: String?) -> Unit,
    private val onRemoteVideo: (VideoTrack?) -> Unit,
    private val onRemoteScreen: (VideoTrack?) -> Unit = {},
    private val onRemoteScreenEnded: () -> Unit = {},
    /** ICE lifecycle for this peer. Drives the hairpin media relay: `FAILED` means WebRTC could not
     *  pair us, and on Android that used to be the end of the call — nothing watched this at all. */
    private val onIceState: (PeerConnection.IceConnectionState) -> Unit = {},
) {
    private var screenSender: org.webrtc.RtpSender? = null

    /** Route an incoming video track: the second video track (`screen0`) is a screen share; the rest
     *  is the camera. Same id contract iOS uses, so the platforms interop. */
    private fun routeRemote(t: VideoTrack) {
        if (t.id() == SCREEN_TRACK_ID) onRemoteScreen(t) else onRemoteVideo(t)
    }
    private val pendingRemote = ArrayList<IceCandidate>()
    /** Answer that arrived before setLocalDescription(offer) finished — apply once local is set. */
    private var pendingAnswerSdp: String? = null
    private var localOfferSet = false
    var remoteSet = false; private set

    private val pc: PeerConnection? = factory.createPeerConnection(
        PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        },
        object : PeerConnection.Observer {
            override fun onIceCandidate(c: IceCandidate) = onLocalIce(c.sdp, c.sdpMLineIndex, c.sdpMid)
            override fun onTrack(transceiver: org.webrtc.RtpTransceiver) {
                (transceiver.receiver.track() as? VideoTrack)?.let { routeRemote(it) }
            }
            override fun onAddTrack(receiver: RtpReceiver, streams: Array<out MediaStream>) {
                (receiver.track() as? VideoTrack)?.let { routeRemote(it) }
            }
            override fun onRemoveTrack(receiver: RtpReceiver) {
                // Mid-call the only track ever removed is the peer's screen share (camera/audio stay),
                // so a removal clears the remote screen tile (no stuck last frame).
                if ((receiver.track() as? VideoTrack)?.id() == SCREEN_TRACK_ID || receiver.track() == null) {
                    onRemoteScreenEnded()
                }
            }
            override fun onIceConnectionChange(s: PeerConnection.IceConnectionState) {
                Log.d(TAG, "$peerHex ice=$s")
                onIceState(s)
            }
            override fun onConnectionChange(s: PeerConnection.PeerConnectionState) { Log.d(TAG, "$peerHex pc=$s") }
            override fun onSignalingChange(p: PeerConnection.SignalingState) {}
            override fun onIceGatheringChange(p: PeerConnection.IceGatheringState) {}
            override fun onIceCandidatesRemoved(c: Array<out IceCandidate>) {}
            override fun onIceConnectionReceivingChange(b: Boolean) {}
            override fun onAddStream(s: MediaStream) {}
            override fun onRemoveStream(s: MediaStream) {}
            override fun onDataChannel(d: DataChannel) {}
            override fun onRenegotiationNeeded() {}
        },
    )

    init {
        val streamIds = listOf("haven")
        localAudio?.let { pc?.addTrack(it, streamIds) }
        localVideo?.let { pc?.addTrack(it, streamIds) }
    }

    /** Add my screen-share track to this peer and renegotiate (the sharer offers; the peer answers). */
    fun addScreenTrack(track: VideoTrack) {
        val pc = pc ?: return
        if (screenSender != null) return
        screenSender = pc.addTrack(track, listOf("screen"))
        makeOffer()   // renegotiate to announce the new m-line
    }

    /** Remove my screen-share track and renegotiate (the m-line goes inactive on the peer). */
    fun removeScreenTrack() {
        val pc = pc ?: return
        screenSender?.let { runCatching { pc.removeTrack(it) } }
        screenSender = null
        makeOffer()
    }

    fun makeOffer() {
        val pc = pc ?: return
        pc.createOffer(object : SimpleSdp() {
            override fun onCreateSuccess(sdp: SessionDescription) {
                pc.setLocalDescription(object : SimpleSdp() {
                    override fun onSetSuccess() {
                        localOfferSet = true
                        onLocalSdp("offer", sdp.description)
                        // Peer may have answered before our local offer finished applying.
                        pendingAnswerSdp?.let { ans ->
                            pendingAnswerSdp = null
                            applyRemoteAnswer(ans)
                        }
                    }
                }, sdp)
            }
        }, mediaConstraints())
    }

    fun onRemoteOffer(sdp: String) {
        val pc = pc ?: return
        pc.setRemoteDescription(object : SimpleSdp() {
            override fun onSetSuccess() {
                remoteSet = true; flushCandidates()
                pc.createAnswer(object : SimpleSdp() {
                    override fun onCreateSuccess(answer: SessionDescription) {
                        pc.setLocalDescription(SimpleSdp(), answer)
                        onLocalSdp("answer", answer.description)
                    }
                }, mediaConstraints())
            }
        }, SessionDescription(SessionDescription.Type.OFFER, sdp))
    }

    fun onRemoteAnswer(sdp: String) {
        if (!localOfferSet) {
            // Answer raced ahead of setLocalDescription(offer) → "Called in wrong state: stable".
            pendingAnswerSdp = sdp
            Log.d(TAG, "$peerHex queuing remote answer until local offer is set")
            return
        }
        applyRemoteAnswer(sdp)
    }

    private fun applyRemoteAnswer(sdp: String) {
        // Accept an answer whenever WE have an offer in flight (initial OR renegotiation) — the
        // old once-forever `remoteSet` guard dropped every RENEGOTIATION answer, so video/screen
        // toggles wedged the offerer in HAVE_LOCAL_OFFER and never reached the remote (iOS
        // parity fix). Redelivered/stale answers arrive while STABLE and are still ignored.
        if (pc?.signalingState() != PeerConnection.SignalingState.HAVE_LOCAL_OFFER) {
            Log.d(TAG, "$peerHex ignoring answer in state ${pc?.signalingState()}")
            return
        }
        pc?.setRemoteDescription(object : SimpleSdp() {
            override fun onSetSuccess() { remoteSet = true; flushCandidates() }
            override fun onSetFailure(error: String?) {
                Log.w(TAG, "$peerHex answer set fail: $error")
            }
        }, SessionDescription(SessionDescription.Type.ANSWER, sdp))
    }

    fun addRemoteCandidate(candidate: String, mLineIndex: Int, mid: String?) {
        val ice = IceCandidate(mid, mLineIndex, candidate)
        if (remoteSet) pc?.addIceCandidate(ice) else pendingRemote.add(ice)
    }

    private fun flushCandidates() {
        pendingRemote.forEach { pc?.addIceCandidate(it) }
        pendingRemote.clear()
    }

    /**
     * Pull the current audio levels for this connection — the REMOTE peer's inbound level and our
     * own mic level on it, both 0…1. Delivered on WebRTC's stats thread. Apple parity
     * (`WebRTCCall.audioLevels`); drives the active-speaker highlight.
     */
    fun audioLevels(onResult: (inbound: Double, outbound: Double) -> Unit) {
        val conn = pc ?: return onResult(0.0, 0.0)
        runCatching {
            conn.getStats { report ->
                var inbound = 0.0
                var outbound = 0.0
                for (stat in report.statsMap.values) {
                    val kind = stat.members["kind"] as? String ?: continue
                    if (kind != "audio") continue
                    val level = (stat.members["audioLevel"] as? Number)?.toDouble() ?: continue
                    when (stat.type) {
                        "inbound-rtp" -> if (level > inbound) inbound = level
                        "media-source" -> if (level > outbound) outbound = level
                    }
                }
                onResult(inbound, outbound)
            }
        }.onFailure { onResult(0.0, 0.0) }
    }

    fun close() {
        runCatching { pc?.dispose() }
    }

    private fun mediaConstraints() = MediaConstraints().apply {
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
        mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "true"))
    }

    /** Most SdpObserver callbacks are no-ops; override only what's needed. */
    private open class SimpleSdp : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) { Log.w(TAG, "sdp create fail: $error") }
        override fun onSetFailure(error: String?) { Log.w(TAG, "sdp set fail: $error") }
    }

    companion object {
        private const val TAG = "WebRTCPeer"
        /** Track id for the screen-share video track — matches iOS `WebRTCCall.screenTrackId`. */
        const val SCREEN_TRACK_ID = "screen0"
    }
}
