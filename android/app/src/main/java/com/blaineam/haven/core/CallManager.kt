package com.blaineam.haven.core

import android.content.Context
import android.util.Log
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack

/**
 * Mesh group calls, the Android counterpart of the iOS CallManager. A call is a sessionId + a
 * roster of node-id hexes; every participant opens one [WebRTCPeer] to every other (full mesh,
 * no SFU). 1:1 is just a 2-person group. The lexicographically smaller hex offers (glare-free).
 * SDP/ICE ride frames 16/17/18 over Haven's sealed channel; media is DTLS-SRTP.
 *
 * In-app call UI (no Telecom yet) — matches the iOS Mac-Catalyst in-app overlay path.
 */
object CallManager {
    private const val TAG = "CallManager"

    // Observable UI state.
    val ringing = mutableStateOf(false)
    val connecting = mutableStateOf(false)
    val inCall = mutableStateOf(false)
    /** True for the WHOLE call lifecycle (ringing → connecting → in progress). Feed/story media
     *  playback checks this so post music previews and video audio never compete with the call.
     *  Reading it inside a Composable subscribes to all three states (recomposes on any flip). */
    val callInProgress: Boolean get() = ringing.value || connecting.value || inCall.value
    val peerName = mutableStateOf("")
    val micOn = mutableStateOf(true)
    val cameraOn = mutableStateOf(true)
    /** Speakerphone (loudspeaker) vs earpiece. Defaults ON for a video call, OFF for voice-only —
     *  set when audio starts; the user can flip it any time (iOS parity). */
    val speakerOn = mutableStateOf(true)
    /** In-app minimized call (small floating tile + tap to restore), iOS parity. */
    val minimized = mutableStateOf(false)
    /** Sharing this device's screen into the call instead of the camera. */
    val screenShare = mutableStateOf(false)
    /** Other participants (hex), drives the video grid. */
    val participants: SnapshotStateList<String> = mutableStateListOf()
    /** Remote video track per participant, attached by the UI renderers. */
    val remoteVideo: SnapshotStateMap<String, VideoTrack?> = mutableStateMapOf()
    /** A peer's incoming SCREEN-share track (its second `screen0` video track), rendered aspect-fit. */
    val remoteScreen: SnapshotStateMap<String, VideoTrack?> = mutableStateMapOf()
    /** Peers whose camera is currently OFF — show their avatar, not a frozen last frame. */
    val remoteCameraOff: SnapshotStateList<String> = mutableStateListOf()
    var localVideo: VideoTrack? = null; private set

    lateinit var eglBase: EglBase; private set

    private lateinit var appContext: Context
    private var myHex: String = ""
    private var factory: PeerConnectionFactory? = null
    private var audioTrack: AudioTrack? = null
    private var videoSource: VideoSource? = null
    private var capturer: CameraVideoCapturer? = null
    private var surfaceHelper: SurfaceTextureHelper? = null
    private var screenCapturer: org.webrtc.VideoCapturer? = null
    private var screenSurfaceHelper: SurfaceTextureHelper? = null
    private var screenVideoSource: VideoSource? = null
    private var screenTrack: VideoTrack? = null   // the shared "screen0" track added to every peer

    private var sessionId: String = ""
    private var isCaller = false
    private var mediaStarted = false
    private val roster = HashSet<String>()                 // includes me
    private val peers = HashMap<String, WebRTCPeer>()

    // Callee-side bounded ring (iOS parity). The caller gives up dialing at ~30s, but its hangup
    // (frame 12) is fire-and-forget — if it never arrives (caller offline, dropped frame, or a
    // stale invite replayed late through a relay hop), we'd ring FOREVER. Ringing always stops
    // after this timeout and the call is treated as missed.
    private const val RING_TIMEOUT_MS = 60_000L
    /** Invites older than this (per the sender's frame-21 timestamp) never start a ring — the
     *  caller stopped dialing long ago. Generous enough to absorb ordinary clock skew. */
    private const val INVITE_MAX_AGE_SECS = 180L
    /** How long an ended session's tombstone suppresses re-ringing. Just outlasts the caller's
     *  ~30s invite retransmit burst: declining mustn't re-ring when our hangup frame is lost, but
     *  a deliberate redial — or being re-added to a group call we left (addToCall reuses the
     *  session id) — rings normally once the burst is over. */
    private const val ENDED_TOMBSTONE_MS = 45_000L
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val ringTimeoutRunnable = Runnable { ringTimedOut() }
    /** Sessions that already ended locally (declined / hung up / timed out / completed), with when.
     *  A caller retransmits the invite every 2.5s and relay hops can replay copies late — none of
     *  those may re-ring a session we've already left. */
    private val endedSessions = HashMap<String, Long>()

    private val iceServers = listOf(
        PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer(),
        PeerConnection.IceServer.builder("stun:stun1.l.google.com:19302").createIceServer(),
    )

    fun init(context: Context, myNodeHex: String) {
        if (this::appContext.isInitialized) { myHex = myNodeHex; return }
        appContext = context.applicationContext
        myHex = myNodeHex
        eglBase = EglBase.create()
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(appContext)
                .createInitializationOptions()
        )
        HavenNet.callRouter = { type, body -> handle(type, body) }
    }

    private fun ensureFactory(): PeerConnectionFactory =
        factory ?: PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .createPeerConnectionFactory().also { factory = it }

    // ---- Sealed + signed call signaling (audit R1) ----

    /** Seal + sign a call frame to [to] before handing it to the transport. The SDP/ICE/control body
     *  is encrypted to the recipient (so a relay on the frame-9 forward path can't read candidate IPs
     *  or rewrite the DTLS-SRTP fingerprint) and carries our Ed25519 signature (so the recipient
     *  proves the sender). No plaintext fallback: if sealing fails we send NOTHING, so a relay can't
     *  force a downgrade to the old spoofable form. Mirrors iOS `FeedStore.sendCallFrame`. */
    private fun send(type: Int, body: ByteArray, to: String) {
        val sealed = runCatching { HavenNet.engine.sealCallFrame(to, type.toUByte(), body) }.getOrNull() ?: return
        if (sealed.isEmpty()) return
        HavenNet.sendCallFrame(type, sealed, to)
    }

    // ---- Starting / joining ----

    private fun invitees(): List<String> = (roster - myHex).sorted()
    private fun rosterCsv(): String = roster.sorted().joinToString(",")

    /** Start (or join) a call with the given OTHER participant hexes. 1:1 = [partnerHex]. */
    fun startCall(others: List<String>, name: String, session: String? = null) {
        if (inCall.value || ringing.value || connecting.value) {
            // Already in a call → treat as adding people.
            others.forEach { roster.add(it) }
            refreshParticipants(); return
        }
        sessionId = session ?: "and-${myHex.take(8)}-${System.nanoTime()}"
        roster.clear(); roster.addAll(others); roster.add(myHex)
        peerName.value = name
        isCaller = true
        connecting.value = true
        com.blaineam.haven.ui.MusicPlayer.stop()   // call audio owns the stage from the first dial
        refreshParticipants()
        // Frame 21 group invite to everyone.
        val frame = CallWire.groupInvite(myHex, sessionId, name, rosterCsv())
        invitees().forEach { send(CallWire.GROUP_INVITE, frame, it) }
        startMesh()
    }

    /** Add people to the IN-PROGRESS call: invite the newcomers and re-broadcast the updated roster so
     *  everyone (old + new) meshes together. No-op for anyone already in or not in a call. */
    fun addToCall(hexes: List<String>) {
        if (!(inCall.value || connecting.value)) return
        val fresh = hexes.filter { it != myHex && !roster.contains(it) }
        if (fresh.isEmpty()) return
        roster.addAll(fresh)
        refreshParticipants()
        // Frame 21 with the NEW roster — to the newcomers (so they ring/join) AND existing members (so
        // they learn the newcomer and open a peer to them; handleGroupInvite fills the mesh in).
        val frame = CallWire.groupInvite(myHex, sessionId, peerName.value, rosterCsv())
        invitees().forEach { send(CallWire.GROUP_INVITE, frame, it) }
        if (mediaStarted) fresh.forEach { connectPeerIfNeeded(it) }
    }

    /** Contacts still addable to the current call (not already in it, not blocked). */
    fun addableContacts(): List<Contact> =
        HavenNet.contacts.filter { !roster.contains(it.idHex) && !HavenNet.blocked.contains(it.idHex) }

    fun accept() {
        mainHandler.removeCallbacks(ringTimeoutRunnable)
        ringing.value = false
        inCall.value = true
        invitees().forEach { send(CallWire.ACCEPT, CallWire.accept(myHex, sessionId), it) }
        startMesh()
        invitees().forEach { connectPeerIfNeeded(it) }
    }

    fun decline() = hangup()

    fun hangup() {
        // The hangup is one fire-and-forget UDP frame; a single drop makes the far side wait out the
        // ICE timeout (~seconds) instead of ending promptly. Send it a few times — it's idempotent on
        // receipt. Capture targets before teardown clears the roster.
        val targets = invitees().toList()
        val h = android.os.Handler(android.os.Looper.getMainLooper())
        repeat(3) { i ->
            h.postDelayed({ targets.forEach { send(CallWire.HANGUP, CallWire.hangup(myHex), it) } }, 90L * i)
        }
        teardown()
    }

    // ---- Inbound signaling (from HavenNet.callRouter, on main) ----

    /** Open + verify a sealed+signed call frame (audit R1) BEFORE any signaling logic sees it: reject
     *  anything we can't decrypt or whose Ed25519 signature doesn't verify against the carried sender
     *  bundle for this recipient + frame type (a relay-forged, relay-rewritten, or replayed-as-another-
     *  type frame all fail), and reject one whose proven sender doesn't match the self-declared `from`
     *  the sub-handlers key on. Runs identically for direct and frame-9-relayed frames — authentication
     *  is the signature, not the transport id. Returns the verified PLAINTEXT body, or null to drop. */
    private fun openCallFrame(type: Int, sealedBody: ByteArray): ByteArray? {
        val opened = runCatching { HavenNet.engine.openCallFrame(type.toUByte(), sealedBody) }.getOrNull() ?: return null
        val verified = opened.senderHex.lowercase()
        val plaintext = opened.data
        if (verified.length != 64 || plaintext.size < 64) return null
        val declared = runCatching { String(plaintext.copyOfRange(0, 64), Charsets.UTF_8) }.getOrNull()?.lowercase() ?: ""
        if (declared != verified) return null            // proven sender must equal the self-declared from
        if (HavenNet.blocked.contains(verified)) return null
        return plaintext
    }

    private fun handle(type: Int, sealedBody: ByteArray) {
        val body = openCallFrame(type, sealedBody) ?: return
        when (type) {
            CallWire.GROUP_INVITE -> handleGroupInvite(body)
            CallWire.INVITE -> CallWire.parseInviteName(body)?.let { (from, name) ->
                if (!knownContact(from)) return@let
                // Already in a call → the sender is joining, not ringing us afresh (iOS parity).
                if (inCall.value || ringing.value || connecting.value) {
                    if (roster.add(from)) refreshParticipants()
                    return@let
                }
                incoming(from, name, "legacy:$from", setOf(from, myHex))
            }
            CallWire.ACCEPT -> handleAccept(body)
            CallWire.HANGUP -> handleHangup(body)
            CallWire.CAMERA -> handleCameraState(body)
            CallWire.OFFER -> handleOffer(body)
            CallWire.ANSWER -> handleAnswer(body)
            CallWire.ICE -> handleIce(body)
        }
    }

    private fun handleGroupInvite(body: ByteArray) {
        val g = CallWire.parseGroupInvite(body) ?: return
        if (!knownContact(g.from)) return   // only contacts can invite you (F3)
        // Optional 4th field (newer senders): the invite's send time. A copy older than the
        // caller's entire dialing window is a replay — a relay hop or reconnect delivering it
        // long after the caller gave up. It must not ring (or resurrect a session's roster).
        val age = g.sentAt?.let { System.currentTimeMillis() / 1000 - it }
        if (age != null && age > INVITE_MAX_AGE_SECS) {
            Log.i(TAG, "dropping stale invite (age=${age}s session=${g.sessionId.take(12)})")
            return
        }
        val members = (g.roster + g.from + myHex).toSet()
        if (inCall.value || ringing.value || connecting.value) {
            if (sessionId == g.sessionId) {
                val added = members - roster
                roster.addAll(members); refreshParticipants()
                if (mediaStarted) added.filter { it != myHex }.forEach { connectPeerIfNeeded(it) }
            }
            return
        }
        incoming(g.from, g.groupName, g.sessionId, members)
    }

    private fun incoming(from: String, name: String, session: String, members: Set<String>) {
        if (recentlyEnded(session)) return   // we already left this session — retransmits can't re-ring
        sessionId = session
        roster.clear(); roster.addAll(members)
        peerName.value = name
        isCaller = false
        ringing.value = true
        startRingTimeout()
        com.blaineam.haven.ui.MusicPlayer.stop()   // stop the song preview before the ring
        refreshParticipants()
    }

    /** Arm the callee-side bounded ring. Cleared by accept and by teardown (decline, hangup, end). */
    private fun startRingTimeout() {
        mainHandler.removeCallbacks(ringTimeoutRunnable)
        mainHandler.postDelayed(ringTimeoutRunnable, RING_TIMEOUT_MS)
    }

    /** Nobody answered and no hangup ever arrived — stop ringing and record a missed call. */
    private fun ringTimedOut() {
        if (!ringing.value || inCall.value) return
        Log.i(TAG, "ring timeout after ${RING_TIMEOUT_MS / 1000}s — ending as missed (session=${sessionId.take(12)})")
        val who = peerName.value
        teardown()
        runCatching {
            Notifications.notify(appContext, "Missed call", if (who.isEmpty()) "You missed a call" else "You missed a call from $who")
        }
    }

    /** Did a session end here recently enough that a fresh invite for it must be ignored? */
    private fun recentlyEnded(sid: String): Boolean {
        val endedAt = endedSessions[sid] ?: return false
        return System.currentTimeMillis() - endedAt < ENDED_TOMBSTONE_MS
    }

    private fun handleAccept(body: ByteArray) {
        val a = CallWire.parseAccept(body) ?: return
        if (!validSession(a.sessionId) || !knownContact(a.from)) return   // only a contact accepts (F3)
        connecting.value = false; inCall.value = true
        if (roster.add(a.from)) refreshParticipants()
        startMesh()
        connectPeerIfNeeded(a.from)
    }

    private fun handleCameraState(body: ByteArray) {
        val (from, on) = CallWire.parseCameraState(body) ?: return
        if (!roster.contains(from)) return   // only a participant
        if (on) remoteCameraOff.remove(from) else if (!remoteCameraOff.contains(from)) remoteCameraOff.add(from)
    }

    private fun handleHangup(body: ByteArray) {
        val from = CallWire.parseHangup(body) ?: return
        dropPeer(from)
        if ((roster - myHex).isEmpty()) teardown()
    }

    private fun handleOffer(body: ByteArray) {
        val s = CallWire.parseSignal(body, sessionId) ?: return
        if (!validSession(s.sessionId) || s.from !in roster) return   // only a participant negotiates (F3)
        if (!mediaStarted) startMesh()
        val sdp = CallSignal.decodeSdp(s.json) ?: return
        peerFor(s.from).onRemoteOffer(sdp.sdp)
    }

    private fun handleAnswer(body: ByteArray) {
        val s = CallWire.parseSignal(body, sessionId) ?: return
        if (!validSession(s.sessionId) || s.from !in roster) return
        val sdp = CallSignal.decodeSdp(s.json) ?: return
        peers[s.from]?.onRemoteAnswer(sdp.sdp)
    }

    private fun handleIce(body: ByteArray) {
        val s = CallWire.parseSignal(body, sessionId) ?: return
        if (!validSession(s.sessionId) || s.from !in roster) return
        val c = CallSignal.decodeCandidate(s.json) ?: return
        peerFor(s.from).addRemoteCandidate(c.candidate, c.mLineIndex, c.mid)
    }

    private fun validSession(sid: String) = sid == sessionId || sessionId.isEmpty()

    /// Call frames are sealed + SIGNATURE-verified before dispatch (audit R1), so `hex` here is the
    /// cryptographically-PROVEN sender, not a self-asserted one. This gate applies AUTHORIZATION on
    /// top of that: a stranger who can sign as themselves still can't ring you, inject participants,
    /// or negotiate a call unless they're a known contact (audit F3, iOS parity).
    private fun knownContact(hex: String): Boolean = HavenNet.contacts.any { it.idHex == hex }

    // ---- Media + mesh ----

    private fun startMesh() {
        if (mediaStarted) return
        mediaStarted = true
        connecting.value = connecting.value && !inCall.value
        val f = ensureFactory()
        // Audio. Put the audio system into in-communication mode and route to the loudspeaker by
        // default (so a video call is hands-free); the speaker toggle flips it to the earpiece.
        runCatching {
            audioManager().mode = android.media.AudioManager.MODE_IN_COMMUNICATION
            applySpeaker()
        }
        val audioSource = f.createAudioSource(MediaConstraints())
        audioTrack = f.createAudioTrack("haven-audio", audioSource).apply { setEnabled(micOn.value) }
        // Video (front camera).
        startCamera(f)
        // Dial everyone we already know (callee dials too, glare rule prevents double offers).
        invitees().forEach { connectPeerIfNeeded(it) }
    }

    private fun startCamera(f: PeerConnectionFactory) {
        runCatching {
            val enumerator = Camera2Enumerator(appContext)
            val front = enumerator.deviceNames.firstOrNull { enumerator.isFrontFacing(it) }
                ?: enumerator.deviceNames.firstOrNull() ?: return
            val cap = enumerator.createCapturer(front, null) ?: return
            capturer = cap
            val src = f.createVideoSource(false); videoSource = src
            surfaceHelper = SurfaceTextureHelper.create("CaptureThread", eglBase.eglBaseContext)
            cap.initialize(surfaceHelper, appContext, src.capturerObserver)
            cap.startCapture(1280, 720, 30)
            localVideo = f.createVideoTrack("haven-video", src).apply { setEnabled(cameraOn.value) }
        }.onFailure { Log.w(TAG, "camera start failed", it) }
    }

    private fun connectPeerIfNeeded(peer: String): WebRTCPeer {
        val conn = peerFor(peer)
        if (myHex < peer && mediaStarted) conn.makeOffer()   // smaller hex offers
        return conn
    }

    private fun peerFor(peer: String): WebRTCPeer = peers.getOrPut(peer) {
        WebRTCPeer(
            peerHex = peer,
            factory = ensureFactory(),
            iceServers = iceServers,
            localAudio = audioTrack,
            localVideo = localVideo,
            onLocalSdp = { type, sdp ->
                val t = if (type == "offer") CallWire.OFFER else CallWire.ANSWER
                send(t, CallWire.signal(myHex, sessionId, CallSignal.encodeSdp(type, sdp)), peer)
            },
            onLocalIce = { cand, m, mid ->
                send(CallWire.ICE, CallWire.signal(myHex, sessionId, CallSignal.encodeCandidate(cand, m, mid)), peer)
            },
            onRemoteVideo = { track -> remoteVideo[peer] = track },
            onRemoteScreen = { track -> remoteScreen[peer] = track },
            onRemoteScreenEnded = { remoteScreen[peer] = null },
        )
    }

    private fun dropPeer(peer: String) {
        peers.remove(peer)?.close()
        roster.remove(peer)
        remoteVideo.remove(peer)
        remoteScreen.remove(peer); remoteCameraOff.remove(peer)
        refreshParticipants()
    }

    private fun refreshParticipants() {
        val others = (roster - myHex).sorted()
        participants.clear(); participants.addAll(others)
    }

    // ---- Controls ----

    fun toggleMic() { micOn.value = !micOn.value; audioTrack?.setEnabled(micOn.value) }
    fun toggleSpeaker() { speakerOn.value = !speakerOn.value; applySpeaker() }

    private fun audioManager(): android.media.AudioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager

    /** Route audio to the loudspeaker or the earpiece per [speakerOn]. Bluetooth/wired headsets, when
     *  present, take over regardless — the OS honors the connected route over this flag. */
    private fun applySpeaker() {
        runCatching { audioManager().isSpeakerphoneOn = speakerOn.value }
    }
    fun toggleCamera() {
        cameraOn.value = !cameraOn.value
        localVideo?.setEnabled(cameraOn.value)
        // Tell every peer so they swap to my avatar instead of freezing on my last camera frame.
        val on = cameraOn.value
        invitees().forEach { send(CallWire.CAMERA, CallWire.cameraState(myHex, sessionId, on), it) }
    }
    fun switchCamera() { if (!screenShare.value) capturer?.switchCamera(null) }

    /**
     * Begin sharing the screen as a SECOND video track ("screen0"), added alongside the camera — not a
     * swap. The remote renders it in its own aspect-fit tile (matching the iOS protocol), and the camera
     * keeps streaming. Adding the track renegotiates each peer (the sharer offers, the peer answers).
     *
     * [resultCode]/[data] come from the system MediaProjection consent dialog (launched by the UI).
     */
    fun startScreenShare(resultCode: Int, data: android.content.Intent) {
        if (screenShare.value) return
        runCatching {
            // Android 14+: a mediaProjection-typed foreground service must be live before capture.
            ConnectionService.startForProjection(appContext)
            val f = ensureFactory()
            val src = f.createVideoSource(true)   // isScreencast=true tunes the encoder for screen content
            screenVideoSource = src
            val helper = SurfaceTextureHelper.create("ScreenCapture", eglBase.eglBaseContext)
            screenSurfaceHelper = helper
            val cap = org.webrtc.ScreenCapturerAndroid(data, object : android.media.projection.MediaProjection.Callback() {
                override fun onStop() {
                    android.os.Handler(android.os.Looper.getMainLooper()).post { stopScreenShare() }
                }
            })
            screenCapturer = cap
            cap.initialize(helper, appContext, src.capturerObserver)
            val dm = appContext.resources.displayMetrics
            cap.startCapture(dm.widthPixels, dm.heightPixels, 15)
            val track = f.createVideoTrack(WebRTCPeer.SCREEN_TRACK_ID, src)
            screenTrack = track
            peers.values.forEach { runCatching { it.addScreenTrack(track) } }
            screenShare.value = true
        }.onFailure { Log.w(TAG, "screen share start failed", it) }
    }

    /** Stop screen sharing: remove the screen track from every peer (renegotiate) and tear it down. */
    fun stopScreenShare() {
        if (!screenShare.value && screenTrack == null) return
        screenShare.value = false
        peers.values.forEach { runCatching { it.removeScreenTrack() } }
        runCatching { screenCapturer?.stopCapture() }
        runCatching { screenCapturer?.dispose() }; screenCapturer = null
        runCatching { screenSurfaceHelper?.dispose() }; screenSurfaceHelper = null
        runCatching { screenTrack?.dispose() }; screenTrack = null
        runCatching { screenVideoSource?.dispose() }; screenVideoSource = null
    }

    fun toggleScreenShare(resultCode: Int, data: android.content.Intent) {
        if (screenShare.value) stopScreenShare() else startScreenShare(resultCode, data)
    }

    private fun teardown() {
        // Remember the session so the caller's still-in-flight invite retransmits can't re-ring it.
        if (sessionId.isNotEmpty()) {
            endedSessions[sessionId] = System.currentTimeMillis()
            if (endedSessions.size > 50) {   // prune long-expired tombstones
                val now = System.currentTimeMillis()
                endedSessions.entries.removeAll { now - it.value >= ENDED_TOMBSTONE_MS }
            }
        }
        mainHandler.removeCallbacks(ringTimeoutRunnable)
        peers.values.forEach { it.close() }; peers.clear()
        runCatching { screenCapturer?.stopCapture() }
        runCatching { screenCapturer?.dispose() }; screenCapturer = null
        runCatching { screenSurfaceHelper?.dispose() }; screenSurfaceHelper = null
        runCatching { screenTrack?.dispose() }; screenTrack = null
        runCatching { screenVideoSource?.dispose() }; screenVideoSource = null
        screenShare.value = false
        runCatching { capturer?.stopCapture() }
        runCatching { capturer?.dispose() }; capturer = null
        runCatching { surfaceHelper?.dispose() }; surfaceHelper = null
        localVideo = null
        remoteVideo.clear(); remoteScreen.clear(); remoteCameraOff.clear(); participants.clear(); roster.clear()
        // Hand audio back to the system (drop in-communication mode + loudspeaker routing).
        runCatching {
            val am = audioManager()
            am.isSpeakerphoneOn = false
            am.mode = android.media.AudioManager.MODE_NORMAL
        }
        speakerOn.value = true   // default for the next call
        sessionId = ""; mediaStarted = false; isCaller = false
        ringing.value = false; connecting.value = false; inCall.value = false; minimized.value = false
        peerName.value = ""
    }
}
