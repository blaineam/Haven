import XCTest
import CoreVideo
import AVFoundation
@testable import HavenUITestHost

/// The relay's media pipe, end to end without a socket: the wire framing, the jitter window, and a
/// REAL H.264 round trip — frames encoded by the bridge's VideoToolbox session come back out of its
/// decoder as a remote video track the call UI can draw. Audio engines are never started (no mic, no
/// speakers): the peer is attached through a test seam instead of `activate`.
@MainActor
final class CallsMediaBridgeTests: XCTestCase {
    private var bridge: CallMediaBridge { CallMediaBridge.shared }
    private let remote = String(repeating: "5c", count: 32)
    private var sent: [Data] = []

    override func setUp() async throws {
        Harness.assertIsolatedHost()
        CallMediaBridge.suppressAudioEngineForTests = true
        bridge.stopAll()
        bridge.qaResetCallStats()
        sent = []
        CallHairpin.shared.outboundTap = { [unowned self] _, d in self.sent.append(d) }
    }
    override func tearDown() async throws {
        CallHairpin.shared.outboundTap = nil
        bridge.stopAll()
        bridge.qaResetCallStats()
        CallMediaBridge.suppressAudioEngineForTests = false
    }

    // MARK: Wire framing

    func testFramesRoundTripWithBigEndianHeaders() throws {
        let payload = Data([9, 8, 7, 6])
        let wire = CallMediaBridge.pack(.videoKey, seq: 0xABCD, ptsMs: 0x01020304, payload: payload)
        XCTAssertEqual(Array(wire.prefix(7)), [2, 0xAB, 0xCD, 0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(wire.count, 7 + payload.count)
        let (type, seq, pts, body) = try XCTUnwrap(CallMediaBridge.unpack(wire))
        XCTAssertEqual(type, .videoKey)
        XCTAssertEqual(seq, 0xABCD)
        XCTAssertEqual(pts, 0x01020304)
        XCTAssertEqual(body, payload)
        for t in [CallMediaBridge.FrameType.audio, .videoKey, .videoDelta] {
            XCTAssertEqual(CallMediaBridge.unpack(CallMediaBridge.pack(t, seq: 1, ptsMs: 2, payload: Data()))?.0, t)
        }
    }

    func testMalformedFramesAreDroppedNotGuessedAt() {
        XCTAssertNil(CallMediaBridge.unpack(Data()))
        XCTAssertNil(CallMediaBridge.unpack(Data([1, 0, 0, 0, 0, 0])), "6 bytes is one short of a header")
        XCTAssertNil(CallMediaBridge.unpack(Data([9, 0, 0, 0, 0, 0, 0, 1])), "type 9 is not a frame type")
        XCTAssertNotNil(CallMediaBridge.unpack(Data([1, 0, 0, 0, 0, 0, 0])), "a header with an empty payload is valid")
    }

    func testUnpackWorksOnASlice() throws {
        let wire = CallMediaBridge.pack(.audio, seq: 7, ptsMs: 0, payload: Data([1, 2, 3]))
        var padded = Data([0xEE, 0xEE]); padded.append(wire)
        let slice = padded.dropFirst(2)
        let (type, seq, _, body) = try XCTUnwrap(CallMediaBridge.unpack(slice))
        XCTAssertEqual(type, .audio); XCTAssertEqual(seq, 7); XCTAssertEqual(body, Data([1, 2, 3]))
    }

    func testTheSilenceFrameIsSixtyMillisecondsOfSixteenKilohertzMono() {
        XCTAssertEqual(CallMediaBridge.silenceFrameSecs, 0.06)
        XCTAssertEqual(CallMediaBridge.silenceFrameBytes, 16_000 * 60 / 1000 * 2)
    }

    // MARK: Annex-B parsing

    func testAnnexBSplitsOnThreeAndFourByteStartCodes() {
        let data = Data([0, 0, 0, 1, 0x67, 1, 2,   0, 0, 1, 0x68, 3,   0, 0, 0, 1, 0x65, 4, 5, 6])
        XCTAssertEqual(CallMediaBridge.splitAnnexB(data), [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5, 6]])
        XCTAssertEqual(CallMediaBridge.splitAnnexB(Data()), [])
        XCTAssertEqual(CallMediaBridge.splitAnnexB(Data([1, 2, 3, 4, 5])), [], "no start code, no NAL units")
    }

    // MARK: Microphone and uplink (no engine)

    func testCapturedAudioIsDownsampledToTheWireFormatAndFramedWithRisingSequenceNumbers() throws {
        bridge.qaAttachPeer(remote)
        let hw = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        bridge.qaInstallCaptureConverter(from: hw)
        func burst() throws -> AVAudioPCMBuffer {
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hw, frameCapacity: 960))
            buf.frameLength = 960   // 20 ms at 48 kHz
            for i in 0..<960 { buf.floatChannelData![0][i] = sinf(Float(i) * 0.2) * 0.5 }
            return buf
        }
        for _ in 0..<3 { bridge.onCapturedAudio(try burst()) }
        let frames = sent.compactMap(CallMediaBridge.unpack)
        guard !frames.isEmpty else { return XCTFail("converted audio must reach the hairpin") }
        XCTAssertTrue(frames.allSatisfy { $0.0 == .audio })
        let seqs = frames.map(\.1)
        XCTAssertEqual(Array(seqs.dropFirst()), seqs.dropLast().map { $0 &+ 1 }, "sequence numbers rise by one per frame")
        let total = frames.reduce(0) { $0 + $1.3.count }
        XCTAssertTrue(frames.allSatisfy { $0.3.count % 2 == 0 }, "16-bit samples")
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(total, 3 * 320 * 2 + 64, "60 ms of 48 kHz becomes at most 60 ms of 16 kHz mono Int16")
    }

    func testCapturedAudioIsDroppedWhenNobodyIsBeingRelayedTo() throws {
        let hw = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        bridge.qaInstallCaptureConverter(from: hw)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hw, frameCapacity: 480))
        buf.frameLength = 480
        bridge.onCapturedAudio(buf)
        XCTAssertTrue(sent.isEmpty)
    }

    func testTheSilenceUplinkKeepsTheFarEndHearingUsWhenThereIsNoMicrophone() async throws {
        bridge.qaAttachPeer(remote)
        bridge.startSilenceUplink()
        await Harness.until(FeedStore.shared, timeout: 30, "two silence frames to be sent") { self.sent.count >= 2 }
        let frames = sent.compactMap(CallMediaBridge.unpack)
        XCTAssertTrue(frames.allSatisfy { $0.0 == .audio })
        XCTAssertTrue(frames.allSatisfy { $0.3 == Data(count: CallMediaBridge.silenceFrameBytes) }, "60 ms of digital silence each")
        XCTAssertEqual(frames[1].1, frames[0].1 &+ 1)
        bridge.stopAll()   // stops the pacing timer
        let after = sent.count
        await Task.yield()
        XCTAssertEqual(sent.count, after, "no uplink once the relay is stopped")
    }

    // MARK: Liveness

    func testSilenceIsOnlyReportedForAPeerBeingRelayedAndHeardFrom() {
        XCTAssertNil(bridge.silenceSecs(for: remote), "not relayed")
        bridge.qaAttachPeer(remote)
        XCTAssertNil(bridge.silenceSecs(for: remote), "relayed but never heard from")
        bridge.ingest(remote: remote, frame: CallMediaBridge.pack(.audio, seq: 1, ptsMs: 0, payload: Data(count: 640)))
        let quiet = bridge.silenceSecs(for: remote)
        XCTAssertNotNil(quiet)
        XCTAssertLessThan(quiet ?? 99, 5)
        bridge.deactivate(remote: remote)
        XCTAssertNil(bridge.silenceSecs(for: remote), "a peer that left stops being timed")
    }

    func testInboundBytesAreCountedPerKindForTheQaDump() {
        bridge.qaAttachPeer(remote)
        bridge.ingest(remote: remote, frame: CallMediaBridge.pack(.audio, seq: 1, ptsMs: 0, payload: Data(count: 100)))
        bridge.ingest(remote: remote, frame: CallMediaBridge.pack(.audio, seq: 2, ptsMs: 0, payload: Data(count: 50)))
        bridge.ingest(remote: remote, frame: CallMediaBridge.pack(.videoDelta, seq: 3, ptsMs: 0, payload: Data(count: 7)))
        let stats = bridge.qaHairpinInbound()[remote]
        XCTAssertEqual(stats?.audio, 150)
        XCTAssertEqual(stats?.video, 7)
        XCTAssertEqual(stats?.frames, 0, "a delta with no keyframe decodes to nothing")
        bridge.ingest(remote: remote, frame: Data([1, 2]))   // junk: not counted
        XCTAssertEqual(bridge.qaHairpinInbound()[remote]?.audio, 150)
        bridge.qaResetCallStats()
        XCTAssertTrue(bridge.qaHairpinInbound().isEmpty)
    }

    func testRemoteVideoNeedsAKeyframeWithParameterSetsBeforeAnythingDecodes() {
        bridge.qaAttachPeer(remote)
        bridge.decodeRemote(remote: remote, annexB: Data([0, 0, 0, 1, 0x41, 1, 2, 3]), isKey: false)
        bridge.decodeRemote(remote: remote, annexB: Data([0, 0, 0, 1, 0x65, 1, 2, 3]), isKey: true)   // key, but no SPS/PPS
        XCTAssertNil(bridge.remoteVideoTrack(remote))
        XCTAssertNil(bridge.qaDecodedStats(remote))
    }

    func testStoppingEverythingClearsTheRelayAndIsRepeatable() {
        bridge.qaAttachPeer(remote)
        XCTAssertTrue(bridge.activePeers.contains(remote))
        bridge.stopAll()
        XCTAssertTrue(bridge.activePeers.isEmpty)
        bridge.stopAll()
        bridge.deactivate(remote: remote)   // already gone: a no-op
        bridge.audioBecameAvailable()       // nothing relayed: must not start an engine
        XCTAssertTrue(bridge.activePeers.isEmpty)
    }

    // MARK: Real video through VideoToolbox

    private func pixelBuffer(width: Int, height: Int, seed: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buf) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buf, plane)!.assumingMemoryBound(to: UInt8.self)
            let rows = CVPixelBufferGetHeightOfPlane(buf, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(buf, plane)
            for r in 0..<rows { for c in 0..<stride { base[r * stride + c] = UInt8(truncatingIfNeeded: (r * 3 + c) &+ Int(seed)) } }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    /// Encode a few frames of `size` through the bridge's own encoder and return what it put on the wire.
    private func encoded(width: Int, height: Int) async -> [Data] {
        sent = []
        bridge.qaAttachPeer(remote)
        for i in 0..<6 {
            bridge.encodeLocal(pixelBuffer(width: width, height: height, seed: UInt8(i * 7)), ptsNs: Int64(i) * 33_000_000)
        }
        await Harness.until(FeedStore.shared, timeout: 60, "the encoder to emit a keyframe") {
            self.sent.contains { CallMediaBridge.unpack($0)?.0 == .videoKey }
        }
        return sent
    }

    func testEncodedVideoComesBackOutOfTheDecoderAsARemoteTrack() async throws {
        let frames = await encoded(width: 320, height: 240)
        let key = try XCTUnwrap(frames.first { CallMediaBridge.unpack($0)?.0 == .videoKey }, "the first frame is a keyframe")
        let (_, _, _, annexB) = try XCTUnwrap(CallMediaBridge.unpack(key))
        let nalTypes = CallMediaBridge.splitAnnexB(annexB).compactMap { $0.first.map { $0 & 0x1f } }
        XCTAssertTrue(nalTypes.contains(7) && nalTypes.contains(8), "a keyframe carries SPS and PPS so a cold decoder can start")
        let seqs = frames.compactMap { CallMediaBridge.unpack($0)?.1 }
        XCTAssertEqual(seqs, Array(seqs.sorted()), "frames leave in sequence order")
        XCTAssertEqual(Set(seqs).count, seqs.count)

        // The far end: feed what was sent back in as if it had arrived from the relay.
        for f in frames { bridge.ingest(remote: remote, frame: f) }
        await Harness.until(FeedStore.shared, timeout: 60, "a decoded frame to appear") {
            (self.bridge.qaDecodedStats(self.remote)?.frames ?? 0) > 0
        }
        let stats = try XCTUnwrap(bridge.qaDecodedStats(remote))
        XCTAssertEqual(stats.width, 320)
        XCTAssertEqual(stats.height, 240)
        XCTAssertNotNil(bridge.remoteVideoTrack(remote), "the call UI falls back to this track when WebRTC delivered none")
        XCTAssertGreaterThan(bridge.qaHairpinInbound()[remote]?.video ?? 0, 0)

        bridge.deactivate(remote: remote)
        XCTAssertNil(bridge.remoteVideoTrack(remote), "leaving drops the decoded track")
    }

    func testAKeyframeWithNewDimensionsGetsAFreshDecoder() async throws {
        let big = await encoded(width: 320, height: 240)
        bridge.stopAll()    // drops the encoder (it is bound to its first frame size) and the relay
        let small = await encoded(width: 160, height: 128)
        let bigKey = try XCTUnwrap(big.first { CallMediaBridge.unpack($0)?.0 == .videoKey })
        let smallKey = try XCTUnwrap(small.first { CallMediaBridge.unpack($0)?.0 == .videoKey })
        bridge.qaAttachPeer(remote)
        bridge.ingest(remote: remote, frame: bigKey)
        await Harness.until(FeedStore.shared, timeout: 60, "the camera-sized frame to decode") {
            self.bridge.qaDecodedStats(self.remote)?.width == 320
        }
        // Camera → screen share changes the shape mid-call: the old session decodes nothing after it.
        bridge.ingest(remote: remote, frame: smallKey)
        await Harness.until(FeedStore.shared, timeout: 60, "the new-shape frame to decode") {
            self.bridge.qaDecodedStats(self.remote)?.width == 160
        }
        XCTAssertEqual(bridge.qaDecodedStats(remote)?.height, 128)
    }

    func testNothingIsEncodedWhenNobodyIsBeingRelayedTo() {
        sent = []
        bridge.encodeLocal(pixelBuffer(width: 64, height: 64, seed: 1), ptsNs: 0)
        XCTAssertTrue(sent.isEmpty)
    }
}
