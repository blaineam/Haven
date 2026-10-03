import XCTest

/// rc.3 field report: after "Load history from your relays" the iPhone got hot re-downloading every
/// recovered photo from the relay it had just downloaded it from, and the recovered posts showed the
/// orange "not backed up" cloud. These pin the decisions that stop it.
final class MediaHoldingTests: XCTestCase {
    private let relay = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)

    // MARK: download → ledger

    func testRestoreMarksTheServingRelayOnlyOnCompleteOpenedDownload() {
        XCTAssertEqual(MediaHolding.holderToRecord(from: .relay(relay), complete: true, opened: true), relay)
        XCTAssertEqual(MediaHolding.holderToRecord(from: .s3, complete: true, opened: true), "s3")
        XCTAssertNil(MediaHolding.holderToRecord(from: .relay(relay), complete: false, opened: true),
                     "a partial reassembly proves nothing about what the relay holds")
        XCTAssertNil(MediaHolding.holderToRecord(from: .relay(relay), complete: true, opened: false),
                     "an undecryptable copy must not be ledgered — the ledger is never revisited")
        XCTAssertNil(MediaHolding.holderToRecord(from: nil, complete: true, opened: true))
        XCTAssertNil(MediaHolding.holderToRecord(from: .relay(""), complete: true, opened: true))
    }

    // MARK: the probe

    /// A fake relay: a key→bytes store that counts what was asked of it.
    private final class FakeRelay {
        var store: [String: Data] = [:]
        var speaksHead = true
        var heads = 0
        var gets: [String] = []
        func head(_ k: String) -> MediaHolding.Head {
            heads += 1
            guard speaksHead else { return .unsupported }
            return store[k] != nil ? .present : .absent
        }
        func get(_ k: String) -> MediaHolding.Fetch {
            gets.append(k)
            return store[k].map { .data($0) } ?? .miss
        }
    }
    private static let magic = Data("HVCHUNK1\n".utf8)
    private func manifest(_ n: Int) -> Data { Self.magic + Data("{\"chunks\":\(n)}".utf8) }
    private func chunks(_ m: Data) -> Int? {
        guard m.starts(with: Self.magic),
              let o = try? JSONSerialization.jsonObject(with: m.dropFirst(Self.magic.count)) as? [String: Any]
        else { return nil }
        return o["chunks"] as? Int
    }
    private func probe(_ r: FakeRelay) async -> (verdict: MediaHolding.Verdict, fullGets: Int) {
        await MediaHolding.probe(manifestKey: "m", chunkKey: { "m.p/\($0)" },
                                 head: { r.head($0) }, get: { r.get($0) }, chunkCount: { self.chunks($0) })
    }

    func testProbeOfAnUnchunkedPhotoDownloadsNothing() async {
        let r = FakeRelay()
        r.store["m"] = Data(count: 3_000_000)   // a whole photo under the media key
        let p = await probe(r)
        XCTAssertEqual(p.verdict, .complete)
        XCTAssertEqual(p.fullGets, 0)
        XCTAssertTrue(r.gets.isEmpty, "the old probe GET the whole photo just to learn 'yes'")
    }

    func testProbeOfAChunkedBlobReadsOnlyTheManifestAndHeadsTheTail() async {
        let r = FakeRelay()
        r.store["m"] = manifest(3)
        for i in 0..<3 { r.store["m.p/\(i)"] = Data(count: 8) }
        let p = await probe(r)
        XCTAssertEqual(p.verdict, .complete)
        XCTAssertEqual(r.gets, ["m"], "only the ~100-byte manifest is read")
        XCTAssertEqual(p.fullGets, 0)
    }

    func testProbeStillCatchesAMissingTail() async {
        let r = FakeRelay()
        r.store["m"] = manifest(3)
        r.store["m.p/0"] = Data(count: 8); r.store["m.p/1"] = Data(count: 8)
        let p = await probe(r)
        XCTAssertEqual(p.verdict, .incomplete)
    }

    func testProbeAbsentIsOneHead() async {
        let r = FakeRelay()
        let p = await probe(r)
        XCTAssertEqual(p.verdict, .absent)
        XCTAssertEqual(r.heads, 1)
        XCTAssertTrue(r.gets.isEmpty)
    }

    func testRelayWithoutHeadFallsBackToTheOldGetProbe() async {
        let r = FakeRelay()
        r.speaksHead = false
        r.store["m"] = Data(count: 10)
        let p = await probe(r)
        XCTAssertEqual(p.verdict, .complete)
        XCTAssertEqual(p.fullGets, 1, "an old relay keeps working — at the old cost")
    }

    func testRefusedAndUnreachableAreNotAbsent() async {
        let refused = await MediaHolding.probe(manifestKey: "m", chunkKey: { "\($0)" }, head: { _ in .refused },
                                               get: { _ in .miss }, chunkCount: { _ in nil })
        XCTAssertEqual(refused.verdict, .refused)
        let down = await MediaHolding.probe(manifestKey: "m", chunkKey: { "\($0)" }, head: { _ in .unreachable },
                                            get: { _ in .miss }, chunkCount: { _ in nil })
        XCTAssertEqual(down.verdict, .unreachable)
        let refusedGet = await MediaHolding.probe(manifestKey: "m", chunkKey: { "\($0)" }, head: { _ in .unsupported },
                                                  get: { _ in .refused }, chunkCount: { _ in nil })
        XCTAssertEqual(refusedGet.verdict, .refused)
    }

    // MARK: backfill

    func testBackfillSkipsRefsTheLedgerConfirmsOnEveryWantedRelay() {
        XCTAssertFalse(MediaHolding.needsBackfill(wanted: [relay], held: [relay], heldRemotely: true),
                       "downloaded from the circle's relay → recorded → never re-probed")
        XCTAssertTrue(MediaHolding.needsBackfill(wanted: [relay, other], held: [relay], heldRemotely: true),
                      "a second relay lacking it still gets its copy (redundancy is kept)")
        XCTAssertTrue(MediaHolding.needsBackfill(wanted: [relay], held: [], heldRemotely: false))
        XCTAssertFalse(MediaHolding.needsBackfill(wanted: [], held: [other], heldRemotely: true))
    }

    func testS3PseudoRelayMatchesTheLedgersS3() {
        XCTAssertFalse(MediaHolding.needsBackfill(wanted: [relay, "s3:bucket"], held: [relay, "s3"], heldRemotely: true),
                       "compared raw, an s3: entry could never be satisfied and re-enqueued every sweep")
    }

    func testMirrorClassification() {
        XCTAssertTrue(MediaHolding.isBackgroundMirror(mine: false, heldRemotely: false), "a friend's media")
        XCTAssertTrue(MediaHolding.isBackgroundMirror(mine: nil, heldRemotely: false), "legacy job / peer-received")
        XCTAssertTrue(MediaHolding.isBackgroundMirror(mine: true, heldRemotely: true),
                      "my post already on a relay (a history recovery) is redundancy now")
        XCTAssertFalse(MediaHolding.isBackgroundMirror(mine: true, heldRemotely: false),
                       "my media with no remote copy is the only copy — keeps the authored budget")
    }

    func testPhoneMirrorCapIsSmall() {
        XCTAssertLessThan(MediaHolding.perCircleCap(hostingRelay: false, phone: true, mirror: true), 200)
        XCTAssertEqual(MediaHolding.perCircleCap(hostingRelay: false, phone: true, mirror: false), 200)
        XCTAssertEqual(MediaHolding.perCircleCap(hostingRelay: true, phone: false, mirror: true), 40)
    }

    // MARK: badge

    private func badge(held: Set<String>, remote: Set<String>, pending: Set<String> = [],
                       progress: Double? = nil, stuck: Bool = false, hasRelay: Bool = true,
                       blobs: [String] = ["x", "y"]) -> MediaHolding.Badge {
        MediaHolding.badge(blobs: blobs, heldRemotely: { remote.contains($0) }, heldAnywhere: { held.contains($0) },
                           pending: { pending.contains($0) }, progress: progress, looksStuck: stuck, hasRelay: hasRelay)
    }

    func testBadgeDerivesFromTheLedger() {
        XCTAssertEqual(badge(held: ["x", "y"], remote: ["x", "y"]), .backedUp,
                       "recovered own post, recorded at download → pink check")
        XCTAssertEqual(badge(held: [], remote: []), .waiting(stuck: true),
                       "the rc.3 orange cloud: nothing in the ledger, nothing queued")
        XCTAssertEqual(badge(held: ["x", "y"], remote: ["x"]), .ownRelayOnly)
        XCTAssertEqual(badge(held: [], remote: [], hasRelay: false), .noRelay)
        XCTAssertEqual(badge(held: [], remote: [], pending: ["x"]), .waiting(stuck: false))
        XCTAssertEqual(badge(held: [], remote: [], pending: ["x"], progress: 0.5), .uploading(0.5, stuck: false))
        XCTAssertEqual(badge(held: [], remote: [], pending: ["x"], progress: 0.5, stuck: true), .uploading(0.5, stuck: true))
    }
}
