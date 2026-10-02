import XCTest

final class HistoryHandoffWireTests: XCTestCase {
    func testV2PageCarriesItsMediaIndex() {
        let media = [HistoryHandoffWire.MediaItem(ref: "i:aaa", size: 123_456),
                     HistoryHandoffWire.MediaItem(ref: "v:bbb", size: 700_000_000)]
        let page = HistoryHandoffWire.encodePage(circleId: "default", envelopes: [Data([0x02, 9])], media: media)
        let back = HistoryHandoffWire.decodePage(page)
        XCTAssertEqual(back?.envelopes, [Data([0x02, 9])])
        XCTAssertEqual(back?.media, media, "sizes past 4 GB-safe range round-trip too")
    }

    func testV1PagesFromOlderSourcesStillDecodeWithoutMedia() {
        // Hand-built v1: "HVH1" ‖ u16 cid ‖ cid ‖ u32 count ‖ (u32 len ‖ env)
        var v1 = Data("HVH1".utf8)
        v1.append(contentsOf: [1, 0]); v1.append(Data("c".utf8))
        v1.append(contentsOf: [1, 0, 0, 0]); v1.append(contentsOf: [2, 0, 0, 0]); v1.append(contentsOf: [0x02, 7])
        let back = HistoryHandoffWire.decodePage(v1)
        XCTAssertEqual(back?.circleId, "c")
        XCTAssertEqual(back?.envelopes, [Data([0x02, 7])])
        XCTAssertEqual(back?.media.count, 0)
    }

    func testBlobRefsExpandEveryCompanionMarker() {
        // Real content refs are `<kind>_<sha256>` (the markers are colon-delimited around them).
        let photo = "img_" + String(repeating: "a", count: 64), thumb = "img_" + String(repeating: "b", count: 64)
        let clip = "vid_" + String(repeating: "c", count: 64), poster = "img_" + String(repeating: "d", count: 64)
        let entries = [photo, MediaVariants.thumbMarker(content: photo, thumb: thumb),
                       MediaVariants.posterMarker(video: clip, poster: poster), photo]
        XCTAssertEqual(HistoryHandoffWire.blobRefs(entries), [photo, thumb, clip, poster])
    }

    func testMediaKeysAreRelaySafe() {
        let key = HistoryHandoffWire.mediaChunkKey("aa", "tt", "ss", "1", "img_abc/../x", 3)
        XCTAssertFalse(key.contains(".."), "a ref can't climb out of its run directory")
        XCTAssertTrue(key.hasSuffix("/3"))
        XCTAssertEqual(HistoryHandoffWire.keySafe("img_abc"), "img_abc")
    }

    func testPageRoundTripsEveryEnvelopeByteForByte() {
        let envs = [Data([0x04, 1, 2, 3]), Data(), Data(repeating: 0xAB, count: 70_000), Data([0x03])]
        let page = HistoryHandoffWire.encodePage(circleId: "dm:aa:bb", envelopes: envs)
        let back = HistoryHandoffWire.decodePage(page)
        XCTAssertEqual(back?.circleId, "dm:aa:bb")
        XCTAssertEqual(back?.envelopes, envs)
    }

    func testUnicodeCircleIdAndEmptyPage() {
        let page = HistoryHandoffWire.encodePage(circleId: "Famille 👪", envelopes: [])
        let back = HistoryHandoffWire.decodePage(page)
        XCTAssertEqual(back?.circleId, "Famille 👪")
        XCTAssertEqual(back?.envelopes.count, 0)
    }

    func testRejectsForeignAndTruncatedBlobs() {
        XCTAssertNil(HistoryHandoffWire.decodePage(Data("not a page".utf8)))
        let page = HistoryHandoffWire.encodePage(circleId: "c", envelopes: [Data(repeating: 1, count: 100)])
        for cut in [4, 7, 12, page.count - 1] {
            XCTAssertNil(HistoryHandoffWire.decodePage(page.prefix(cut)), "truncated at \(cut)")
        }
    }

    func testKeysStayOnTheOwnAccountLane() {
        let acct = String(repeating: "AB", count: 32), dev = String(repeating: "cd", count: 32)
        let lane = "haven/self/\(acct.lowercased())/"
        XCTAssertEqual(HistoryHandoffWire.requestKey(acct, dev), lane + "history-req/" + dev)
        XCTAssertTrue(HistoryHandoffWire.requestKey(acct, dev).hasPrefix(HistoryHandoffWire.requestPrefix(acct)))
        let src = String(repeating: "ef", count: 32)
        XCTAssertEqual(HistoryHandoffWire.manifestKey(acct, dev, src), lane + "history-m/\(dev)/\(src)")
        XCTAssertTrue(HistoryHandoffWire.manifestKey(acct, dev, src).hasPrefix(HistoryHandoffWire.manifestPrefix(acct, dev)))
        XCTAssertEqual(HistoryHandoffWire.pageKey(acct, dev, src, "123", 7), lane + "history/\(dev)/\(src)/123/7")
        // Pages never live under the manifest prefix, so listing manifests stays small.
        XCTAssertFalse(HistoryHandoffWire.pageKey(acct, dev, src, "1", 0).hasPrefix(HistoryHandoffWire.manifestPrefix(acct, dev)))
    }

    func testASourceGoesStaleOnlyWhileIncomplete() {
        let now: UInt64 = 10_000_000_000
        var m = HistoryHandoffWire.Manifest(run: "1", source: "s", forRequest: 1, pages: 3, complete: false, updatedAt: now - 60_000)
        XCTAssertTrue(m.isLive(now: now))
        m.updatedAt = now - HistoryHandoffWire.staleSourceMs - 1
        XCTAssertFalse(m.isLive(now: now), "quiet for longer than the stale window → another source may take over")
        m.complete = true
        XCTAssertTrue(m.isLive(now: now), "a finished run never goes stale")
        m.complete = false; m.updatedAt = nil
        XCTAssertFalse(m.isLive(now: now), "no timestamp → treated as stale")
    }

    func testManifestDecodesAcrossVersionsOfTheSameShape() throws {
        let json = #"{"v":1,"run":"9","source":"s","forRequest":5,"pages":3,"complete":false}"#
        let m = try JSONDecoder().decode(HistoryHandoffWire.Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.pages, 3)
        XCTAssertFalse(m.complete)
        let r = try JSONDecoder().decode(HistoryHandoffWire.Request.self, from: Data(#"{"v":1,"device":"d","at":1}"#.utf8))
        XCTAssertNil(r.done)
    }

    // MARK: - Cancelling a transfer (HandoffCancelLedger)

    private let acct = String(repeating: "a", count: 64)
    private let target = String(repeating: "b", count: 64)
    private let source = String(repeating: "c", count: 64)

    private func run(at: UInt64) -> HandoffCancelLedger.Run {
        .init(device: target, requestAt: at, run: "900", pages: 4, totalEvents: 500, servedEvents: 480)
    }
    private func request(at: UInt64, cancelled: Bool? = nil, done: Bool? = nil) -> HistoryHandoffWire.Request {
        HistoryHandoffWire.Request(device: target, at: at, done: done, cancelled: cancelled)
    }

    /// Cancel on the NEW device: the request is never written back (no auto-resume), a stop record
    /// for the source is queued on the request key, and the source drops the run when it reads it.
    func testCancelFromReceiverStopsBothSides() throws {
        var t = HandoffCancelLedger()
        t.cancelAsTarget(account: acct, me: target, requestAt: 100, remote: false)
        XCTAssertFalse(t.acceptsWant(at: 100), "an in-flight pull must not persist the cancelled request")
        XCTAssertEqual(t.banner, .byThisDevice)
        XCTAssertEqual(t.pending.count, 1)
        XCTAssertEqual(t.pending[0].key, HistoryHandoffWire.requestKey(acct, target))
        let sent = try JSONDecoder().decode(HistoryHandoffWire.Request.self, from: t.pending[0].body)
        XCTAssertEqual(sent.cancelled, true)
        XCTAssertEqual(sent.at, 100)

        // The source reads that record on its next pass.
        var s = HandoffCancelLedger()
        XCTAssertEqual(s.verdict(device: target, request: sent), .cancelledByTarget)
        s.cancelAsSource(account: acct, me: source, runs: [run(at: 100)], remote: true, now: 1)
        XCTAssertFalse(s.acceptsServe(device: target, requestAt: 100))
        XCTAssertEqual(s.verdict(device: target, request: sent), .declined, "seen once is enough")
        XCTAssertEqual(s.banner, .byOtherDevice, "the old device says the transfer was cancelled")
        XCTAssertTrue(s.pending.isEmpty, "a remote cancel publishes nothing back")
    }

    /// Cancel on the OLD device: a cancelled manifest is queued; the target stops on reading it and
    /// no other source takes the request over.
    func testCancelFromSenderStopsTheReceiver() throws {
        var s = HandoffCancelLedger()
        s.cancelAsSource(account: acct, me: source, runs: [run(at: 100)], remote: false, now: 5)
        XCTAssertEqual(s.banner, .byThisDevice)
        XCTAssertFalse(s.acceptsServe(device: target, requestAt: 100))
        XCTAssertEqual(s.verdict(device: target, request: request(at: 100)), .declined,
                       "the still-open request is never served again here")
        XCTAssertEqual(s.pending.map(\.key), [HistoryHandoffWire.manifestKey(acct, target, source)])
        let m = try JSONDecoder().decode(HistoryHandoffWire.Manifest.self, from: s.pending[0].body)
        XCTAssertEqual(m.cancelled, true)
        XCTAssertEqual(m.forRequest, 100)

        XCTAssertTrue(HandoffCancelLedger.sourceCancelled([m], requestAt: 100))
        var t = HandoffCancelLedger()
        t.cancelAsTarget(account: acct, me: target, requestAt: 100, remote: true)
        XCTAssertFalse(t.acceptsWant(at: 100))
        XCTAssertEqual(t.banner, .byOtherDevice)
        XCTAssertTrue(t.pending.isEmpty)
    }

    /// The other device is offline: the local cancel takes effect at once and the stop waits in the
    /// ledger (persisted) until a relay takes it; a second cancel replaces, never duplicates, it.
    func testCancelWhileOfflineQueuesUntilPublished() throws {
        var t = HandoffCancelLedger()
        t.cancelAsTarget(account: acct, me: target, requestAt: 100, remote: false)
        t.cancelAsTarget(account: acct, me: target, requestAt: 100, remote: false)
        XCTAssertEqual(t.pending.count, 1)
        // Survives a relaunch (the ledger is what HistoryHandoff persists).
        let back = try JSONDecoder().decode(HandoffCancelLedger.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        XCTAssertFalse(back.acceptsWant(at: 100), "no auto-resume after a relaunch")
        var published = back
        published.published(back.pending[0])
        XCTAssertTrue(published.pending.isEmpty)
        XCTAssertFalse(published.acceptsWant(at: 100))
    }

    /// Stale records never stop a NEW transfer: an old cancelled manifest doesn't match a fresh request.
    func testOldCancelDoesNotStopANewRequest() {
        let old = HistoryHandoffWire.Manifest(run: "1", source: source, forRequest: 100, pages: 2, complete: false,
                                              updatedAt: 1, cancelled: true)
        XCTAssertFalse(HandoffCancelLedger.sourceCancelled([old], requestAt: 200))
        let live = HistoryHandoffWire.Manifest(run: "2", source: source, forRequest: 200, pages: 2, complete: false,
                                               updatedAt: 1)
        XCTAssertFalse(HandoffCancelLedger.sourceCancelled([live], requestAt: 200))
    }

    /// After a cancel a new transfer may start, on either end, and the banner clears.
    func testRestartAllowedAfterCancel() {
        var t = HandoffCancelLedger()
        t.cancelAsTarget(account: acct, me: target, requestAt: 100, remote: false)
        t.startedAgain()
        XCTAssertNil(t.banner)
        XCTAssertTrue(t.acceptsWant(at: 250), "a fresh request is followed")
        XCTAssertFalse(t.acceptsWant(at: 100), "the old one still can't be written back by a late pull")

        var s = HandoffCancelLedger()
        s.cancelAsSource(account: acct, me: source, runs: [run(at: 100)], remote: false, now: 5)
        XCTAssertEqual(s.verdict(device: target, request: request(at: 250)), .serve, "a new ask is served")
        XCTAssertEqual(s.verdict(device: target.uppercased(), request: request(at: 100)), .declined,
                       "device ids compare case-insensitively")
        XCTAssertEqual(s.verdict(device: target, request: request(at: 250, done: true)), .finished)
    }

    /// Records from builds before cancelling existed still decode (and mean "not cancelled").
    func testPreCancelRecordsStillDecode() throws {
        let req = try JSONDecoder().decode(HistoryHandoffWire.Request.self,
                                           from: Data(#"{"v":1,"device":"d","at":7}"#.utf8))
        XCTAssertNil(req.cancelled)
        XCTAssertEqual(HandoffCancelLedger().verdict(device: "d", request: req), .serve)
        let m = try JSONDecoder().decode(HistoryHandoffWire.Manifest.self,
                                         from: Data(#"{"v":1,"run":"1","source":"s","forRequest":7,"pages":0,"complete":false}"#.utf8))
        XCTAssertNil(m.cancelled)
    }
}
