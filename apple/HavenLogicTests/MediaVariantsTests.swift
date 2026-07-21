import XCTest
@testable import HavenLogicTests

/// Pure-logic coverage for poster/original pairing and super-data-saver prefetch filtering.
/// These markers ride in the signed media array; a wrong parse silently drops the original
/// option or prefetches a full video under data saver — both worth catching in unit tests.
final class MediaVariantsTests: XCTestCase {

    func testPosterMarkerRoundTrip() {
        let m = MediaVariants.posterMarker(video: "vid_aaa", poster: "img_bbb")
        XCTAssertEqual(m, "poster:vid_aaa:img_bbb")
        let p = MediaVariants.parsePoster(m)
        XCTAssertEqual(p?.video, "vid_aaa")
        XCTAssertEqual(p?.poster, "img_bbb")
    }

    func testOriginalMarkerRoundTrip() {
        let m = MediaVariants.originalMarker(optimized: "vid_opt", original: "vid_orig")
        XCTAssertEqual(m, "orig:vid_opt:vid_orig")
        let o = MediaVariants.parseOriginal(m)
        XCTAssertEqual(o?.optimized, "vid_opt")
        XCTAssertEqual(o?.original, "vid_orig")
    }

    func testComposeVideoMediaOrdersPosterThenVideoThenOriginal() {
        let refs = MediaVariants.composeVideoMedia(
            poster: "img_poster", optimized: "vid_opt", original: "vid_orig")
        XCTAssertEqual(refs, [
            "img_poster",
            "poster:vid_opt:img_poster",
            "vid_opt",
            "vid_orig",
            "orig:vid_opt:vid_orig",
        ])
    }

    func testComposeWithoutOriginalOmitsCompanion() {
        let refs = MediaVariants.composeVideoMedia(
            poster: "img_p", optimized: "vid_v", original: nil)
        XCTAssertEqual(refs, ["img_p", "poster:vid_v:img_p", "vid_v"])
    }

    func testDisplayRefsDropsMarkersAndOriginals() {
        let media = MediaVariants.composeVideoMedia(
            poster: "img_p", optimized: "vid_v", original: "vid_o")
        let display = MediaVariants.displayRefs(media)
        // Poster image + playable video stay; original and both markers go.
        XCTAssertEqual(display, ["img_p", "vid_v"])
        XCTAssertFalse(display.contains("vid_o"))
        XCTAssertFalse(display.contains(where: { $0.hasPrefix("poster:") }))
        XCTAssertFalse(display.contains(where: { $0.hasPrefix("orig:") }))
    }

    func testDataSaverPrefetchSkipsVideosKeepsPostersAndImages() {
        let media = [
            "img_still",
            "img_poster",
            "poster:vid_clip:img_poster",
            "vid_clip",
            "vid_orig",
            "orig:vid_clip:vid_orig",
            "aud_voice",
            "file_zip",
        ]
        let prefetch = MediaVariants.dataSaverPrefetchRefs(media)
        XCTAssertTrue(prefetch.contains("img_still"))
        XCTAssertTrue(prefetch.contains("img_poster"))
        XCTAssertTrue(prefetch.contains("aud_voice"))
        XCTAssertTrue(prefetch.contains("file_zip"))
        // Full video + original must NOT be prefetched under data saver.
        XCTAssertFalse(prefetch.contains("vid_clip"))
        XCTAssertFalse(prefetch.contains("vid_orig"))
    }

    func testHasOriginal() {
        let media = MediaVariants.composeVideoMedia(
            poster: nil, optimized: "vid_a", original: "vid_b")
        XCTAssertTrue(MediaVariants.hasOriginal("vid_a", in: media))
        XCTAssertFalse(MediaVariants.hasOriginal("vid_b", in: media))
        XCTAssertFalse(MediaVariants.hasOriginal("vid_missing", in: media))
    }

    func testParseRejectsMalformed() {
        XCTAssertNil(MediaVariants.parsePoster("poster:onlyone"))
        XCTAssertNil(MediaVariants.parseOriginal("orig:"))
        XCTAssertNil(MediaVariants.parsePoster("img_not_a_marker"))
    }
}
