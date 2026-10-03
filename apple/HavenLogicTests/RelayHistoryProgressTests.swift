import XCTest

/// "Load history from your relays" (RelayHistoryProgress.swift): the progress bar only moves for real
/// work, the summary never claims more than came back, and the fetch plan is stable and bounded.
final class RelayHistoryProgressTests: XCTestCase {

    // MARK: progress

    func testFractionIsMonotonicAcrossPhasesAndEmptyPhasesDoNotStall() {
        var p = RelayHistoryProgress(phase: .scanning)
        p.circlesTotal = 4
        var last = p.fraction
        for done in 1...4 {
            p.circlesDone = done
            XCTAssertGreaterThanOrEqual(p.fraction, last)
            last = p.fraction
        }
        p.phase = .retrying
        XCTAssertGreaterThanOrEqual(p.fraction, last); last = p.fraction
        p.phase = .media   // nothing to download: the media share is complete at once
        XCTAssertEqual(p.fraction, 1, accuracy: 0.0001)
        p.mediaTotal = 10
        p.mediaDone = 5
        XCTAssertGreaterThanOrEqual(p.fraction, 0.6)
        XCTAssertLessThan(p.fraction, 1)
        p.phase = .done
        XCTAssertEqual(p.fraction, 1)
    }

    func testRunningOnlyWhileWorking() {
        XCTAssertFalse(RelayHistoryProgress().running)
        for ph in [RelayHistoryProgress.Phase.scanning, .retrying, .media] {
            XCTAssertTrue(RelayHistoryProgress(phase: ph).running)
        }
        XCTAssertFalse(RelayHistoryProgress(phase: .done).running)
        XCTAssertFalse(RelayHistoryProgress(phase: .cancelled).running)
    }

    // MARK: summary

    func testOutcomeAddedUpToDateAndUnreachable() {
        var p = RelayHistoryProgress(phase: .done)
        p.circlesTotal = 2
        XCTAssertEqual(p.outcome, .upToDate)
        p.postsAdded = 312
        p.mediaDone = 1204
        XCTAssertEqual(p.outcome, .added(posts: 312, media: 1204))

        var q = RelayHistoryProgress(phase: .done)
        q.circlesTotal = 2
        q.relayErrors = 2
        XCTAssertEqual(q.outcome, .unreachable, "no relay answered for any circle")
        q.relayErrors = 1
        XCTAssertEqual(q.outcome, .upToDate, "one circle unreachable is a footnote, not the headline")
    }

    func testRetentionCaveatOnlyOnAFinishedRun() {
        XCTAssertTrue(RelayHistoryProgress(phase: .done).showsRetentionCaveat)
        XCTAssertFalse(RelayHistoryProgress(phase: .cancelled).showsRetentionCaveat)
        XCTAssertFalse(RelayHistoryProgress(phase: .media).showsRetentionCaveat)
    }

    // MARK: plan

    func testMergeDedupesKeysAcrossRelaysKeepingRelayOrder() {
        let m = RelayHistoryPlan.merge([
            (node: "r1", keys: ["a", "b"]),
            (node: "r2", keys: ["b", "c"]),
            (node: "r2", keys: ["b"]),
        ])
        XCTAssertEqual(m.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(m.map(\.nodes), [["r1"], ["r1", "r2"], ["r2"]])
    }

    func testBatchesAreBoundedAndCoverEverything() {
        let items = Array(0..<50)
        let b = RelayHistoryPlan.batches(items, size: 24)
        XCTAssertEqual(b.map(\.count), [24, 24, 2])
        XCTAssertEqual(b.flatMap { $0 }, items)
        XCTAssertEqual(RelayHistoryPlan.batches([Int](), size: 24).count, 0)
        XCTAssertEqual(RelayHistoryPlan.batches([1, 2], size: 0).count, 2, "size is clamped to 1")
    }

    func testWantedMediaSkipsHeldEvictedSyntheticAndDuplicatesAndHonoursConstrainedLinks() {
        let refs = ["full1", "thumb1", "geo:1,2", "held", "gone", "full1"]
        let small: Set<String> = ["thumb1"]
        let have: (String) -> Bool = { $0 == "held" }
        let evicted: (String) -> Bool = { $0 == "gone" }
        let synthetic: (String) -> Bool = { $0.hasPrefix("geo:") }
        XCTAssertEqual(RelayHistoryPlan.wanted(refs: refs, small: small, have: have, evicted: evicted,
                                               synthetic: synthetic, constrained: false), ["full1", "thumb1"])
        XCTAssertEqual(RelayHistoryPlan.wanted(refs: refs, small: small, have: have, evicted: evicted,
                                               synthetic: synthetic, constrained: true), ["thumb1"])
    }

    /// The e2e bug: a recovered photo post whose photo the ordinary ingest path had already fetched
    /// was never counted ("Added 2 posts and 0 photos and videos").
    func testLandedCountsRecoveredMediaAnotherPathAlreadyFetched() {
        let before: Set<String> = ["old", "gone"]
        let onDisk: Set<String> = ["old", "new", "new.t"]
        let refs = ["old", "gone", "new", "new.t", "new", "geo:1"]
        let small: Set<String> = ["new.t"]
        let have: (String) -> Bool = { onDisk.contains($0) }
        let synthetic: (String) -> Bool = { $0.hasPrefix("geo:") }
        let landed = RelayHistoryPlan.landed(refs: refs, small: small, before: before, have: have,
                                             synthetic: synthetic, constrained: false)
        XCTAssertEqual(landed, ["new", "new.t"], "new-to-the-feed media on disk counts once; old media never")
        XCTAssertEqual(RelayHistoryPlan.landed(refs: refs, small: small, before: before, have: have,
                                               synthetic: synthetic, constrained: true), ["new.t"])
        let wanted = RelayHistoryPlan.wanted(refs: refs, small: small, have: have, evicted: { _ in false },
                                             synthetic: synthetic, constrained: false)
        XCTAssertEqual(wanted, ["gone"])
        XCTAssertTrue(Set(landed).isDisjoint(with: wanted))

        var p = RelayHistoryProgress(phase: .done)
        p.postsAdded = 2
        p.mediaTotal = landed.count + wanted.count
        p.mediaDone = landed.count
        XCTAssertEqual(p.outcome, .added(posts: 2, media: 2))
        p.phase = .media
        XCTAssertLessThanOrEqual(p.fraction, 1)
    }
}
