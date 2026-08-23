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
/// offer/answer + ICE) is **sealed + signed per-recipient** (`FeedStore.sendCallFrame` →
/// `seal_call_frame`) and opened + sender-verified on receipt (`openCallFrame`), so a relay can
/// neither spoof caller-id, forge control, nor rewrite the DTLS-SRTP fingerprint (audit R1). No
/// call/signaling server.
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
    /// WebRTC would not give us a peer connection for someone in this call, so there is no media path
    /// to them and there never will be on this attempt. Surfaced so the call screen can say "Couldn't
    /// start audio" instead of sitting on "Connecting…" forever — and, more to the point, so this
    /// state is a message rather than the `fatalError` it used to be.
    @Published private(set) var mediaFailed = false
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

    private var active = false {      // a call exists (ringing, connecting, or in progress)
        didSet {
            guard oldValue != active else { return }
            // Arm/disarm the feed's live-call HTTP poll timer with the call lifecycle — the
            // 3s timer used to run forever and wake the main actor for a no-op guard when idle.
            let on = active
            Task { @MainActor in FeedStore.shared.callActivityChanged(on) }
        }
    }
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
    /// TRUE only when at least one peer's ICE path is actually up. The call UI used to say
    /// "Connected" the moment the ACCEPT frame arrived — app-level signaling — while ICE was
    /// still dead (field: both sides "Connected", zero audio). The label now tells the truth.
    var mediaConnected: Bool {
        lastPeerState.values.contains { $0 == .connected || $0 == .completed }
            || !hairpinPeers.isEmpty
    }
    /// Peers whose media is currently relayed over the /webrtc/hairpin WebSocket (ICE failed).
    private var hairpinPeers: Set<String> = []

    /// The relay produced a decoded remote video track for a hairpin peer — publish it into the
    /// same map the call UI renders, so relayed video appears with no view changes.
    func adoptHairpinRemoteVideo(peer: String, track: RTCVideoTrack) {
        remoteVideoTracks[peer] = track
    }

    /// Hand the mic between WebRTC's audio unit and the hairpin bridge's `AVAudioEngine`. Two
    /// mic consumers conflict on iOS, so when the relay takes over audio (ICE failed) WebRTC's
    /// dead audio path is silenced; restored if ICE recovers. Only reached on the failed path,
    /// so it can't disturb a working direct call.
    func setNativeAudioSuspendedForHairpin(_ suspended: Bool) {
        #if os(iOS)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = !suspended
        #endif
    }
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
    /// Consecutive winning polls (1s each) before we switch the highlight, to avoid flicker.
    private let speakerDebounce = 2

    // Mac in-app ringing (no CallKit on Catalyst).
    private var inAppRinging = false

    // Callee-side bounded ring. The caller gives up dialing at ~30s, but its hangup (frame 12) is
    // fire-and-forget — if it never arrives (caller offline, dropped frame, or the invite itself
    // was a stale copy delivered late through a relay hop), the ringtone would loop FOREVER
    // (observed: a Mac rang nonstop for 20+ minutes). Ringing always stops after this timeout and
    // the call is treated as missed.
    private var ringTimeoutTimer: Timer?
    private static var ringTimeoutSecs: TimeInterval {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["HAVEN_RING_TIMEOUT"], let v = TimeInterval(s) { return v }
        #endif
        return 60
    }
    /// Invites older than this (per the sender's frame-21 timestamp) never start a ring — the
    /// caller stopped dialing long ago. Generous enough to absorb ordinary clock skew.
    private static let inviteMaxAgeSecs: TimeInterval = 180
    /// How long "this session already ended" is remembered. MUST outlive [inviteMaxAgeSecs]: a
    /// caller retransmits its invite and the relay can deliver one late, so the same session id
    /// keeps arriving. At 45s the tombstone expired ~135s before an invite stopped being accepted,
    /// so a retransmit found nothing suppressing it and re-rang a call the user had already ended.
    private static let endedTombstoneSecs: TimeInterval = inviteMaxAgeSecs + 30
    /// Sessions that already ended locally (declined / hung up / timed out / completed), with when.
    /// A caller retransmits the invite every 2.5s and relay hops can replay copies late — none of
    /// those may re-ring a session we've already left.
    private var endedSessions: [String: Date] = [:]

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
    /// CallKit on the iOS Simulator often settles then immediately drops the call (no usable
    /// accept UI in sim screenshots; FaceTime launch ends the ring in ~100ms). Use the in-app
    /// overlay there so multi-device QA can actually answer. Real devices keep CallKit.
    private var useCallKit: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return provider != nil
        #endif
    }
    #else
    private var useCallKit: Bool { false }   // native macOS: in-app flow drives everything
    #endif

    /// DEBUG/TEST ONLY: relay call media over the hairpin even when ICE is perfectly healthy.
    ///
    /// The hairpin is the fallback for networks where ICE cannot connect at all — double-CGNAT,
    /// locked-down corporate wifi. If every network you own works, the fallback never engages, so
    /// the whole path (join, framing, audio bridge, video decode, teardown) is untestable in
    /// practice and ships unproven. This forces it: the race below fires immediately instead of
    /// after a grace period, and ICE recovery does not stand it down. Settings → toggle; off by
    /// default and never persisted anywhere a normal user would meet it.
    /// Gated on launching with `DEBUG=1` in the environment, so it is invisible — and INERT —
    /// during normal use.
    ///
    /// The gate is on the GETTER, not just the UI. Hiding only the toggle would leave a stored
    /// `true` from a previous test session quietly relaying every call through the WebSocket path
    /// forever, with no control anywhere to turn it back off. Reading the flag through the same
    /// condition that shows it means a forgotten switch cannot outlive the debug launch that set it.
    static var debugEnabled: Bool { ProcessInfo.processInfo.environment["DEBUG"] == "1" }

    static var forceHairpin: Bool {
        get { debugEnabled && UserDefaults.standard.bool(forKey: "haven.debug.forceHairpin") }
        set { UserDefaults.standard.set(newValue, forKey: "haven.debug.forceHairpin") }
    }

    private var myHex: String { FeedStore.shared.myNodeHex }
    /// This DEVICE's node id — distinct from the account id above, and the id a device-transport peer
    /// is dialed by. Needed wherever we must not treat ourselves as a callable participant.
    private var myDeviceHex: String { FeedStore.shared.myDeviceNodeHex }
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
        // A swallowed tap is INVISIBLE in the UI — the button just does nothing — which reads as
        // "I have to press call several times". Say so, and say what state swallowed it: `active` is
        // only cleared by teardown(), so a call that ended without one strands every later attempt.
        guard !active else {
            HavenLog.call("startCall IGNORED — a call is already active (connecting=\(connecting) inCall=\(inCall) ringing=\(ringing) session=\(self.sessionId.prefix(8)))")
            return
        }
        // Never dial blocked people (defense in depth — circle calls also pre-filter removed members).
        // Exclude BOTH of our own ids, case-insensitively. `myHex` is the ACCOUNT id, but a
        // participant list can name a DEVICE id — that is the id a device-transport peer is actually
        // dialed by — and filtering only the account meant we invited ourselves: the call bounced
        // straight back and this phone rang for its own outgoing call. `dialTargets` has always
        // excluded both (`mineAcct`/`mineDev`); this filter never did. Case matters too, for the same
        // reason it did in the history opt-out: hex arrives here from sources that disagree on case,
        // so an exact `!=` silently fails to match.
        let mineIds: Set<String> = [myHex.lowercased(), myDeviceHex.lowercased()].filter { !$0.isEmpty }.reduce(into: Set()) { $0.insert($1) }
        let invitees = others.filter {
            !$0.isEmpty && !mineIds.contains($0.lowercased()) && !ConnectionsStore.shared.isBlocked($0)
        }
        guard !invitees.isEmpty else {
            HavenLog.call("startCall IGNORED — no dialable invitees from \(others.count) participant(s)")
            return
        }
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
            if err != nil { Task { @MainActor in self?.teardown("CXStartCall failed") } }
        }
        // Watchdog — the last of the swallowed-CallKit failures, and the most damaging.
        //
        // An outgoing call sends its invites from `beginOutgoing`, and the ONLY caller of that is
        // `provider(_:perform: CXStartCallAction)`. A transaction reported as successful whose
        // provider callback never arrives therefore rings nobody at all: no error to catch, no
        // teardown, just "Calling…" forever while the callee's phone stays silent. Mute and Answer
        // failed the same way and read as dead buttons; here it reads as the other person ignoring
        // you. `beginOutgoing` is idempotent, so the provider firing late is harmless.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.active, self.connecting, !self.outgoingBegun else { return }
            HavenLog.call("CallKit never started the call 1.5s after the tap — dialing directly")
            self.beginOutgoing()
        }
        #endif
    }

    /// Convenience for the existing 1:1 call sites.
    func startCall(peerHex: String, name: String) {
        startCall(participants: [peerHex], name: name)
    }

    /// Fired by CXStartCallAction: send the group invite to everyone + ONE push each, then keep
    /// retransmitting the iroh invite until somebody answers.
    /// Hold the screen awake ONLY while a call is genuinely up — derived from state, never latched.
    ///
    /// This used to be a bare `isIdleTimerDisabled = true` in `startMesh` paired with a `= false` in
    /// `teardown`. That is a latch, and it survives every way a call can end WITHOUT a clean
    /// teardown — a crash mid-call, a wedged `inCall`, a stale hangup that tore down some other
    /// session. Miss the release once and the phone never sleeps again for the rest of the app's
    /// life, which reads as "my screen won't turn off" long after the call is forgotten.
    ///
    /// Deriving it from `active` means the worst case is one stale assertion until the next state
    /// change, instead of a permanent one.
    func syncIdleTimer() {
        #if !os(macOS)
        let shouldHold = active
        if UIApplication.shared.isIdleTimerDisabled != shouldHold {
            UIApplication.shared.isIdleTimerDisabled = shouldHold
            HavenLog.call("idle timer \(shouldHold ? "DISABLED (call up)" : "restored (no call)")")
        }
        #endif
    }

    /// True once [beginOutgoing] has actually run for the current call — so the CallKit provider and
    /// the watchdog below cannot both send the invites.
    private var outgoingBegun = false

    private func beginOutgoing() {
        guard !outgoingBegun else { HavenLog.call("beginOutgoing ignored — already dialing"); return }
        outgoingBegun = true
        // The ONLY place a call push is sent. If this never logs, the callee was never rung — no
        // amount of looking at the worker or APNs will explain it, because nothing was ever sent.
        HavenLog.call("beginOutgoing — \(invitees().count) invitee(s), callKit=\(useCallKit) session=\(sessionId.prefix(8))")
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
    /// A 4th length-prefixed field carries the send time (unix seconds, decimal) so receivers can
    /// refuse to ring for a stale copy; every platform's parser reads exactly 3 fields and ignores
    /// trailing bytes, so older receivers are unaffected.
    private func sendInvites() {
        var f = Data(myHex.utf8)
        CallManager.lpAppend(&f, Data(sessionId.utf8))
        CallManager.lpAppend(&f, Data(peerName.utf8))
        CallManager.lpAppend(&f, Data(rosterCSV().utf8))
        CallManager.lpAppend(&f, Data(String(UInt64(Date().timeIntervalSince1970)).utf8))
        for p in invitees() { FeedStore.shared.sendCallFrame(21, f, to: p) }
    }

    // MARK: - Inbound signaling

    /// Legacy 1:1 invite (frame 10). Treated as a 2-person group with a synthetic session id.
    /// Call frames are sealed + SIGNATURE-verified before dispatch (audit R1), so by the time a
    /// handler runs the `from` hex is the cryptographically-PROVEN sender, not a self-asserted one.
    /// This gate then applies *authorization* on top of that authenticity — a stranger who can sign
    /// as themselves still can't ring you, inject participants, or negotiate a call unless they're a
    /// known contact (audit F3).
    private func knownContact(_ hex: String) -> Bool {
        ContactsStore.shared.contacts.contains { $0.idHex == hex }
    }

    func handleInvite(_ payload: Data) {
        guard payload.count > 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        let name = String(data: payload.dropFirst(64), encoding: .utf8) ?? "Someone"
        guard from.count == 64, knownContact(from) else { return }   // strangers can't ring you (F3)
        if active {
            // GLARE: we are ringing THEM while they are ringing US. Both sides were swallowing the
            // other's invite here ("already active → just merge the roster"), so two people who
            // called each other at the same moment both sat listening to ringback and NEITHER call
            // ever connected. They obviously both want this call — so connect it.
            //
            // Both devices run this identical logic, so they must agree without another round trip:
            // the session id is derived from the two hexes in sorted order, and the lower hex takes
            // the caller role for negotiation politeness. Each side also sends an ACCEPT, which is
            // what drives the other's normal accept path if it gets there first.
            if isCaller, !inCall, roster.contains(from) {
                let a = myHex.lowercased(), b = from.lowercased()
                sessionId = "glare:\(min(a, b))-\(max(a, b))"
                isCaller = a < b
                inviteTimer?.invalidate(); inviteTimer = nil
                ringTimeoutTimer?.invalidate(); ringTimeoutTimer = nil
                ringing = false; stopInAppRinging()
                connecting = false; inCall = true
                HavenLog.call("glare with \(from.prefix(8)) — both dialing, adopting shared session \(sessionId)")
                sendAccept(to: from)
                startMesh()
                return
            }
            if roster.isEmpty || !roster.contains(from) { roster.insert(from); refreshParticipants() }
            return
        }
        guard !recentlyEnded("legacy:\(from)") else { return }   // declined/ended → retransmits can't re-ring
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
        // Optional 4th field (newer senders): the invite's send time. A copy older than the
        // caller's entire dialing window is a replay — a relay hop or reconnect delivering it
        // long after the caller gave up. It must not ring (or resurrect a session's roster).
        if let tsData = CallManager.lpRead(body, &off),
           let ts = TimeInterval(String(data: tsData, encoding: .utf8) ?? ""),
           Date().timeIntervalSince1970 - ts > Self.inviteMaxAgeSecs {
            HavenLog.call("dropping stale invite (age=\(Int(Date().timeIntervalSince1970 - ts))s session=\(sid2.prefix(12)))")
            return
        }

        if active {
            // Same session, new roster info → merge (someone learned about more participants).
            if sessionId == sid2 {
                // The caller is STILL retransmitting this invite — which means our ACCEPT (sent
                // once, link-cold) may never have landed. Re-send it: the caller's own retry loop
                // becomes the retry channel for frame 11, and the caller stops retransmitting the
                // moment one arrives. This replaces inferring "answered" from media.
                if inCall, !isCaller { for p in invitees() { sendAccept(to: p) } }
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
        guard !recentlyEnded(sid2) else { return }   // we already left this session — don't re-ring
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
        startRingTimeout()
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
                if err != nil { self.teardown("reportIncoming failed") } else { self.ringing = true }
            }
        }
        #endif
    }

    // MARK: - Ring timeout / stale-session suppression

    /// Arm the callee-side bounded ring. Cleared by accept and by teardown (decline, hangup, end).
    private func startRingTimeout() {
        ringTimeoutTimer?.invalidate()
        ringTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.ringTimeoutSecs, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.ringTimedOut() }
        }
    }

    /// Nobody answered and no hangup ever arrived — stop ringing and record a missed call.
    private func ringTimedOut() {
        guard active, ringing, !inCall else { return }
        HavenLog.call("ring timeout after \(Int(Self.ringTimeoutSecs))s — ending as missed (session=\(sessionId.prefix(12)))")
        let who = peerName
        #if !os(macOS)
        if useCallKit, let provider, let uuid = callUUID {
            provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
        }
        #endif
        teardown("ring timeout — unanswered")
        NotificationManager.shared.notify(
            title: "Missed call",
            body: who.isEmpty ? "You missed a call" : "You missed a call from \(who)",
            dedupeKey: "missed-call:\(Date().timeIntervalSince1970)")
    }

    /// Did a session end here recently enough that a fresh invite for it must be ignored? The
    /// window just outlasts the caller's ~30s retransmit burst: declining mustn't re-ring when our
    /// hangup frame is lost, but a deliberate redial — or being re-added to a group call we left
    /// (addToCall reuses the session id) — rings normally once the burst is over.
    private func recentlyEnded(_ sid: String) -> Bool {
        guard let endedAt = endedSessions[sid] else { return false }
        // Must OUTLIVE `inviteMaxAgeSecs` — see the note on the prune below.
        return Date().timeIntervalSince(endedAt) < Self.endedTombstoneSecs
    }

    // MARK: - Mac in-app ringing (no CallKit)

    /// Play a looping ringtone and bring the window forward so a Mac user notices an incoming call.
    /// No-op on iOS (CallKit drives the system ring there).
    private func startInAppRinging() {
        #if targetEnvironment(macCatalyst) || os(macOS)
        guard !inAppRinging else { return }
        inAppRinging = true
        HavenLog.call("in-app ring START (session=\(sessionId.prefix(12)))")
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
        HavenLog.call("in-app ring STOP")
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
        // Ask CallKit FIRST, and fall back on a watchdog — do NOT pick up locally straight away.
        //
        // Mute could be applied locally with no ceremony, but answering cannot: CallKit owns the
        // audio session, and `reallyAccept` → `startMesh` brings audio up expecting that session to
        // be active. Jumping the gun there takes the call down. So keep CallKit's ordering on the
        // normal path, and only act ourselves if it goes silent — which is the failure that left
        // this button dead: the transaction reports success, `provider(_:perform:)` is never
        // invoked, so there is neither an error to catch nor a callback to answer in.
        HavenLog.call("answer tapped → asking CallKit")
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { [weak self] err in
            guard let err else { return }
            HavenLog.call("CallKit refused answer: \(err.localizedDescription) — accepting directly")
            Task { @MainActor in self?.reallyAccept() }
        }
        // Watchdog: if CallKit neither refused nor picked up, the tap must still mean something.
        //
        // Taking over means TAKING OVER. Answering locally while CallKit still holds the call in a
        // ringing state leaves the system ringtone going for a call we have already answered, and —
        // worse — CallKit never activates the audio session, so the call reports itself connected
        // and carries no media at all. Retire its copy of the call first (`answeredElsewhere` is
        // precisely this situation: the call was picked up somewhere other than CallKit's UI), then
        // bring our own audio up, which `CallMediaBridge` now does by activating the session itself.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.ringing, !self.inCall else { return }
            HavenLog.call("CallKit never answered 1.5s after the tap — retiring its call and accepting directly")
            #if !targetEnvironment(macCatalyst) && !os(macOS)
            if let provider = self.provider, let uuid = self.callUUID {
                provider.reportCall(with: uuid, endedAt: Date(), reason: .answeredElsewhere)
            }
            self.callUUID = nil   // CallKit no longer owns this call — later mute/end act locally
            #endif
            self.reallyAccept()
        }
        #endif
    }
    func decline() {
        #if os(macOS)
        reallyEnd(); return
        #else
        guard useCallKit, let uuid = callUUID else { reallyEnd(); return }
        // Same reasoning as `accept()`: a swallowed refusal leaves Decline dead, which is worse —
        // the phone keeps ringing at someone who is actively trying to stop it.
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] err in
            guard let err else { return }
            HavenLog.call("CallKit refused end: \(err.localizedDescription) — ending directly")
            Task { @MainActor in self?.reallyEnd() }
        }
        #endif
    }

    /// Fired by CXAnswerCallAction (system UI or our button): really pick up. Accept-frame goes to
    /// EVERY other participant so they know to start dialing us; then we bring up media + mesh.
    private func reallyAccept() {
        // Idempotent: `accept()` now picks up IMMEDIATELY and CallKit's provider echo lands here
        // again a moment later. Without this guard that echo would re-send every ACCEPT frame and
        // restart the mesh mid-setup.
        guard !inCall else { HavenLog.call("reallyAccept ignored — already in the call"); return }
        ringTimeoutTimer?.invalidate(); ringTimeoutTimer = nil
        ringing = false; stopInAppRinging(); inCall = true
        notifyOwnDevicesHandled()   // stop my OTHER devices ringing before they can join and take the audio
        for p in invitees() { sendAccept(to: p) }
        startMesh()
    }

    private func sendAccept(to peer: String) {
        var f = Data(myHex.utf8)
        CallManager.lpAppend(&f, Data(sessionId.utf8))
        FeedStore.shared.sendCallFrame(11, f, to: peer)
    }

    /// Tell my OTHER devices this ringing call was handled here (answered or declined), so they stop
    /// ringing and never join.
    ///
    /// Every device of mine rings — that part is right. Nothing told the losers to stand down, so the
    /// one I didn't answer on kept its session live, completed signalling when the offer arrived, and
    /// joined the mesh: "I answered on my iPhone and my Mac took the audio", then the reverse when I
    /// touched the Mac. Two devices in one call also explains one of them sounding choppy — they were
    /// competing, not degraded.
    ///
    /// Sealed PER DEVICE rather than to my account, so a seedless device (which holds no account key)
    /// can open it too.
    private func notifyOwnDevicesHandled(ended: Bool = false) {
        guard !sessionId.isEmpty else { return }
        var f = Data(myHex.utf8)
        CallManager.lpAppend(&f, Data(sessionId.utf8))
        let others = FeedStore.shared.myOtherDeviceHexes()
        guard !others.isEmpty else { return }
        // 30 = "handled elsewhere": only silences a device still RINGING, deliberately, so a late
        // frame cannot kill a conversation in progress.
        // 35 = "ENDED elsewhere": the session is over, so a device that has already ANSWERED must
        // tear down too. Without this an established call ended on one device left my other devices
        // sitting in a dead call with no way out — 30 was ignored by exactly the devices that were
        // stuck. Both carry the session id, so neither can affect a different call.
        let type: UInt8 = ended ? 35 : 30
        HavenLog.call("call \(sessionId.prefix(8)) \(ended ? "ended" : "handled") here — standing down \(others.count) other device(s) of mine")
        for dev in others { FeedStore.shared.sendCallFrame(type, f, to: dev) }
        // AND to my own ACCOUNT, not only to each device id.
        //
        // Addressing devices alone left both of my other devices sitting in a dead call: neither
        // received the frame at all. Two reasons, and the account lane fixes both.
        //
        // Sealing is per-recipient and can only resolve OUR OWN ACCOUNT, a circle member, or a
        // KNOWN device bundle — so a device whose bundle has not been learned yet seals to nothing
        // and the frame is dropped before it is ever transmitted. The account always resolves.
        //
        // And the receive side already listens for it: the live-frame poller matches keys addressed
        // to [myDevice, myAccount], so an account-addressed frame is picked up over the mailbox lane
        // that reaches a device with no dialable path — which is exactly the case here, and exactly
        // why `dm echo (own devices)` lands on both of those legs in ~2.5s while this did not.
        //
        // Idempotent by construction: both handlers require the session id to match the call this
        // device is actually in, so receiving it twice is a no-op.
        let myAccount = FeedStore.shared.myAccountHex
        if !myAccount.isEmpty, !others.contains(where: { $0.lowercased() == myAccount.lowercased() }) {
            FeedStore.shared.sendCallFrame(type, f, to: myAccount)
        }
    }

    /// My account ENDED this call session on another device. Tear down whatever state we are in —
    /// ringing or answered. Narrowly guarded: the sender must be my own account (proven by the
    /// frame's signature before dispatch) and the session id must match the one we are in.
    func handleEndedElsewhere(_ payload: Data) {
        guard payload.count > 64 else { return }
        let from = String(decoding: payload.prefix(64), as: UTF8.self)
        guard from.count == 64, from == myHex else { return }
        var off = 0
        let body = payload.dropFirst(64)
        guard let sidData = CallManager.lpRead(body, &off) else { return }
        let sid = String(decoding: sidData, as: UTF8.self)
        guard active, sid == sessionId || sessionId.isEmpty else { return }
        HavenLog.call("call \(sid.prefix(8)) ended on another of my devices — tearing down here")
        teardown("ended on another device")
    }

    /// Another of MY devices answered or declined this call: stop ringing and tear down.
    ///
    /// Deliberately narrow. It only silences a call this device is still RINGING — never one already
    /// answered here (`inCall`), so a late-arriving frame can't hang up a conversation in progress —
    /// and only when the sender is my own account, which the frame's signature proves before dispatch.
    func handleHandledElsewhere(_ payload: Data) {
        guard payload.count > 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64, from == myHex else { return }   // only MY account may silence my ring
        let body = payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex)
        var off = 0
        guard let sidData = CallManager.lpRead(body, &off) else { return }
        let sid = String(data: sidData, encoding: .utf8) ?? ""
        guard active, !inCall, sid == sessionId else {
            HavenLog.call("handled-elsewhere for \(sid.prefix(8)) ignored (active=\(active) inCall=\(inCall) mine=\(sessionId.prefix(8)))")
            return
        }
        HavenLog.call("call \(sid.prefix(8)) was handled on another of my devices — standing down")
        endedSessions[sid] = Date()   // a retransmitted invite must not re-ring us
        teardown("handled on another of my devices")
    }

    /// Caller side: a callee accepted → stop re-inviting, bring up media + dial that peer.
    func handleAccept(_ payload: Data) {
        guard active, payload.count >= 64 else {
            HavenLog.call("ACCEPT ignored — active=\(active) bytes=\(payload.count) (no call in progress to answer)")
            return
        }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        // The last gate before the caller leaves "Calling". `knownContact` keys on the ACCOUNT hex,
        // so an accept that names a device id — or comes from someone missing from our contact list —
        // is dropped here and the caller rings on forever with no indication why.
        guard from.count == 64, knownContact(from) else {
            HavenLog.call("ACCEPT DROPPED from=\(from.prefix(8)) — not a known contact; caller stays stuck on Calling")
            return
        }
        HavenLog.call("ACCEPT from \(from.prefix(8)) — connecting → in-call")
        inviteTimer?.invalidate(); inviteTimer = nil
        CallTones.shared.stop()   // answered — ringback ends HERE, not on transport events
        connecting = false; inCall = true
        if !roster.contains(from) { roster.insert(from); refreshParticipants() }
        startMesh()
        connectPeerIfNeeded(from)
    }

    func handleHangup(_ payload: Data) {
        guard active, payload.count >= 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64 else { return }
        // GATE ON THE SESSION. The hangup frame has always carried its session id (`sendCallFrame(12,
        // myHex + lp(sessionId))`) and this handler threw it away, acting on nothing but the sender.
        //
        // Hangups are retransmitted and the relay can deliver one late, so a BYE from a call that
        // ended minutes ago still arrives — and killed whatever call happened to be running when it
        // did. That is an outgoing call whose screen appears and vanishes at once, and a connected
        // call that hangs itself up seemingly at random: `teardown(remote hung up)` with the far end
        // having done nothing at all. Every other signal handler already gates on `validSession`;
        // this one is the reason a stale frame could reach across sessions and end a live call.
        let body = payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex)
        var off = 0
        if let sidData = CallManager.lpRead(body, &off) {
            let sid = String(data: sidData, encoding: .utf8) ?? ""
            guard validSession(sid) else {
                HavenLog.call("HANGUP IGNORED from \(from.prefix(8)) for session \(sid.prefix(8)) — ours is \(sessionId.prefix(8)) (stale/replayed frame)")
                return
            }
        }
        // One peer leaving does NOT end the call for the rest — only drop that connection. The call
        // ends only when nobody else is left.
        dropPeer(from)
        let remaining = roster.subtracting([myHex])
        if remaining.isEmpty {
            let missed = ringing && !inCall   // caller hung up before we answered
            let who = peerName
            #if !os(macOS)
            if let provider, let uuid = callUUID { provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
            #endif
            teardown("remote hung up")
            if missed {
                NotificationManager.shared.notify(
                    title: "Missed call",
                    body: who.isEmpty ? "You missed a call" : "You missed a call from \(who)",
                    dedupeKey: "missed-call:\(Date().timeIntervalSince1970)")
            }
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
        guard let peer = peerConn(for: from), let sdp = CallSignal.decodeSDP(json) else { return }
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
        guard let peer = peerConn(for: from) else { return }
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
        // NO SESSION MEANS NO NEGOTIATION: the old `sessionId.isEmpty` clause accepted any media
        // signal while in no call, letting a late OFFER rebuild a zombie call whose teardown frame
        // could then never match (Android twin has the full account). The "push:" placeholder stays:
        // there we ARE in a call, we just learned its id from the push before the invite.
        return sid == sessionId || sessionId.hasPrefix("push:")
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
        syncIdleTimer()
        configureAudioSession()
        // TCP/WSS media hairpin via path proxy (works over free Cloudflare) — pairs while ICE runs.
        CallHairpin.shared.openForRoster(sessionId: sessionId, me: myHex, others: invitees())
        // Tell peers the camera state a call STARTS in. `broadcastCameraState` only ever fired on
        // TOGGLE, so the opening state — camera off, because calls start audio-only — was the one
        // state never sent. A peer that is never told renders a black tile instead of the avatar
        // until the camera is toggled twice. Android and desktop announce on connect; this side did
        // not, which is why an iPhone caller looked broken to everyone else.
        broadcastCameraState(videoOn)
        for p in invitees() { connectPeerIfNeeded(p) }
        startSpeakerDetection()
    }

    // MARK: - Active-speaker detection

    /// Poll WebRTC audio levels (1s) across all pairwise connections: the loudest inbound peer
    /// vs. our own outbound mic level. A small debounce + threshold keep `activeSpeaker` from
    /// flickering between near-silent participants. 1s, not 0.3s — each poll walks a FULL stats
    /// report per connection, and 3×/s of that was measurable call heat for a highlight that only
    /// needs ~1s responsiveness. 1:1 calls skip entirely (see pollAudioLevels): with one remote
    /// peer there is nothing to disambiguate, so the highlight isn't worth any stats traffic.
    private func startSpeakerDetection() {
        guard speakerTimer == nil else { return }
        speakerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
        // 1:1 call: no ambiguity to resolve — skip the stats polling entirely. (The report parse
        // itself already runs off the main actor, on WebRTC's stats queue; see WebRTCCall.audioLevels.)
        guard conns.count > 1 else {
            if activeSpeaker != nil { activeSpeaker = nil }
            speakerStreak.removeAll()
            return
        }
        // Gather one async stats read per connection, then pick the loudest once all return.
        var remaining = conns.count
        var bestPeer = ""           // loudest remote peer hex
        var bestRemote = 0.0
        var myLevel = 0.0           // loudest local outbound level across connections
        for conn in conns {
            let hex = conn.hex
            conn.call.audioLevels { inbound, outbound in
                Task { @MainActor in
                    if inbound > bestRemote { bestRemote = inbound; bestPeer = hex }
                    if outbound > myLevel { myLevel = outbound }
                    remaining -= 1
                    if remaining == 0 {
                        self.resolveActiveSpeaker(bestPeer: bestPeer, bestRemote: bestRemote, myLevel: myLevel)
                    }
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
    private func connectPeerIfNeeded(_ peer: String) -> PeerConn? {
        guard let conn = peerConn(for: peer) else { return nil }
        if myHex < peer && mediaStarted {   // glare-free: smaller hex offers
            conn.call.makeOffer()
        }
        return conn
    }

    /// Get-or-create the pairwise connection for `peer`, wiring its callbacks. Nil when WebRTC
    /// cannot give us a peer connection at all — see `WebRTCCall.make()`. That used to be a
    /// `fatalError` inside the constructor, so a peer whose relay advertised an ICE server WebRTC
    /// wouldn't parse killed the app at the moment of answering.
    private func peerConn(for peer: String) -> PeerConn? {
        if let existing = peers[peer] { return existing }
        if !roster.contains(peer) { roster.insert(peer); refreshParticipants() }
        guard let c = WebRTCCall.make() else {
            HavenLog.call("no media for \(peer.prefix(8)) — WebRTC would not create a peer connection")
            mediaFailed = true
            return nil
        }
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
                    // TRANSPORT truth is recorded unconditionally — mediaConnected reads it, and an
                    // earlier guard that skipped this write left the UI on "Connecting media…" over
                    // a live call. ANSWERED-ness is a different fact entirely: early media (a
                    // caller negotiates at dial) must neither answer a RINGING callee (the
                    // inCall+ringing poison — accept then no-ops forever) nor flip a CALLER to
                    // connected before anyone accepted. inCall moves ONLY on ACCEPT (frame 11 /
                    // reallyAccept); lost 11s are healed by re-accept-on-invite-retransmit.
                    self.lastPeerState[peer] = state
                    if self.ringing { return }
                    if self.inCall { CallTones.shared.stop() }
                    // ICE RECOVERED while we were relaying — drop back to WebRTC's own (better)
                    // path. This used to live in a fourth `else if state == .connected ...` arm,
                    // which this very branch already swallows, so it was unreachable: once the
                    // hairpin engaged it relayed FOREVER, encoding + decoding + pushing WebSocket
                    // frames alongside the WebRTC media that had come back. That is two full media
                    // pipelines for one call — the "iPhone got noticeably hot after a few minutes".
                    if self.hairpinPeers.contains(peer), !Self.forceHairpin {
                        CallMediaBridge.shared.deactivate(remote: peer)
                        self.hairpinPeers.remove(peer)
                        HavenLog.relay("ice recovered \(peer.prefix(8)) — hairpin relay stopped")
                    } else if self.hairpinPeers.contains(peer) {
                        HavenLog.relay("ice recovered \(peer.prefix(8)) — STAYING on the hairpin (forceHairpin)")
                    }
                    // ICE/media path is up — audio session must be live or UI says Connected with silence.
                    #if os(iOS)
                    self.ensureWebRTCAudioLive(reason: "ice-connected", forceEnable: true)
                    #endif
                    #if !os(macOS)
                    if self.isCaller, let provider = self.provider, let uuid = self.callUUID {
                        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
                    }
                    #endif
                } else if state == .failed {
                    // ICE couldn't pair this peer (two hard NATs, no TURN). Rather than drop the
                    // call, RELAY the media over the /webrtc/hairpin WebSocket through the circle's
                    // public HTTPS origin (the cloudflared tunnel fronts WSS fine — only UDP TURN
                    // can't ride it). Audio + video hop onto the relay; the call survives with zero
                    // router config. An explicit hangup frame (12) still ends it.
                    // The relay IS the media path now, so the call is CONNECTED — startHairpin says
                    // so. Without that the UI sat on "connecting media" while audio was already
                    // flowing over the hairpin, the dialing tone kept looping, the audio session was
                    // never forced live, and CallKit never got its connected report. Usually the
                    // grace timer in createPeer has already raced us here.
                    self.startHairpin(for: peer)
                } else if state == .closed {
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
                        // NEVER drop a peer whose media is riding the hairpin. When the relay is
                        // carrying the call, ICE legitimately sits in disconnected/failed — that is
                        // the whole reason we relayed. Dropping on it hung up a call whose audio was
                        // flowing perfectly ("stuck on connecting media, then connected, then it
                        // hung itself up"). The relay has its own liveness; an explicit hangup
                        // frame (12) still ends the call, as does the peer actually leaving.
                        if self.hairpinPeers.contains(peer) {
                            // ...unless the RELAY has gone quiet too. Media riding the hairpin means
                            // ICE is legitimately failed, so ICE can't tell us the peer is gone —
                            // the relay's own inbound clock has to. Without this a relayed call
                            // whose far end vanished (crash, killed app, no hangup frame) would sit
                            // "connected" forever.
                            if let quiet = CallMediaBridge.shared.silenceSecs(for: peer),
                               quiet > Self.relaySilenceDropSecs {
                                HavenLog.call("relay silent \(Int(quiet))s for \(peer.prefix(8)) — peer gone, ending")
                                self.dropPeer(peer)
                                if self.roster.subtracting([self.myHex]).isEmpty { self.endCall() }
                            }
                            return
                        }
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
        // Media must be there right after both sides accept — NOT after ICE's ~30s failure timer,
        // which is what produced half a minute of "connecting media". So we race: the direct path
        // gets a brief head start, then the relay comes up alongside it, and whichever pairs first
        // carries the call. `.connected` tears the relay back down.
        //
        // Why a beat instead of literally instant: activating the relay SUSPENDS WebRTC's own audio
        // and hands the mic to the hairpin's engine (CallMediaBridge.activate →
        // setNativeAudioSuspendedForHairpin). Doing that unconditionally would seize and then
        // return the mic on every healthy call, an audible glitch plus needless load. 1.5s is long
        // enough that a normal pairing (sub-second once candidates land) never relays at all, and
        // short enough that a failing one is talking almost immediately instead of after 30s.
        let racePeer = peer
        let forced = Self.forceHairpin
        DispatchQueue.main.asyncAfter(deadline: .now() + (forced ? 0.2 : Self.directMediaGraceSecs)) { [weak self] in
            guard let self, self.peers[racePeer] != nil else { return }
            guard !self.hairpinPeers.contains(racePeer) else { return }      // already relaying
            if forced {
                HavenLog.relay("forceHairpin — relaying \(racePeer.prefix(8)) over the hairpin regardless of ICE")
                self.startHairpin(for: racePeer)
                return
            }
            let st = self.lastPeerState[racePeer]
            guard st != .connected, st != .completed else { return }        // direct path won
            HavenLog.relay("direct media not up in \(Self.directMediaGraceSecs)s — racing hairpin for \(racePeer.prefix(8))")
            self.startHairpin(for: racePeer)
        }
        return conn
    }

    /// Head start for the DIRECT path before the relay races it. See createPeer for why this is a
    /// beat rather than zero.
    private static let directMediaGraceSecs: TimeInterval = 1.5

    /// How long a RELAYED peer may be silent before we treat them as gone. Generous — the relay
    /// carries audio continuously, so real silence this long means the far end is not there.
    private static let relaySilenceDropSecs: TimeInterval = 20

    /// Bring the hairpin relay up for `peer` and reflect it in the UI/CallKit. Shared by the grace
    /// timer above and the ICE `.failed` arm, so both paths report CONNECTED the same way.
    private func startHairpin(for peer: String) {
        // Never while RINGING: relay-activating (and promoting to in-call) before the user answers
        // is the same early-media poison as the ICE-connected path above. Post-accept negotiation
        // re-fires this through its own failure arm if the relay is really needed.
        guard !ringing else { return }
        guard !hairpinPeers.contains(peer) else { return }
        CallMediaBridge.shared.activate(remote: peer, sessionId: sessionId,
                                        me: myHex, localVideoTrack: localVideoTrack)
        hairpinPeers.insert(peer)
        connecting = false; inCall = true
        CallTones.shared.stop()
        #if os(iOS)
        ensureWebRTCAudioLive(reason: "hairpin-connected", forceEnable: true)
        #endif
        #if !os(macOS)
        if isCaller, let provider = provider, let uuid = callUUID {
            provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        }
        #endif
    }

    /// Remove a peer from the roster + tear down its connection + its remote tile.
    private func dropPeer(_ peer: String) {
        peers[peer]?.call.close()
        peers[peer] = nil
        if hairpinPeers.remove(peer) != nil { CallMediaBridge.shared.deactivate(remote: peer) }
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
        installAudioSessionObservers()
        // Configure category/mode now. WebRTC playout is gated by `isAudioEnabled` under
        // `useManualAudio` (CallKit owns activation). Without CallKit, or if CallKit never
        // delivers didActivate, we still must enable — field: "Connected" UI but silence both ways.
        ensureWebRTCAudioLive(reason: "startMesh", forceEnable: !useCallKit)
        // CallKit path: fail-open if didActivate is late/missing once media is running.
        if useCallKit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.mediaStarted || self.inCall else { return }
                let rtc = RTCAudioSession.sharedInstance()
                if !rtc.isAudioEnabled {
                    HavenLog.call("CallKit audio still disabled 1.5s after mesh — fail-open enable")
                    self.ensureWebRTCAudioLive(reason: "callkit-timeout", forceEnable: true)
                }
            }
        }
        #endif
    }

    /// Make WebRTC capture + playout live. Safe to call repeatedly mid-call (ICE connect, recovery).
    private func ensureWebRTCAudioLive(reason: String, forceEnable: Bool = true) {
        #if os(iOS)
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        // Mirror the user's speaker choice — recovery used to reassert .defaultToSpeaker
        // unconditionally, which put an earpiece call back on the speaker behind their back.
        try? rtc.setCategory(.playAndRecord,
                             with: speakerOn ? [.allowBluetoothHFP, .defaultToSpeaker] : [.allowBluetoothHFP])
        try? rtc.setMode(.voiceChat)
        try? rtc.setActive(true)
        // Default to speaker for in-app video-style calls so "connected but silent" isn't just
        // earpiece at zero volume against the cheek — user can still toggle.
        if !speakerOn {
            speakerOn = true
        }
        try? rtc.overrideOutputAudioPort(.speaker)
        rtc.unlockForConfiguration()
        guard forceEnable else { return }
        if !rtc.isAudioEnabled {
            HavenLog.call("WebRTC audio enable (\(reason))")
            rtc.isAudioEnabled = true
        } else if reason.contains("recover") || reason.contains("Deactivate") || reason.contains("reset") {
            // Bounce only on recovery paths — not every ICE "connected" tick.
            rtc.isAudioEnabled = false
            rtc.isAudioEnabled = true
            HavenLog.call("WebRTC audio bounce (\(reason))")
        }
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
        try? rtc.setCategory(.playAndRecord, with: [.allowBluetoothHFP, .defaultToSpeaker])
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
        // THE CATEGORY HAS TO MOVE WITH THE OVERRIDE.
        //
        // The session is configured `.playAndRecord` with `.defaultToSpeaker`, and under that option
        // `.none` does not mean "earpiece" — it means "the default", which IS the speaker. So
        // overriding to `.none` left the route on the built-in speaker, syncSpeakerState then read
        // `.builtInSpeaker` back off the route and snapped `speakerOn` to true again, and the button
        // did nothing at all in either direction.
        //
        // Drop `.defaultToSpeaker` when going to the earpiece, restore it for speakerphone. The
        // override still does the actual switching; the category just stops contradicting it.
        try? s.setCategory(.playAndRecord,
                           with: speakerOn ? [.allowBluetoothHFP, .defaultToSpeaker] : [.allowBluetoothHFP])
        try? s.overrideOutputAudioPort(speakerOn ? .speaker : .none)
        s.unlockForConfiguration()
        #endif
    }

    func toggleMute() {
        // APPLY FIRST, then tell CallKit — never the other way round.
        //
        // Routing the tap THROUGH CallKit and waiting for its echo meant the button did nothing at
        // all whenever that echo never came. The error path was already handled; the silent case is
        // the one that bit: `controller.request` reports success, CallKit simply never invokes
        // `provider(_:perform: CXSetMutedCallAction)`, and `applyMuted` is therefore never reached.
        // The mic stays live, `muted` never changes, the icon never flips, and tapping harder does
        // nothing forever — mute is the only control that round-trips through CallKit, which is
        // exactly why it was the only one that felt dead.
        //
        // Applying locally first makes the tap authoritative. The CallKit request still goes out so
        // the system UI agrees, and its echo lands on `applyMuted` with the value we already set,
        // which is idempotent.
        let next = !muted
        applyMuted(next)
        HavenLog.call("mute tapped → \(next ? "MUTED" : "unmuted") (applied locally; syncing CallKit)")
        if useCallKit { requestCallKitMuted(next) }
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
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: m))) { [weak self] err in
            guard let err else { return }   // fulfilled → provider handler re-applies the same value
            // CallKit REFUSED the transaction — most often because it doesn't consider this UUID an
            // active call (answered through our own UI without CallKit ever reporting it, or already
            // reported ended). Swallowing that error left the mute button doing NOTHING while every
            // other control worked, because mute is the only one that round-trips through CallKit —
            // "I can't reliably toggle mute but all the other buttons respond". A tap must always
            // take effect, so apply it directly and say what happened.
            HavenLog.call("CallKit refused mute: \(err.localizedDescription) — applying locally")
            Task { @MainActor in self?.applyMuted(m) }
        }
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

    #if DEBUG
    // MARK: - QA introspection

    /// Latest inbound RTP counters per peer, refreshed by [qaSnapshot]. Stats arrive on WebRTC's own
    /// queue, so the snapshot reports the previous sample and kicks a refresh for the next one —
    /// the E2E suite polls to convergence anyway.
    private var qaInbound: [String: (audio: Int, video: Int, frames: Int)] = [:]

    /// Call state for the QA dump. Reports BYTES RECEIVED, not just connection state: a call that
    /// shows "connected" on both sides while carrying no audio is exactly the failure this has to
    /// catch, and only the RTP counters distinguish the two.
    /// QA visibility ONLY — see the Android twin. `in_call` alone cannot say WHICH session a leg is
    /// in, and every teardown handler is gated on the session id matching.
    private(set) var qaLastCallEvent: String = "none"
    func qaNoteCallEvent(_ what: String) { qaLastCallEvent = what }

    func qaSnapshot() -> [String: Any] {
        for (hex, conn) in peers {
            conn.call.inboundMedia { [weak self] audio, video, frames in
                Task { @MainActor in self?.qaInbound[hex] = (audio, video, frames) }
            }
        }
        var audioTotal = 0, videoTotal = 0, framesTotal = 0
        var perPeer: [String: [String: Int]] = [:]
        for (hex, m) in qaInbound {
            audioTotal += m.audio; videoTotal += m.video; framesTotal += m.frames
            perPeer[hex] = ["audio_bytes": m.audio, "video_bytes": m.video, "video_frames": m.frames]
        }
        return [
            "session": sessionId,
            "last_event": qaLastCallEvent,
            "in_call": inCall,
            "connecting": connecting,
            "ringing": ringing,
            "video_on": videoOn,
            "participants": participants,
            "hairpin_peers": Array(hairpinPeers),
            "remote_video_tracks": Array(remoteVideoTracks.keys),
            "inbound_audio_bytes": audioTotal,
            "inbound_video_bytes": videoTotal,
            "inbound_video_frames": framesTotal,
            "peers": perPeer,
        ]
    }
    #endif

    // MARK: - End

    func endCall() {
        #if os(macOS)
        reallyEnd(); return
        #else
        guard useCallKit, let uuid = callUUID else { reallyEnd(); return }
        // END LOCALLY FIRST, then tell CallKit.
        //
        // This had the same swallowed-error shape that made Answer and Mute feel dead — `{ _ in }`
        // threw away the refusal — but hanging up is worse when it fails, because the user is
        // actively trying to get OUT and the screen simply will not go away. Unlike answering, this
        // needs nothing from CallKit first: no audio session, no ordering. So act on the tap, then
        // let CallKit retire its copy; `reallyEnd` is guarded, so its echo is a no-op.
        HavenLog.call("hang up tapped → ending locally, syncing CallKit")
        reallyEnd()
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { err in
            guard let err else { return }
            HavenLog.call("CallKit refused end: \(err.localizedDescription) — already ended locally")
        }
        #endif
    }

    /// Fired by CXEndCallAction (system UI or our button): send hangup to ALL participants + tear down.
    private func reallyEnd() {
        // Idempotent: the tap ends the call and CallKit's echo arrives here again a moment later.
        guard active else { HavenLog.call("reallyEnd ignored — no active call"); return }
        // Stand down my OTHER devices on any end, not just a decline.
        //
        // This used to fire only for `ringing && !inCall`, so declining a ring silenced my other
        // devices but ENDING an established call did not — the hangup below goes to `invitees()`,
        // which is the roster minus my own account, so nothing ever told my other devices the call
        // was over. Observed on a QA fleet: iOS and the Mac stub hung up correctly while the Android
        // and desktop legs sat in the call indefinitely.
        //
        // Ending is at least as much "I have handled this" as declining is. The receiving side stays
        // deliberately narrow — it only silences a device still RINGING, never one already answered,
        // so this cannot tear down a conversation someone is actively having on another device.
        notifyOwnDevicesHandled(ended: true)
        for p in invitees() {
            var f = Data(myHex.utf8)
            CallManager.lpAppend(&f, Data(sessionId.utf8))
            FeedStore.shared.sendCallFrame(12, f, to: p)
        }
        teardown("local hang up")
    }

    /// Every path that ends a call funnels here. It used to do so ANONYMOUSLY, which is why a call
    /// that "ended on its own" left nothing in the log to explain it — nine call sites, no way to
    /// tell which one fired. The reason is required now.
    private func teardown(_ reason: String = "unspecified") {
        outgoingBegun = false
        defer { syncIdleTimer() }   // after `active` is cleared, so it always restores
        HavenLog.call("teardown(\(reason)) — active=\(active) inCall=\(inCall) ringing=\(ringing) connecting=\(connecting) peers=\(peers.count) session=\(sessionId.prefix(8))")
        // Remember the session so the caller's still-in-flight invite retransmits can't re-ring it.
        if !sessionId.isEmpty {
            endedSessions[sessionId] = Date()
            if endedSessions.count > 50 {   // prune long-expired tombstones
                endedSessions = endedSessions.filter { Date().timeIntervalSince($0.value) < Self.endedTombstoneSecs }
            }
        }
        ringTimeoutTimer?.invalidate(); ringTimeoutTimer = nil
        mediaFailed = false   // per-attempt, never carried into the next call
        CallTones.shared.stop()
        stopInAppRinging()
        stopSpeakerDetection()
        CallMediaBridge.shared.stopAll()
        hairpinPeers.removeAll()
        CallHairpin.shared.closeAll()
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

    #if DEBUG
    /// HAVEN_RING_TEST=1: simulate an incoming call at launch so the bounded-ring path (ring →
    /// timeout → missed-call teardown) is verifiable on one machine with no second device. Pair
    /// with HAVEN_RING_TIMEOUT=<secs> to shorten the wait, and HAVEN_NO_NET=1 to stay offline.
    func debugSimulateIncomingRing() {
        guard ProcessInfo.processInfo.environment["HAVEN_RING_TEST"] == "1", !active else { return }
        sessionId = "ringtest-\(UUID().uuidString.prefix(8))"
        roster = [String(repeating: "f", count: 64), myHex]
        peerName = "Ring Test"; isCaller = false; active = true
        refreshParticipants()
        reportIncoming(name: peerName)
    }
    #endif

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
        Task { @MainActor in self.teardown("CXEndCallAction from CallKit") }
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
        // Re-assert call category after CallKit hands us the session (otherwise we can stay in
        // a silent/playback-only route and "Connected" with no hearable audio).
        Task { @MainActor in
            self.ensureWebRTCAudioLive(reason: "callkit-didActivate", forceEnable: true)
        }
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(audioSession)
        // Only mute WebRTC if the call is over — mid-call deactivation (route blip) must recover.
        Task { @MainActor in
            if self.active {
                HavenLog.call("CallKit didDeactivate while active — recovering audio")
                self.recoverCallAudio(reason: "callkit-didDeactivate")
            } else {
                rtc.isAudioEnabled = false
            }
        }
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
        #if os(macOS)
        // Mac scaffold instead of a NavigationStack toolbar — Cancel landed on a gray system band.
        HavenMacSheet("Add to call") {
            let people = call.addableContacts()
            if people.isEmpty {
                Text("Everyone you know is already on the call.").foregroundStyle(.secondary).padding()
            } else {
                VStack(spacing: 8) { ForEach(people, id: \.hex) { row($0) } }
            }
        }
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                let people = call.addableContacts()
                if people.isEmpty {
                    Text("Everyone you know is already on the call.").foregroundStyle(.secondary).padding()
                } else {
                    List(people, id: \.hex) { p in
                        row(p).listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Add to call")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { dismiss() }.havenToolbarPill() } }
        }
        #endif
    }

    private func row(_ p: (hex: String, name: String)) -> some View {
        Button { CallManager.shared.addToCall(p.hex); dismiss() } label: {
            HStack(spacing: 12) {
                PeerAvatar(nodeHex: p.hex, name: p.name, size: 40)
                Text(p.name).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(HavenTheme.pink)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)   // the row is the button; no bezel behind it
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
            // Opaque, not 0.96: this overlays the live feed, and 4% was enough to read post text,
            // names and the tab bar straight through the call.
            HavenTheme.brand.ignoresSafeArea()
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
                .buttonStyle(.plain)   // answer/decline supply their own circles; drop macOS's bezel
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
        .transition(.move(edge: .bottom))
    }

    private var active: some View {
        ZStack {
            // Opaque, not 0.96 — see `incoming`. The gaps around the tiles are the only place this
            // shows, and they were showing the feed.
            HavenTheme.brand.ignoresSafeArea()
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
                            .padding(.top, 8).padding(.trailing, 16)
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
                        Button { call.minimized = true } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(GlassIconButtonStyle(size: 40, tint: .white))
                            .accessibilityIdentifier("callMinimize")
                        Spacer()
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 20)
                Spacer()
                controls.padding(.bottom, 16)
            }
        }
        // No ignoresSafeArea here: this scene's chrome (minimize, the name, the controls) has to sit
        // INSIDE the safe area, and an ignoresSafeArea on the whole ZStack zeroes it for every
        // descendant — which left minimize at x=0/y=54, hard against the display's rounded corner,
        // and the name under the Dynamic Island. Each full-bleed layer (background, soloTile,
        // screenStage) already ignores the safe area itself, so those visuals stay edge-to-edge;
        // `grid` deliberately does not, so its tiles stay clear of the rounded corners.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // WebRTC refused a peer connection outright, so there is no media path on this attempt and
        // there will not be one. This used to be a `fatalError` — the app simply died on answering —
        // so the whole point of making it survivable is that it now has something to SAY. Checked
        // before `connecting`, because a call that can't start must not sit on "Calling…" forever.
        if call.mediaFailed { return "Couldn't start audio" }
        if call.connecting { return "Calling…" }
        // Answered but no ICE path yet: say so — "Connected" with silence erodes trust in the
        // label (and hides real media-path failures from the person staring at the screen).
        guard call.mediaConnected else { return "Connecting media…" }
        let n = call.participants.count
        return n > 1 ? "\(n) participants" : "Connected"
    }

    /// A grid of remote participant tiles. Column count adapts to the *shape* of the space, not a
    /// fixed number: a tall, narrow phone stacks people full-width (one column) instead of slicing
    /// the screen into useless thin columns; a wide Mac window lays them side-by-side. Tiles go
    /// square once there's more than one row (so they fill width and scroll), and fill the height
    /// for a single row. One peer fills the screen.
    private var grid: some View {
        // Tiles sit INSIDE the safe area (+ a corner margin) so their rounded corners, name badges
        // and active-speaker borders never bleed into the device's rounded screen corners. Unlike
        // the other layers in `active`, this one must NOT ignore the safe area: the reader below is
        // laid out within it, so `geo.size` is already inset and only the margin is left to apply.
        // Do not reach for `geo.safeAreaInsets` here — an `.ignoresSafeArea()` attached under the
        // reader consumes the insets before it resolves, so the proxy reports .zero and padding by
        // it silently does nothing (which is how the tiles ended up under the status bar clock).
        GeometryReader { geo in
            let margin: CGFloat = 12
            let w = max(geo.size.width - margin * 2, 80)
            let h = max(geo.size.height, 80)
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
            .padding(.horizontal, margin)
        }
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
        .sheet(isPresented: $showAddPicker) {
            #if os(macOS)
            AddToCallPicker()   // HavenMacSheet already brings its own frame + gradient
            #else
            AddToCallPicker().macSheetFrame()
            #endif
        }
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

    /// One glass circle per control — `on` brightens the same surface with a tint instead of
    /// swapping in a second hand-rolled scrim.
    private func callButton(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(.white).frame(width: 52, height: 52)
            .havenGlass(in: Circle(), tint: on ? Color.white.opacity(0.3) : nil)
            // Make the WHOLE 52pt circle tappable.
            //
            // Without this SwiftUI hit-tests an Image against its rendered GLYPH, not its frame, so
            // a tap only counted when it landed on the mic strokes themselves — everything else in
            // the button, including the visible glass disc, was a dead zone. That is the "mute needs
            // four or five taps" report: the taps were not being lost or debounced, they were
            // missing a target far smaller than the control looks. It never reached `toggleMute()`
            // at all — the log recorded zero taps while the user was hammering it.
            .contentShape(Circle())
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
        #if os(macOS)
        // Mac scaffold instead of NavigationView + toolbar — the list sat on the bare gray window
        // background with a system band under Cancel. The close circle (or Esc) cancels.
        HavenMacSheet("Share screen") {
            VStack(alignment: .leading, spacing: 6) { sources }
        }
        #else
        NavigationView {
            List { sources }
            .navigationTitle("Share screen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { call.showScreenPicker = false; dismiss() }
                }
            }
        }
        #endif
    }

    @ViewBuilder private var sources: some View {
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
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
#endif
