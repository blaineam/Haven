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

    func testDisplayRefsDropsMarkersOriginalsAndVideoPosters() {
        let media = MediaVariants.composeVideoMedia(
            poster: "img_p", optimized: "vid_v", original: "vid_o")
        let display = MediaVariants.displayRefs(media)
        // Playable video stays; poster still rides with the video page (not its own slide).
        // Original and both markers go.
        XCTAssertEqual(display, ["vid_v"])
        XCTAssertFalse(display.contains("img_p"))
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

    func testRewriteAddsPosterOnlyWithoutTouchingVideo() {
        let media = ["vid_old", "img_still"]
        let out = MediaVariants.rewriteMedia(media, swap: [:], posters: ["vid_old": "img_poster"])
        XCTAssertEqual(out, [
            "img_poster",
            "poster:vid_old:img_poster",
            "vid_old",
            "img_still",
        ])
    }

    func testRewriteReencodeReplacesPosterAndVideo() {
        let media = MediaVariants.composeVideoMedia(
            poster: "img_oldp", optimized: "vid_a", original: nil)
        let out = MediaVariants.rewriteMedia(
            media, swap: ["vid_a": "vid_b"], posters: ["vid_a": "img_newp"])
        XCTAssertEqual(out, [
            "img_newp",
            "poster:vid_b:img_newp",
            "vid_b",
        ])
        XCTAssertFalse(out.contains("img_oldp"))
        XCTAssertFalse(out.contains("vid_a"))
    }

    /// Picking a VIDEO for a story must attach the clip, not a still of its first frame.
    ///
    /// composeVideoMedia deliberately puts the poster FIRST so a feed tile can paint something
    /// immediately — which made `refs.first` look like the natural way to take "the" ref. It isn't:
    /// it is the poster, and the story picker used it, so choosing a video published a photo of
    /// frame 0 with no clip attached. displayRefs is the selector that survives the layout.
    func testDisplayRefsPicksThePlayableClipNotThePoster() {
        let media = MediaVariants.composeVideoMedia(
            poster: "img_poster", optimized: "vid_play", original: "vid_orig")
        // The layout that caused the bug: poster first, playable third.
        XCTAssertEqual(media.first, "img_poster")
        XCTAssertTrue(media.contains("vid_play"))

        let display = MediaVariants.displayRefs(media)
        XCTAssertEqual(display.first, "vid_play",
                       "a picked video must resolve to its playable ref, not its poster")
        XCTAssertFalse(display.contains("img_poster"), "the poster is a companion, never the story")
        XCTAssertFalse(display.contains("vid_orig"), "the original is a companion too")
    }

    /// A picked PHOTO has no companions, so the same selector must still return the image itself.
    func testDisplayRefsLeavesAPlainPhotoAlone() {
        XCTAssertEqual(MediaVariants.displayRefs(["img_solo"]).first, "img_solo")
    }
}

// MARK: - The 512px AVIF preview tier (docs/PREVIEW-TIER-DESIGN.md)

extension MediaVariantsTests {

    /// A preview is a companion, not a slide. Rendering it as its own tile would show the same
    /// picture twice — small, then full — the moment the real bytes landed.
    func testPreviewsNeverRenderAsSlides() {
        let media = [
            "img_photo",
            MediaVariants.previewMarker(content: "img_photo", preview: "img_prev"),
            "img_prev",
        ]
        XCTAssertEqual(MediaVariants.displayRefs(media), ["img_photo"])
    }

    func testPreviewRoundTripsAndIsFound() {
        let m = MediaVariants.previewMarker(content: "img_a", preview: "img_a_prev")
        let parsed = MediaVariants.parsePreview(m)
        XCTAssertEqual(parsed?.content, "img_a")
        XCTAssertEqual(parsed?.preview, "img_a_prev")
        XCTAssertEqual(MediaVariants.preview(for: "img_a", in: [m]), "img_a_prev")
        XCTAssertEqual(MediaVariants.allPreviews(in: [m]), ["img_a_prev"])
        // A thumb marker is not a preview marker and vice versa.
        XCTAssertNil(MediaVariants.parsePreview(MediaVariants.thumbMarker(content: "x", thumb: "y")))
        XCTAssertNil(MediaVariants.parseThumb(m))
    }

    /// The satellite contract: previews and nothing else. Everything heavier waits for service.
    func testOnlyPreviewsCrossASatelliteLink() {
        let media = [
            "vid_clip",
            MediaVariants.posterMarker(video: "vid_clip", poster: "img_poster"), "img_poster",
            MediaVariants.thumbMarker(content: "vid_clip", thumb: "img_thumb"), "img_thumb",
            MediaVariants.previewMarker(content: "vid_clip", preview: "img_prev"), "img_prev",
            MediaVariants.originalMarker(optimized: "vid_clip", original: "vid_orig"), "vid_orig",
        ]
        XCTAssertEqual(MediaVariants.satelliteRefs(media), ["img_prev"],
                       "only the preview may cross; poster, thumb, original and video must not")
    }

    /// On a constrained link the upload may only get through the first rank before the pass ends,
    /// so rank order decides what a recipient can see at all. Preview must outrank everything.
    func testUploadOrderPutsPreviewsFirst() {
        let media = [
            "vid_clip",
            MediaVariants.posterMarker(video: "vid_clip", poster: "img_poster"), "img_poster",
            MediaVariants.thumbMarker(content: "vid_clip", thumb: "img_thumb"), "img_thumb",
            MediaVariants.previewMarker(content: "vid_clip", preview: "img_prev"), "img_prev",
        ]
        let order = MediaVariants.uploadOrder(media)
        XCTAssertEqual(order.first, "img_prev", "preview uploads before anything else")
        XCTAssertEqual(order, ["img_prev", "img_thumb", "img_poster", "vid_clip"])
    }

    /// Data saver renders the preview until a tap, so it must always be fetched — it is the
    /// cheapest thing in the post at ≤8 KB.
    func testDataSaverAlwaysFetchesThePreview() {
        let media = [
            "vid_clip",
            MediaVariants.previewMarker(content: "vid_clip", preview: "img_prev"), "img_prev",
        ]
        XCTAssertTrue(MediaVariants.dataSaverPrefetchRefs(media).contains("img_prev"))
        XCTAssertFalse(MediaVariants.dataSaverPrefetchRefs(media).contains("vid_clip"),
                       "the video still waits for a tap")
    }

    /// Deleting a photo must take its preview with it, or the post keeps pointing at a picture it
    /// no longer carries — the orphaned-companion bug the thumb/poster cases already cover.
    func testRemovingContentTakesItsPreview() {
        let media = [
            "img_photo",
            MediaVariants.previewMarker(content: "img_photo", preview: "img_prev"), "img_prev",
        ]
        let companions = MediaVariants.companionRefs("img_photo", in: media)
        XCTAssertTrue(companions.contains("img_prev"))
        XCTAssertTrue(companions.contains(MediaVariants.previewMarker(content: "img_photo", preview: "img_prev")))
    }
}
