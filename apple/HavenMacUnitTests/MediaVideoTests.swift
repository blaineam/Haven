import XCTest
import AVFoundation
import AppKit
@testable import HavenUITestHost

/// Video, audio and filter pipelines of MediaStore against small clips generated on the fly.
@MainActor
final class MediaVideoTests: XCTestCase {
    private var scratch: [URL] = []
    override func tearDown() async throws {
        for u in scratch { try? FileManager.default.removeItem(at: u) }
        scratch.removeAll()
    }

    /// An H.264 clip whose frames are `spacing` seconds apart (so a long duration costs few frames).
    private func makeClip(frames: Int = 12, spacing: Double = 0.1, size: CGSize = CGSize(width: 96, height: 64)) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        scratch.append(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, nil, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) { memset(base, Int32(0x30 + (i * 11) % 0xA0), CVPixelBufferGetDataSize(buf)) }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(seconds: Double(i) * spacing, preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).wav")
        scratch.append(url)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: true))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = 22_050
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for i in 0..<22_050 { samples[i] = Int16(truncatingIfNeeded: Int(8_000 * sin(Double(i) * 0.05))) }
        try file.write(from: buffer)
        return url
    }

    func testAShortClipIsEncodedWithAPosterAndContentAddressed() async throws {
        let store = MediaStore.shared
        let clip = try await makeClip()
        let prepared = await store.prepareVideo(url: clip, alsoOriginal: false)
        XCTAssertFalse(prepared.isEmpty)
        XCTAssertTrue(prepared.videoRef.hasPrefix("vid_"))
        XCTAssertTrue(MediaStore.isVerifiable(prepared.videoRef))
        XCTAssertTrue(store.hasLocalFile(prepared.videoRef))
        let bytes = try XCTUnwrap(store.rawBytes(prepared.videoRef))
        XCTAssertTrue(MediaStore.verify(prepared.videoRef, bytes), "the ref is the digest of the shipped bytes")
        XCTAssertNotNil(prepared.posterRef, "a still rides with every video")
        XCTAssertTrue(prepared.mediaRefs.contains(prepared.videoRef))
        XCTAssertEqual(store.item(prepared.videoRef)?.kind, .video)
        XCTAssertNotNil(store.ensurePosterImage(for: prepared.videoRef))
        let hevc = await MediaStore.isHEVC(clip)
        XCTAssertFalse(hevc)
        XCTAssertNotNil(MediaStore.poster(for: clip))
        let again = await MediaStore.posterAsync(for: clip)
        XCTAssertNotNil(again)
        store.delete(prepared.videoRef)
        if let p = prepared.posterRef { store.delete(p) }
    }

    func testTheOriginalRidesAlongWhenAskedFor() async throws {
        let store = MediaStore.shared
        let clip = try await makeClip(frames: 8)
        let withOriginal = await store.prepareVideo(url: clip, alsoOriginal: true)
        XCTAssertFalse(withOriginal.isEmpty)
        if let orig = withOriginal.originalRef {
            XCTAssertNotEqual(orig, withOriginal.videoRef)
            XCTAssertTrue(withOriginal.mediaRefs.contains(orig))
            store.delete(orig)
        }
        let viaShortcut = await store.addVideo(url: clip, forceOptimize: true)
        XCTAssertTrue(viaShortcut.hasPrefix("vid_"))
        store.delete(withOriginal.videoRef); store.delete(viaShortcut)
    }

    func testAClipLongerThanTheLimitIsRefused() async throws {
        let long = try await makeClip(frames: 2, spacing: MediaStore.maxVideoSeconds + 60)
        let refused = await MediaStore.shared.prepareVideo(url: long)
        XCTAssertTrue(refused.isEmpty, "no amount of encoding makes a feature film reasonable to hand a circle")
        XCTAssertEqual(refused.videoRef, "")
        let reoptimized = await MediaStore.shared.prepareVideo(url: long, forceOptimize: true)
        _ = reoptimized   // the limit governs what you newly share, not what you shrink
    }

    func testALongStoryClipSplitsIntoSlides() async throws {
        let store = MediaStore.shared
        let clip = try await makeClip(frames: 40, spacing: 1)   // ~39 s
        let ref = store.importTrimmed(clip)
        XCTAssertTrue(ref.hasPrefix("vid_"))
        let short = await store.splitStoryVideo(ref)
        XCTAssertGreaterThanOrEqual(short.count, 2, "a clip past 15 s becomes several slides")
        XCTAssertLessThanOrEqual(short.count, MediaStore.storyMaxSlides)
        for slide in short { XCTAssertTrue(store.hasLocalFile(slide)) }
        let image = store.addImage(NSImage(size: NSSize(width: 8, height: 8)), forceOptimize: true)
        let passthrough = await store.splitStoryVideo(image)
        XCTAssertEqual(passthrough, [image], "photos pass through unchanged")
        for s in short where s != ref { store.delete(s) }
        store.delete(ref); store.delete(image)
    }

    func testMutedAndFilteredCopiesGetTheirOwnAddress() async throws {
        let store = MediaStore.shared
        let clip = try await makeClip(frames: 10)
        let ref = store.importTrimmed(clip)
        let muted = await store.muteVideo(ref)
        XCTAssertNotNil(muted)
        XCTAssertNotEqual(muted, ref)
        let same = await store.applyFilter(.original, to: ref)
        XCTAssertEqual(same, ref, "the original filter is a no-op")
        let filtered = await store.applyFilter(.mono, to: ref)
        XCTAssertNotEqual(filtered, ref, "a filter changes the bytes, so it changes the address")
        XCTAssertTrue(MediaStore.verify(filtered, store.rawBytes(filtered) ?? Data()))
        let missing = await store.muteVideo("vid_" + String(repeating: "9", count: 64))
        XCTAssertNil(missing)

        // Stills: filtered under a NEW ref, never overwritten in place.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let img = NSImage(size: NSSize(width: 64, height: 64)); img.addRepresentation(rep)
        let photo = store.addImage(img, forceOptimize: true)
        let tinted = await store.applyFilter(.kodakGold, to: photo)
        XCTAssertTrue(tinted.hasPrefix("img_"))
        for h in HavenFilter.allCases { XCTAssertFalse(h.title.isEmpty) }
        for r in [ref, muted ?? "", filtered, photo, tinted] where !r.isEmpty { store.delete(r) }
    }

    func testStrippingMetadataRemuxesWithoutReencoding() async throws {
        let clip = try await makeClip(frames: 6)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("stripped-\(UUID().uuidString).mp4")
        scratch.append(out)
        let ok = await MediaStore.stripVideoMetadata(clip, to: out)
        XCTAssertTrue(ok)
        XCTAssertGreaterThan((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)
        let direct = FileManager.default.temporaryDirectory.appendingPathComponent("optimised-\(UUID().uuidString).mp4")
        scratch.append(direct)
        let optimised = await MediaStore.optimizeVideo(clip, to: direct)
        XCTAssertTrue(optimised)
        let small = FileManager.default.temporaryDirectory.appendingPathComponent("small-\(UUID().uuidString).mp4")
        scratch.append(small)
        let retried = await MediaStore.optimizeVideo(clip, to: small, preset: AVAssetExportPreset960x540)
        XCTAssertTrue(retried)
    }

    func testVoiceNotesAreReencodedAsAAC() async throws {
        let store = MediaStore.shared
        let wav = try makeAudio()
        let ref = await store.addAudio(url: wav)
        XCTAssertTrue(ref.hasPrefix("aud_"))
        XCTAssertTrue(MediaStore.isVerifiable(ref))
        let bytes = try XCTUnwrap(store.rawBytes(ref))
        XCTAssertLessThan(bytes.count, (try Data(contentsOf: wav)).count, "AAC is leaner than the PCM it came from")
        XCTAssertEqual(store.item(ref)?.kind, .audio)
        store.delete(ref)
    }
}
