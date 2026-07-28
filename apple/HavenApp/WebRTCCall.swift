import Foundation
import WebRTC
import AVFoundation

/// A single WebRTC peer connection for one call. Media (audio + optional video) flows directly
/// peer-to-peer, encrypted by WebRTC's DTLS-SRTP (end-to-end for a 1:1 direct connection). The
/// SDP offer/answer and ICE candidates are produced here and handed to `CallManager`, which sends
/// them via `FeedStore.sendCallFrame` — where each frame is SEALED + SIGNED to the recipient
/// (`seal_call_frame`) before it leaves the device, so there is no signaling server and no relay on
/// the path can read or rewrite the signaling (audit R1). The DTLS-SRTP fingerprint inside the
/// offer is therefore integrity-protected end-to-end: a relay cannot swap it to MITM the media.
/// STUN handles most NATs; a TURN relay (e.g. haven-relay) can be added for symmetric NATs.
///
/// Signaling payloads are tiny JSON, framed as `[hex64][lp sessionId?][json]` then sealed+signed:
///   16 = SDP offer · 17 = SDP answer · 18 = ICE candidate.
final class WebRTCCall: NSObject {
    /// One shared factory (creating several is wasteful and can crash).
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        // Prefer H264: hardware encode/decode on Apple. Left to the default order a call can
        // land on VP8/VP9 — SOFTWARE codecs that peg the CPU (device heat), starve the audio
        // thread (dropouts), and pixelate under load. Peers without H264 still negotiate down.
        if let h264 = RTCDefaultVideoEncoderFactory.supportedCodecs()
            .first(where: { $0.name == kRTCVideoCodecH264Name }) {
            encoder.preferredCodec = h264
        }
        return RTCPeerConnectionFactory(encoderFactory: encoder,
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let pc: RTCPeerConnection
    private let audioTrack: RTCAudioTrack
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var captureProxy: RTCVideoCapturerDelegate?
    private var cameraPosition: AVCaptureDevice.Position = .front
    // A SECOND video track dedicated to screen sharing, so screen + camera can coexist on the
    // same peer connection (two video m-lines under unified plan). Frames are pushed externally
    // (ScreenCaptureKit on macOS, a ReplayKit broadcast extension on iOS) via `pushScreenFrame`.
    private var screenSource: RTCVideoSource?
    private var screenTrack: RTCVideoTrack?
    /// A neutral capturer object required only because `RTCVideoSource.capturer(_:didCapture:)`
    /// takes one; it never actually captures anything itself.
    private lazy var screenCapturer = RTCVideoCapturer()
    /// When set (e.g. via the Mac device menu), capture uses this exact device instead of `cameraPosition`.
    private var preferredCameraUniqueID: String?

    /// Outbound signaling (sealed + sent by CallManager) + remote-track callbacks.
    var onLocalSDP: ((RTCSessionDescription) -> Void)?
    var onLocalCandidate: ((RTCIceCandidate) -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?
    /// Fires with a track id when a remote video track is removed (e.g. peer stopped screen sharing).
    var onRemoteVideoTrackEnded: ((String) -> Void)?
    var onStateChange: ((RTCIceConnectionState) -> Void)?
    /// Fires once the remote description is actually applied — only then is it safe to add the
    /// peer's ICE candidates.
    var onRemoteReady: (() -> Void)?

    /// Perfect-negotiation politeness. When BOTH sides renegotiate at once (glare), the *polite*
    /// side rolls its own offer back and accepts the peer's; the *impolite* side ignores the
    /// colliding offer so its own wins. CallManager sets the larger-hex peer polite. Single-sided
    /// renegotiation (the common case — one person toggles video/screen) never collides.
    var polite = false
    private var isMakingOffer = false

    /// Fails (rather than crashing) when WebRTC won't give us a peer connection at all.
    ///
    /// This used to `fatalError`. `RTCPeerConnectionFactory.peerConnection` returns nil when it
    /// REJECTS THE CONFIGURATION, and the configuration is not ours: `iceServers` is built from
    /// `haven.fabric.turnUrls`, which arrives from whatever relay the circle is using. One
    /// malformed entry there — a `turns:` URL with a bad port, a scheme WebRTC won't parse — makes
    /// the whole list invalid, so the factory returns nil and the app terminated. On the ACCEPT
    /// path (`startMesh` → `connectPeerIfNeeded` → here), that is an app that dies the instant you
    /// pick up, which is exactly what a caller on another platform, in another circle, with
    /// different relay config, was able to trigger.
    ///
    /// A bad ICE server should cost you server-reflexive candidates, never the process. So: try the
    /// circle's config, then plain STUN, then no servers at all (host candidates + the hairpin still
    /// carry a LAN or hairpinned call). Only if WebRTC refuses all three is there genuinely no peer
    /// connection to be had, and then we return nil and the caller fails the call politely.
    /// The only way to build one. Returns nil instead of terminating when WebRTC won't hand us a
    /// peer connection; `CallManager` turns that into a failed call rather than a dead app.
    static func make() -> WebRTCCall? {
        guard let pc = makePeerConnection() else { return nil }
        return WebRTCCall(pc: pc)
    }

    /// Try the circle's ICE config, then plain STUN, then no servers at all. Nil only if WebRTC
    /// refuses every one of them.
    private static func makePeerConnection() -> RTCPeerConnection? {
        let attempts: [(String, [RTCIceServer])] = [
            ("circle", configuredIceServers()),
            ("stun-only", [RTCIceServer(urlStrings: HavenFabric.googleStunUrls)]),
            ("host-only", []),
        ]
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        for (label, servers) in attempts {
            let config = RTCConfiguration()
            config.iceServers = servers
            config.sdpSemantics = .unifiedPlan
            config.continualGatheringPolicy = .gatherContinually
            if let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil) {
                if label != "circle" {
                    HavenLog.call("ICE config rejected by WebRTC — fell back to \(label). This call may not traverse NAT.")
                }
                return pc
            }
            HavenLog.call("peerConnection(\(label)) returned nil — trying the next ICE fallback")
        }
        HavenLog.call("WebRTC refused a peer connection under every ICE configuration — cannot place media")
        return nil
    }

    /// The circle's own ICE servers, as WebRTC objects. Entries with no URLs are dropped rather than
    /// passed through — an empty `urls` array is one of the things that makes the factory reject the
    /// whole configuration.
    private static func configuredIceServers() -> [RTCIceServer] {
        HavenFabric.iceServersFromDefaults().compactMap { d -> RTCIceServer? in
            let urls = (d["urls"] as? [String] ?? []).filter { !$0.isEmpty }
            guard !urls.isEmpty else { return nil }
            if let user = d["username"] as? String, let pass = d["credential"] as? String,
               !user.isEmpty, !pass.isEmpty {
                return RTCIceServer(urlStrings: urls, username: user, credential: pass)
            }
            return RTCIceServer(urlStrings: urls)
        }
    }

    private init(pc: RTCPeerConnection) {
        self.pc = pc

        // Explicitly enable WebRTC's audio processing: acoustic echo cancellation, automatic
        // gain control, noise suppression, and a high-pass filter. These make speakerphone +
        // video calls usable on any hardware (without AEC the far end hears their own voice back).
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "true",
            "googEchoCancellation2": "true",
            "googAutoGainControl": "true",
            "googNoiseSuppression": "true",
            "googNoiseSuppression2": "true",
            "googHighpassFilter": "true",
        ], optionalConstraints: nil)
        let audioSource = WebRTCCall.factory.audioSource(with: audioConstraints)
        audioTrack = WebRTCCall.factory.audioTrack(with: audioSource, trackId: "audio0")
        super.init()
        pc.delegate = self
        pc.add(audioTrack, streamIds: ["stream0"])
        // Establish the VIDEO m-line NOW, disabled — do not wait for the camera to be switched on.
        //
        // Adding a track mid-call adds an m-line mid-call, and the re-offer that carries it can
        // present its m-lines in a different order than the one already negotiated. WebRTC refuses
        // that outright — "The order of m-lines in subsequent offer doesn't match order from
        // previous offer/answer" — and the peer connection dies: ICE goes DISCONNECTED → CLOSED, the
        // far end hangs up, and the call ends itself a minute in with no explanation. Android now
        // publishes its video track up front for the same reason, so an asymmetric setup here is
        // exactly what produced the mismatch.
        //
        // Creating both m-lines at construction makes the session shape FIXED for the call's
        // lifetime: turning the camera on or off flips `isEnabled` on an existing sender, which
        // needs no renegotiation at all. It also makes enabling video instant rather than a round
        // trip. `startVideo()` still creates the capturer on demand — only the track and its m-line
        // are pre-established.
        let vSource = WebRTCCall.factory.videoSource()
        let vTrack = WebRTCCall.factory.videoTrack(with: vSource, trackId: "video0")
        vTrack.isEnabled = false
        videoSource = vSource
        videoTrack = vTrack
        pc.add(vTrack, streamIds: ["stream0"])
        tuneVideoSender(trackId: vTrack.trackId, maxBitrateBps: 1_200_000)
    }

    // MARK: Offer / answer

    func makeOffer() {
        // Don't stack offers on ourselves: only offer from a stable state when none is in flight.
        // (A mid-call track add by either side renegotiates safely; collisions are handled below.)
        guard pc.signalingState == .stable, !isMakingOffer else { return }
        isMakingOffer = true
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: c) { [weak self] sdp, _ in
            guard let self else { return }
            guard let sdp else { self.isMakingOffer = false; return }
            self.pc.setLocalDescription(sdp) { _ in
                self.isMakingOffer = false
                self.onLocalSDP?(sdp)
            }
        }
    }

    func setRemoteOfferAndAnswer(_ sdp: RTCSessionDescription) {
        // Perfect negotiation: an incoming offer "collides" if we're mid-offer or not stable. The
        // impolite side keeps its own offer (drops theirs); the polite side rolls back and accepts.
        let collision = isMakingOffer || pc.signalingState != .stable
        if collision && !polite { return }
        if collision {
            let rollback = RTCSessionDescription(type: .rollback, sdp: "")
            pc.setLocalDescription(rollback) { [weak self] _ in
                self?.isMakingOffer = false
                self?.applyRemoteOffer(sdp)
            }
        } else {
            applyRemoteOffer(sdp)
        }
    }

    private func applyRemoteOffer(_ sdp: RTCSessionDescription) {
        pc.setRemoteDescription(sdp) { [weak self] _ in
            guard let self else { return }
            self.onRemoteReady?()
            let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self.pc.answer(for: c) { [weak self] answer, _ in
                guard let self, let answer else { return }
                self.pc.setLocalDescription(answer) { _ in self.onLocalSDP?(answer) }
            }
        }
    }

    func setRemoteAnswer(_ sdp: RTCSessionDescription) {
        // Accept an answer whenever WE have an offer in flight (initial OR renegotiation).
        // The old guard bailed whenever remoteDescription was non-nil — which is true forever
        // after the first negotiation — so every RENEGOTIATION answer (video/screen toggle →
        // renegotiateAll → makeOffer) was dropped: the offerer wedged in have-local-offer,
        // makeOffer's .stable guard then no-op'd all future renegotiations, and toggling video
        // never reached the remote even on a healthy ICE path. Redelivered/stale answers (the
        // HTTP live-lane repeats itself) are exactly the ones that arrive while we're .stable
        // with no offer outstanding — still ignored.
        guard pc.signalingState == .haveLocalOffer else { return }
        pc.setRemoteDescription(sdp) { [weak self] err in
            if let err { HavenLog.call("answer set fail: \(err.localizedDescription)"); return }
            self?.onRemoteReady?()
        }
    }

    func addRemoteCandidate(_ candidate: RTCIceCandidate) {
        pc.add(candidate) { _ in }
    }

    /// Mute/unmute the mic by disabling the audio track (instant, no renegotiation).
    func setMicEnabled(_ on: Bool) { audioTrack.isEnabled = on }

    // MARK: Audio levels (active-speaker detection)

    /// Pull the current audio level for this peer connection.
    /// - `inbound`: the level of the REMOTE peer's audio we're receiving (their `inbound-rtp`).
    /// - `outbound`: the level of OUR own mic on this connection (the local `media-source`).
    /// Both are 0…1 (from WebRTC's `audioLevel`). The result is delivered on the WebRTC stats queue.
    func audioLevels(_ completion: @escaping (_ inbound: Double, _ outbound: Double) -> Void) {
        pc.statistics { report in
            var inbound = 0.0
            var outbound = 0.0
            for (_, stat) in report.statistics {
                switch stat.type {
                case "inbound-rtp":
                    if (stat.values["kind"] as? String) == "audio",
                       let lvl = stat.values["audioLevel"] as? NSNumber {
                        inbound = max(inbound, lvl.doubleValue)
                    }
                case "media-source":
                    if (stat.values["kind"] as? String) == "audio",
                       let lvl = stat.values["audioLevel"] as? NSNumber {
                        outbound = max(outbound, lvl.doubleValue)
                    }
                default:
                    break
                }
            }
            completion(inbound, outbound)
        }
    }

    /// How much media has actually ARRIVED on this connection — bytes and decoded frames, not
    /// track presence. The field failure was a call both sides showed as "connected", with tracks
    /// attached, that carried no audio in either direction and never showed the remote video. Only
    /// inbound-rtp byte counters can tell those apart, so this is what QA asserts on.
    func inboundMedia(_ completion: @escaping (_ audioBytes: Int, _ videoBytes: Int, _ videoFrames: Int) -> Void) {
        pc.statistics { report in
            var audio = 0, video = 0, frames = 0
            for (_, stat) in report.statistics where stat.type == "inbound-rtp" {
                let bytes = (stat.values["bytesReceived"] as? NSNumber)?.intValue ?? 0
                switch stat.values["kind"] as? String {
                case "audio": audio += bytes
                case "video":
                    video += bytes
                    frames += (stat.values["framesDecoded"] as? NSNumber)?.intValue ?? 0
                default: break
                }
            }
            completion(audio, video, frames)
        }
    }

    // MARK: Video (toggled mid-call)

    /// Build the camera capturer for an existing video source. Split out of [startVideo] so the
    /// pre-established track (created in init, before any camera exists) can bring capture up later
    /// without re-adding a track — adding one mid-call is what reorders m-lines and kills the call.
    private func buildCapturer(for source: RTCVideoSource?) {
        guard let source else { return }
        #if targetEnvironment(macCatalyst) || os(macOS)
        let proxy = RotatingVideoProxy(source: source)
        captureProxy = proxy
        capturer = RTCCameraVideoCapturer(delegate: proxy)
        #else
        capturer = RTCCameraVideoCapturer(delegate: source)
        #endif
    }

    func startVideo() {
        // The track and its m-line are created at construction (see init), so the common path is
        // simply: enable it and start the camera. No track add, no renegotiation, no m-line change.
        if let existing = videoTrack {
            existing.isEnabled = true
            if capturer == nil { buildCapturer(for: videoSource) }
            startCapture()
            return
        }
        let source = WebRTCCall.factory.videoSource()
        let track = WebRTCCall.factory.videoTrack(with: source, trackId: "video0")
        #if targetEnvironment(macCatalyst) || os(macOS)
        // The Mac webcam's frames come in rotated 90° clockwise (no device-orientation cue), so
        // both the local preview and the peer see it sideways. This is a property of
        // RTCCameraVideoCapturer + the Mac camera, so it applies to the NATIVE macOS build too, not
        // just Catalyst. Rotate every frame 90° CCW here, at the source, so it's upright everywhere.
        let proxy = RotatingVideoProxy(source: source)
        captureProxy = proxy
        let cap = RTCCameraVideoCapturer(delegate: proxy)
        #else
        let cap = RTCCameraVideoCapturer(delegate: source)
        #endif
        videoSource = source; videoTrack = track; capturer = cap
        pc.add(track, streamIds: ["stream0"])
        tuneVideoSender(trackId: track.trackId, maxBitrateBps: 1_200_000)
        startCapture()
    }

    /// Cap a video sender's bitrate and tell WebRTC to DEGRADE GRACEFULLY (drop resolution +
    /// framerate together) under CPU/bandwidth pressure. Without this the encoder holds
    /// resolution and just starves — which the user sees as pixelation, lag, and audio dropouts
    /// (audio loses the CPU fight against an overloaded video encode).
    private func tuneVideoSender(trackId: String, maxBitrateBps: Int) {
        for sender in pc.senders where sender.track?.trackId == trackId {
            let p = sender.parameters
            p.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
            for enc in p.encodings { enc.maxBitrateBps = NSNumber(value: maxBitrateBps) }
            sender.parameters = p
        }
    }

    func stopVideo() {
        videoTrack?.isEnabled = false
        capturer?.stopCapture()
    }

    // MARK: Screen share (a second video track, fed external frames)

    /// The track id used for the screen-share track. Used on the receiving side to tell a peer's
    /// screen track apart from their camera track (`video0`).
    static let screenTrackId = "screen0"

    /// Whether the screen track currently exists (sharing is active on this connection).
    var isSharingScreen: Bool { screenTrack != nil }

    /// Lazily create + add the screen-share video track. Returns true if a NEW track was added
    /// (caller should renegotiate). Idempotent: returns false if it already existed.
    @discardableResult
    func startScreenShare() -> Bool {
        guard screenTrack == nil else { screenTrack?.isEnabled = true; return false }
        let source = WebRTCCall.factory.videoSource(forScreenCast: true)
        let track = WebRTCCall.factory.videoTrack(with: source, trackId: WebRTCCall.screenTrackId)
        screenSource = source; screenTrack = track
        // Use a distinct stream id so the receiver groups it separately from the camera.
        pc.add(track, streamIds: ["screen"])
        // Screen content gets more headroom than the camera (text needs the detail), but is
        // still capped + degradable so it can't starve the camera/audio.
        tuneVideoSender(trackId: track.trackId, maxBitrateBps: 2_500_000)
        return true
    }

    /// Tear down the screen-share track. Returns true if a track was actually removed (caller
    /// should renegotiate).
    @discardableResult
    func stopScreenShare() -> Bool {
        guard let track = screenTrack else { return false }
        // Remove the sender carrying the screen track so the m-line goes inactive on renegotiation.
        for sender in pc.senders where sender.track?.trackId == track.trackId {
            pc.removeTrack(sender)
        }
        screenTrack = nil
        screenSource = nil
        return true
    }

    /// Push one captured screen frame (already a CVPixelBuffer) into the screen source. No-op if
    /// screen sharing isn't active on this connection. `rotation` defaults to upright.
    func pushScreenFrame(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64,
                         rotation: RTCVideoRotation = ._0) {
        guard let source = screenSource else { return }
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: buffer, rotation: rotation, timeStampNs: timeStampNs)
        source.capturer(screenCapturer, didCapture: frame)
    }

    func flipCamera() {
        preferredCameraUniqueID = nil
        cameraPosition = (cameraPosition == .front) ? .back : .front
        startCapture()
    }

    /// Switch capture to a specific camera (desktop device menu). Restarts capture on that device.
    func selectCamera(_ deviceUniqueID: String) {
        preferredCameraUniqueID = deviceUniqueID
        if let dev = RTCCameraVideoCapturer.captureDevices().first(where: { $0.uniqueID == deviceUniqueID }) {
            cameraPosition = dev.position
        }
        startCapture()
    }

    /// The unique ID of the camera capture currently targeted (best-effort, for menu checkmarks).
    var currentCameraUniqueID: String? {
        if let id = preferredCameraUniqueID { return id }
        return RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == cameraPosition })?.uniqueID
    }

    /// The local camera track, for a self-preview view.
    var localVideoTrack: RTCVideoTrack? { videoTrack }

    /// True while capturing from the front camera — the self-preview should mirror, the sent frames
    /// (and the rear camera, always) should not.
    var usingFrontCamera: Bool { cameraPosition == .front }

    /// Camera work happens HERE, never on the main thread. Enumerating devices, querying supported
    /// formats and starting an AVCaptureSession are each synchronous and slow (hundreds of ms), and
    /// every caller of startCapture/stopCapture used to be on the @MainActor CallManager — so
    /// toggling video, flipping the camera, or hanging up froze the UI mid-tap. That is the
    /// "buttons need several taps, camera switch is the worst" experience: the taps landed, the
    /// main thread was just blocked inside AVFoundation. Serial so start/stop can't interleave.
    private static let captureQueue = DispatchQueue(label: "haven.call.capture", qos: .userInitiated)

    private func startCapture() {
        // Read the actor-ish state on the CALLING thread, then do the blocking work off it.
        guard let cap = capturer else { return }
        let wantID = preferredCameraUniqueID
        let wantPosition = cameraPosition
        Self.captureQueue.async {
            let devices = RTCCameraVideoCapturer.captureDevices()
            let picked: AVCaptureDevice?
            if let id = wantID {
                picked = devices.first(where: { $0.uniqueID == id })
            } else {
                picked = devices.first(where: { $0.position == wantPosition })
            }
            guard let device = picked ?? devices.first else { return }
            let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
            // A modest 640-wide format keeps the bitrate friendly.
            let format = formats.min(by: { f1, f2 in
                let d1 = CMVideoFormatDescriptionGetDimensions(f1.formatDescription)
                let d2 = CMVideoFormatDescriptionGetDimensions(f2.formatDescription)
                return abs(Int(d1.width) - 640) < abs(Int(d2.width) - 640)
            }) ?? formats.first
            guard let format else { return }
            let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            cap.startCapture(with: device, format: format, fps: Int(min(fps, 30)))
        }
    }

    func close() {
        // Fully release the camera so the iOS "in use" (green) indicator goes off on hangup/decline.
        // stopCapture tears down the capturer's internal AVCaptureSession; dropping our references
        // releases the capturer + source + track so the device isn't retained.
        videoTrack?.isEnabled = false
        // stopCapture tears down an AVCaptureSession synchronously — off the main thread, or the
        // hang-up button takes a second to respond and reads as "the tap didn't register".
        // Hand the capturer to the queue and drop our reference immediately.
        if let cap = capturer {
            Self.captureQueue.async { cap.stopCapture() }
        }
        capturer = nil
        captureProxy = nil
        videoTrack = nil
        videoSource = nil
        screenTrack = nil
        screenSource = nil
        pc.close()
    }
}

extension WebRTCCall: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onStateChange?(newState)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCVideoTrack { onRemoteVideoTrack?(track) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        if let track = rtpReceiver.track as? RTCVideoTrack { onRemoteVideoTrackEnded?(track.trackId) }
    }
    // Unused delegate methods.
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Signaling wire format (tiny JSON, sealed + sent by CallManager)

enum CallSignal {
    /// Encode an SDP as JSON `{ "t": "offer"|"answer", "sdp": "..." }`.
    static func encodeSDP(_ sdp: RTCSessionDescription) -> Data {
        let type = sdp.type == .offer ? "offer" : "answer"
        return (try? JSONSerialization.data(withJSONObject: ["t": type, "sdp": sdp.sdp])) ?? Data()
    }
    static func decodeSDP(_ data: Data) -> RTCSessionDescription? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let t = o["t"], let sdp = o["sdp"] else { return nil }
        return RTCSessionDescription(type: t == "offer" ? .offer : .answer, sdp: sdp)
    }
    /// Encode an ICE candidate as JSON.
    static func encodeCandidate(_ c: RTCIceCandidate) -> Data {
        var o: [String: Any] = ["c": c.sdp, "m": c.sdpMLineIndex]
        if let mid = c.sdpMid { o["i"] = mid }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
    static func decodeCandidate(_ data: Data) -> RTCIceCandidate? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = o["c"] as? String, let m = o["m"] as? Int32 else { return nil }
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: m, sdpMid: o["i"] as? String)
    }
}

/// Rotates every captured frame 90° counter-clockwise before handing it to the WebRTC source.
/// Mac webcam frames arrive rotated 90° CW (there's no device orientation to correct them), so
/// this makes the camera upright for both the local preview and the remote peer.
final class RotatingVideoProxy: NSObject, RTCVideoCapturerDelegate {
    private let source: RTCVideoSource
    init(source: RTCVideoSource) { self.source = source }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        let rotated: RTCVideoRotation
        switch frame.rotation {              // subtract 90° (counter-clockwise)
        case ._0: rotated = ._270
        case ._90: rotated = ._0
        case ._180: rotated = ._90
        case ._270: rotated = ._180
        @unknown default: rotated = frame.rotation
        }
        let out = RTCVideoFrame(buffer: frame.buffer, rotation: rotated, timeStampNs: frame.timeStampNs)
        source.capturer(capturer, didCapture: out)
    }
}
