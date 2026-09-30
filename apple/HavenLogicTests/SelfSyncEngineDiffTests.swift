import XCTest

/// A self-sync apply that re-applies unchanged circles must read as "engine unchanged".
final class SelfSyncEngineDiffTests: XCTestCase {
    private func shape(_ c: [String: String], _ m: [String: [String]]) -> SelfSyncEngineDiff.Shape {
        SelfSyncEngineDiff.Shape(circles: c, members: m.mapValues(Set.init))
    }

    func testIdempotentReapplyIsNoChange() {
        XCTAssertEqual(shape(["c1": "Fam"], ["c1": ["a", "b"]]), shape(["c1": "Fam"], ["c1": ["b", "a"]]),
                       "member listing order is not a change")
    }

    func testRealChangesAreDetected() {
        let base = shape(["c1": "Fam"], ["c1": ["a"]])
        XCTAssertNotEqual(base, shape(["c1": "Family"], ["c1": ["a"]]), "rename")
        XCTAssertNotEqual(base, shape(["c1": "Fam"], ["c1": ["a", "b"]]), "member added")
        XCTAssertNotEqual(base, shape(["c1": "Fam", "c2": "New"], ["c1": ["a"], "c2": []]), "circle created")
        XCTAssertNotEqual(base, shape([:], [:]), "circle left")
    }
}
