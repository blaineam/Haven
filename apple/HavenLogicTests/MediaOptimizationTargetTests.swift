import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// "What does already-optimized look like": the predicate the re-optimize run uses to decide which
/// stored blobs to rewrite. A false positive re-encodes (and re-shares to the whole circle) a file
/// that is already fine, forever; a false negative leaves a 320 MB video in place. Fixtures are
/// generated here from deterministic noise, so no test depends on a file on disk.
final class MediaOptimizationTargetTests: XCTestCase {
    private typealias T = MediaOptimizationTarget
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Constants

    func testTargetsMatchTheEncoder() {
        XCTAssertEqual(T.imageMaxDimension, 1600)
        XCTAssertEqual(T.imageQuality, 0.62, accuracy: 0.0001)
        XCTAssertEqual(T.videoMaxDimension, 1920)
        XCTAssertEqual(T.videoBitrateCeiling, Int(Double(VideoEncoderTargets.videoBitrate + VideoEncoderTargets.audioBitrate) * 1.30))
        XCTAssertGreaterThan(T.videoBitrateCeiling, VideoEncoderTargets.videoBitrate + VideoEncoderTargets.audioBitrate,
                             "headroom is what makes a second pass a no-op")
        XCTAssertGreaterThan(T.audioBitrateCeiling, VideoEncoderTargets.standaloneAudioBitrate)
        XCTAssertLessThan(T.requiredShrinkFactor, 1)
    }

    func testLegacyCutoffIsAFixedInstantIndependentOfTheReadersZone() {
        // 2026-07-20 08:00 America/Los_Angeles (PDT, UTC-7) == 15:00Z.
        XCTAssertEqual(T.legacyCutoff.timeIntervalSince1970, 1_784_559_600, accuracy: 0.5)
    }

    func testLegacyByAge() {
        let cutoffMs = UInt64(T.legacyCutoff.timeIntervalSince1970 * 1000)
        XCTAssertTrue(T.isLegacyByAge(createdAtMs: cutoffMs - 1))
        XCTAssertFalse(T.isLegacyByAge(createdAtMs: cutoffMs))
        XCTAssertFalse(T.isLegacyByAge(createdAtMs: cutoffMs + 86_400_000))
        XCTAssertTrue(T.isLegacyByAge(createdAtMs: 0))
    }

    // MARK: Fixture builders

    /// Deterministic noise bitmap so file sizes are reproducible.
    private func noiseImage(_ w: Int, _ h: Int) -> CGImage {
        var state: UInt64 = 0x9E3779B97F4A7C15
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in stride(from: 0, to: px.count, by: 4) {
            for c in 0..<3 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                px[i + c] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return px.withUnsafeMutableBytes { raw -> CGImage in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            return ctx.makeImage()!
        }
    }

    @discardableResult
    private func write(_ image: CGImage, as type: UTType, quality: CGFloat? = nil, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var opts: [CFString: Any] = [:]
        if let quality { opts[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    // MARK: Stills

    func testUnreadableAndUnknownFilesAreLeftAlone() async throws {
        let missing = dir.appendingPathComponent("nope.jpg")
        let a = await T.probe(missing)
        XCTAssertNil(a)
        let empty = dir.appendingPathComponent("empty.jpg")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let b = await T.probe(empty)
        XCTAssertNil(b, "an empty file is not judged")
        let unknown = dir.appendingPathComponent("blob.bin")
        try Data(repeating: 7, count: 300_000).write(to: unknown)
        let c = await T.probe(unknown)
        XCTAssertNil(c, "an unknown extension is not a re-encode candidate")
        let garbage = dir.appendingPathComponent("garbage.jpg")
        try Data(repeating: 7, count: 300_000).write(to: garbage)
        let d = await T.probe(garbage)
        XCTAssertNil(d, "undecodable bytes fail closed")
    }

    func testSmallStillIsNeverInteresting() async throws {
        let url = try write(noiseImage(64, 64), as: .jpeg, quality: 0.9, name: "tiny.jpg")
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertLessThan(shape.bytes, T.minimumInterestingBytes)
        XCTAssertEqual(shape.maxDimension, 64)
        XCTAssertEqual(shape.codec, "jpeg")
        XCTAssertFalse(shape.aboveTarget, "small files are left exactly as they are")
        XCTAssertEqual(shape.bitrate, 0)
        XCTAssertTrue(shape.summary.hasSuffix("jpeg · 64px"), shape.summary)
    }

    func testOversizeJPEGIsAboveTargetByDimension() async throws {
        let url = try write(noiseImage(2400, 1800), as: .jpeg, quality: 0.5, name: "big.jpg")
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertEqual(shape.maxDimension, 2400)
        XCTAssertEqual(shape.aboveTargetReason, "2400px, target 1600px")
        XCTAssertTrue(shape.aboveTarget)
    }

    func testNonJPEGStillIsAboveTargetBecauseTheOptimizedPathAlwaysWritesJPEG() async throws {
        let url = try write(noiseImage(400, 400), as: .png, name: "shot.png")
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertGreaterThanOrEqual(shape.bytes, T.minimumInterestingBytes)
        XCTAssertEqual(shape.aboveTargetReason, "not a JPEG (png)")
    }

    func testDenseJPEGAtTargetSizeIsCaughtByBytesPerPixel() async throws {
        let url = try write(noiseImage(1600, 1200), as: .jpeg, quality: 0.95, name: "dense.jpg")
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertEqual(shape.maxDimension, 1600)
        let reason = try XCTUnwrap(shape.aboveTargetReason, "q0.95 noise is far above 0.40 bytes/pixel")
        XCTAssertTrue(reason.contains("bytes/pixel"), reason)
    }

    func testLeanJPEGAtTargetIsLeftAlone() async throws {
        let url = try write(noiseImage(1600, 1200), as: .jpeg, quality: 0.1, name: "lean.jpg")
        let bytes = size(url)
        // The test's own precondition: big enough to be judged, lean enough to pass.
        XCTAssertGreaterThanOrEqual(bytes, T.minimumInterestingBytes, "fixture too small to exercise the density rule")
        XCTAssertLessThan(Double(bytes) / Double(1600 * 1200), T.imageBytesPerPixelCeiling, "fixture not lean enough")
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertNil(shape.aboveTargetReason, "an already-optimized still must read as done, or it is re-encoded forever")
    }

    func testDimensionSlackAllowsEvenNumberRounding() async throws {
        // 1632 = 1600 x 1.02 sits exactly on the slack boundary and stays within target; 1700 does not.
        let onEdge = try write(noiseImage(1632, 1224), as: .jpeg, quality: 0.1, name: "edge.jpg")
        XCTAssertGreaterThanOrEqual(size(onEdge), T.minimumInterestingBytes, "fixture too small to be judged")
        XCTAssertLessThan(Double(size(onEdge)) / Double(1632 * 1224), T.imageBytesPerPixelCeiling, "fixture not lean enough")
        let a = await T.probe(onEdge)
        XCTAssertEqual(a?.maxDimension, 1632)
        XCTAssertNil(a?.aboveTargetReason)

        let over = try write(noiseImage(1700, 1275), as: .jpeg, quality: 0.1, name: "over.jpg")
        let b = await T.probe(over)
        XCTAssertEqual(b?.aboveTargetReason, "1700px, target 1600px")
    }

    // MARK: Audio

    private func wav(seconds: Int, sampleRate: Int = 8000) -> Data {
        let samples = seconds * sampleRate
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples * 2); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples * 2)
        d.append(Data(repeating: 0, count: samples * 2))
        return d
    }

    func testUncompressedAudioIsAboveTarget() async throws {
        let url = dir.appendingPathComponent("speech.wav")
        try wav(seconds: 20).write(to: url)      // 320 KB of PCM
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertEqual(shape.maxDimension, 0)
        XCTAssertEqual(shape.seconds, 20, accuracy: 0.1)
        XCTAssertEqual(shape.aboveTargetReason, "lpcm, not AAC")
        XCTAssertTrue(shape.summary.contains("kbps"), shape.summary)
    }

    func testShortUncompressedAudioIsNotWorthRewriting() async throws {
        let url = dir.appendingPathComponent("blip.wav")
        try wav(seconds: 1).write(to: url)
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertFalse(shape.aboveTarget)
        XCTAssertEqual(shape.codec, "lpcm")
    }

    // MARK: Video

    private func makeH264Clip(side: Int, frames: Int, name: String) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, nil, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                memset(base, Int32(f * 20 % 255), CVPixelBufferGetBytesPerRow(buf) * side)
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(adaptor.append(buf, withPresentationTime: CMTime(value: Int64(f), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testSmallH264ClipReadsAsAlreadyFine() async throws {
        let url = try await makeH264Clip(side: 64, frames: 10, name: "clip.mp4")
        let probed = await T.probe(url)
        let shape = try XCTUnwrap(probed)
        XCTAssertEqual(shape.codec, "avc1")
        XCTAssertEqual(shape.maxDimension, 64)
        XCTAssertEqual(shape.seconds, 1, accuracy: 0.2)
        XCTAssertGreaterThan(shape.bitrate, 0)
        XCTAssertFalse(shape.aboveTarget, "below the interesting-size floor nothing is rewritten")
        XCTAssertTrue(shape.summary.contains("avc1"), shape.summary)
    }

    func testVideoExtensionsAreRoutedToTheVideoProbe() async throws {
        let mp4 = try await makeH264Clip(side: 32, frames: 5, name: "a.mp4")
        let mov = dir.appendingPathComponent("b.MOV")
        try FileManager.default.copyItem(at: mp4, to: mov)
        let m4v = dir.appendingPathComponent("c.m4v")
        try FileManager.default.copyItem(at: mp4, to: m4v)
        for u in [mp4, mov, m4v] {
            let shape = await T.probe(u)
            XCTAssertEqual(shape?.codec, "avc1", u.lastPathComponent)
        }
    }

    func testShapeSummaryFormatting() {
        let video = T.Shape(bytes: 2_097_152, maxDimension: 1080, codec: "avc1", bitrate: 4_500_000, seconds: 3.7, aboveTargetReason: nil)
        XCTAssertEqual(video.summary, "2.0 MB · avc1 · 1080px · 4500 kbps")
        let still = T.Shape(bytes: 1_048_576, maxDimension: 1600, codec: "jpeg", bitrate: 0, seconds: 0, aboveTargetReason: "x")
        XCTAssertEqual(still.summary, "1.0 MB · jpeg · 1600px")
        XCTAssertTrue(still.aboveTarget)
        let audio = T.Shape(bytes: 524_288, maxDimension: 0, codec: "aac ", bitrate: 0, seconds: 0, aboveTargetReason: nil)
        XCTAssertEqual(audio.summary, "0.5 MB · aac ")
    }
}
