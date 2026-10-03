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

    /// The e2e: ONE recovered photo post — photo + thumb + preview, all already fetched by the
    /// ordinary ingest path — is one item, done ("Added 2 posts and 1 photo", never 0, never 3).
    func testOneRecoveredPhotoWithCompanionsIsOneItem() {
        let refs = ["p", "thumb:p:pt", "preview:p:pv"]
        let cands = RelayHistoryPlan.mediaCandidates(circle: "c", refs: refs)
        XCTAssertEqual(Set(cands.filter { !$0.ref.contains(":") }.map(\.item)), ["p"])
        let synthetic: (String) -> Bool = { $0.contains(":") }
        let plan = { (have: Set<String>, constrained: Bool) in
            RelayHistoryPlan.mediaPlan(cands, before: [], constrained: constrained, have: { have.contains($0) },
                                       evicted: { _ in false }, synthetic: synthetic)
        }
        let all = plan(["p", "pt", "pv"], false)
        XCTAssertEqual([all.landed, all.total, all.want.count], [1, 1, 0])
        var p = RelayHistoryProgress(phase: .done)
        p.postsAdded = 2; p.mediaDone = all.landed; p.mediaTotal = all.total
        XCTAssertEqual(p.outcome, .added(posts: 2, media: 1))

        // Nothing on disk yet: three refs fetched small-first, the item counts once.
        let none = plan([], false)
        XCTAssertEqual([none.landed, none.total], [0, 1])
        XCTAssertEqual(none.want.map(\.ref), ["pt", "pv", "p"])
        var tally = RelayHistoryMediaTally(none)
        let done = none.want.map { tally.record(item: $0.item, ok: true).done }.reduce(0, +)
        XCTAssertEqual(done, 1)

        // Only the full-size landed by another path: done up front, its companions never re-count.
        let full = plan(["p"], false)
        XCTAssertEqual([full.landed, full.total, full.want.count], [1, 1, 2])
        tally = RelayHistoryMediaTally(full)
        XCTAssertTrue(tally.record(item: "p", ok: true) == (0, 0))

        // Constrained: the companion alone is the item.
        let lean = plan(["pt"], true)
        XCTAssertEqual([lean.landed, lean.total, lean.want.count], [1, 1, 1])
    }

    func testMediaPlanIgnoresOldMediaAndCountsMissingItemsOnce() {
        let cands = RelayHistoryPlan.mediaCandidates(circle: "c", refs: [
            "a", "thumb:a:at", "b", "thumb:b:bt", "gone", "x", "thumb:x:xt", "geo:1,2"])
        let plan = RelayHistoryPlan.mediaPlan(
            cands, before: ["a", "at", "gone", "x", "xt"], constrained: false,
            have: { ["at", "b", "bt"].contains($0) }, evicted: { $0 == "gone" }, synthetic: { $0.contains(":") })
        XCTAssertEqual(plan.landed, 1, "old media never counts; the recovered item once")
        XCTAssertEqual(plan.total, 3)
        XCTAssertEqual(plan.want.map(\.ref), ["xt", "a", "x"])
        var tally = RelayHistoryMediaTally(plan)
        XCTAssertTrue(tally.record(item: "x", ok: false) == (0, 0), "x still has a ref to try")
        XCTAssertTrue(tally.record(item: "a", ok: true) == (1, 0))
        XCTAssertTrue(tally.record(item: "x", ok: false) == (0, 1), "every ref of x failed → one missing item")
    }
}
