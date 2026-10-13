import XCTest
import SwiftUI
import AVFoundation
import AppKit
@testable import HavenUITestHost

/// "Re-optimize media I already shared": a video of mine that never published a poster still is found
/// by the scan, the run cuts the still and re-points the post at it with an ordinary edit, and a
/// second scan finds nothing left to do.
@MainActor
final class ViewsReoptimizeTests: XCTestCase {
    private var scratch: [URL] = []
    override func tearDown() async throws {
        ViewBench.reset()
        for u in scratch { try? FileManager.default.removeItem(at: u) }
        scratch.removeAll()
    }

    private func makeClip(frames: Int = 10) async throws -> URL {
        let size = CGSize(width: 96, height: 64)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reopt-\(UUID().uuidString).mp4")
        scratch.append(url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, nil, &pb)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) { memset(base, Int32(0x30 + (i * 13) % 0xA0), CVPixelBufferGetDataSize(buf)) }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(seconds: Double(i) * 0.1, preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func testAPostedVideoWithoutAPosterGetsOneAndTheScanThenComesUpClean() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let clip = try await makeClip()
        let prepared = await MediaStore.shared.prepareVideo(url: clip, alsoOriginal: false)
        XCTAssertFalse(prepared.isEmpty)
        defer { MediaStore.shared.delete(prepared.videoRef); if let p = prepared.posterRef { MediaStore.shared.delete(p) } }

        // Post ONLY the clip: no poster marker rides with it, the shape an old post is in.
        let posted = await store.postNow("a clip with no still", media: [prepared.videoRef])
        let postId = try XCTUnwrap(posted)
        await Harness.until(store, "the clip post is in my feed") { store.feedItems.contains { $0.id == postId } }
        XCTAssertNil(MediaVariants.poster(for: prepared.videoRef, in: try XCTUnwrap(store.feedItems.first { $0.id == postId }).media))

        let targets = await store.reoptimizeTargets()
        let mine = try XCTUnwrap(targets.first { $0.eventId == postId })
        XCTAssertEqual(mine.circleId, "default")
        XCTAssertEqual(mine.body, "a clip with no still")
        XCTAssertFalse(targets.contains { $0.media.isEmpty }, "only posts that name media are candidates")

        let reopt = MediaReoptimizer.shared
        await reopt.scan()
        XCTAssertTrue(reopt.hasScanned)
        let candidate = try XCTUnwrap(reopt.candidates.first { $0.ref == prepared.videoRef }, "the posterless clip is offered")
        XCTAssertEqual(candidate.work, .posterOnly, "it is already small, so only a still is missing")
        XCTAssertEqual(candidate.kind, .video)
        XCTAssertEqual(reopt.posterOnlyCount, reopt.candidates.filter { $0.work == .posterOnly }.count)
        await ViewBench.renderDrawn(ReoptimizeMediaRow().padding(8), height: 300)   // "Add posters to 1 video"

        await reopt.run()
        XCTAssertFalse(reopt.running)
        XCTAssertGreaterThanOrEqual(reopt.doneCount, 1)
        XCTAssertNil(reopt.lastWarning)

        // The run edited the post in place: same id, same text, now with a poster marker for the clip.
        await Harness.until(store, "the post now carries a poster") {
            guard let item = store.feedItems.first(where: { $0.id == postId }) else { return false }
            return MediaVariants.poster(for: prepared.videoRef, in: item.media) != nil
        }
        let edited = try XCTUnwrap(store.feedItems.first { $0.id == postId })
        XCTAssertEqual(edited.body, "a clip with no still", "re-sharing leaves the caption alone")
        XCTAssertTrue(edited.media.contains(prepared.videoRef))

        await reopt.scan()
        XCTAssertFalse(reopt.candidates.contains { $0.ref == prepared.videoRef }, "a post that has its still is not offered again")
        await ViewBench.renderDrawn(ReoptimizeMediaRow().padding(8), height: 300)
    }
}
