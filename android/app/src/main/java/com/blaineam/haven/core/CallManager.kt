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
    /** Calls START AUDIO-ONLY, matching Apple. The video TRACK is still created and published up
     *  front (see [startCamera]) — only disabled — so turning the camera on later is instant and
     *  needs no renegotiation. */
    val cameraOn = mutableStateOf(false)
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
    /** Must OUTLIVE [INVITE_MAX_AGE_SECS], or an ended call rings again.
     *
     *  A caller retransmits its invite, and the relay can hand one over late, so the same session id
     *  keeps arriving. `endedSessions` is what says "we already dealt with that" — but at 45s it
     *  expired long before the 180s window in which an invite is still considered fresh, leaving
     *  ~135s where a retransmit found no tombstone and re-opened the call screen on its own, over
     *  and over. A tombstone that does not outlive the thing it suppresses suppresses nothing. */
    private const val ENDED_TOMBSTONE_MS = (INVITE_MAX_AGE_SECS + 30L) * 1000L
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val ringTimeoutRunnable = Runnable { ringTimedOut() }
    /** Sessions that already ended locally (declined / hung up / timed out / completed), with when.
     *  A caller retransmits the invite every 2.5s and relay hops can replay copies late — none of
     *  those may re-ring a session we've already left. */
    private val endedSessions = HashMap<String, Long>()

    /** Peers whose media is currently relayed over the /webrtc/hairpin WebSocket (ICE failed). */
    private val hairpinPeers = HashSet<String>()

    // Active-speaker detection (Apple parity). Same threshold and debounce, so a group call
    // highlights the same person on every platform at the same moment.
    /** Loudest participant right now — a peer hex, "" for me, or null for nobody. */
    val activeSpeaker = mutableStateOf<String?>(null)
    /** How many consecutive polls each candidate has led, for debounce (key "" = me). */
    private val speakerStreak = HashMap<String, Int>()
    private const val SPEAKING_THRESHOLD = 0.02
    private const val SPEAKER_DEBOUNCE = 2
    private var speakerPolling = false
    private val speakerRunnable = object : Runnable {
        override fun run() {
            pollAudioLevels()
            if (speakerPolling) mainHandler.postDelayed(this, 1_000)
        }
    }
    /** How long a RELAYED peer may go completely silent before we treat it as gone. ICE cannot tell
     *  us — it is failed by definition on this path — so the relay's own inbound clock has to. */
    private const val RELAY_SILENCE_DROP_SECS = 20L

    /**
     * Haven-first ICE — parity with Apple [HavenFabric].
     * Prefs `haven.fabric.derpUrls` + `turnUrls`/`turnUser`/`turnPass`.
     *
     * The decision lives in [FabricIcePolicy.plan] so the unit tests pin what actually ships; this
     * function only translates that plan into WebRTC's types. It used to make its own call and
     * override the policy object, which meant [FabricIcePolicyTest] passed while describing
     * behaviour no device had.
     *
     * Call *signaling* rides sealed iroh over fabric DERP / direct QUIC regardless.
     */
    private fun iceServers(): List<PeerConnection.IceServer> {
        val prefs = appContext.getSharedPreferences("haven.fabric", android.content.Context.MODE_PRIVATE)
        val plan = FabricIcePolicy.plan(
            derp = prefs.getStringSet("derpUrls", emptySet()).orEmpty(),
            turn = prefs.getStringSet("turnUrls", emptySet()).orEmpty(),
            user = prefs.getString("turnUser", "") ?: "",
            pass = prefs.getString("turnPass", "") ?: "",
        )
        val servers = mutableListOf<PeerConnection.IceServer>()
        if (plan.turnUrls.isNotEmpty()) {
            servers.add(
                PeerConnection.IceServer.builder(plan.turnUrls)
                    .setUsername(plan.turnUser)
                    .setPassword(plan.turnPass)
                    .createIceServer(),
            )
        }
        if (plan.stunUrls.isNotEmpty()) {
            servers.add(PeerConnection.IceServer.builder(plan.stunUrls).createIceServer())
        }
        servers.addAll(plan.google.map { PeerConnection.IceServer.builder(it).createIceServer() })
        if (plan.usesGoogleStun) Log.i(TAG, "ice: no Haven relay for this call — falling back to public STUN")
        return servers
    }

    fun init(context: Context, myNodeHex: String) {
        if (this::appContext.isInitialized) { myHex = myNodeHex; return }
        appContext = context.applicationContext
        myHex = myNodeHex
        CallMediaBridge.init(appContext)
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
        // seal_media can only seal to a recipient it can RESOLVE to a bundle: our own account, a circle
        // member, or a known device bundle. If none match it throws and this drops the frame silently —
        // nothing is transmitted and nothing is recorded. For an ACCEPT that is indistinguishable from
        // the network eating it: the callee has already flipped itself in-call, so it looks connected
        // while the caller waits out the full invite timer. Say so. iOS parity.
        val sealed = runCatching { HavenNet.engine.sealCallFrame(to, type.toUByte(), body) }.getOrNull()
        if (sealed == null || sealed.isEmpty()) {
            val known = runCatching { HavenNet.engine.deviceNodeIdsFor(to).size }.getOrDefault(0)
            Log.i(TAG, "call frame type=$type NOT SENT to ${to.take(8)} — seal failed " +
                "(recipient unresolvable: $known known device id(s), ${if (sealed == null) "threw" else "empty"})")
            return
        }
        HavenNet.sendCallFrame(type, sealed, to)
    }

    /** Seal + send a NON-call frame that must be as unforgeable as a call frame — today the media
     *  frames 31/32 (HavenNet). They aren't call signaling, but "re-upload this blob" and "your media
     *  is back" are exactly as abusable as an invite if they can be forged, so they borrow this path
     *  rather than growing a second, subtly-different sealing implementation. */
    fun sealedSend(type: Int, body: ByteArray, to: String) = send(type, body, to)

    /** [openCallFrame] for the same non-call frames — one verification implementation, so a guard
     *  fixed here is fixed for every sealed frame type. Returns the verified plaintext, or null. */
    fun openSealed(type: Int, sealedBody: ByteArray): ByteArray? = openCallFrame(type, sealedBody)

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
        // Claim the mic under a typed foreground service BEFORE capture starts, so switching apps
        // mid-call doesn't have Android silently cut it (one-way audio: they hear you, you hear them,
        // but nothing of yours reaches them).
        ConnectionService.startForCall(appContext)
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
        runCatching { Notifications.clearIncomingCall(appContext) }
        mainHandler.removeCallbacks(ringTimeoutRunnable)
        ringing.value = false
        inCall.value = true
        ConnectionService.startForCall(appContext)   // same mic claim as the outbound path
        notifyOwnDevicesHandled()   // stop my OTHER devices ringing before they can join and take the audio
        invitees().forEach { send(CallWire.ACCEPT, CallWire.accept(myHex, sessionId), it) }
        startMesh()
        invitees().forEach { connectPeerIfNeeded(it) }
    }

    fun decline() = hangup()

    /**
     * Tell my OTHER devices this ringing call was handled here (answered or declined), so they stop
     * ringing and never join.
     *
     * Every device of mine rings — that part is right. Nothing told the losers to stand down, so the
     * one I didn't answer on kept its session live, completed signalling when the offer arrived, and
     * joined the mesh: "I answered on my phone and my Mac took the audio", then the reverse when I
     * touched the Mac. Two devices in one call also explains one of them sounding choppy — they were
     * competing, not degraded.
     *
     * Sealed PER DEVICE rather than to my account, so a seedless device (which holds no account key)
     * can open it too. iOS CallManager.notifyOwnDevicesHandled parity.
     */
    private fun notifyOwnDevicesHandled() {
        if (sessionId.isEmpty()) return
        val others = runCatching { HavenNet.myOtherDeviceHexes() }.getOrDefault(emptyList())
        if (others.isEmpty()) return
        Log.i(TAG, "call ${sessionId.take(8)} handled here — standing down ${others.size} other device(s) of mine")
        val frame = CallWire.handledElsewhere(myHex, sessionId)
        others.forEach { send(CallWire.HANDLED_ELSEWHERE, frame, it) }
    }

    /**
     * Another of MY devices answered or declined this call: stop ringing and tear down.
     *
     * Deliberately narrow. It only silences a call this device is still RINGING — never one already
     * answered here ([inCall]), so a late-arriving frame can't hang up a conversation in progress —
     * and only when the sender is my own account, which the frame's signature proves in
     * [openCallFrame] before dispatch. iOS CallManager.handleHandledElsewhere parity.
     */
    private fun handleHandledElsewhere(body: ByteArray) {
        val a = CallWire.parseAccept(body) ?: return
        if (a.from != myHex) return   // only MY account may silence my ring
        if (!ringing.value || inCall.value || a.sessionId != sessionId) {
            Log.i(TAG, "handled-elsewhere for ${a.sessionId.take(8)} ignored " +
                "(ringing=${ringing.value} inCall=${inCall.value} mine=${sessionId.take(8)})")
            return
        }
        Log.i(TAG, "call ${a.sessionId.take(8)} was handled on another of my devices — standing down")
        endedSessions[a.sessionId] = System.currentTimeMillis()   // a retransmitted invite must not re-ring us
        teardown()
    }

    fun hangup() {
        // Declining counts as handling it: silence my other devices too, or they keep ringing after I
        // have dismissed the call here.
        if (ringing.value && !inCall.value) notifyOwnDevicesHandled()
        // The hangup is one fire-and-forget UDP frame; a single drop makes the far side wait out the
        // ICE timeout (~seconds) instead of ending promptly. Send it a few times — it's idempotent on
        // receipt. Capture targets before teardown clears the roster.
        val targets = invitees().toList()
        val h = android.os.Handler(android.os.Looper.getMainLooper())
        repeat(3) { i ->
            val sid = sessionId
            h.postDelayed({ targets.forEach { send(CallWire.HANGUP, CallWire.hangup(myHex, sid), it) } }, 90L * i)
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
        // Seed-drop S4 (D9): a seedless sender signs call frames with its DEVICE key, so the proven
        // signer is the device hex while the plaintext `from` names the ACCOUNT (what contacts key on).
        // Accept iff the verified device resolves to the declared account; legacy account-signed frames
        // keep verified == declared. Either way the sub-handlers still see the account hex as `from`.
        if (declared != verified) {
            val acct = runCatching { HavenNet.engine.accountForDevice(verified) }.getOrNull()?.lowercase()
            if (acct == null || acct != declared) return null
        }
        if (HavenNet.blocked.contains(declared)) return null
        return plaintext
    }

    private fun handle(type: Int, sealedBody: ByteArray) {
        val body = openCallFrame(type, sealedBody) ?: return
        when (type) {
            CallWire.GROUP_INVITE -> handleGroupInvite(body)
            CallWire.INVITE -> CallWire.parseInviteName(body)?.let { (from, name) ->
                if (!knownContact(from)) return@let
                // GLARE: we are ringing THEM while they are ringing US. Both sides used to swallow
                // the other's invite here ("already active → just merge the roster"), so two people
                // who called each other at the same moment both sat listening to ringback and NEITHER
                // call ever connected. They obviously both want this call — so connect it.
                //
                // Both devices run this identical logic, so they must agree without another round
                // trip: the session id is derived from the two hexes in sorted order, and the lower
                // hex takes the caller role for negotiation politeness. Each side also sends an
                // ACCEPT, which drives the other's normal accept path if it gets there first.
                // iOS parity (CallManager.handleInvite).
                if (isCaller && !inCall.value && roster.contains(from)) {
                    val a = myHex.lowercase()
                    val b = from.lowercase()
                    sessionId = "glare:" + minOf(a, b) + "-" + maxOf(a, b)
                    isCaller = a < b
                    mainHandler.removeCallbacks(ringTimeoutRunnable)
                    ringing.value = false
                    connecting.value = false
                    inCall.value = true
                    Log.i(TAG, "glare with ${from.take(8)} — both dialing, adopting shared session ${sessionId.take(20)}")
                    send(CallWire.ACCEPT, CallWire.accept(myHex, sessionId), from)
                    startMesh()
                    connectPeerIfNeeded(from)
                    return@let
                }
                // Already in a call → the sender is joining, not ringing us afresh (iOS parity).
                if (inCall.value || ringing.value || connecting.value) {
                    if (roster.add(from)) refreshParticipants()
                    return@let
                }
                incoming(from, name, "legacy:$from", setOf(from, myHex))
            }
            CallWire.ACCEPT -> handleAccept(body)
            CallWire.HANGUP -> handleHangup(body)
            CallWire.HANDLED_ELSEWHERE -> handleHandledElsewhere(body)
            CallWire.CAMERA -> handleCameraState(body)
            CallWire.OFFER -> handleOffer(body)
            CallWire.ANSWER -> handleAnswer(body)
            CallWire.ICE -> handleIce(body)
        }
    }

    private fun handleGroupInvite(body: ByteArray) {
        // Every rejection here says WHY. Invites were arriving and vanishing — 52 of them ingested
        // from the relay with no ring and no line explaining it — because four of the five ways out
        // of this function were silent `return`s.
        val g = CallWire.parseGroupInvite(body)
        if (g == null) { Log.i(TAG, "invite DROPPED — unparseable (${body.size} B)"); return }
        if (!knownContact(g.from)) {
            Log.i(TAG, "invite DROPPED from ${g.from.take(8)} — not a known contact (F3); known=${HavenNet.contacts.size}")
            return
        }
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
            Log.i(TAG, "invite from ${g.from.take(8)} session=${g.sessionId.take(12)} — busy " +
                "(inCall=${inCall.value} ringing=${ringing.value} connecting=${connecting.value} mine=${sessionId.take(12)})")
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
        if (recentlyEnded(session)) {
            Log.i(TAG, "invite DROPPED session=${session.take(12)} — tombstoned (we already left it)")
            return
        }
        Log.i(TAG, "INCOMING call from ${from.take(8)} session=${session.take(12)} — ringing + notifying")
        sessionId = session
        roster.clear(); roster.addAll(members)
        peerName.value = name
        isCaller = false
        ringing.value = true
        acquireCallWakeLock()
        startRingTimeout()
        // Ring the PHONE, not just the app. Without this the call existed only inside a screen the
        // callee had to already be looking at — the process knew, and said nothing.
        runCatching { Notifications.showIncomingCall(appContext, name) }
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
        // Gate on the session, like every other signal handler. A retransmitted or late-relayed BYE
        // from an EARLIER call used to tear down whichever call was live when it landed — an
        // outgoing call whose screen appears and vanishes, or a connected call that hangs itself up
        // for no visible reason. Frames from older builds carry no session id; those still apply, so
        // this only ever tightens behaviour.
        val s = runCatching { CallWire.parseSignal(body, sessionId) }.getOrNull()
        if (s != null && s.sessionId.isNotEmpty() && !validSession(s.sessionId)) {
            Log.i(TAG, "HANGUP IGNORED from ${from.take(8)} for session ${s.sessionId.take(8)} — ours is ${sessionId.take(8)} (stale/replayed)")
            return
        }
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
        acquireCallWakeLock()   // outgoing calls never pass through `incoming`, so claim it here too
        if (mediaStarted) return
        mediaStarted = true
        connecting.value = connecting.value && !inCall.value
        val f = ensureFactory()
        // Audio. Put the audio system into in-communication mode and route to the loudspeaker by
        // default (so a video call is hands-free); the speaker toggle flips it to the earpiece.
        // Without MODE_IN_COMMUNICATION + speaker, ICE can show Connected while playout is silent
        // or stuck on the earpiece at near-zero volume (iOS parity "connected but no audio").
        runCatching {
            val am = audioManager()
            am.mode = android.media.AudioManager.MODE_IN_COMMUNICATION
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = speakerOn.value
            // Re-assert after a beat — some devices ignore the first speakerphone flip at start.
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (mediaStarted) applySpeaker()
            }, 400)
        }
        val audioSource = f.createAudioSource(MediaConstraints().apply {
            // Prefer hardware AEC/NS when available (same intent as iOS googEchoCancellation*).
            optional.add(MediaConstraints.KeyValuePair("googEchoCancellation", "true"))
            optional.add(MediaConstraints.KeyValuePair("googAutoGainControl", "true"))
            optional.add(MediaConstraints.KeyValuePair("googNoiseSuppression", "true"))
        })
        audioTrack = f.createAudioTrack("haven-audio", audioSource).apply { setEnabled(micOn.value) }
        // Video (front camera).
        startCamera(f)
        // Open the hairpin sockets NOW, alongside ICE, rather than at the moment ICE gives up. The
        // WebSocket handshake plus the relay's pairing round-trip is dead time on top of ICE's own
        // ~30s failure timeout, and a call that only starts negotiating its fallback after that has
        // already lost the user. Pairing is idle until CallMediaBridge actually pushes frames.
        // Apple parity (startMesh → CallHairpin.openForRoster).
        runCatching { CallHairpin.openForRoster(appContext, sessionId, myHex, invitees()) }
        // Dial everyone we already know (callee dials too, glare rule prevents double offers).
        invitees().forEach { connectPeerIfNeeded(it) }
        startSpeakerDetection()
    }

    /**
     * Bring the camera up and publish the track — ALWAYS, even for a call that starts audio-only.
     *
     * The track is created and then disabled, rather than not created at all, because a track added
     * after the peer connections exist needs a full renegotiation round trip; an existing-but-
     * disabled track flips on instantly with [toggleCamera]. That is also what makes "start audio,
     * turn the camera on later" work at all.
     *
     * Every failure path here says WHY. The three `?: return`s used to be silent — `onFailure` never
     * sees them, because returning early is not throwing — so a device that enumerated no camera
     * left `localVideo` null, and the camera button then did nothing forever with not one line
     * logged to explain it.
     */
    /** CPU wake lock held for the lifetime of a call. */
    private var callWakeLock: android.os.PowerManager.WakeLock? = null

    /**
     * Keep the CPU running for the duration of a call.
     *
     * The foreground service keeps the PROCESS alive, but it does not stop the device suspending
     * when the screen goes off — and a suspended CPU stops encoding and shipping audio, so the call
     * goes silent (or drops on the far side's silence timer) the moment the phone is pocketed or the
     * display times out. A partial wake lock is the narrow fix: CPU only, no screen, released the
     * instant the call ends. Bounded by a generous timeout so a leaked lock can never outlive a call
     * and quietly drain the battery.
     */
    private fun acquireCallWakeLock() {
        if (callWakeLock?.isHeld == true) return
        runCatching {
            val pm = appContext.getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
            val wl = pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "haven:call")
            wl.setReferenceCounted(false)
            wl.acquire(4 * 60 * 60 * 1000L)   // hard ceiling; teardown releases far sooner
            callWakeLock = wl
            Log.i(TAG, "call wake lock acquired — CPU stays up while the screen may sleep")
        }.onFailure { Log.w(TAG, "call wake lock failed", it) }
    }

    private fun releaseCallWakeLock() {
        runCatching { callWakeLock?.takeIf { it.isHeld }?.release() }
        callWakeLock = null
    }

    private fun startCamera(f: PeerConnectionFactory) {
        runCatching {
            val enumerator = Camera2Enumerator(appContext)
            val names = enumerator.deviceNames
            if (names.isEmpty()) { Log.w(TAG, "camera: Camera2Enumerator found NO devices — video cannot be enabled"); return }
            val front = names.firstOrNull { enumerator.isFrontFacing(it) } ?: names.first()
            val cap = enumerator.createCapturer(front, null)
            if (cap == null) { Log.w(TAG, "camera: createCapturer returned null for '$front' (${names.size} device(s) seen)"); return }
            capturer = cap
            val src = f.createVideoSource(false); videoSource = src
            surfaceHelper = SurfaceTextureHelper.create("CaptureThread", eglBase.eglBaseContext)
            cap.initialize(surfaceHelper, appContext, src.capturerObserver)
            localVideo = f.createVideoTrack("haven-video", src).apply { setEnabled(cameraOn.value) }
            // Publish the TRACK unconditionally (fixed m-lines, see the call site) but only open the
            // CAMERA when it is actually wanted. Starting capture here regardless meant every audio
            // call held the camera open for its whole duration — privacy indicator lit, battery
            // burning, for a camera nobody had switched on.
            if (cameraOn.value) startCapture(cap)
            Log.i(TAG, "camera: track published on '$front' (enabled=${cameraOn.value}, capturing=${cameraOn.value})")
        }.onFailure { Log.w(TAG, "camera start failed", it) }
    }

    private fun connectPeerIfNeeded(peer: String): WebRTCPeer {
        val conn = peerFor(peer)
        // Tell them the camera state UP FRONT. The video track is published from the start (so the
        // m-line never changes mid-call) but starts DISABLED — and a disabled WebRTC track does not
        // stop sending, it sends BLACK FRAMES. Without this the far end renders a black rectangle
        // and reasonably concludes the video is broken, when the camera is simply off. Peers that
        // know show the avatar instead. Only the toggle announced this before, so the state every
        // call actually STARTS in was the one never sent.
        runCatching {
            send(CallWire.CAMERA, CallWire.cameraState(myHex, sessionId, cameraOn.value), peer)
        }
        if (myHex < peer && mediaStarted) conn.makeOffer()   // smaller hex offers
        return conn
    }

    private fun peerFor(peer: String): WebRTCPeer = peers.getOrPut(peer) {
        WebRTCPeer(
            peerHex = peer,
            factory = ensureFactory(),
            iceServers = iceServers(),
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
            onIceState = { s -> onPeerIceState(peer, s) },
        )
    }

    /**
     * ICE lifecycle for one peer — and, on FAILED, the hairpin relay.
     *
     * Nothing watched ICE state on Android before this: `onIceConnectionChange` logged and returned.
     * So when ICE could not pair (two hard NATs, no reachable TURN — the ordinary case on mobile
     * carriers) the call simply stayed in "connecting" forever, which is the field report about
     * calls to and from Android ringing, being accepted, and never connecting. Apple has relayed
     * media over `/webrtc/hairpin` for this exact case all along.
     */
    private fun onPeerIceState(peer: String, s: PeerConnection.IceConnectionState) {
        // Hop to the main thread before touching ANY call state. This callback arrives on WebRTC's
        // signalling thread, while `peers`, `roster` and `hairpinPeers` are plain unsynchronised
        // collections that the frame handler mutates from its own thread — every other entry point
        // in this file (handleAccept, handleHangup, the ring timeout) is already main-thread-driven.
        // Racing a HashMap from two threads corrupts it, and the corruption surfaces far from here.
        mainHandler.post { onPeerIceStateOnMain(peer, s) }
    }

    private fun onPeerIceStateOnMain(peer: String, s: PeerConnection.IceConnectionState) {
        when (s) {
            PeerConnection.IceConnectionState.CONNECTED,
            PeerConnection.IceConnectionState.COMPLETED -> {
                connecting.value = false
                inCall.value = true
                // ICE RECOVERED while we were relaying — drop back to WebRTC's own (better) path.
                // Leaving both running is two full media pipelines for one call, which is heat and
                // bandwidth for no gain. Apple parity.
                if (CallMediaBridge.isRelaying(peer)) {
                    CallMediaBridge.deactivate(peer)
                    hairpinPeers.remove(peer)
                    Log.i(TAG, "ice recovered ${peer.take(8)} — hairpin relay stopped")
                }
            }
            PeerConnection.IceConnectionState.FAILED -> startHairpin(peer)
            PeerConnection.IceConnectionState.CLOSED -> {
                dropPeer(peer)
                if ((roster - myHex).isEmpty()) teardown()
            }
            PeerConnection.IceConnectionState.DISCONNECTED -> {
                // A transient blip, OR the peer left and their fire-and-forget hangup never arrived.
                // Give it a grace period, then drop — but NEVER drop a peer whose media is riding the
                // hairpin: when the relay carries the call, ICE legitimately sits failed. That is the
                // whole reason we relayed. The relay's own inbound clock is the liveness signal.
                mainHandler.postDelayed({
                    if (peers[peer] == null) return@postDelayed
                    if (CallMediaBridge.isRelaying(peer)) {
                        val quiet = CallMediaBridge.silenceSecs(peer)
                        if (quiet != null && quiet > RELAY_SILENCE_DROP_SECS) {
                            Log.i(TAG, "relay silent ${quiet}s for ${peer.take(8)} — peer gone, ending")
                            dropPeer(peer)
                            if ((roster - myHex).isEmpty()) teardown()
                        }
                        return@postDelayed
                    }
                    dropPeer(peer)
                    if ((roster - myHex).isEmpty()) teardown()
                }, 6_000)
            }
            else -> Unit
        }
    }

    // ---- Active-speaker detection (Apple parity) ----

    private fun startSpeakerDetection() {
        if (speakerPolling) return
        speakerPolling = true
        mainHandler.postDelayed(speakerRunnable, 1_000)
    }

    private fun stopSpeakerDetection() {
        speakerPolling = false
        mainHandler.removeCallbacks(speakerRunnable)
        speakerStreak.clear()
        activeSpeaker.value = null
    }

    /**
     * One stats read per connection, then pick the loudest. 1 s, not faster: each poll walks a FULL
     * stats report per connection, and a highlight only needs about that much responsiveness.
     * A 1:1 call skips entirely — with one remote peer there is nothing to disambiguate, so the
     * highlight is not worth any stats traffic at all.
     */
    private fun pollAudioLevels() {
        val conns = peers.entries.toList()
        if (conns.size <= 1) {
            if (activeSpeaker.value != null) activeSpeaker.value = null
            speakerStreak.clear()
            return
        }
        var remaining = conns.size
        var bestPeer = ""
        var bestRemote = 0.0
        var myLevel = 0.0
        for ((hex, peer) in conns) {
            peer.audioLevels { inbound, outbound ->
                mainHandler.post {
                    if (inbound > bestRemote) { bestRemote = inbound; bestPeer = hex }
                    if (outbound > myLevel) myLevel = outbound
                    remaining -= 1
                    if (remaining == 0) resolveActiveSpeaker(bestPeer, bestRemote, myLevel)
                }
            }
        }
    }

    /** Decide the active speaker, with a short debounce so a blip doesn't steal the highlight. */
    private fun resolveActiveSpeaker(bestPeer: String, bestRemote: Double, myLevel: Double) {
        val candidate: String? = when {
            myLevel >= SPEAKING_THRESHOLD && micOn.value && myLevel >= bestRemote -> ""
            bestRemote >= SPEAKING_THRESHOLD -> bestPeer
            else -> null
        }
        if (candidate == null) {
            speakerStreak.clear()
            if (activeSpeaker.value != null) activeSpeaker.value = null
            return
        }
        val streak = (speakerStreak[candidate] ?: 0) + 1
        speakerStreak.clear(); speakerStreak[candidate] = streak
        if (streak >= SPEAKER_DEBOUNCE && activeSpeaker.value != candidate) {
            activeSpeaker.value = candidate
        }
    }

    /** Bring the hairpin relay up for a peer whose ICE cannot pair. Idempotent. */
    private fun startHairpin(peer: String) {
        if (!hairpinPeers.add(peer)) return
        Log.i(TAG, "ice failed ${peer.take(8)} — relaying media over /webrtc/hairpin")
        // The relay IS the media path now, so the call is CONNECTED. Without saying so the UI sits on
        // "connecting" while audio is already flowing, and the dialing tone keeps looping.
        connecting.value = false
        inCall.value = true
        CallMediaBridge.activate(
            remote = peer,
            sessionId = sessionId,
            me = myHex,
            localVideoTrack = localVideo,
            eglBase = eglBase,
            factory = ensureFactory(),
        )
    }

    /**
     * Hand the microphone between WebRTC's audio device and the hairpin bridge's own recorder. Two
     * capture clients conflict, so when the relay takes over audio (ICE failed) WebRTC's dead audio
     * path is silenced; restored if ICE recovers. Only ever reached on the failed path, so it cannot
     * disturb a working direct call. Apple parity (`setNativeAudioSuspendedForHairpin`).
     */
    fun setNativeAudioSuspendedForHairpin(suspended: Boolean) {
        audioTrack?.setEnabled(!suspended && micOn.value)
    }

    /**
     * The relay produced a decoded remote video track — publish it into the same map the call UI
     * renders, so relayed video appears with no view changes.
     */
    fun adoptHairpinRemoteVideo(peer: String, track: VideoTrack) {
        mainHandler.post { remoteVideo[peer] = track }
    }

    fun dropHairpinRemoteVideo(peer: String) {
        mainHandler.post { if (remoteVideo[peer]?.id()?.startsWith("hairpin-") == true) remoteVideo.remove(peer) }
    }

    /** When the current call last had at least one live peer. Drives [checkStuckCall]. */
    private var lastPeerSeenMs = 0L

    /**
     * A call with no peers is not a call. End it.
     *
     * Teardown normally arrives with a hangup — but a hangup is one fire-and-forget frame, and if it
     * is lost (or gated, or the far end dies) nothing else ever clears `inCall`. The state then
     * sticks FOREVER: every later invite takes the "already in a call, they must be joining" branch,
     * so the phone stops ringing altogether and no notification is raised. That is a call that
     * worked once and then silently made the device unreachable — far worse than a dropped call,
     * because nothing on screen says anything is wrong.
     *
     * 45s with zero peers is well beyond any legitimate reconnect (ICE gives up sooner, and the
     * hairpin's own silence drop is 20s), so this only ever fires on a call that is already dead.
     */
    /** Called from the 2s live-call lane. Main-thread hop: call state is main-only. */
    fun noticeStuckCall() { mainHandler.post { checkStuckCall() } }

    private fun checkStuckCall() {
        if (!inCall.value) { lastPeerSeenMs = 0L; return }
        val now = System.currentTimeMillis()
        if (peers.isNotEmpty()) { lastPeerSeenMs = now; return }
        if (lastPeerSeenMs == 0L) { lastPeerSeenMs = now; return }
        if (now - lastPeerSeenMs < 45_000) return
        Log.i(TAG, "call ${sessionId.take(12)} has had NO peers for 45s — ending a call that is already gone")
        hangup()
    }

    private fun dropPeer(peer: String) {
        if (hairpinPeers.remove(peer)) CallMediaBridge.deactivate(peer)
        CallHairpin.close(peer)
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
    /** Open the camera at the best resolution it will accept. */
    private fun startCapture(cap: org.webrtc.VideoCapturer) {
        if (capturing) return
        // Fall back down the ladder: a 1280x720@30 request is fine on modern hardware and simply
        // FAILS on older sensors — and a failed startCapture leaves an enabled track publishing
        // nothing, which the far end renders as a permanently black tile rather than an error.
        for ((w, h, fps) in listOf(Triple(1280, 720, 30), Triple(960, 540, 30), Triple(640, 480, 30), Triple(640, 480, 15))) {
            val ok = runCatching { cap.startCapture(w, h, fps); true }.getOrElse {
                Log.w(TAG, "camera: startCapture ${w}x$h@$fps failed (${it.message})"); false
            }
            if (ok) { capturing = true; Log.i(TAG, "camera: capturing at ${w}x$h@$fps"); return }
        }
        Log.w(TAG, "camera: every capture format was refused — this device cannot publish video")
    }

    private fun stopCapture() {
        val cap = capturer ?: return
        if (!capturing) return
        runCatching { cap.stopCapture() }.onFailure { Log.w(TAG, "camera: stopCapture failed", it) }
        capturing = false
        Log.i(TAG, "camera: released")
    }

    /** True while the camera hardware is actually open. */
    private var capturing = false

    fun toggleCamera() {
        cameraOn.value = !cameraOn.value
        // If the track is missing the camera never came up — say so instead of no-opping in silence,
        // and try once more now (permission may have been granted since, or the camera may have been
        // held by another app when the call started).
        if (localVideo == null) {
            Log.w(TAG, "camera: no local video track — retrying capture now")
            // NOTE: peers created before this point have no video sender, so a track recovered here
            // reaches them only after the next renegotiation. The real guarantee is that
            // `startCamera` now publishes the track up front (disabled) so this path stays rare.
            runCatching { startCamera(ensureFactory()) }
        }
        // Drive the CAPTURER, not just the track. Enabling a track whose capture session never
        // delivered a frame publishes black forever — the far end sees a dead tile and there is
        // nothing on screen to say why. Turning the camera on now always opens a fresh session.
        val cap = capturer
        if (cameraOn.value) { if (cap != null) startCapture(cap) } else stopCapture()
        localVideo?.setEnabled(cameraOn.value)
            ?: Log.w(TAG, "camera: still no track after retry — this device cannot publish video")
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
        // Answered, declined, missed, or the caller gave up — in every case stop ringing the phone.
        runCatching { Notifications.clearIncomingCall(appContext) }
        releaseCallWakeLock()
        // Give the mic back. Holding a microphone-typed service after the call is a standing
        // privacy indicator for a mic nobody is using.
        runCatching { ConnectionService.endCall(appContext) }
        // Remember the session so the caller's still-in-flight invite retransmits can't re-ring it.
        if (sessionId.isNotEmpty()) {
            endedSessions[sessionId] = System.currentTimeMillis()
            if (endedSessions.size > 50) {   // prune long-expired tombstones
                val now = System.currentTimeMillis()
                endedSessions.entries.removeAll { now - it.value >= ENDED_TOMBSTONE_MS }
            }
        }
        mainHandler.removeCallbacks(ringTimeoutRunnable)
        stopSpeakerDetection()
        // Tear the relay down BEFORE the peers: it holds a microphone, two codecs and a WebSocket
        // per remote, none of which any other path releases.
        runCatching { CallMediaBridge.stopAll() }
        runCatching { CallHairpin.closeAll() }
        hairpinPeers.clear()
        peers.values.forEach { it.close() }; peers.clear()
        runCatching { screenCapturer?.stopCapture() }
        runCatching { screenCapturer?.dispose() }; screenCapturer = null
        runCatching { screenSurfaceHelper?.dispose() }; screenSurfaceHelper = null
        runCatching { screenTrack?.dispose() }; screenTrack = null
        runCatching { screenVideoSource?.dispose() }; screenVideoSource = null
        screenShare.value = false
        runCatching { capturer?.stopCapture() }
        capturing = false   // teardown releases the camera; the next call opens a fresh session
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
