import XCTest
import SwiftUI
import AppKit
import WebKit
@testable import HavenUITestHost

/// Link handling, location refs, song refs, report reasons and the video-sound switch: the pure and
/// near-pure rules the link cards, map tiles, song chips, report sheet and media viewer are built on.
@MainActor
final class ViewsHelpersTests: XCTestCase {
    // MARK: links

    func testLinkNormalisationAcceptsOnlyWebAddresses() {
        XCTAssertEqual(LinkPresenter.normalized("example.org/a?b=1")?.absoluteString, "https://example.org/a?b=1")
        XCTAssertEqual(LinkPresenter.normalized("  http://example.org  ")?.absoluteString, "http://example.org")
        XCTAssertEqual(LinkPresenter.normalized("HTTPS://Example.org/x")?.host?.lowercased(), "example.org", "an upper-case scheme is still a web link")
        XCTAssertNil(LinkPresenter.normalized(""))
        XCTAssertNil(LinkPresenter.normalized("   \n"))
        XCTAssertNil(LinkPresenter.normalized("ftp://example.org/file"))
        XCTAssertNil(LinkPresenter.normalized("javascript://alert(1)"))
        XCTAssertNil(LinkPresenter.normalized("file:///etc/passwd"))
        XCTAssertNil(LinkPresenter.normalized("https://"), "a scheme with no host is not a link")
    }

    func testOpeningALinkPresentsTheBrowserOrRoutesInApp() {
        let presenter = LinkPresenter.shared
        presenter.presented = nil
        presenter.open("example.org/page")
        XCTAssertEqual(presenter.presented?.url.absoluteString, "https://example.org/page")
        presenter.presented = nil

        presenter.open("ftp://example.org")
        XCTAssertNil(presenter.presented, "a non-web scheme never opens the browser")
        presenter.open("")
        XCTAssertNil(presenter.presented)

        // A Haven link is a destination INSIDE the app: it routes there and the browser stays closed.
        let router = DeepLinkRouter.shared
        router.route = nil
        let node = String(repeating: "ab", count: 32)
        presenter.open("haven://u/\(node)")
        XCTAssertNil(presenter.presented, "an in-app route must not also load a web page")
        if case .profile(let hex)? = router.route { XCTAssertEqual(hex, node) } else { XCTFail("expected a profile route, got \(String(describing: router.route))") }
        router.route = nil
        XCTAssertTrue(presenter.routeInApp(URL(string: "haven://u/\(node)")!))
        XCTAssertFalse(presenter.routeInApp(URL(string: "https://example.org")!))
        router.route = nil
    }

    func testLinkScannerFindsWebLinksAndStripsThemTidily() {
        let text = "see https://example.org/a and mail me@example.org or visit http://foo.test/b?x=1 ok"
        let urls = LinkScanner.urls(in: text)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.org/a", "http://foo.test/b?x=1"],
                       "http(s) links only: mailto: is not a web link")
        XCTAssertEqual(LinkScanner.urls(in: text), urls, "the memoised answer matches")
        XCTAssertEqual(LinkScanner.urls(in: "no links here"), [])
        XCTAssertEqual(LinkScanner.urls(in: ""), [])

        let url = URL(string: "https://example.org/a")!
        XCTAssertEqual(LinkScanner.stripping(url, from: "look https://example.org/a now"), "look now",
                       "the hole the link leaves is closed")
        XCTAssertEqual(LinkScanner.stripping(url, from: "https://example.org/a"), "")
        XCTAssertEqual(LinkScanner.stripping(url, from: "line one\n\nhttps://example.org/a\n\nline two"), "line one\n\nline two")
        XCTAssertEqual(LinkScanner.stripping(url, from: "nothing to strip"), "nothing to strip")
        XCTAssertEqual(LinkScanner.stripping(url, from: "look https://example.org/a now"), "look now", "cached call agrees")
    }

    func testBrowserModelTracksTheWebView() {
        let model = WebViewModel()
        XCTAssertFalse(model.canGoBack); XCTAssertFalse(model.canGoForward); XCTAssertFalse(model.isLoading)
        let web = WKWebView(frame: .zero)
        model.bind(web)
        model.refresh(web, loading: true)
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.canGoBack)
        XCTAssertEqual(model.currentHost, "", "no page loaded yet: nothing to show")
        model.refresh(web, loading: false)
        XCTAssertFalse(model.isLoading)
        model.goBack(); model.goForward(); model.reload()   // no history: harmless
    }

    // MARK: locations

    func testLocationRefsRoundTripAndTolerateJunk() throws {
        let ref = SharedLocation.ref(lat: 37.7749, lon: -122.4194, label: "Ferry Building, SF")
        XCTAssertEqual(ref, "geo:37.7749,-122.4194,Ferry Building  SF", "commas in the label are stripped so they cannot split the ref")
        let parsed = try XCTUnwrap(SharedLocation.parse(ref))
        XCTAssertEqual(parsed.lat, 37.7749, accuracy: 1e-9)
        XCTAssertEqual(parsed.lon, -122.4194, accuracy: 1e-9)
        XCTAssertEqual(parsed.label, "Ferry Building  SF")

        let bare = try XCTUnwrap(SharedLocation.parse("geo:1.5,2.5"))
        XCTAssertEqual(bare.label, "")
        XCTAssertEqual(try XCTUnwrap(SharedLocation.parse("geo:1,2,")).label, "")
        XCTAssertNil(SharedLocation.parse("img_deadbeef"))
        XCTAssertNil(SharedLocation.parse("geo:abc,def,x"))
        XCTAssertNil(SharedLocation.parse("geo:12"))
        XCTAssertNil(SharedLocation.parse("geo:"))
    }

    func testCoordinateTextNamesTheHemispheres() {
        XCTAssertEqual(SharedLocation.coordinateText(lat: 37.7749, lon: -122.4194), "37.7749° N, 122.4194° W")
        XCTAssertEqual(SharedLocation.coordinateText(lat: -33.8688, lon: 151.2093), "33.8688° S, 151.2093° E")
        XCTAssertEqual(SharedLocation.coordinateText(lat: 0, lon: 0), "0.0000° N, 0.0000° E")
    }

    // MARK: songs

    func testSongStartAndArtworkShareOneField() {
        func track(_ art: String) -> TrackRefFfi { TrackRefFfi(catalogId: "1~2", title: "T", artist: "A", artworkUrl: art, durationMs: 1000) }
        XCTAssertNil(track("").songStartMs)
        XCTAssertNil(track("https://art.example/x.jpg").songStartMs)
        XCTAssertEqual(track("https://art.example/x.jpg").artworkURLString, "https://art.example/x.jpg")
        XCTAssertEqual(track("start:1200").songStartMs, 1200)
        XCTAssertEqual(track("start:1200").artworkURLString, "", "an offset with no artwork has none")
        XCTAssertEqual(track("start:1200;https://art.example/x.jpg").songStartMs, 1200)
        XCTAssertEqual(track("start:1200;https://art.example/x.jpg").artworkURLString, "https://art.example/x.jpg")
        XCTAssertNil(track("start:0").songStartMs, "a zero offset means the beginning: no section")
        XCTAssertNil(track("start:-5").songStartMs)
        XCTAssertNil(track("start:abc").songStartMs)

        // Choosing a section must keep the artwork the suggester stored.
        let withArt = track("https://art.example/x.jpg").withSongStart(ms: 4500)
        XCTAssertEqual(withArt.artworkUrl, "start:4500;https://art.example/x.jpg")
        XCTAssertEqual(withArt.songStartMs, 4500)
        XCTAssertEqual(withArt.artworkURLString, "https://art.example/x.jpg")
        XCTAssertEqual(withArt.catalogId, "1~2"); XCTAssertEqual(withArt.title, "T"); XCTAssertEqual(withArt.durationMs, 1000)
        let plain = track("").withSongStart(ms: 900)
        XCTAssertEqual(plain.artworkUrl, "start:900")
        // Re-choosing replaces the offset rather than stacking another one.
        let again = withArt.withSongStart(ms: 100)
        XCTAssertEqual(again.artworkUrl, "start:100;https://art.example/x.jpg")
    }

    func testTrackIdsSplitStoreAndLibraryIds() {
        XCTAssertEqual(trackIds("12345~67890").store, "12345")
        XCTAssertEqual(trackIds("12345~67890").pid, 67890)
        XCTAssertEqual(trackIds("12345").store, "12345")
        XCTAssertNil(trackIds("12345").pid)
        XCTAssertNil(trackIds("~42").store, "an empty store half means library-only")
        XCTAssertEqual(trackIds("~42").pid, 42)
        XCTAssertNil(trackIds("0~42").store, "store id 0 means not in the catalog")
        XCTAssertNil(trackIds("9~notanumber").pid)
        XCTAssertNil(trackIds("").store)
        XCTAssertNil(trackIds("").pid)
    }

    // MARK: reports

    func testEveryReportReasonHasAnIconAndIsUnique() {
        XCTAssertEqual(ReportReason.allCases.count, 5)
        XCTAssertEqual(Set(ReportReason.allCases.map(\.id)).count, 5)
        XCTAssertEqual(Set(ReportReason.allCases.map(\.icon)).count, 5, "each reason has its own glyph")
        XCTAssertEqual(ReportReason.spam.id, "Spam or scam")
        XCTAssertEqual(ReportReason(rawValue: "Something else"), .other)
        XCTAssertNil(ReportReason(rawValue: "nonsense"))
    }

    func testTheModerationLedgerSendsNothingWhenOffline() {
        // HAVEN_NO_NET is set for the whole run: no ledger row may leave the harness, and the call must not trap.
        XCTAssertTrue(HavenNet.offline)
        ModerationLedger.report(subject: String(repeating: "a", count: 64), reason: "Spam or scam")
        ModerationLedger.report(subject: "", reason: "x")
    }

    // MARK: video sound

    func testTheVideoSoundSwitchLiftsAGlobalMute() {
        let s = SettingsStore.shared
        let was = (s.silent, s.videoSoundOn)
        defer { s.silent = was.0; s.videoSoundOn = was.1 }
        s.silent = true; s.videoSoundOn = false
        XCTAssertFalse(HavenVideoSound.on)
        HavenVideoSound.set(true)
        XCTAssertFalse(s.silent, "tapping the speaker is the intent to hear it, so the app-wide mute lifts")
        XCTAssertTrue(s.videoSoundOn)
        XCTAssertTrue(HavenVideoSound.on)
        HavenVideoSound.toggle()
        XCTAssertFalse(s.videoSoundOn)
        XCTAssertFalse(HavenVideoSound.on)
        s.silent = true; s.videoSoundOn = true
        XCTAssertFalse(HavenVideoSound.on, "global silence beats the video preference")
        HavenVideoSound.set(false)
        XCTAssertFalse(s.videoSoundOn)
        XCTAssertTrue(s.silent, "turning sound off does not touch the mute")
    }

    func testZoomTargetDefaultsDescribeMediaWithNoPostBehindIt() {
        let t = ZoomTarget(refs: ["a", "b"], index: 1)
        XCTAssertNil(t.postId); XCTAssertNil(t.music); XCTAssertFalse(t.authorMutedVideo)
        XCTAssertNotEqual(t.id, ZoomTarget(refs: ["a", "b"], index: 1).id, "every presentation is its own identity")
    }

    // MARK: card geometry and labels

    func testReactionChipsAreCappedButYourOwnAlwaysShows() {
        func r(_ e: String, _ n: UInt32, mine: Bool = false) -> ReactionFfi { ViewFixtures.reaction(e, count: n, mine: mine) }
        let all = [r("a", 1), r("b", 9), r("c", 5), r("d", 3), r("e", 2, mine: true)]
        XCTAssertEqual(PostCard.cappedReactions(all, cap: 3).map(\.emoji), ["b", "c", "e"],
                       "the top chips by count, with my own swapped in for the last slot")
        XCTAssertEqual(PostCard.cappedReactions(all, cap: 2).map(\.emoji), ["b", "e"])
        XCTAssertEqual(PostCard.cappedReactions(all, cap: 5).map(\.emoji), ["b", "c", "d", "e", "a"], "under the cap everything is kept, by count")
        let mineAlreadyTop = [r("x", 7, mine: true), r("y", 1)]
        XCTAssertEqual(PostCard.cappedReactions(mineAlreadyTop, cap: 1).map(\.emoji), ["x"], "mine is not duplicated")
        XCTAssertEqual(PostCard.cappedReactions([], cap: 3), [])
    }

    func testDisappearingMessageLabelsUseTheCoarsestUnit() {
        XCTAssertEqual(DMThreadView.disappearLabel(300), "5m")
        XCTAssertEqual(DMThreadView.disappearLabel(3_599), "59m")
        XCTAssertEqual(DMThreadView.disappearLabel(3_600), "1h")
        XCTAssertEqual(DMThreadView.disappearLabel(86_399), "23h")
        XCTAssertEqual(DMThreadView.disappearLabel(86_400), "1d")
        XCTAssertEqual(DMThreadView.disappearLabel(604_799), "6d")
        XCTAssertEqual(DMThreadView.disappearLabel(604_800), "1w")
        XCTAssertEqual(DMThreadView.disappearLabel(3 * 604_800), "3w")
    }

    func testCardAspectComesFromTheBytesThenTheThumbThenMemory() async throws {
        _ = await Harness.feed()
        func png(_ w: Int, _ h: Int, tag: String) -> (ref: String, data: Data) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            var d = rep.representation(using: .jpeg, properties: [:])!
            d.append(contentsOf: (tag + UUID().uuidString).utf8)
            return (MediaStore.contentRef(.image, d), d)
        }
        let wide = png(80, 40, tag: "wide")
        XCTAssertTrue(MediaStore.shared.store(wide.ref, wide.data))
        defer { MediaStore.shared.delete(wide.ref) }
        XCTAssertEqual(postSingleAspect(wide.ref, in: [wide.ref]), 2.0, accuracy: 0.01)
        XCTAssertFalse(postLetterboxes(wide.ref, in: 2.0), "a container of the same shape has no bars")
        XCTAssertTrue(postLetterboxes(wide.ref, in: 1.0), "a square container letterboxes a 2:1 image")
        XCTAssertNotNil(postShareURL(wide.ref))
        XCTAssertEqual(postShareURL(wide.ref), MediaStore.shared.storagePath(for: wide.ref))

        // Nothing on disk and nothing remembered: the 4:3 guess; and no pixel size means we assume bars.
        let unknown = "img_" + String(repeating: "5", count: 64)
        XCTAssertEqual(postSingleAspect(unknown, in: [unknown]), 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertTrue(postLetterboxes(unknown, in: 1.5))
        // Once a shape has been seen it is remembered, so the card never changes height afterwards.
        MediaAspectStore.shared.record(unknown, aspect: 0.5625)
        XCTAssertEqual(postSingleAspect(unknown, in: [unknown]), 0.5625, accuracy: 0.0001)
    }
}
