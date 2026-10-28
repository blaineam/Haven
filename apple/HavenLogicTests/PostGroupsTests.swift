import XCTest

final class PostGroupsTests: XCTestCase {
    private func fresh() -> PostGroups {
        let d = UserDefaults(suiteName: "PostGroupsTests-\(UUID().uuidString)")!
        return PostGroups(defaults: d)
    }
    private typealias M = PostGroups.Member

    func testRegisteredOnlyWhenMoreThanOneCircle() {
        let g = fresh()
        g.register([M(circleId: "a", eventId: "e1")])
        XCTAssertTrue(g.siblings(circleId: "a", eventId: "e1").isEmpty)
        // Same circle twice is still one circle.
        g.register([M(circleId: "a", eventId: "e1"), M(circleId: "a", eventId: "e2")])
        XCTAssertTrue(g.siblings(circleId: "a", eventId: "e1").isEmpty)
        g.register([M(circleId: "a", eventId: "e1"), M(circleId: "b", eventId: "e2")])
        XCTAssertEqual(g.siblings(circleId: "a", eventId: "e1"), [M(circleId: "b", eventId: "e2")])
    }

    func testEditFansOutToEverySiblingWithItsOwnTarget() {
        let g = fresh()
        g.register([M(circleId: "a", eventId: "ea"), M(circleId: "b", eventId: "eb"), M(circleId: "c", eventId: "ec")])
        // Editing from any copy yields the OTHER copies, each with its own event id.
        XCTAssertEqual(g.siblings(circleId: "b", eventId: "eb"),
                       [M(circleId: "a", eventId: "ea"), M(circleId: "c", eventId: "ec")])
        XCTAssertEqual(g.siblings(circleId: "c", eventId: "ec").map(\.eventId), ["ea", "eb"])
        // An unrelated post, or the right id in the wrong circle, has no group.
        XCTAssertTrue(g.siblings(circleId: "a", eventId: "zzz").isEmpty)
        XCTAssertTrue(g.siblings(circleId: "b", eventId: "ea").isEmpty)
    }

    func testSiblingInMissingCircleIsSkipped() {
        let g = fresh()
        g.register([M(circleId: "a", eventId: "ea"), M(circleId: "b", eventId: "eb"), M(circleId: "c", eventId: "ec")])
        XCTAssertEqual(g.siblings(circleId: "a", eventId: "ea", liveCircleIds: ["a", "c"]), [M(circleId: "c", eventId: "ec")])
    }

    func testSingleCirclePostUnaffected() {
        let g = fresh()
        g.register([M(circleId: "a", eventId: "ea")])
        XCTAssertTrue(g.siblings(circleId: "a", eventId: "ea").isEmpty)
    }

    func testCapEvictsOldest() {
        let g = fresh()
        for i in 0..<(PostGroups.cap + 3) {
            g.register([M(circleId: "a", eventId: "a\(i)"), M(circleId: "b", eventId: "b\(i)")])
        }
        XCTAssertTrue(g.siblings(circleId: "a", eventId: "a0").isEmpty)
        XCTAssertTrue(g.siblings(circleId: "a", eventId: "a2").isEmpty)
        XCTAssertFalse(g.siblings(circleId: "a", eventId: "a3").isEmpty)
        XCTAssertFalse(g.siblings(circleId: "a", eventId: "a\(PostGroups.cap + 2)").isEmpty)
    }

    func testPersistsAcrossInstances() {
        let d = UserDefaults(suiteName: "PostGroupsTests-\(UUID().uuidString)")!
        PostGroups(defaults: d).register([M(circleId: "a", eventId: "ea"), M(circleId: "b", eventId: "eb")])
        XCTAssertEqual(PostGroups(defaults: d).siblings(circleId: "a", eventId: "ea").count, 1)
    }

    func testStaggerGivesDistinctTimestamps() {
        let ts = (0..<5).map { PostGroups.stagger(base: 1_000, index: $0) }
        XCTAssertEqual(Set(ts).count, 5)
        XCTAssertEqual(ts.first, 1_000)
    }

    func testSelectAllToggle() {
        let all = ["a", "b", "c"]
        XCTAssertFalse(MultiCirclePost.allSelected(["a"], of: all))
        XCTAssertEqual(MultiCirclePost.toggleAll(["a"], of: all), ["a", "b", "c"])
        XCTAssertTrue(MultiCirclePost.allSelected(["a", "b", "c"], of: all))
        XCTAssertEqual(MultiCirclePost.toggleAll(["a", "b", "c"], of: all), [])
        XCTAssertFalse(MultiCirclePost.allSelected([], of: []))
    }
}
