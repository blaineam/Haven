import XCTest
@testable import HavenUITestHost

/// "Load history from your relays": the deep pass over every circle's mailbox, run against the
/// in-process relay. Covers the listing, the control-plane-first ingest, the journal that makes a
/// second run a no-op, cancellation and the two reasons the button is unavailable.
@MainActor
final class RelayHistoryResyncTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayHex = String(repeating: "c4", count: 32)
    private var resync: RelayHistoryResync { RelayHistoryResync.shared }

    override func setUp() async throws {
        _ = await Harness.feed()
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        resync.cancel()
        await Harness.until(FeedStore.shared, timeout: 60, "an earlier run to finish") { !self.resync.progress.running }
        resync.dismiss()
    }

    override func tearDown() async throws {
        resync.cancel()
        await Harness.until(FeedStore.shared, timeout: 60, "the run to wind down") { !self.resync.progress.running }
        removeRelay()
        wire.uninstall()
    }

    private func adoptRelay() {
        let r = RelayMailboxStore.shared
        r.add(circleId: "default", nodeHex: relayHex)
        r.setHttpInterface(relayHex, urls: [FakeWire.relayBase], token: "tok")
        RelayEnrollment.confirm(relayHex)
    }
    private func removeRelay() {
        let r = RelayMailboxStore.shared
        r.eraseNow(relayHex); r.dropErased(relayHex); r.unforget(relayHex)
        r.setDefault(nil)
    }
    /// Put everything `peer` has authored on the relay, the way their own uploads would.
    private func publish(_ peer: Peer) -> [String] {
        var keys: [String] = []
        for env in peer.engine.syncEnvelopes(circleId: "default") {
            let k = SharedStore.mailboxKeyHint(circleId: "default", env: env)
            wire.putRelay(k, env)
            keys.append(k)
        }
        return keys
    }
    private func post(_ peer: Peer, _ body: String) throws {
        _ = try peer.engine.post(circleId: "default", body: body, media: [], music: nil, retentionSecs: nil,
                                 story: false, muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
    }
    private func runToCompletion() async {
        resync.start()
        await Harness.until(FeedStore.shared, timeout: 90, "the resync to finish") {
            let p = self.resync.progress.phase
            return p == .done || p == .cancelled
        }
    }

    func testWithNoRelayBackedCircleTheButtonIsUnavailable() {
        removeRelay()
        XCTAssertEqual(resync.unavailableReason, "norelay")
        resync.start()
        XCTAssertEqual(resync.progress.phase, .idle, "start() refuses while unavailable")
    }

    func testAnAdoptedRelayMakesItAvailable() {
        adoptRelay()
        XCTAssertNil(resync.unavailableReason)
    }

    func testARunPullsAFriendsHistoryOffTheRelayAndASecondRunFindsNothingNew() async throws {
        let store = await Harness.feed()
        let dee = Peer(byte: 0xC1, name: "Dee")
        await dee.befriend(store)
        store.setActiveCircle("default")
        let tag = UUID().uuidString.prefix(6)
        try post(dee, "history one \(tag)")
        try post(dee, "history two \(tag)")
        let keys = publish(dee)
        XCTAssertFalse(keys.isEmpty)
        adoptRelay()

        await runToCompletion()
        let first = resync.progress
        XCTAssertEqual(first.phase, .done)
        XCTAssertGreaterThanOrEqual(first.entriesFound, keys.count, "every listed key the journal lacked is planned")
        XCTAssertEqual(first.entriesChecked, first.entriesFound)
        XCTAssertGreaterThanOrEqual(first.postsAdded, 2)
        XCTAssertEqual(first.circlesTotal, first.circlesDone)
        XCTAssertEqual(first.relayErrors, 0)
        XCTAssertGreaterThan(first.finishedAtMs, 0)
        XCTAssertGreaterThanOrEqual(first.finishedAtMs, first.startedAtMs)
        XCTAssertEqual(first.fraction, 1)
        if case .added(let posts, _) = first.outcome { XCTAssertGreaterThanOrEqual(posts, 2) }
        else { XCTFail("a run that brought posts reports them: \(first.outcome)") }
        await Harness.until(store, "the pulled posts reach the feed") {
            store.items.contains { $0.body == "history one \(tag)" } && store.items.contains { $0.body == "history two \(tag)" }
        }
        XCTAssertTrue(wire.requests(method: "GET").contains { $0.path.hasPrefix("/l/haven/mailbox/default") }, "the FULL listing is asked for")
        XCTAssertTrue(wire.requests(method: "GET").allSatisfy { $0.authorized }, "every read is signed")

        // The journal now knows these keys: the same relay holds them but nothing is re-fetched.
        let snap = resync.qaSnapshot
        XCTAssertGreaterThanOrEqual(snap["journal_keys"] as? Int ?? 0, keys.count)
        XCTAssertEqual(snap["state"] as? String, "done")
        func downloads(of key: String) -> Int { wire.requests(method: "GET").filter { $0.path == "/k/" + key }.count }
        let before = keys.map(downloads(of:))
        XCTAssertTrue(before.allSatisfy { $0 >= 1 }, "run one fetched every key the friend published")
        resync.dismiss()
        await runToCompletion()
        let second = resync.progress
        XCTAssertEqual(second.phase, .done)
        // Anything this device itself uploaded since the first listing is legitimately new; the friend's
        // keys are not, and none of them may be downloaded a second time.
        XCTAssertLessThan(second.entriesFound, first.entriesFound, "committed keys are skipped on a re-run")
        XCTAssertEqual(keys.map(downloads(of:)), before, "no envelope the journal already holds is downloaded twice")
    }

    func testARelayThatCannotBeListedIsCountedAsAnErrorNotACrash() async {
        _ = await Harness.feed()
        adoptRelay()
        wire.unreachable = true
        await runToCompletion()
        XCTAssertEqual(resync.progress.phase, .done)
        XCTAssertGreaterThan(resync.progress.relayErrors, 0)
        XCTAssertEqual(resync.progress.entriesFound, 0)
        XCTAssertEqual(resync.progress.outcome, .unreachable, "no relay answered, so nothing could be checked")
    }

    func testCancellingBeforeTheScanLeavesACancelledSummary() async {
        _ = await Harness.feed()
        adoptRelay()
        resync.start()
        resync.cancel()
        await Harness.until(FeedStore.shared, timeout: 60, "the run to wind down") { !self.resync.progress.running }
        XCTAssertEqual(resync.progress.phase, .cancelled)
        XCTAssertEqual(resync.progress.fraction, 1)
        resync.dismiss()
        XCTAssertEqual(resync.progress.phase, .idle, "a finished summary can be hidden")
    }

    func testDismissNeverHidesARunThatIsStillGoing() async {
        _ = await Harness.feed()
        adoptRelay()
        resync.start()
        XCTAssertTrue(resync.progress.running)
        resync.dismiss()
        XCTAssertTrue(resync.progress.running, "dismiss() is for finished summaries only")
        resync.cancel()
        await Harness.until(FeedStore.shared, timeout: 60, "the run to wind down") { !self.resync.progress.running }
    }

    func testResettingTheJournalForgetsWhatWasIngested() async throws {
        let store = await Harness.feed()
        let eli = Peer(byte: 0xC2, name: "Eli")
        await eli.befriend(store)
        try post(eli, "journal reset \(UUID().uuidString.prefix(6))")
        let keys = publish(eli)
        adoptRelay()
        await runToCompletion()
        XCTAssertGreaterThanOrEqual(resync.qaSnapshot["journal_keys"] as? Int ?? 0, keys.count)
        resync.resetJournal()
        XCTAssertEqual(resync.progress.phase, .idle)
        XCTAssertEqual(resync.qaSnapshot["journal_keys"] as? Int, 0, "a new identity must not inherit the old journal")
        await runToCompletion()
        XCTAssertGreaterThanOrEqual(resync.progress.entriesFound, keys.count, "after a reset the keys are planned again")
    }
}
