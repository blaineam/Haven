import XCTest
@testable import HavenUITestHost

/// The "your circle is big enough to want a relay" gate: >2 other members, no relay of the circle's
/// OWN, not already hosting, and not waved away.
@MainActor
final class RelayNudgeStoreTests: XCTestCase {
    private var nudge: RelayNudgeStore { RelayNudgeStore.shared }
    private let relayHex = String(repeating: "f3", count: 32)

    override func setUp() async throws {
        _ = await Harness.feed()
        nudge.wipe()
    }
    override func tearDown() async throws {
        let r = RelayMailboxStore.shared
        r.eraseNow(relayHex); r.dropErased(relayHex); r.unforget(relayHex)
        r.setDefault(nil)
        nudge.wipe()
        if RelayHost.shared.enabled { RelayHost.shared.setEnabled(false) }
    }

    private func growCircle(to others: Int) async {
        let store = FeedStore.shared
        for i in 0..<others {
            let p = Peer(byte: UInt8(0xD0 + i), name: "Nudge \(i)")
            await p.befriend(store)
        }
        await Harness.until(store, "the circle to list the new members") {
            store.memberHexes(circleId: "default").count > RelayNudgeStore.connectionThreshold
        }
    }

    func testDismissalIsPerCircleAndFinalUntilAFactoryReset() {
        XCTAssertFalse(nudge.isDismissed("a"))
        nudge.dismiss("a")
        XCTAssertTrue(nudge.isDismissed("a"))
        XCTAssertFalse(nudge.isDismissed("b"), "another circle is unaffected")
        nudge.wipe()
        XCTAssertFalse(nudge.isDismissed("a"))
        XCTAssertEqual(RelayNudgeStore.connectionThreshold, 2)
    }

    func testNeverShownForAnEmptyOrUnknownCircle() {
        XCTAssertFalse(nudge.shouldShow(for: ""))
        XCTAssertFalse(nudge.shouldShow(for: "no-such-circle"), "no members, nothing to nudge about")
    }

    func testShownOnceTheCircleOutgrowsAPairAndHasNoRelayOfItsOwn() async {
        await growCircle(to: 3)
        XCTAssertGreaterThan(FeedStore.shared.memberHexes(circleId: "default").count, RelayNudgeStore.connectionThreshold)
        XCTAssertTrue(nudge.shouldShow(for: "default"))
        nudge.dismiss("default")
        XCTAssertFalse(nudge.shouldShow(for: "default"), "waved away for good")
    }

    func testACirclesOwnActiveRelaySatisfiesItButAnInheritedDefaultDoesNot() async {
        await growCircle(to: 3)
        let r = RelayMailboxStore.shared
        r.add(circleId: "default", nodeHex: relayHex)
        r.setDefault(nil)
        XCTAssertFalse(nudge.shouldShow(for: "default"), "an explicit active relay is the circle's own")
        r.forget(nodeHex: relayHex)
        XCTAssertTrue(nudge.shouldShow(for: "default"), "a deactivated relay no longer counts")
        r.restore(nodeHex: relayHex)
        r.reactivate(relayHex)
        XCTAssertFalse(nudge.shouldShow(for: "default"))
        r.eraseNow(relayHex)
        r.setDefault(relayHex)
        XCTAssertTrue(nudge.shouldShow(for: "default"), "the all-circles default is a global setting, not a mailbox somebody here runs")
    }

    func testAHostThatIsAlreadyRelayingNeedsNoNudge() async {
        await growCircle(to: 3)
        XCTAssertTrue(nudge.shouldShow(for: "default"))
        RelayHost.shared.setEnabled(true)   // offline: enabled, never serving — the toggle alone counts
        XCTAssertFalse(nudge.shouldShow(for: "default"))
        RelayHost.shared.setEnabled(false)
        XCTAssertTrue(nudge.shouldShow(for: "default"))
    }
}
