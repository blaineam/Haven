import XCTest

final class HistoryHandoffWireTests: XCTestCase {
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
}
