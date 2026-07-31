import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import WebRTC

/// Real call media over the `/webrtc/hairpin` WebSocket — the TCP/TLS path that free Cloudflare
/// tunnels front (WSS is an HTTPS upgrade; only UDP TURN is impossible over the tunnel). When
/// WebRTC's own ICE can't pair two hard-NAT peers, this relays the media itself so a call still
/// carries audio and video with ZERO router configuration.
///
/// It is a PARALLEL pipeline to WebRTC, not a plug-in to it: WebRTC owns its capture/render and
/// exposes no PCM tap, so audio runs on a dedicated `AVAudioEngine` (voice-processing I/O for
/// hardware AEC/AGC/NS — the remote is played through the same engine so it's the echo
/// reference). Video reuses WebRTC's capture (a renderer tapped off the local track) and its
/// render (decoded frames injected into an `RTCVideoSource` whose track the existing call UI
/// draws), so only the transit hops onto the WebSocket.
///
/// Wire frame (opaque to the relay, which bipipes bytes): `[type u8][seq u16 BE][ptsMs u32 BE]`
/// then the payload. Real-time: loss is dropped, never retried — a retry only adds latency.
@MainActor
final class CallMediaBridge {
    static let shared = CallMediaBridge()

    enum FrameType: UInt8 { case audio = 1, videoKey = 2, videoDelta = 3 }

    /// Remotes we are actively relaying to/from (ICE failed for these peers).
    private var activePeers: Set<String> = []
    private var audioSeq: UInt16 = 0
    private var videoSeq: UInt16 = 0

    // Audio: one engine so voice-processing AEC sees remote playout as its echo reference.
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                           channels: 1, interleaved: true)!
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var jitter = JitterBuffer()

    // Video encode (VideoToolbox H.264) fed by a renderer on the local WebRTC track.
    private var encoder: VTCompressionSession?
    private var localRenderer: LocalFrameTap?
    private weak var localTrack: RTCVideoTrack?

    // Video decode → inject into an RTCVideoSource per remote so the call UI renders it.
    fileprivate struct Decoder { let session: VTDecompressionSession; let fmt: CMVideoFormatDescription }
    private var decoders: [String: Decoder] = [:]
    private var remoteSources: [String: RTCVideoSource] = [:]
    private var remoteTracks: [String: RTCVideoTrack] = [:]

    /// Last time a relay frame arrived from each peer. The ICE disconnect watchdog deliberately
    /// never drops a peer we are relaying (ICE sits failed BECAUSE we relayed), so without this a
    /// relayed call whose far end simply vanished — no hangup frame — would stay "connected"
    /// forever. This is the relay's own liveness signal.
    private var lastInboundAt: [String: Date] = [:]

    /// Seconds since we last heard anything from `remote` over the relay, or nil if it is not being
    /// relayed / has never been heard from.
    func silenceSecs(for remote: String) -> TimeInterval? {
        guard activePeers.contains(remote) else { return nil }
        guard let t = lastInboundAt[remote] else { return nil }
        return Date().timeIntervalSince(t)
    }

    private init() {}

    // MARK: - Lifecycle

    /// Begin relaying media to `remote` over the hairpin (called when its ICE path fails). Starts
    /// the audio engine on first peer and mutes WebRTC's own (dead) audio so the two don't fight
    /// for the mic. Idempotent.
    func activate(remote: String, sessionId: String, me: String, localVideoTrack: RTCVideoTrack?) {
        CallHairpin.shared.onBinary = { [weak self] r, d in
            Task { @MainActor in self?.ingest(remote: r, frame: d) }
        }
        CallHairpin.shared.open(sessionId: sessionId, me: me, remote: remote)
        guard activePeers.insert(remote).inserted else { return }
        HavenLog.call("hairpin media: activating relay for \(remote.prefix(8))")
        if activePeers.count == 1 {
            CallManager.shared.setNativeAudioSuspendedForHairpin(true)   // hand mic to our engine
            startAudio()
        }
        if let lt = localVideoTrack { attachLocalVideo(lt) }
    }

    /// Stop relaying to `remote` (its ICE recovered, or the peer left). Tears the engine down
    /// when the last relayed peer goes.
    func deactivate(remote: String) {
        guard activePeers.remove(remote) != nil else { return }
        lastInboundAt[remote] = nil
        HavenLog.call("hairpin media: deactivating relay for \(remote.prefix(8))")
        if let d = decoders.removeValue(forKey: remote) { VTDecompressionSessionInvalidate(d.session) }
        remoteTracks[remote] = nil
        remoteSources[remote] = nil
        if activePeers.isEmpty {
            stopAll()
            CallManager.shared.setNativeAudioSuspendedForHairpin(false)   // give the mic back
        }
    }

    func stopAll() {
        let wasActive = !activePeers.isEmpty
        activePeers.removeAll()
        lastInboundAt.removeAll()
        stopAudio()
        if wasActive { CallManager.shared.setNativeAudioSuspendedForHairpin(false) }
        detachLocalVideo()
        for (_, d) in decoders { VTDecompressionSessionInvalidate(d.session) }
        decoders.removeAll(); remoteTracks.removeAll(); remoteSources.removeAll()
        CallHairpin.shared.onBinary = nil
    }

    /// The decoded remote video track for a peer, if the relay is producing one (the call UI
    /// falls back to this when WebRTC delivered no track for that peer).
    func remoteVideoTrack(_ remote: String) -> RTCVideoTrack? { remoteTracks[remote] }

    // MARK: - Audio

    /// How many times [startAudio] has deferred waiting for a usable input format.
    private var audioStartAttempts = 0

    private func startAudio() {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // The audio session must be LIVE before we ask the input node anything.
        //
        // `outputFormat(forBus:)` answers 0 Hz / 0 channels while the session is inactive, and
        // `installTap(onBus:format:)` reacts to that by raising an Objective-C exception —
        // "required condition is false: IsFormatSampleRateAndChannelCountValid(format)" — which no
        // Swift `try?` can catch, so it terminates the app outright. That is the crash on answering
        // a call: the hairpin activates its audio the moment media is needed, which is BEFORE
        // CallKit has activated the session, so the format it reads is empty.
        //
        // Ask for the session, then verify the format is real, and defer rather than proceed with a
        // format we already know is invalid.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true, options: [])
        #endif
        // Hardware echo cancellation / noise suppression / AGC — the same processing WebRTC uses.
        // Enabling it on the input also enables it on the output, so the player node below becomes
        // the echo reference. Without this a speaker call echoes badly.
        try? input.setVoiceProcessingEnabled(true)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: wireFormat)

        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            // Still not ready. Retry on a short bounded schedule instead of crashing or giving up:
            // CallKit usually activates the session within a few hundred ms of the answer.
            audioStartAttempts += 1
            guard audioStartAttempts <= 20 else {
                HavenLog.call("hairpin audio: input format never became valid — relaying video only")
                return
            }
            HavenLog.call("hairpin audio: input format not ready (\(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch) — retry \(audioStartAttempts)/20")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, !self.activePeers.isEmpty, self.audioEngine == nil else { return }
                self.startAudio()
            }
            return
        }
        audioStartAttempts = 0
        captureConverter = AVAudioConverter(from: hwFormat, to: wireFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buf, _ in
            self?.onCapturedAudio(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            HavenLog.call("hairpin audio engine start failed: \(error.localizedDescription)")
            return
        }
        player.play()
        audioEngine = engine
        playerNode = player
        jitter.reset()
    }

    private func stopAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil; playerNode = nil
        captureConverter = nil; playbackConverter = nil
        jitter.reset()
    }

    /// Downsample a HW capture buffer to 16 kHz mono Int16 and ship 20 ms frames.
    private func onCapturedAudio(_ buf: AVAudioPCMBuffer) {
        guard !activePeers.isEmpty, let conv = captureConverter else { return }
        let ratio = wireFormat.sampleRate / buf.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: outCap) else { return }
        var fed = false
        var err: NSError?
        // AVAudioPCMBuffer isn't Sendable and AVFAudio now marks this callback @Sendable, but the
        // callback is synchronous — AVAudioConverter invokes it inline, on this thread, before
        // `convert` returns — so `buf` never actually crosses a concurrency domain. Targeted here
        // rather than `@preconcurrency import AVFoundation`, which would silence every Sendable
        // diagnostic from the whole module including ones worth hearing.
        nonisolated(unsafe) let inputBuf = buf
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inputBuf
        }
        if let err { HavenLog.call("hairpin audio convert: \(err.localizedDescription)"); return }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * 2
        let payload = Data(bytes: ch[0], count: bytes)
        audioSeq &+= 1
        let frame = Self.pack(.audio, seq: audioSeq, ptsMs: 0, payload: payload)
        for r in activePeers { CallHairpin.shared.send(remote: r, frame) }
    }

    private func playAudio(seq: UInt16, payload: Data) {
        guard let engine = audioEngine, let player = playerNode else { return }
        // Reorder within a small window and pace playout so brief loss/jitter doesn't glitch.
        for ordered in jitter.push(seq: seq, payload: payload) {
            let frames = AVAudioFrameCount(ordered.count / 2)
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: frames),
                  let dst = pcm.int16ChannelData else { continue }
            pcm.frameLength = frames
            ordered.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: Int16.self).baseAddress {
                    dst[0].update(from: base, count: Int(frames))
                }
            }
            player.scheduleBuffer(pcm, completionHandler: nil)
        }
        if !player.isPlaying { player.play() }
        _ = engine
    }

    // MARK: - Video encode (local)

    private func attachLocalVideo(_ track: RTCVideoTrack) {
        guard localRenderer == nil else { return }
        localTrack = track
        let tap = LocalFrameTap { [weak self] pixelBuffer, ptsNs in
            Task { @MainActor in self?.encodeLocal(pixelBuffer, ptsNs: ptsNs) }
        }
        track.add(tap)
        localRenderer = tap
    }

    private func detachLocalVideo() {
        if let tap = localRenderer, let track = localTrack { track.remove(tap) }
        localRenderer = nil; localTrack = nil
        if let e = encoder { VTCompressionSessionInvalidate(e); encoder = nil }
    }

    private func ensureEncoder(width: Int32, height: Int32) -> VTCompressionSession? {
        if let e = encoder { return e }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let s = session else { return nil }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // High profile, not Baseline. Baseline has no CABAC and no 8x8 transform, so at the same
        // bitrate it looks visibly softer/blockier — which is exactly how the relayed leg came
        // across on the far end while the direct leg looked sharp. Every device that can run this
        // app decodes High in hardware.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        // Bitrate scaled to the frame size instead of a flat 800 kbps. 800k is fine for 480p and
        // starves 720p+, and the capture here is whatever the camera track hands us — so a big
        // frame got the same tiny budget and turned to mush. ~0.11 bits/pixel/frame at 30fps,
        // clamped so we never flood a WebSocket that is riding a tunnel.
        let pixels = Double(width) * Double(height)
        let target = min(max(pixels * 30.0 * 0.11, 600_000), 2_500_000)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: Int(target) as CFNumber)
        // Tell rate control the real frame rate, otherwise it budgets for a default that doesn't
        // match and over-compresses the frames it does get.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        encoder = s
        return s
    }

    private func encodeLocal(_ pixelBuffer: CVPixelBuffer, ptsNs: Int64) {
        guard !activePeers.isEmpty else { return }
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer)), h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        guard let session = ensureEncoder(width: w, height: h) else { return }
        let pts = CMTime(value: ptsNs, timescale: 1_000_000_000)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            Task { @MainActor in self?.onEncoded(sample) }
        }
    }

    /// Serialize an encoded H.264 sample to a self-contained Annex-B frame (SPS/PPS prepended on
    /// keyframes so the far decoder can start cold) and send it.
    private func onEncoded(_ sample: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sample),
              let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        let isKey = !(CFArrayGetCount(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)) > 0
            && (unsafeBitCast(CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false), 0), to: CFDictionary.self)
                as NSDictionary)[kCMSampleAttachmentKey_NotSync] as? Bool == true)
        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        if isKey {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?; var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out.append(contentsOf: startCode); out.append(ptr, count: size)
                }
            }
        }
        var lenTotal = 0; var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &lenTotal, dataPointerOut: &dataPtr) == noErr, let dataPtr else { return }
        // AVCC (4-byte length prefixes) → Annex-B start codes.
        var offset = 0
        let base = UnsafeRawPointer(dataPtr)
        while offset + 4 <= lenTotal {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, base.advanced(by: offset), 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            if offset + Int(nalLen) > lenTotal { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: base.advanced(by: offset), count: Int(nalLen)))
            offset += Int(nalLen)
        }
        videoSeq &+= 1
        let frame = Self.pack(isKey ? .videoKey : .videoDelta, seq: videoSeq, ptsMs: 0, payload: out)
        for r in activePeers { CallHairpin.shared.send(remote: r, frame) }
    }

    // MARK: - Inbound

    private func ingest(remote: String, frame: Data) {
        guard let (type, seq, _, payload) = Self.unpack(frame) else { return }
        lastInboundAt[remote] = Date()
        switch type {
        case .audio:
            playAudio(seq: seq, payload: payload)
        case .videoKey, .videoDelta:
            decodeRemote(remote: remote, annexB: payload, isKey: type == .videoKey)
        }
    }

    private func decodeRemote(remote: String, annexB: Data, isKey: Bool) {
        // A decoder needs SPS/PPS from a keyframe to initialize; ignore deltas until one arrives.
        if decoders[remote] == nil {
            guard isKey, let dec = Self.makeDecoder(fromAnnexBKeyframe: annexB, sink: { [weak self] pb, r in
                Task { @MainActor in self?.injectRemote(remote: r, pixelBuffer: pb) }
            }, remote: remote) else { return }
            decoders[remote] = dec
        }
        guard let dec = decoders[remote],
              let sample = Self.sampleFromAnnexB(annexB, fmt: dec.fmt) else { return }
        VTDecompressionSessionDecodeFrame(dec.session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: nil)
    }

    private func injectRemote(remote: String, pixelBuffer: CVPixelBuffer) {
        let source: RTCVideoSource
        if let s = remoteSources[remote] { source = s } else {
            source = WebRTCCall.factory.videoSource()
            remoteSources[remote] = source
            let track = WebRTCCall.factory.videoTrack(with: source, trackId: "hairpin-\(remote.prefix(8))")
            remoteTracks[remote] = track
            CallManager.shared.adoptHairpinRemoteVideo(peer: remote, track: track)
        }
        let rtc = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtc, rotation: ._0, timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        let capturer = RTCVideoCapturer(delegate: source)
        source.capturer(capturer, didCapture: frame)
    }

    // MARK: - Wire framing

    static func pack(_ type: FrameType, seq: UInt16, ptsMs: UInt32, payload: Data) -> Data {
        var d = Data(capacity: 7 + payload.count)
        d.append(type.rawValue)
        d.append(UInt8(seq >> 8)); d.append(UInt8(seq & 0xff))
        d.append(UInt8((ptsMs >> 24) & 0xff)); d.append(UInt8((ptsMs >> 16) & 0xff))
        d.append(UInt8((ptsMs >> 8) & 0xff)); d.append(UInt8(ptsMs & 0xff))
        d.append(payload)
        return d
    }

    static func unpack(_ d: Data) -> (FrameType, UInt16, UInt32, Data)? {
        guard d.count >= 7, let type = FrameType(rawValue: d[d.startIndex]) else { return nil }
        let b = [UInt8](d)
        let seq = UInt16(b[1]) << 8 | UInt16(b[2])
        let pts = UInt32(b[3]) << 24 | UInt32(b[4]) << 16 | UInt32(b[5]) << 8 | UInt32(b[6])
        return (type, seq, pts, d.subdata(in: d.startIndex.advanced(by: 7)..<d.endIndex))
    }
}

/// Reorders audio frames within a small window and paces them out, so brief loss/jitter on the
/// WebSocket doesn't turn into stutter. Deliberately shallow (≈60 ms) — a voice call values low
/// latency over gap-free playout.
private struct JitterBuffer {
    private var pending: [UInt16: Data] = [:]
    private var next: UInt16?
    private let depth = 3

    mutating func reset() { pending.removeAll(); next = nil }

    mutating func push(seq: UInt16, payload: Data) -> [Data] {
        pending[seq] = payload
        if next == nil, pending.count >= depth {
            next = pending.keys.min()
        }
        var out: [Data] = []
        while let n = next, let p = pending.removeValue(forKey: n) {
            out.append(p)
            next = n &+ 1
            // Drop the buffer if it grows unbounded (a lost frame we'll never get).
            if pending.count > depth * 4, let lowest = pending.keys.min() { next = lowest }
        }
        return out
    }
}

/// A WebRTC renderer that hands each local camera frame's pixel buffer to a callback — how we
/// tap WebRTC's existing capture without running a second AVCaptureSession.
private final class LocalFrameTap: NSObject, RTCVideoRenderer {
    private let onFrame: (CVPixelBuffer, Int64) -> Void
    init(onFrame: @escaping (CVPixelBuffer, Int64) -> Void) { self.onFrame = onFrame }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buf = frame.buffer as? RTCCVPixelBuffer else { return }
        onFrame(buf.pixelBuffer, frame.timeStampNs)
    }
}

// MARK: - Decoder helpers (Annex-B → CMSampleBuffer)

extension CallMediaBridge {
    /// Build a decompression session from a keyframe's SPS/PPS. `sink` receives decoded buffers.
    fileprivate static func makeDecoder(fromAnnexBKeyframe annexB: Data,
                            sink: @escaping (CVPixelBuffer, String) -> Void,
                            remote: String) -> Decoder? {
        let nals = splitAnnexB(annexB)
        var sps: [UInt8]?; var pps: [UInt8]?
        for n in nals {
            guard let first = n.first else { continue }
            switch first & 0x1f {
            case 7: sps = n
            case 8: pps = n
            default: break
            }
        }
        guard let sps, let pps else { return nil }
        var fmt: CMVideoFormatDescription?
        let created = sps.withUnsafeBufferPointer { spsPtr in
            pps.withUnsafeBufferPointer { ppsPtr -> OSStatus in
                let params: [UnsafePointer<UInt8>] = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                let sizes: [Int] = [sps.count, pps.count]
                return params.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { ss in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: pp.baseAddress!, parameterSetSizes: ss.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                    }
                }
            }
        }
        guard created == noErr, let fmt else { return nil }
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let box = DecodeSink(sink: sink, remote: remote)
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer, let refcon else { return }
                let sink = Unmanaged<DecodeSink>.fromOpaque(refcon).takeUnretainedValue()
                sink.sink(imageBuffer, sink.remote)
            },
            decompressionOutputRefCon: Unmanaged.passRetained(box).toOpaque())
        var session: VTDecompressionSession?
        let ok = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
                                              decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: &record, decompressionSessionOut: &session)
        guard ok == noErr, let session else { return nil }
        return Decoder(session: session, fmt: fmt)
    }

    /// AnnexB frame → CMSampleBuffer for the decoder (converts start codes to AVCC lengths).
    static func sampleFromAnnexB(_ annexB: Data, fmt: CMVideoFormatDescription) -> CMSampleBuffer? {
        let nals = splitAnnexB(annexB).filter { n in
            guard let f = n.first else { return false }
            let t = f & 0x1f
            return t != 7 && t != 8   // parameter sets already in the format description
        }
        guard !nals.isEmpty else { return nil }
        var avcc = Data()
        for n in nals {
            var len = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: n)
        }
        var block: CMBlockBuffer?
        let bytes = [UInt8](avcc)
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var sample: CMSampleBuffer?
        var sizes = [bytes.count]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 0,
                sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                sampleBufferOut: &sample) == noErr, let sample else { return nil }
        return sample
    }

    private static func splitAnnexB(_ data: Data) -> [[UInt8]] {
        let b = [UInt8](data)
        var nals: [[UInt8]] = []
        var i = 0
        var start: Int?
        while i + 3 < b.count {
            if b[i] == 0, b[i+1] == 0, b[i+2] == 0, b[i+3] == 1 {
                if let s = start { nals.append(Array(b[s..<i])) }
                i += 4; start = i; continue
            }
            if i + 2 < b.count, b[i] == 0, b[i+1] == 0, b[i+2] == 1 {
                if let s = start { nals.append(Array(b[s..<i])) }
                i += 3; start = i; continue
            }
            i += 1
        }
        if let s = start, s < b.count { nals.append(Array(b[s..<b.count])) }
        return nals
    }
}

/// Retained box so the C decode callback can reach the Swift sink + peer id.
private final class DecodeSink {
    let sink: (CVPixelBuffer, String) -> Void
    let remote: String
    init(sink: @escaping (CVPixelBuffer, String) -> Void, remote: String) { self.sink = sink; self.remote = remote }
}

