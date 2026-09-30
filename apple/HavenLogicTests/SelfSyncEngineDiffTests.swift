import XCTest

/// A self-sync merge owes an ENGINE export only when an engine-applied record changed — a relay
/// re-adopted by a linked device rewrites the `circle:` record but not the engine.
final class SelfSyncEngineDiffTests: XCTestCase {
    /// Test encoding of a circle record: "name|members|creator|relays".
    private func rec(_ name: String, _ members: String, relays: String) -> Data {
        Data("\(name)|\(members)|c|\(relays)".utf8)
    }
    private func view(_ d: Data) -> AnyHashable? {
        let parts = String(decoding: d, as: UTF8.self).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        return AnyHashable(parts.prefix(3).joined(separator: "|"))
    }
    private func differs(_ a: [String: Data], _ b: [String: Data]) -> Bool {
        SelfSyncEngineDiff.differs(a, b, circleEngineView: view)
    }

    func testRelayOnlyChangeInACircleRecordIsNotAnEngineChange() {
        XCTAssertFalse(differs(["circle:c1": rec("Fam", "a,b", relays: "")],
                               ["circle:c1": rec("Fam", "a,b", relays: "fe26")]))
    }

    func testNameMembersAndNewCirclesAre() {
        XCTAssertTrue(differs(["circle:c1": rec("Fam", "a,b", relays: "")], ["circle:c1": rec("Family", "a,b", relays: "")]))
        XCTAssertTrue(differs(["circle:c1": rec("Fam", "a", relays: "")], ["circle:c1": rec("Fam", "a,b", relays: "")]))
        XCTAssertTrue(differs([:], ["circle:c2": rec("New", "a", relays: "")]))
    }

    func testOtherEngineNamespacesCompareRawAndTheRestIsIgnored() {
        XCTAssertTrue(differs(["roster:x": Data([1])], ["roster:x": Data([2])]))
        XCTAssertTrue(differs([:], ["circle-deleted:c1": Data([1])]))
        XCTAssertFalse(differs(["profile:name": Data([1]), "relay-cleared:x": Data([1])],
                               ["profile:name": Data([2]), "relay-cleared:x": Data([2])]))
    }

    func testUndecodableCircleRecordFallsBackToBytes() {
        XCTAssertTrue(differs(["circle:c1": Data([1])], ["circle:c1": Data([2])]))
    }
}
