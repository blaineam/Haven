import XCTest

/// The /notify storm (release gate 2026-09-30): a relay host re-offers already-seen control keys on
/// every poll by design; those must never read as "new", fan out, or push.
final class MailboxIngestTests: XCTestCase {
    private let tags: [String: UInt8] = ["k/commit": 0x03, "k/roster": 0x04, "k/post1": 0x02, "k/post2": 0x02]

    private func plan(_ keys: [String], seen: Set<String>) -> (unseen: [String], reoffered: [String]) {
        MailboxIngest.planOwnRelayScan(keys: keys, isSeen: { seen.contains($0) }, claimable: { _ in true },
                                       controlTag: { self.tags[$0] })
    }

    func testSecondPollWithNothingNewHasNothingUnseen() {
        let keys = ["k/commit", "k/roster", "k/post1", "k/post2"]
        let first = plan(keys, seen: [])
        XCTAssertEqual(first.unseen, keys)
        XCTAssertEqual(first.reoffered, [], "nothing is seen yet")
        // Everything from the first poll was ingested and marked seen.
        let second = plan(keys, seen: Set(keys))
        XCTAssertEqual(second.unseen, [], "0 new on the second poll")
        XCTAssertEqual(second.reoffered, ["k/commit", "k/roster"], "only control keys are re-offered")
    }

    func testReofferIsBounded() {
        let many = (0..<500).map { "c/\($0)" }
        let p = MailboxIngest.planOwnRelayScan(keys: many, isSeen: { _ in true }, claimable: { _ in true },
                                               controlTag: { _ in 0x04 })
        XCTAssertEqual(p.reoffered.count, MailboxIngest.controlReofferBudget)
    }

    func testRepeatsNeverFanOutOrPush() {
        // The re-offered roster comes back as a repeat: applied locally, never fanned out / pushed.
        let pass: [(String, MailboxIngest.Outcome)] = [("roster", .quietRoster), ("commit", .none),
                                                       ("post", .changed)]
        XCTAssertEqual(MailboxIngest.fanOut(pass), ["post"])
        XCTAssertEqual(MailboxIngest.fanOut([("roster", .quietRoster), ("commit", .none)]), [],
                       "a poll of re-offered control keys pushes nothing")
        XCTAssertTrue(MailboxIngest.Outcome.quietRoster.applied)
        XCTAssertFalse(MailboxIngest.Outcome.none.applied)
    }

    func testReofferedControlKeysOweNoMarkAndNoExport() {
        // Idle steady state: the pass re-ingested only already-seen control keys (quiet repeats).
        let durable: Set<String> = ["k/commit", "k/roster"]
        let owed = MailboxIngest.marksOwed(["k/commit", "k/roster"], durablySeen: { durable.contains($0) })
        XCTAssertEqual(owed, [], "their marks were paid when they first landed")
        // 100 idle polls of 33 re-offered keys never reach the deferred-mark bound → never export.
        var deferred = 0, exports = 0
        for _ in 0..<100 {
            let o = MailboxIngest.marksOwed(Array(repeating: "k/roster", count: 33), durablySeen: { durable.contains($0) })
            guard !o.isEmpty else { continue }
            if MailboxIngest.owesExport(changed: false, unlockedCircle: false, deferred: deferred, owed: o.count, cap: 64) {
                exports += 1; deferred = 0
            } else { deferred += o.count }
        }
        XCTAssertEqual(exports, 0)
    }

    func testNewDuplicateMarksStillReachDiskWithoutAnyRealChange() {
        // Genuinely unseen keys that landed nothing (duplicates / buffered) still owe their marks, and
        // with no export from anyone else the bound forces one: a stream of such passes can never
        // hold more than `cap` marks off disk.
        let cap = 64
        var deferred = 0, onDisk = 0, pending = 0
        for pass in 0..<50 {
            let keys = (0..<5).map { "new/\(pass)/\($0)" }
            let owed = MailboxIngest.marksOwed(keys, durablySeen: { _ in false })
            XCTAssertEqual(owed, keys)
            if MailboxIngest.owesExport(changed: false, unlockedCircle: false, deferred: deferred, owed: owed.count, cap: cap) {
                onDisk += pending + owed.count; pending = 0; deferred = 0
            } else {
                deferred += owed.count; pending += owed.count
            }
            XCTAssertLessThanOrEqual(pending, cap)
        }
        XCTAssertGreaterThan(onDisk, 0, "marks persisted although no pass changed the engine")
        XCTAssertEqual(onDisk + pending, 250)
    }

    func testRealChangeOrUnlockAlwaysExports() {
        XCTAssertTrue(MailboxIngest.owesExport(changed: true, unlockedCircle: false, deferred: 0, owed: 1, cap: 64))
        XCTAssertTrue(MailboxIngest.owesExport(changed: false, unlockedCircle: true, deferred: 0, owed: 1, cap: 64))
        XCTAssertFalse(MailboxIngest.owesExport(changed: false, unlockedCircle: false, deferred: 60, owed: 4, cap: 64))
        XCTAssertTrue(MailboxIngest.owesExport(changed: false, unlockedCircle: false, deferred: 60, owed: 5, cap: 64))
    }
}
