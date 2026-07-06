import Foundation
import AVFoundation
import AVKit
import CoreImage
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import WebRTC
#if !os(macOS)
import CallKit
#endif
#if !targetEnvironment(macCatalyst) && !os(macOS)
import ReplayKit
#endif

/// Peer-to-peer **mesh** audio/video calls over **WebRTC**, fully **in-app** (CallKit is used only
/// for the system call UI + audio-session coordination on iOS — never to drive the mesh). The media
/// path is DTLS-SRTP (E2EE per pairwise connection); all signaling (invite/accept/hangup + SDP
/// offer/answer + ICE) rides Haven's existing sealed P2P channel — no call/signaling server.
///
/// A "group call" is a session (`sessionId` UUID) with a roster of participant node-id hexes. Every
/// participant opens ONE `WebRTCCall` to EVERY OTHER participant (full mesh — there is no SFU). A
/// 1:1 DM call is just a 2-person group. For each pair, the peer whose hex is lexicographically
/// SMALLER creates the offer and the larger answers (glare-free).
///
/// Wire frame types:
///   10 invite (legacy 1:1)  [hex64][name]
///   21 group-invite         [hex64][lp:sessionId][lp:groupName][lp:roster(csv of hexes)]
///   11 accept               [hex64][lp:sessionId?]
///   12 hangup               [hex64][lp:sessionId?]
///   16 SDP offer            [hex64][lp:sessionId?][json]
///   17 SDP answer           [hex64][lp:sessionId?][json]
///   18 ICE candidate        [hex64][lp:sessionId?][json]
/// The `hex64` prefix is always the SENDER's node-id hex — used to route 16/17/18 to the correct
/// per-peer `WebRTCCall`. The `lp:sessionId` is length-prefixed and OPTIONAL on 11/12/16/17/18 for
/// backward compatibility with the old single-session 1:1 path.
@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published private(set) var inCall = false
    @Published private(set) var connecting = false
    @Published private(set) var peerName = ""           // group/DM-partner display name (top bar)
    @Published private(set) var videoOn = false
    @Published private(set) var ringing = false
    @Published private(set) var speakerOn = false
    @Published private(set) var muted = false
    /// Collapsed to a floating pill so the user can use the rest of the app mid-call.
    @Published var minimized = false
    /// Per-peer remote video tracks for the grid (nil tile = audio-only / no camera).
    @Published private(set) var remoteVideoTracks: [String: RTCVideoTrack] = [:]
    /// Peers who signalled their camera is OFF. We show their avatar instead of the last (now frozen)
    /// video frame — a paused camera otherwise leaves a stale still on the other side.
    @Published private(set) var remoteCameraOff: Set<String> = []
    /// Per-peer remote SCREEN-share tracks (a peer's second video track, `screen0`). When non-empty
    /// the grid promotes that peer's screen to the dominant tile.
    @Published private(set) var remoteScreenTracks: [String: RTCVideoTrack] = [:]
    /// Whether WE are currently sharing our screen to the mesh.
    @Published private(set) var screenShareOn = false
    /// The roster of OTHER participants (hex order), drives the grid tiles.
    @Published private(set) var participants: [String] = []
    @Published private(set) var localVideoTrack: RTCVideoTrack?
    /// Whether the local camera is the front one — the self-preview mirrors only then (rear never).
    @Published private(set) var frontCamera = true
    /// The hex of the participant currently speaking, `""` for me (the local mic), or nil if nobody.
    /// Drives the glowing highlight on the active speaker's grid tile / local PiP.
    @Published private(set) var activeSpeaker: String?

    private var active = false        // a call exists (ringing, connecting, or in progress)
    private var isCaller = false
    /// True for the WHOLE call lifecycle (ringing → connecting → in progress). Feed/story/DM
    /// media playback checks this so post music and video audio never compete with call audio.
    var callInProgress: Bool { active }
    private var inviteTimer: Timer?   // caller resends the invite until someone answers

    // Group-call session.
    private var sessionId = ""
    /// All participant hexes INCLUDING me (canonical roster).
    private var roster: Set<String> = []
    private var lastPeerState: [String: RTCIceConnectionState] = [:]   // for the grace-then-drop on .disconnected
    /// One pairwise connection per OTHER participant.
    private var peers: [String: PeerConn] = [:]
    /// Whether we've started media at all (after accept / first offer).
    private var mediaStarted = false

    // Active-speaker detection.
    private var speakerTimer: Timer?
    /// How many consecutive polls each candidate has led, for debounce (key "" = me).
    private var speakerStreak: [String: Int] = [:]
    /// Audio level above which a participant is considered "speaking".
    private let speakingThreshold = 0.02
    /// Consecutive winning polls (≈300ms each) before we switch the highlight, to avoid flicker.
    private let speakerDebounce = 2

    // Mac in-app ringing (no CallKit on Catalyst).
    private var inAppRinging = false

    /// Per-peer connection + its candidate-buffering state.
    private final class PeerConn {
        let hex: String
        let call: WebRTCCall
        var remoteDescriptionSet = false
        var pendingCandidates: [RTCIceCandidate] = []
        init(hex: String, call: WebRTCCall) { self.hex = hex; self.call = call }
    }

    // CallKit: the system call UI + audio-session coordination. `callUUID` identifies the live
    // call to CallKit; `useManualAudio` hands WebRTC's audio unit to CallKit so it only goes live
    // in provider(_:didActivate:). CallKit is iOS-only — on Mac Catalyst `provider` stays nil and
    // we run a pure in-app flow + activate the audio session directly. ONE CXProvider call per
    // group (handle = group/DM name), regardless of how many mesh peers.
    #if !os(macOS)
    private var provider: CXProvider?
    private let controller = CXCallController()
    #endif
    private var callUUID: UUID?
    #if !os(macOS)
    private var useCallKit: Bool { provider != nil }
    #else
    private var useCallKit: Bool { false }   // native macOS: in-app flow drives everything
    #endif

    private var myHex: String { FeedStore.shared.myNodeHex }
    private var myName: String {
        let n = ProfileStore.shared.displayName
        return n.isEmpty ? "Someone" : n
    }

    override init() {
        super.init()
        #if !targetEnvironment(macCatalyst) && !os(macOS)
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = true
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        let p = CXProvider(configuration: cfg)
        p.setDelegate(self, queue: nil)
        provider = p
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        #endif
    }

    // MARK: - Length-prefixed field helpers (match FeedView's lpAppend/lpRead)

    private static func lpAppend(_ d: inout Data, _ field: Data) {
        let n = UInt16(min(field.count, 0xffff))
        d.append(UInt8(n & 0xff)); d.append(UInt8(n >> 8)); d.append(field.prefix(Int(n)))
    }
    private static func lpRead(_ d: Data, _ off: inout Int) -> Data? {
        guard d.count >= off + 2 else { return nil }
        let s = d.startIndex
        let n = Int(UInt16(d[s + off]) | UInt16(d[s + off + 1]) << 8)
        off += 2
        guard d.count >= off + n else { return nil }
        let field = d.subdata(in: (s + off)..<(s + off + n))
        off += n
        return field
    }

    // MARK: - Outgoing

    /// Start (or join) a call. Pass the full set of OTHER participant hexes. A 1:1 DM call is just
    /// `others = [partnerHex]`. `name` is the group / DM-partner display name shown in the UI.
    func startCall(participants others: [String], name: String, sessionId: String? = nil) {
        guard !active else { return }
        // Never dial blocked people (defense in depth — circle calls also pre-filter removed members).
        let invitees = others.filter { !$0.isEmpty && $0 != myHex && !ConnectionsStore.shared.isBlocked($0) }
        guard !invitees.isEmpty else { return }
        self.sessionId = sessionId ?? UUID().uuidString
        self.roster = Set(invitees).union([myHex])
        self.peerName = name; connecting = true; isCaller = true; active = true
        AudioCoordinator.shared.silenceForCall()   // call audio owns the stage from the first ring
        refreshParticipants()
        let uuid = UUID(); callUUID = uuid
        guard useCallKit else { beginOutgoing(); return }   // Catalyst/macOS: no CallKit, send invites directly
        #if !os(macOS)
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        action.isVideo = false
        controller.request(CXTransaction(action: action)) { [weak self] err in
            if err != nil { Task { @MainActor in self?.teardown() } }
        }
        #endif
    }

    /// Convenience for the existing 1:1 call sites.
    func startCall(peerHex: String, name: String) {
        startCall(participants: [peerHex], name: name)
    }

    /// Fired by CXStartCallAction: send the group invite to everyone + ONE push each, then keep
    /// retransmitting the iroh invite until somebody answers.
    private func beginOutgoing() {
        CallTones.shared.startRingback()   // gentle dialing loop until the first peer connects
        sendInvites()
        for p in invitees() { FeedStore.shared.pushCallInvite(to: p, callerName: myName) }
        var tries = 0
        inviteTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.connecting else { t.invalidate(); return }
                tries += 1
                if tries > 12 { t.invalidate(); self.endCall(); return }   // ~30s, then give up
                self.sendInvites()   // iroh frames only — no push
            }
        }
        #if !os(macOS)
        if let provider, let uuid = callUUID { provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil) }
        #endif
    }

    private func invitees() -> [String] { roster.subtracting([myHex]).sorted() }

    private func rosterCSV() -> String { roster.sorted().joined(separator: ",") }

    /// Add someone to the call already in progress: put them in the roster, ring them (group-invite +
    /// push), and re-send the updated roster to everyone already in so the newcomer meshes with all of
    /// them. Existing participants union the new roster on receipt and connect to the new peer.
    func addToCall(_ hex: String) {
        guard active, !hex.isEmpty, hex != myHex, !roster.contains(hex) else { return }
        roster.insert(hex)
        refreshParticipants()
        sendInvites()                                                  // updated roster → all invitees + newcomer
        FeedStore.shared.pushCallInvite(to: hex, callerName: myName)   // wake just the newcomer
    }

    /// Contacts not already in the call — the candidates for the in-call "add" button.
    func addableContacts() -> [(hex: String, name: String)] {
        ContactsStore.shared.contacts
            .filter { !roster.contains($0.idHex) && $0.idHex != myHex && !ConnectionsStore.shared.isBlocked($0.idHex) }
            .map { ($0.idHex, $0.displayName) }
    }

    /// Frame 21: group-invite carrying the session id + group name + full roster, sent to everyone.
    private func sendInvites() {
        var f = Data(myHex.utf8)
        CallManager.lpAppend(&f, Data(sessionId.utf8))
        CallManager.lpAppend(&f, Data(peerName.utf8))
        CallManager.lpAppend(&f, Data(rosterCSV().utf8))
        for p in invitees() { FeedStore.shared.sendCallFrame(21, f, to: p) }
    }

    // MARK: - Inbound signaling

    /// Legacy 1:1 invite (frame 10). Treated as a 2-person group with a synthetic session id.
    /// An UNSEALED call control frame's self-asserted sender must be a known contact — a stranger
    /// can't ring you, inject participants, or negotiate a call (audit F3). Sealed posts are already
    /// author-verified; this gates the call signaling, which is plaintext-authenticated only.
    private func knownContact(_ hex: String) -> Bool {
        ContactsStore.shared.contacts.contains { $0.idHex == hex }
    }

    func handleInvite(_ payload: Data) {
        guard payload.count > 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        let name = String(data: payload.dropFirst(64), encoding: .utf8) ?? "Someone"
        guard from.count == 64, knownContact(from) else { return }   // strangers can't ring you (F3)
        if active {
            if roster.isEmpty || !roster.contains(from) { roster.insert(from); refreshParticipants() }
            return
        }
        sessionId = "legacy:\(from)"
        roster = [from, myHex]
        // Show the CALLER's name, not the name they sent (which is *our* name for a DM call).
        peerName = displayName(for: from); isCaller = false; active = true
        refreshParticipants()
        reportIncoming(name: name)
    }

    /// Group invite (frame 21): set up the session + full roster, then show the incoming UI.
    func handleGroupInvite(_ payload: Data) {
        guard payload.count > 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64, knownContact(from) else { return }   // only contacts can invite you (F3)
        let body = payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex)
        var off = 0
        guard let sid = CallManager.lpRead(body, &off),
              let gname = CallManager.lpRead(body, &off),
              let rosterData = CallManager.lpRead(body, &off) else { return }
        let sid2 = String(data: sid, encoding: .utf8) ?? ""
        let gname2 = String(data: gname, encoding: .utf8) ?? "Group call"
        let rosterStr = String(data: rosterData, encoding: .utf8) ?? ""
        var members = Set(rosterStr.split(separator: ",").map(String.init).filter { $0.count == 64 })
        members.insert(from); members.insert(myHex)
        guard !sid2.isEmpty else { return }

        if active {
            // Same session, new roster info → merge (someone learned about more participants).
            if sessionId == sid2 {
                let added = members.subtracting(roster)
                roster.formUnion(members)
                refreshParticipants()
                // If media is already up, dial any newly-known peers per the glare rule.
                if mediaStarted { for p in added where p != myHex { connectPeerIfNeeded(p) } }
            } else if sessionId.hasPrefix("push:"), roster.contains(from) {
                // A VoIP push rang us first with a PLACEHOLDER session ("push:<caller>") — this
                // frame is the REAL invite catching up. It used to be DROPPED here (session-id
                // mismatch), so a call answered from the CallKit screen never adopted the real
                // session: every later SDP frame failed validSession and the call sat dead. Adopt
                // the real id + roster; if the user already answered, re-accept under the real id
                // so the caller proceeds.
                sessionId = sid2
                roster.formUnion(members)
                peerName = members.count <= 2 ? displayName(for: from) : (gname2.isEmpty ? peerName : gname2)
                refreshParticipants()
                if inCall { for p in invitees() { sendAccept(to: p) } }
            }
            return
        }
        sessionId = sid2; roster = members
        // A 1:1 call's "group name" is really the callee's own name (what the caller called us), so
        // displaying it verbatim made both ends show the same person. Resolve the caller's name from
        // their hex instead; only true group calls use the shared group name.
        peerName = members.count <= 2 ? displayName(for: from) : (gname2.isEmpty ? "Group call" : gname2)
        isCaller = false; active = true
        refreshParticipants()
        reportIncoming(name: peerName)
    }

    /// A VoIP push woke us for an incoming call — set up state + show the system call screen.
    func reportIncomingFromPush(name: String, peerHex: String) {
        guard !active else { return }
        peerName = name
        if peerHex.count == 64 {
            sessionId = "push:\(peerHex)"; roster = [peerHex, myHex]
        }
        isCaller = false; active = true
        refreshParticipants()
        reportIncoming(name: name)
    }

    func reportIncoming(name: String) {
        AudioCoordinator.shared.silenceForCall()   // stop feed music/video audio before the ring
        let uuid = callUUID ?? UUID(); callUUID = uuid
        #if os(macOS)
        ringing = true; startInAppRinging(); return   // native macOS: in-app overlay + ring
        #else
        guard useCallKit, let provider else { ringing = true; startInAppRinging(); return }   // Catalyst: in-app overlay + ring
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if err != nil { self.teardown() } else { self.ringing = true }
            }
        }
        #endif
    }

    // MARK: - Mac in-app ringing (no CallKit)

    /// Play a looping ringtone and bring the window forward so a Mac user notices an incoming call.
    /// No-op on iOS (CallKit drives the system ring there).
    private func startInAppRinging() {
        #if targetEnvironment(macCatalyst) || os(macOS)
        guard !inAppRinging else { return }
        inAppRinging = true
        // Ensure the audio session is live so the synthesized ringtone is audible (iOS/Catalyst only;
        // native macOS has no AVAudioSession).
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        #endif
        CallTones.shared.startRingtone()
        bringWindowToFront()
        #endif
    }

    private func stopInAppRinging() {
        #if targetEnvironment(macCatalyst) || os(macOS)
        guard inAppRinging else { return }
        inAppRinging = false
        CallTones.shared.stop()
        // Only relax the session if we're not about to bring up the call audio.
        #if os(iOS)
        if !mediaStarted {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        #endif
    }

    /// Make the app's window key & visible and request user attention (bounce the Dock icon) so the
    /// incoming-call overlay is seen even when Haven is in the background.
    private func bringWindowToFront() {
        #if os(macOS)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #elseif targetEnvironment(macCatalyst)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
            for window in scene.windows where window.canBecomeKey {
                window.makeKeyAndVisible()
            }
        }
        #endif
    }

    func accept() {
        #if os(macOS)
        reallyAccept(); return
        #else
        guard useCallKit, let uuid = callUUID else { reallyAccept(); return }
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { _ in }
        #endif
    }
    func decline() {
        #if os(macOS)
        reallyEnd(); return
        #else
        guard useCallKit, let uuid = callUUID else { reallyEnd(); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        #endif
    }

    /// Fired by CXAnswerCallAction (system UI or our button): really pick up. Accept-frame goes to
    /// EVERY other participant so they know to start dialing us; then we bring up media + mesh.
    private func reallyAccept() {
        ringing = false; stopInAppRinging(); inCall = true
        for p in invitees() { sendAccept(to: p) }
        startMesh()
    }

    private func sendAccept(to peer: String) {
        var f = Data(myHex.utf8)
        CallManager.lpAppend(&f, Data(sessionId.utf8))
        FeedStore.shared.sendCallFrame(11, f, to: peer)
    }

    /// Caller side: a callee accepted → stop re-inviting, bring up media + dial that peer.
    func handleAccept(_ payload: Data) {
        guard active, payload.count >= 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64, knownContact(from) else { return }   // only a contact can accept (F3)
        inviteTimer?.invalidate(); inviteTimer = nil
        connecting = false; inCall = true
        if !roster.contains(from) { roster.insert(from); refreshParticipants() }
        startMesh()
        connectPeerIfNeeded(from)
    }

    func handleHangup(_ payload: Data) {
        guard active, payload.count >= 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64 else { return }
        // One peer leaving does NOT end the call for the rest — only drop that connection. The call
        // ends only when nobody else is left.
        dropPeer(from)
        let remaining = roster.subtracting([myHex])
        if remaining.isEmpty {
            #if !os(macOS)
            if let provider, let uuid = callUUID { provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
            #endif
            teardown()
        }
    }

    func handleOffer(_ payload: Data) {
        guard let (from, sid, json) = parseSignal(payload), validSession(sid),
              roster.contains(from) else { return }   // only a session participant negotiates (F3)
        // First real signal into a VoIP-push placeholder session → adopt the caller's session id
        // (the answer-before-invite ordering: our accept went out under "push:<caller>", the
        // caller ignored the sid and dialed us — this offer carries the real id).
        if sessionId.hasPrefix("push:"), !sid.isEmpty { sessionId = sid }
        if !mediaStarted { startMesh() }
        let peer = peerConn(for: from)
        guard let sdp = CallSignal.decodeSDP(json) else { return }
        peer.call.setRemoteOfferAndAnswer(sdp)   // flushes candidates via onRemoteReady
    }
    func handleAnswer(_ payload: Data) {
        guard let (from, sid, json) = parseSignal(payload), validSession(sid), roster.contains(from),
              let peer = peers[from], let sdp = CallSignal.decodeSDP(json) else { return }
        peer.call.setRemoteAnswer(sdp)
    }
    func handleIce(_ payload: Data) {
        guard let (from, sid, json) = parseSignal(payload), validSession(sid), roster.contains(from),
              let cand = CallSignal.decodeCandidate(json) else { return }
        let peer = peerConn(for: from)
        if peer.remoteDescriptionSet { peer.call.addRemoteCandidate(cand) }
        else { peer.pendingCandidates.append(cand) }
    }

    /// Decode `[hex64][lp:sessionId?][json]`. The session id is optional (legacy 1:1 frames omit it),
    /// in which case we infer it from the active session.
    private func parseSignal(_ payload: Data) -> (from: String, sid: String, json: Data)? {
        guard payload.count > 64 else { return nil }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64 else { return nil }
        let body = payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex)
        // Try to read a length-prefixed session id followed by JSON. JSON always starts with '{'.
        var off = 0
        if let sidData = CallManager.lpRead(body, &off),
           let sid = String(data: sidData, encoding: .utf8),
           !sid.isEmpty, off < body.count,
           body[body.startIndex + off] == UInt8(ascii: "{") {
            let json = body.subdata(in: (body.startIndex + off)..<body.endIndex)
            return (from, sid, json)
        }
        // Legacy framing: body is raw JSON. Use the active session id.
        return (from, sessionId, body)
    }

    private func validSession(_ sid: String) -> Bool {
        // Accept frames for the active session; also accept legacy/inferred ids when we only have
        // one session. Mismatched concurrent sessions are dropped. A "push:" session is a VoIP-push
        // PLACEHOLDER (we were rung before the real invite reached us) — the signal's sid IS the
        // real session, so accept it; the sender is still gated by roster membership at every call
        // site, so only the pushed caller (or their roster) can speak into the placeholder.
        return sid == sessionId || sessionId.isEmpty || sessionId.hasPrefix("push:")
    }

    func handleAudio(_ payload: Data) {}
    func handleVideo(_ payload: Data) {}

    // MARK: - Mesh setup

    /// Bring up the audio session + create per-peer connections for every other participant. The
    /// glare rule (smaller hex offers) determines who sends the first offer.
    private func startMesh() {
        guard !mediaStarted else { return }
        mediaStarted = true
        CallTones.shared.startRingback()   // keep ringing until the FIRST peer connects
        #if !os(macOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        configureAudioSession()
        for p in invitees() { connectPeerIfNeeded(p) }
        startSpeakerDetection()
    }

    // MARK: - Active-speaker detection

    /// Poll WebRTC audio levels (~300ms) across all pairwise connections: the loudest inbound peer
    /// vs. our own outbound mic level. A small debounce + threshold keep `activeSpeaker` from
    /// flickering between near-silent participants.
    private func startSpeakerDetection() {
        guard speakerTimer == nil else { return }
        speakerTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAudioLevels() }
        }
    }

    private func stopSpeakerDetection() {
        speakerTimer?.invalidate(); speakerTimer = nil
        speakerStreak.removeAll()
        activeSpeaker = nil
    }

    private func pollAudioLevels() {
        let conns = Array(peers.values)
        guard !conns.isEmpty else { return }
        // Gather one async stats read per connection, then pick the loudest once all return.
        var remaining = conns.count
        var bestPeer = ""           // loudest remote peer hex
        var bestRemote = 0.0
        var myLevel = 0.0           // loudest local outbound level across connections
        for conn in conns {
            let hex = conn.hex
            conn.call.audioLevels { inbound, outbound in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if inbound > bestRemote { bestRemote = inbound; bestPeer = hex }
                    if outbound > myLevel { myLevel = outbound }
                    remaining -= 1
                    if remaining == 0 { self.resolveActiveSpeaker(bestPeer: bestPeer, bestRemote: bestRemote, myLevel: myLevel) }
                }
            }
        }
    }

    /// Decide the active speaker from this poll's loudest remote peer and our own mic level, with a
    /// short debounce so a momentary blip doesn't steal the highlight.
    private func resolveActiveSpeaker(bestPeer: String, bestRemote: Double, myLevel: Double) {
        // Candidate = whoever is loudest this tick, if above threshold. "" represents me.
        var candidate: String?
        if myLevel >= speakingThreshold && (!muted) && myLevel >= bestRemote {
            candidate = ""
        } else if bestRemote >= speakingThreshold {
            candidate = bestPeer
        }

        guard let candidate else {
            // Nobody clearly speaking — decay toward clearing the highlight.
            speakerStreak.removeAll()
            if activeSpeaker != nil { activeSpeaker = nil }
            return
        }
        // Count this candidate's streak; reset everyone else.
        let streak = (speakerStreak[candidate] ?? 0) + 1
        speakerStreak = [candidate: streak]
        if streak >= speakerDebounce, activeSpeaker != candidate {
            activeSpeaker = candidate
        }
    }

    /// Ensure a `WebRTCCall` exists for `peer`; if I'm the offerer (smaller hex), kick off the offer.
    @discardableResult
    private func connectPeerIfNeeded(_ peer: String) -> PeerConn {
        let conn = peerConn(for: peer)
        if myHex < peer && mediaStarted {   // glare-free: smaller hex offers
            conn.call.makeOffer()
        }
        return conn
    }

    /// Get-or-create the pairwise connection for `peer`, wiring its callbacks.
    private func peerConn(for peer: String) -> PeerConn {
        if let existing = peers[peer] { return existing }
        if !roster.contains(peer) { roster.insert(peer); refreshParticipants() }
        let c = WebRTCCall()
        // Perfect-negotiation politeness: the larger-hex side is polite (yields on glare). This
        // lets EITHER side renegotiate when it adds a track (see renegotiateAll) without breaking.
        c.polite = myHex > peer
        let conn = PeerConn(hex: peer, call: c)
        // Sync the new connection to the current call state (mic/video).
        if muted { c.setMicEnabled(false) }
        c.onLocalSDP = { [weak self] sdp in
            Task { @MainActor in
                guard let self else { return }
                let type: UInt8 = sdp.type == .offer ? 16 : 17
                var f = Data(self.myHex.utf8)
                CallManager.lpAppend(&f, Data(self.sessionId.utf8))
                f.append(CallSignal.encodeSDP(sdp))
                FeedStore.shared.sendCallFrame(type, f, to: peer)
            }
        }
        c.onLocalCandidate = { [weak self] cand in
            Task { @MainActor in
                guard let self else { return }
                var f = Data(self.myHex.utf8)
                CallManager.lpAppend(&f, Data(self.sessionId.utf8))
                f.append(CallSignal.encodeCandidate(cand))
                FeedStore.shared.sendCallFrame(18, f, to: peer)
            }
        }
        c.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor in
                guard let self else { return }
                // The screen-share track is published separately so the grid can promote it.
                if track.trackId == WebRTCCall.screenTrackId {
                    self.remoteScreenTracks[peer] = track
                } else {
                    self.remoteVideoTracks[peer] = track
                }
            }
        }
        c.onRemoteVideoTrackEnded = { [weak self] trackId in
            Task { @MainActor in
                guard let self else { return }
                if trackId == WebRTCCall.screenTrackId { self.remoteScreenTracks[peer] = nil }
                else { self.remoteVideoTracks[peer] = nil }
            }
        }
        c.onRemoteReady = { [weak self] in
            Task { @MainActor in
                guard let self, let conn = self.peers[peer] else { return }
                conn.remoteDescriptionSet = true
                conn.pendingCandidates.forEach { conn.call.addRemoteCandidate($0) }
                conn.pendingCandidates.removeAll()
            }
        }
        c.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if state == .connected || state == .completed {
                    self.connecting = false; self.inCall = true
                    CallTones.shared.stop()   // first peer connected → stop the dialing loop
                    #if !os(macOS)
                    if self.isCaller, let provider = self.provider, let uuid = self.callUUID {
                        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
                    }
                    #endif
                } else if state == .failed || state == .closed {
                    // A single pairwise link dying drops just that peer; the call ends only when
                    // there's nobody left.
                    self.dropPeer(peer)
                    if self.roster.subtracting([self.myHex]).isEmpty { self.endCall() }
                } else if state == .disconnected {
                    // The link went quiet — a transient blip, OR the peer left and their fire-and-forget
                    // hangup frame never reached us (the "hanging up on Android didn't end the call on iOS"
                    // case). WebRTC otherwise sits in .disconnected for a long ICE-failure timeout before
                    // reaching .failed. Give it a short grace, then drop if it hasn't recovered.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self, self.peers[peer] != nil,
                              self.lastPeerState[peer] == .disconnected else { return }
                        self.dropPeer(peer)
                        if self.roster.subtracting([self.myHex]).isEmpty { self.endCall() }
                    }
                }
                self.lastPeerState[peer] = state
            }
        }
        // If video is already on, add our camera track to this new connection too.
        if videoOn { c.startVideo() }
        // If we're already sharing our screen, add the screen track to this new peer as well.
        if screenShareOn { c.startScreenShare() }
        peers[peer] = conn
        return conn
    }

    /// Remove a peer from the roster + tear down its connection + its remote tile.
    private func dropPeer(_ peer: String) {
        peers[peer]?.call.close()
        peers[peer] = nil
        remoteVideoTracks[peer] = nil
        remoteScreenTracks[peer] = nil
        remoteCameraOff.remove(peer)
        roster.remove(peer)
        lastPeerState[peer] = nil
        refreshParticipants()
    }

    private func refreshParticipants() {
        participants = roster.subtracting([myHex]).sorted()
    }

    private func configureAudioSession() {
        // `RTCAudioSession` / `AVAudioSession` routing is iOS/Catalyst-only; native macOS manages the
        // audio device itself and WebRTC drives it without a session.
        #if os(iOS)
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
        try? session.setMode(.voiceChat)
        #if targetEnvironment(macCatalyst)
        try? session.setActive(true)
        #endif
        session.unlockForConfiguration()
        #if targetEnvironment(macCatalyst)
        session.isAudioEnabled = true
        #endif
        installAudioSessionObservers()
        #endif
    }

    #if os(iOS)
    // MARK: - Audio-session recovery
    //
    // iOS can tear call audio down mid-call: a Siri/phone-call interruption, or mediaserverd dying
    // under system memory pressure ("media services were reset"). Without handling those, the call
    // goes PERMANENTLY silent in both directions — the mic and playout units are dead, the speaker
    // override is lost (the button visibly flips off), and re-toggling the speaker only sets an
    // override on a dead session. Recovery = reconfigure + reactivate the session, then bounce
    // WebRTC's audio unit so it rebuilds capture/playout on the fresh session (Apple QA1749).
    private var audioObserversInstalled = false
    private func installAudioSessionObservers() {
        guard !audioObserversInstalled else { return }
        audioObserversInstalled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in CallManager.shared.recoverCallAudio(reason: "media services reset") }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in CallManager.shared.recoverCallAudio(reason: "interruption ended") }
        }
        // Keep the speaker button honest: a route change (headset unplug, session reset) can move
        // output off the speaker — reflect reality instead of showing a stale toggle.
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in CallManager.shared.syncSpeakerState() }
        }
    }

    private func recoverCallAudio(reason: String) {
        guard active else { return }
        HavenLog.net("call audio recovery (\(reason))")
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        try? rtc.setCategory(.playAndRecord, with: [.allowBluetooth, .defaultToSpeaker])
        try? rtc.setMode(.voiceChat)
        try? rtc.setActive(true)
        try? rtc.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        rtc.unlockForConfiguration()
        // Bounce the audio unit so WebRTC tears down + rebuilds capture/playout on the new session.
        rtc.isAudioEnabled = false
        rtc.isAudioEnabled = true
    }

    private func syncSpeakerState() {
        guard active else { return }
        let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType == .builtInSpeaker }
        if speakerOn != onSpeaker { speakerOn = onSpeaker }
    }
    #endif

    // MARK: - Controls (apply to ALL pairwise connections)

    func toggleSpeaker() {
        speakerOn.toggle()
        #if os(iOS)
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        s.unlockForConfiguration()
        #endif
    }

    func toggleMute() {
        // Route through CallKit when it's driving the call so the system mute button and ours stay
        // in sync (otherwise the two toggles fight). CallKit echoes the change back to our
        // CXSetMutedCallAction handler, which applies it. No CallKit on Catalyst/macOS → apply now.
        if useCallKit { requestCallKitMuted(!muted) }
        else { applyMuted(!muted) }
    }

    /// Apply a muted state to the local audio tracks. Does NOT re-notify CallKit (avoids a loop) —
    /// callers that originate from CallKit, or from `toggleMute` on non-CallKit platforms, use this.
    private func applyMuted(_ m: Bool) {
        muted = m
        for conn in peers.values { conn.call.setMicEnabled(!m) }
    }

    /// Ask CallKit to change the mute state; its handler echoes back into `applyMuted`.
    private func requestCallKitMuted(_ m: Bool) {
        #if !targetEnvironment(macCatalyst) && !os(macOS)
        guard useCallKit, let uuid = callUUID else { applyMuted(m); return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: m))) { _ in }
        #else
        applyMuted(m)
        #endif
    }

    func toggleVideo() {
        if videoOn {
            videoOn = false; localVideoTrack = nil
            for conn in peers.values { conn.call.stopVideo() }
            broadcastCameraState(false)   // tell peers to drop my (now frozen) frame → show my avatar
            renegotiateAll()
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                Task { @MainActor in
                    guard let self else { return }
                    for conn in self.peers.values { conn.call.startVideo() }
                    self.localVideoTrack = self.peers.values.first?.call.localVideoTrack
                    self.frontCamera = self.peers.values.first?.call.usingFrontCamera ?? true
                    self.videoOn = true
                    self.broadcastCameraState(true)
                    self.renegotiateAll()
                }
            }
        }
    }

    /// Frame 22: tell every peer whether my camera is on, so they show live video vs. my avatar
    /// immediately (instead of a frozen last frame) when I pause the camera.
    private func broadcastCameraState(_ on: Bool) {
        var f = Data(myHex.utf8)
        CallManager.lpAppend(&f, Data(sessionId.utf8))
        f.append(on ? 1 : 0)
        for p in invitees() { FeedStore.shared.sendCallFrame(22, f, to: p) }
    }

    /// A peer signalled their camera on/off (frame 22).
    func handleCameraState(_ payload: Data) {
        guard payload.count > 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64, roster.contains(from) else { return }   // only a participant (F3/F4)
        let on = payload.last == 1   // trailing flag byte
        if on { remoteCameraOff.remove(from) } else { remoteCameraOff.insert(from) }
    }

    /// Adding/removing a track mid-call needs a fresh offer from the side that changed — a track I
    /// add only reaches a peer if *I* offer it (a peer's offer can't describe my new sender). So
    /// every peer re-offers here regardless of hex; perfect negotiation (politeness set in
    /// peerConn) keeps the rare both-sides-at-once case glare-free. (The old smaller-hex-only rule
    /// is exactly why the larger-hex device — e.g. the iPhone — could never share its video back.)
    private func renegotiateAll() {
        guard inCall || mediaStarted else { return }
        for conn in peers.values { conn.call.makeOffer() }
    }

    func flipCamera() {
        guard videoOn else { return }
        for conn in peers.values { conn.call.flipCamera() }
        frontCamera = peers.values.first?.call.usingFrontCamera ?? frontCamera
    }

    // MARK: - Device selection (Mac / desktop menus)

    /// All available cameras (uniqueID, localizedName) for the camera-picker menu.
    func availableCameras() -> [(id: String, name: String)] {
        RTCCameraVideoCapturer.captureDevices().map { ($0.uniqueID, $0.localizedName) }
    }

    /// The uniqueID of the camera currently in use (for a menu checkmark), if any.
    var currentCameraID: String? { peers.values.first?.call.currentCameraUniqueID }

    /// Switch every pairwise connection's capture to the chosen camera.
    func selectCamera(_ deviceUniqueID: String) {
        guard videoOn else { return }
        for conn in peers.values { conn.call.selectCamera(deviceUniqueID) }
        frontCamera = peers.values.first?.call.usingFrontCamera ?? frontCamera
    }

    // MARK: - Screen sharing (a SECOND video track, coexists with the camera)

    /// macOS: the list of pickable displays + windows for the share sheet.
    #if targetEnvironment(macCatalyst) || os(macOS)
    @Published private(set) var screenSources: [ScreenSource] = []
    @Published var showScreenPicker = false

    /// Populate `screenSources` and present the picker.
    func presentScreenPicker() {
        guard #available(macCatalyst 18.2, macOS 13, *) else { return }
        Task { @MainActor in
            self.screenSources = await ScreenShareManager.shared.availableSources()
            self.showScreenPicker = true
        }
    }

    /// Begin sharing the chosen display/window to the whole mesh.
    func startScreenShare(_ source: ScreenSource) {
        guard #available(macCatalyst 18.2, macOS 13, *), !screenShareOn else { return }
        showScreenPicker = false
        wireScreenFrameSink()
        Task { @MainActor in
            await ScreenShareManager.shared.start(source: source)
            guard ScreenShareManager.shared.isSharing else { return }
            self.beginScreenTracks()
        }
    }
    #else
    /// iOS: start listening for frames from the broadcast extension. The user kicks off the actual
    /// system broadcast via `RPSystemBroadcastPickerView` in the UI. Once frames flow we add the
    /// screen track to the mesh.
    func startScreenShareListening() {
        guard !screenShareOn else { return }
        wireScreenFrameSink()
        ScreenShareManager.shared.startListeningForBroadcast()
        beginScreenTracks()
    }
    #endif

    /// Stop sharing our screen and remove the screen track from every peer.
    func stopScreenShare() {
        guard screenShareOn else { return }
        ScreenShareManager.shared.stop()
        screenShareOn = false
        var changed = false
        for conn in peers.values { if conn.call.stopScreenShare() { changed = true } }
        // The iOS ReplayKit broadcast suspends the app's camera capture session while it runs; removing
        // the screen track doesn't bring it back, so the user's video0 track stays live but frame-less
        // ("can't broadcast video after stopping screen share"). Restart the camera capture if it was on.
        #if os(iOS)
        if videoOn { for conn in peers.values { conn.call.startVideo() } }
        #endif
        if changed { renegotiateAll() }
    }

    /// Toggle entry point used by the UI button (macOS opens the picker; iOS toggles the listener).
    func toggleScreenShare() {
        if screenShareOn { stopScreenShare(); return }
        #if targetEnvironment(macCatalyst) || os(macOS)
        presentScreenPicker()
        #else
        startScreenShareListening()
        #endif
    }

    /// Add the screen-share track to every mesh peer and renegotiate.
    private func beginScreenTracks() {
        screenShareOn = true
        var changed = false
        for conn in peers.values { if conn.call.startScreenShare() { changed = true } }
        if changed { renegotiateAll() }
    }

    /// Route captured screen frames into every peer's screen source; auto-clean on stop.
    private func wireScreenFrameSink() {
        ScreenShareManager.shared.onFrame = { [weak self] pixelBuffer, ts in
            guard let self else { return }
            for conn in self.peers.values { conn.call.pushScreenFrame(pixelBuffer, timeStampNs: ts) }
        }
        ScreenShareManager.shared.onStop = { [weak self] in
            Task { @MainActor in self?.stopScreenShare() }
        }
    }

    /// All available audio inputs (uid, portName) for the mic-picker menu. AVAudioSession enumeration
    /// is iOS/Catalyst-only; native macOS has no session so we surface nothing (device picking is
    /// system-managed).
    func availableMicInputs() -> [(uid: String, name: String)] {
        #if os(iOS)
        return (AVAudioSession.sharedInstance().availableInputs ?? []).map { ($0.uid, $0.portName) }
        #else
        return []
        #endif
    }

    /// The portName of the current preferred/active input (for a menu checkmark), if any.
    var currentMicName: String? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if let pref = session.preferredInput { return pref.portName }
        return session.currentRoute.inputs.first?.portName
        #else
        return nil
        #endif
    }

    /// Set the preferred audio input by its port uid.
    func selectMicInput(_ uid: String) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard let port = (session.availableInputs ?? []).first(where: { $0.uid == uid }) else { return }
        try? session.setPreferredInput(port)
        #endif
    }

    /// Current audio output name(s) — on Mac, output is system-managed, so we surface it as a label.
    var currentOutputName: String {
        #if os(iOS)
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outs.isEmpty { return "Default" }
        return outs.map(\.portName).joined(separator: ", ")
        #else
        return "Default"
        #endif
    }

    // MARK: - End

    func endCall() {
        #if os(macOS)
        reallyEnd(); return
        #else
        guard useCallKit, let uuid = callUUID else { reallyEnd(); return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        #endif
    }

    /// Fired by CXEndCallAction (system UI or our button): send hangup to ALL participants + tear down.
    private func reallyEnd() {
        for p in invitees() {
            var f = Data(myHex.utf8)
            CallManager.lpAppend(&f, Data(sessionId.utf8))
            FeedStore.shared.sendCallFrame(12, f, to: p)
        }
        teardown()
    }

    private func teardown() {
        CallTones.shared.stop()
        stopInAppRinging()
        stopSpeakerDetection()
        #if !os(macOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        inviteTimer?.invalidate(); inviteTimer = nil
        if screenShareOn { ScreenShareManager.shared.stop() }
        ScreenShareManager.shared.onFrame = nil
        ScreenShareManager.shared.onStop = nil
        for conn in peers.values { conn.call.close() }
        peers.removeAll()
        #if os(iOS)
        let audio = RTCAudioSession.sharedInstance()
        audio.isAudioEnabled = false
        #if targetEnvironment(macCatalyst)
        audio.lockForConfiguration(); try? audio.setActive(false); audio.unlockForConfiguration()
        #endif
        #endif
        remoteVideoTracks.removeAll(); remoteScreenTracks.removeAll(); remoteCameraOff.removeAll(); participants = []
        localVideoTrack = nil; videoOn = false; screenShareOn = false
        ringing = false; speakerOn = false; muted = false; minimized = false
        isCaller = false; mediaStarted = false
        active = false; inCall = false; connecting = false; peerName = ""
        sessionId = ""; roster.removeAll()
        callUUID = nil
    }

    // MARK: - UI helpers

    /// Display name for a participant tile (resolved from contacts; falls back to a short hex).
    func displayName(for hex: String) -> String {
        ContactsStore.shared.name(forNodePrefix: hex) ?? String(hex.prefix(6))
    }

    /// Put the overlay into a connected group-call state for a screenshot, with no real signaling
    /// or media. HAVEN_DEMO-gated so it can never fire in a shipping build. The participant tiles
    /// render the brand-gradient + initial placeholders (no camera), which is exactly the populated
    /// group-call look we want to capture.
    func enterDemoCall(participants: [String], name: String) {
        guard ProcessInfo.processInfo.environment["HAVEN_DEMO"] == "1" else { return }
        peerName = name
        self.participants = participants
        activeSpeaker = participants.first
        connecting = false
        inCall = true
    }
}

// MARK: - CallKit

// CallKit (`CXProvider`/`CXProviderDelegate`/`CX*Action`) and the `AVAudioSession`-typed activation
// callbacks are iOS/Catalyst-only. On native macOS the in-app `CallOverlay` buttons drive the call
// flow directly, so the entire delegate is compiled out.
#if !os(macOS)
extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.teardown() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in self.beginOutgoing(); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in self.reallyAccept(); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in self.reallyEnd(); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        // The system mute button (or our own toggle, routed through CallKit) lands here — apply it
        // to the audio tracks so the CallKit screen and the in-app screen never disagree.
        Task { @MainActor in self.applyMuted(action.isMuted); action.fulfill() }
    }
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(audioSession)
        rtc.isAudioEnabled = true
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(audioSession)
        rtc.isAudioEnabled = false
    }
}
#endif

// MARK: - Video views

#if !os(macOS)
/// Renders a WebRTC video track with Metal (iOS/Catalyst — `RTCMTLVideoView`).
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    /// Aspect-FIT (letterbox, no crop) — used for shared screens so nothing is cut off. Camera
    /// tiles default to aspect-FILL so faces fill the frame.
    var fit: Bool = false
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        return v
    }
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.videoContentMode = fit ? .scaleAspectFit : .scaleAspectFill
        context.coordinator.bind(track, to: uiView)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        private weak var bound: RTCVideoTrack?
        func bind(_ track: RTCVideoTrack?, to view: RTCMTLVideoView) {
            guard bound !== track else { return }
            bound?.remove(view)
            bound = track
            track?.add(view)
        }
    }
}
#else
/// Native-macOS WebRTC video renderer. The stasel/WebRTC macOS slice ships the `RTCMTLNSVideoView`
/// header but NOT its implementation (the class isn't in the binary), so we render frames ourselves
/// via a layer-backed `NSView` conforming to `RTCVideoRenderer`: pull the `CVPixelBuffer` out of each
/// `RTCVideoFrame`, turn it into a `CGImage` with a cached `CIContext`, and set it as `layer.contents`.
final class RTCNSVideoRenderer: NSView, RTCVideoRenderer {
    /// Aspect-FILL (crop to fill) when `fit == false`; aspect-FIT (letterbox) when `fit == true`.
    var fit: Bool = false {
        didSet { applyGravity() }
    }
    /// Reused across frames — creating a `CIContext` per frame is very expensive.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    /// Last reported frame size from `setSize`, kept for layout/debug (no-op layout is fine).
    private var frameSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        applyGravity()
    }

    private func applyGravity() {
        layer?.contentsGravity = fit ? .resizeAspect : .resizeAspectFill
    }

    // MARK: RTCVideoRenderer

    func setSize(_ size: CGSize) {
        // Store it; layout is driven by the SwiftUI frame + layer gravity, so this is a no-op.
        frameSize = size
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        // `renderFrame` is invoked off the main thread by WebRTC; CVPixelBuffer → CGImage conversion
        // is fine to do here, but all layer mutation must happen on the main queue.
        guard let frame else { return }

        // Only the CVPixelBuffer-backed path is supported. The I420 path would require allocating a
        // CVPixelBuffer and copying planes — skip those frames rather than risk a bad conversion.
        guard let pixelBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }

        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Respect rotation if present (the easy cases). RTCVideoFrame.rotation is in degrees.
        switch frame.rotation {
        case ._90:  ciImage = ciImage.oriented(.right)
        case ._180: ciImage = ciImage.oriented(.down)
        case ._270: ciImage = ciImage.oriented(.left)
        default: break   // ._0 — no rotation
        }

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = cgImage
        }
    }
}

/// Renders a WebRTC video track on native macOS via the custom `RTCNSVideoRenderer`. Same public
/// surface (`track`, `fit`) as the iOS `RTCVideoView` so call sites are unchanged.
struct RTCVideoView: NSViewRepresentable {
    let track: RTCVideoTrack?
    /// Aspect-FIT (letterbox, no crop) — used for shared screens so nothing is cut off. Camera
    /// tiles default to aspect-FILL so faces fill the frame.
    var fit: Bool = false
    func makeNSView(context: Context) -> RTCNSVideoRenderer {
        let v = RTCNSVideoRenderer()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.fit = fit
        return v
    }
    func updateNSView(_ nsView: RTCNSVideoRenderer, context: Context) {
        nsView.fit = fit
        context.coordinator.bind(track, to: nsView)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        private weak var bound: RTCVideoTrack?
        func bind(_ track: RTCVideoTrack?, to view: RTCNSVideoRenderer) {
            guard bound !== track else { return }
            bound?.remove(view)
            bound = track
            track?.add(view)
        }
    }
}
#endif

/// In-call overlay (CallKit shows the system UI; this is the in-app screen). Active calls show a
/// GRID of remote tiles (one per connected peer — video, or an avatar/initial tile when a peer has
/// no camera) with the local camera as a picture-in-picture and a name/status top bar.
/// In-call "add someone" picker — lists contacts not already on the call; tap to ring them in.
struct AddToCallPicker: View {
    @ObservedObject private var call = CallManager.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                let people = call.addableContacts()
                if people.isEmpty {
                    Text("Everyone you know is already on the call.").foregroundStyle(.secondary).padding()
                } else {
                    List(people, id: \.hex) { p in
                        Button { CallManager.shared.addToCall(p.hex); dismiss() } label: {
                            HStack(spacing: 12) {
                                PeerAvatar(nodeHex: p.hex, name: p.name, size: 40)
                                Text(p.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(HavenTheme.pink)
                            }.contentShape(Rectangle())
                        }
                        .listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Add to call")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct CallOverlay: View {
    @ObservedObject private var call = CallManager.shared
    @State private var showAddPicker = false
    var body: some View {
        if call.ringing { incoming }
        // Minimized → render nothing here; the return-to-call bar lives above the tab bar
        // (CallReturnBar) so it's out of the way of the app's own nav/menus.
        else if (call.inCall || call.connecting) && !call.minimized { active }
    }

    private var incoming: some View {
        ZStack {
            HavenTheme.brand.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: call.participants.count > 1 ? "person.3.fill" : "phone.fill.arrow.down.left")
                    .font(.system(size: 40)).foregroundStyle(.white)
                Text(call.peerName.isEmpty ? "Call" : call.peerName).font(.title2.weight(.semibold)).foregroundStyle(.white)
                Text(call.participants.count > 1 ? "Incoming group call…" : "Incoming call…")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                Spacer()
                HStack(spacing: 60) {
                    Button { CallManager.shared.decline() } label: {
                        Image(systemName: "phone.down.fill").font(.title).foregroundStyle(.white)
                            .frame(width: 70, height: 70).background(Color.red, in: Circle())
                    }
                    Button { CallManager.shared.accept() } label: {
                        Image(systemName: "phone.fill").font(.title).foregroundStyle(.white)
                            .frame(width: 70, height: 70).background(Color.green, in: Circle())
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        .transition(.move(edge: .bottom))
    }

    private var active: some View {
        ZStack {
            HavenTheme.brand.opacity(0.96).ignoresSafeArea()
            // A peer sharing their screen takes over the layout: their screen fills the view and the
            // participant tiles shrink to a filmstrip along the bottom.
            if let shareHex = call.remoteScreenTracks.keys.sorted().first,
               let screen = call.remoteScreenTracks[shareHex] {
                screenStage(shareHex, track: screen)
            } else if call.participants.count == 1, let hex = call.participants.first {
                // 1:1 — the other person fills the screen edge-to-edge (no tile margin, badge, or
                // active-speaker border); their name is already in the top bar. Group calls (2+) use
                // the bordered, badged grid instead.
                soloTile(hex)
            } else {
                grid
            }
            // Local camera PiP.
            if call.localVideoTrack != nil {
                VStack {
                    HStack {
                        Spacer()
                        RTCVideoView(track: call.localVideoTrack)
                            // Mirror the self-preview for the front camera only (feels like a mirror);
                            // the rear camera and the frames we SEND stay un-mirrored.
                            .scaleEffect(x: call.frontCamera ? -1 : 1, y: 1)
                            .frame(width: 96, height: 128).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.6)))
                            .overlay(activeSpeakerBorder(cornerRadius: 12, active: call.activeSpeaker == ""))
                            .animation(.easeInOut(duration: 0.2), value: call.activeSpeaker)
                            .padding(.top, 60).padding(.trailing, 16)
                    }
                    Spacer()
                }
            }
            VStack(spacing: 16) {
                ZStack {
                    VStack(spacing: 2) {
                        Text(call.peerName.isEmpty ? "Call" : call.peerName).font(.headline).foregroundStyle(.white)
                        Text(statusText).font(.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    // Minimize sits at the top-leading, level with the name (was floating mid-screen).
                    HStack {
                        Button { call.minimized = true } label: {
                            Image(systemName: "chevron.down")
                                .font(.headline.weight(.semibold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40).background(.black.opacity(0.3), in: Circle())
                        }
                        Spacer()
                    }
                }
                .padding(.top, 54)
                Spacer()
                controls.padding(.bottom, 50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        .transition(.move(edge: .bottom))
        #if targetEnvironment(macCatalyst) || os(macOS)
        .sheet(isPresented: Binding(get: { call.showScreenPicker },
                                    set: { call.showScreenPicker = $0 })) {
            ScreenPickerSheet()
        }
        #endif
    }

    /// A peer's shared screen filling the stage, with a thin filmstrip of participant tiles below.
    private func screenStage(_ shareHex: String, track: RTCVideoTrack) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.black
                RTCVideoView(track: track, fit: true)   // letterbox the whole screen — never crop
                Text("\(call.displayName(for: shareHex))'s screen")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.top, 96).padding(.leading, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(call.participants, id: \.self) { hex in
                        tile(hex).frame(width: 120, height: 90)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 100)
            .padding(.bottom, 130)
        }
        .ignoresSafeArea()
    }

    private var statusText: String {
        if call.connecting { return "Calling…" }
        let n = call.participants.count
        return n > 1 ? "\(n) participants" : "Connected"
    }

    /// A grid of remote participant tiles. Column count adapts to the *shape* of the space, not a
    /// fixed number: a tall, narrow phone stacks people full-width (one column) instead of slicing
    /// the screen into useless thin columns; a wide Mac window lays them side-by-side. Tiles go
    /// square once there's more than one row (so they fill width and scroll), and fill the height
    /// for a single row. One peer fills the screen.
    private var grid: some View {
        GeometryReader { geo in
            // Inset tiles inside the safe area (+ a corner margin) so their rounded corners, name
            // badges and active-speaker borders never bleed into the device's rounded screen corners.
            let safe = geo.safeAreaInsets
            let margin: CGFloat = 12
            let w = max(geo.size.width - safe.leading - safe.trailing - margin * 2, 80)
            let h = max(geo.size.height - safe.top - safe.bottom, 80)
            let tiles = call.participants
            let count = max(tiles.count, 1)
            let aspect = Double(w / max(h, 1))
            // Closest-to-square column count for this area, but never narrower than ~150pt/tile —
            // on a phone that caps it at ~2 columns so each feed stays usefully wide.
            let byShape = max(1, Int((Double(count) * aspect).squareRoot().rounded(.up)))
            let byWidth = max(1, Int(w / 150))
            let cols = max(1, min(count, byShape, byWidth))
            let rows = Int(ceil(Double(count) / Double(cols)))
            let spacing: CGFloat = 6
            let tileW = (w - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let tileH = rows > 1 ? tileW : h   // square when stacked, fill when single row
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(tiles, id: \.self) { hex in
                        tile(hex).frame(height: tileH)
                    }
                }
            }
            .scrollDisabled(rows <= 1)
            .frame(width: w, height: h)
            .padding(.top, safe.top).padding(.bottom, safe.bottom)
            .padding(.leading, safe.leading + margin).padding(.trailing, safe.trailing + margin)
        }
        .ignoresSafeArea()
    }

    /// Full-bleed 1:1 view: the peer's camera aspect-fills the screen — no tile margin, name badge or
    /// active-speaker border. Their avatar shows if the camera is off.
    @ViewBuilder private func soloTile(_ hex: String) -> some View {
        ZStack {
            if let track = call.remoteVideoTracks[hex], !call.remoteCameraOff.contains(hex) {
                RTCVideoView(track: track).ignoresSafeArea()
            } else {
                HavenTheme.brand.opacity(0.9).ignoresSafeArea()
                PeerAvatar(nodeHex: hex, name: call.displayName(for: hex), size: 110)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            }
        }
        // When the other caller is speaking, glow a full-screen border that hugs the device's
        // rounded corners (no badge/tile border in 1:1 — this is the only speaking indicator).
        .overlay {
            let speaking = call.activeSpeaker == hex
            RoundedRectangle(cornerRadius: deviceCornerRadius, style: .continuous)
                .strokeBorder(HavenTheme.pink, lineWidth: speaking ? 5 : 0)
                .shadow(color: speaking ? HavenTheme.pink.opacity(0.85) : .clear, radius: 10)
                .opacity(speaking ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.2), value: call.activeSpeaker)
    }

    /// Best-effort rounded-display-corner radius for the full-screen speaking border. Reads the
    /// screen's actual corner radius when available, falling back to a modern-iPhone value.
    private var deviceCornerRadius: CGFloat {
        #if os(iOS)
        if let r = UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat, r > 0 { return r }
        #endif
        return 52
    }

    @ViewBuilder private func tile(_ hex: String) -> some View {
        ZStack {
            if let track = call.remoteVideoTracks[hex], !call.remoteCameraOff.contains(hex) {
                RTCVideoView(track: track)
                LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle().fill(HavenTheme.brand.opacity(0.9))
                // Camera off → show the participant's profile photo (falls back to their emoji,
                // then an initialed gradient) just like FaceTime/Messages do.
                PeerAvatar(nodeHex: hex, name: call.displayName(for: hex), size: 78)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            VStack {
                Spacer()
                HStack {
                    Text(call.displayName(for: hex)).font(.caption2.weight(.medium))
                        .foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                }
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(activeSpeakerBorder(cornerRadius: 10, active: call.activeSpeaker == hex))
        .animation(.easeInOut(duration: 0.2), value: call.activeSpeaker)
    }

    /// A glowing colored border drawn on the active speaker's tile / PiP. Hidden when not speaking.
    @ViewBuilder
    private func activeSpeakerBorder(cornerRadius: CGFloat, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(HavenTheme.pink, lineWidth: active ? 3 : 0)
            .shadow(color: active ? HavenTheme.pink.opacity(0.9) : .clear, radius: active ? 8 : 0)
            .opacity(active ? 1 : 0)
    }

    private var controls: some View {
        // TWO rows: the media toggles up top, the call actions (add / hang up) below — a single row
        // overflowed on iPhone once screen-share + flip-camera were added.
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { CallManager.shared.toggleMute() } label: {
                    callButton(call.muted ? "mic.slash.fill" : "mic.fill", on: call.muted)
                }
                #if targetEnvironment(macCatalyst)
                micMenu
                #else
                Button { CallManager.shared.toggleSpeaker() } label: {
                    callButton(call.speakerOn ? "speaker.wave.3.fill" : "speaker.fill", on: call.speakerOn)
                }
                #endif
                Button { CallManager.shared.toggleVideo() } label: {
                    callButton(call.videoOn ? "video.fill" : "video.slash.fill", on: call.videoOn)
                }
                #if targetEnvironment(macCatalyst)
                if call.videoOn { cameraMenu }
                #else
                if call.videoOn {
                    Button { CallManager.shared.flipCamera() } label: {
                        callButton("arrow.triangle.2.circlepath.camera.fill", on: false)
                    }
                }
                #endif
            }
            HStack(spacing: 14) {
                screenShareButton
                #if targetEnvironment(macCatalyst)
                outputLabel
                #endif
                // Add another person to the live call — rings them and meshes them with everyone already in.
                Button { showAddPicker = true } label: { callButton("person.badge.plus", on: false) }
                Button { CallManager.shared.endCall() } label: {
                    Image(systemName: "phone.down.fill").font(.title2)
                        .foregroundStyle(.white).frame(width: 58, height: 58)
                        .background(Color.red, in: Circle())
                }
            }
        }
        .padding(.horizontal, 12)
        .buttonStyle(.plain)   // the call buttons supply their own circles; drop macOS's rectangular chrome
        .sheet(isPresented: $showAddPicker) { AddToCallPicker().macSheetFrame() }
    }

    #if targetEnvironment(macCatalyst)
    /// Camera-source picker (Mac): lists every capture device by localizedName.
    private var cameraMenu: some View {
        Menu {
            let current = call.currentCameraID
            ForEach(call.availableCameras(), id: \.id) { cam in
                Button {
                    CallManager.shared.selectCamera(cam.id)
                } label: {
                    if cam.id == current { Label(cam.name, systemImage: "checkmark") }
                    else { Text(cam.name) }
                }
            }
        } label: {
            callButton("camera.fill", on: false)
        }
    }

    /// Mic-input picker (Mac): lists every available input port by portName.
    private var micMenu: some View {
        Menu {
            let current = call.currentMicName
            ForEach(call.availableMicInputs(), id: \.uid) { input in
                Button {
                    CallManager.shared.selectMicInput(input.uid)
                } label: {
                    if input.name == current { Label(input.name, systemImage: "checkmark") }
                    else { Text(input.name) }
                }
            }
        } label: {
            callButton("mic.circle.fill", on: false)
        }
    }

    /// Audio output (Mac): output is system-managed, so we surface the current device as a label and
    /// a System-Settings hint. (No public per-app output-device selection on Catalyst.)
    private var outputLabel: some View {
        Menu {
            Section("Output (managed by macOS)") {
                Text(call.currentOutputName)
            }
        } label: {
            callButton("speaker.wave.2.fill", on: false)
        }
    }
    #endif

    /// "Share screen" control. macOS: opens the display/window picker. iOS: when not sharing, taps
    /// the system broadcast picker (overlaid) and starts listening for frames; when sharing, stops.
    @ViewBuilder private var screenShareButton: some View {
        #if targetEnvironment(macCatalyst) || os(macOS)
        Button { CallManager.shared.toggleScreenShare() } label: {
            callButton(call.screenShareOn ? "rectangle.inset.filled.and.person.filled" : "macwindow",
                       on: call.screenShareOn)
        }
        #else
        ZStack {
            callButton(call.screenShareOn ? "rectangle.inset.filled.and.person.filled" : "macwindow",
                       on: call.screenShareOn)
            // Always the system broadcast picker: one tap toggles the OS broadcast on/off (the old
            // split button left a separate "stop" that killed our listener but not the system
            // broadcast, so stopping took several taps). Sync our listener to the direction it's going.
            BroadcastPickerButton {
                if CallManager.shared.screenShareOn { CallManager.shared.stopScreenShare() }
                else { CallManager.shared.startScreenShareListening() }
            }
            .frame(width: 52, height: 52)
        }
        #endif
    }

    private func callButton(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(.white).frame(width: 52, height: 52)
            .background(Color.white.opacity(on ? 0.3 : 0.16), in: Circle())
    }
}

#if !targetEnvironment(macCatalyst) && !os(macOS)
/// Wraps `RPSystemBroadcastPickerView` so the call control row can present the system broadcast
/// sheet. `onTap` fires when the user taps it, so the app can begin listening for the extension's
/// frames just before the broadcast starts.
struct BroadcastPickerButton: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        v.preferredExtension = "com.blaineam.kith.Broadcast"
        v.showsMicrophoneButton = false
        v.backgroundColor = .clear
        // Make the embedded button transparent (we draw our own icon underneath in the ZStack).
        for sub in v.subviews {
            if let b = sub as? UIButton {
                b.imageView?.tintColor = .clear
                b.setImage(PlatformImage(), for: .normal)
            }
        }
        v.addTarget(context.coordinator, action: #selector(Coordinator.tapped))
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }
    final class Coordinator: NSObject {
        let onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func tapped() { onTap() }
    }
}

private extension RPSystemBroadcastPickerView {
    /// Hook the inner UIButton's touch-up so we can begin listening right as the picker appears.
    func addTarget(_ target: Any?, action: Selector) {
        for sub in subviews {
            if let b = sub as? UIButton { b.addTarget(target, action: action, for: .touchUpInside) }
        }
    }
}
#endif

#if os(macOS)
/// Native macOS screen-share control. `RPSystemBroadcastPickerView` (ReplayKit) is iOS-only; on
/// macOS we route through `CallManager`'s ScreenCaptureKit picker flow. Same public surface (`onTap`)
/// as the iOS `BroadcastPickerButton` — but the button also opens the display/window picker so it's
/// functional even if a call site wires it directly instead of going through `screenShareButton`.
struct BroadcastPickerButton: View {
    let onTap: () -> Void
    var body: some View {
        Button {
            onTap()
            CallManager.shared.presentScreenPicker()
        } label: {
            Image(systemName: "rectangle.on.rectangle").foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
#endif

#if !os(macOS)
/// The system audio-output picker (speaker / receiver / Bluetooth / AirPlay) for a call.
/// `AVRoutePickerView` is iOS/Catalyst-only.
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(HavenTheme.pink)
        v.prioritizesVideoDevices = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

#if targetEnvironment(macCatalyst) || os(macOS)
/// macOS screen-share picker: lists every display and open window (title + app). Selecting one
/// starts an `SCStream` and adds the screen track to the mesh.
struct ScreenPickerSheet: View {
    @ObservedObject private var call = CallManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                let displays = call.screenSources.filter { $0.kind == .display }
                let windows = call.screenSources.filter { $0.kind == .window }
                if !displays.isEmpty {
                    Section("Displays") {
                        ForEach(displays) { src in row(src, icon: "display") }
                    }
                }
                if !windows.isEmpty {
                    Section("Windows") {
                        ForEach(windows) { src in row(src, icon: "macwindow") }
                    }
                }
                if call.screenSources.isEmpty {
                    Text("No shareable content found. Grant Screen Recording permission in System Settings ▸ Privacy & Security.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Share screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { call.showScreenPicker = false; dismiss() }
                }
            }
        }
    }

    private func row(_ src: ScreenSource, icon: String) -> some View {
        Button {
            CallManager.shared.startScreenShare(src)
            dismiss()
        } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(HavenTheme.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(src.title).lineLimit(1)
                    Text(src.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
#endif
