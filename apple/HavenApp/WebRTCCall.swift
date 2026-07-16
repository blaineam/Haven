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

    override init() {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ])]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCCall.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            fatalError("WebRTC peer connection unavailable")
        }
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
        pc.setRemoteDescription(sdp) { [weak self] _ in self?.onRemoteReady?() }
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

    // MARK: Video (toggled mid-call)

    func startVideo() {
        // Re-enabling after a stop: the track still exists but stopVideo() tore down the capture
        // session, so just flipping isEnabled gives a live track with no frames. Restart capture.
        guard videoTrack == nil else { videoTrack?.isEnabled = true; startCapture(); return }
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

    private func startCapture() {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let picked: AVCaptureDevice?
        if let id = preferredCameraUniqueID {
            picked = devices.first(where: { $0.uniqueID == id })
        } else {
            picked = devices.first(where: { $0.position == cameraPosition })
        }
        guard let cap = capturer, let device = picked ?? devices.first else { return }
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

    func close() {
        // Fully release the camera so the iOS "in use" (green) indicator goes off on hangup/decline.
        // stopCapture tears down the capturer's internal AVCaptureSession; dropping our references
        // releases the capturer + source + track so the device isn't retained.
        videoTrack?.isEnabled = false
        capturer?.stopCapture()
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
