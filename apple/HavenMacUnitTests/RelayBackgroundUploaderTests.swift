import XCTest
@testable import HavenUITestHost

/// The persisted authored-event queue, against the in-process relay: what lands, what waits, what the
/// composer's sync pill is told, and that a dead relay is retried rather than forgotten.
@MainActor
final class RelayBackgroundUploaderTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayHex = String(repeating: "d7", count: 32)
    /// Its own circle: other suites leave authored events for circles with no relay in the shared queue,
    /// and those never land, so nothing here may reason about the queue as a whole.
    private let circle = "bgup-test-circle"
    private var uploader: BackgroundUploader { BackgroundUploader.shared }

    override func setUp() async throws {
        _ = await Harness.feed()
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        let r = RelayMailboxStore.shared
        r.add(circleId: circle, nodeHex: relayHex)
        r.setHttpInterface(relayHex, urls: [FakeWire.relayBase], token: "tok")
        RelayEnrollment.confirm(relayHex)
        await drain()
    }

    override func tearDown() async throws {
        wire.unreachable = false
        SharedStore.clearAllHttpUrlBad()
        await drain()
        let r = RelayMailboxStore.shared
        r.eraseNow(relayHex); r.dropErased(relayHex); r.unforget(relayHex)
        wire.uninstall()
    }

    /// Land whatever an earlier test left behind: every flush runs against a reachable wire.
    private func drain() async {
        wire.unreachable = false
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        for _ in 0..<50 {
            if !uploader.hasPending(circleId: circle) && !uploader.isFlushing { return }
            if uploader.isFlushing {
                await Harness.until(FeedStore.shared, timeout: 90, "the running pass ends") { !self.uploader.isFlushing }
            } else {
                await uploader.flush()
            }
        }
    }

    private func envelope(_ tag: String) -> Data { Data("authored-\(tag)-\(UUID().uuidString)".utf8) }
    private func key(_ env: Data) -> String { SharedStore.mailboxKeyHint(circleId: circle, env: env) }

    func testAnEnqueuedEventReachesTheRelayAndTheQueueEmpties() async {
        let env = envelope("lands")
        uploader.enqueue(circleId: circle, env: env)
        XCTAssertTrue(uploader.hasPending(circleId: circle) || wire.relayData(key(env)) != nil)
        await Harness.until(FeedStore.shared, "the event lands on the relay") { self.wire.relayData(self.key(env)) == env }
        await Harness.until(FeedStore.shared, "the circle's queue empties") { !self.uploader.hasPending(circleId: self.circle) && !self.uploader.isFlushing }
        XCTAssertEqual(uploader.progress.pending(circle), 0)
        XCTAssertTrue(wire.requests(method: "PUT", host: FakeWire.relayHost).allSatisfy(\.authorized), "every write is signed")
    }

    func testADeadRelayKeepsTheEventQueuedAndTheNextPassDeliversIt() async {
        wire.unreachable = true
        let env = envelope("dead")
        uploader.enqueue(circleId: circle, env: env)
        await Harness.until(FeedStore.shared, "the pass ends in backoff") { self.uploader.progress.backingOff }
        XCTAssertTrue(uploader.hasPending(circleId: circle))
        XCTAssertTrue(uploader.hasAnyPending)
        XCTAssertEqual(uploader.progress.pending(circle), 1)
        XCTAssertNil(wire.relayData(key(env)))
        // The relay comes back; the retry (here driven by hand — the timer is just a schedule) delivers it.
        wire.unreachable = false
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        await uploader.flush()
        XCTAssertEqual(wire.relayData(key(env)), env)
        XCTAssertFalse(uploader.hasPending(circleId: circle))
        XCTAssertEqual(uploader.progress.pending(circle), 0)
    }

    func testMaintenanceUploadsNeverShowInTheSyncPill() async {
        wire.unreachable = true
        uploader.enqueue(circleId: circle, env: envelope("head"), maintenance: true)
        await Harness.until(FeedStore.shared, "the maintenance pass has run and failed") {
            !self.uploader.isFlushing && self.uploader.hasPending(circleId: self.circle)
        }
        XCTAssertTrue(uploader.hasPending(circleId: circle), "it is still uploaded…")
        XCTAssertEqual(uploader.progress.pending(circle), 0, "…but is not something the user authored")
    }

    func testTheSyncPillCountsAuthoredMediaOnTopOfEvents() {
        uploader.setAuthoredMediaPending([circle: 3])
        XCTAssertEqual(uploader.progress.mediaPending(circle), 3)
        XCTAssertEqual(uploader.progress.totalPending(circle), 3 + uploader.progress.pending(circle))
        uploader.setAuthoredMediaPending([circle: 3])   // unchanged: no republish
        uploader.setAuthoredMediaPending([:])
        XCTAssertEqual(uploader.progress.mediaPending(circle), 0)
    }

    func testAQueueNeverGrowsPastItsCapAndTheOldestAreDropped() async {
        wire.unreachable = true
        var first: Data?
        for i in 0..<205 {
            let e = envelope("cap-\(i)")
            if i == 0 { first = e }
            uploader.enqueue(circleId: circle, env: e)
        }
        XCTAssertEqual(uploader.progress.pending(circle), 200, "205 queued, the cap keeps the newest 200")
        wire.unreachable = false
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        await drain()
        XCTAssertFalse(uploader.hasPending(circleId: circle))
        XCTAssertNil(wire.relayData(key(first!)), "the oldest was evicted, never uploaded")
        XCTAssertEqual(wire.relayKeys(prefix: "haven/mailbox/\(circle)/").count, 200)
    }

    func testFlushWithNothingQueuedDoesNothing() async {
        let before = wire.requests().count
        await uploader.flush()
        XCTAssertEqual(wire.requests().count, before)
        XCTAssertFalse(uploader.isFlushing)
    }
}
