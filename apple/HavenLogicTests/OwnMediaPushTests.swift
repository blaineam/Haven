import XCTest

/// The own-device media push obeys the satellite gate, and what it holds back goes on the next pass
/// (mirrors Android's OwnMediaPushTest).
final class OwnMediaPushTests: XCTestCase {
    private let refs = ["img_full", "img_prev", "img_other"]
    private let satelliteSafe: Set<String> = ["img_prev"]

    func testUltraConstrainedPushesOnlySatelliteSafeMedia() {
        var pushed = Set<String>()
        let picked = OwnMediaPush.pick(refs, alreadyPushed: &pushed, budget: 10, eligible: { _ in true },
            mayMoveOverLink: { HeavyWorkPolicy.mayMoveOverLink(ultraConstrained: true,
                                                               satelliteSafe: self.satelliteSafe.contains($0)) })
        XCTAssertEqual(picked, ["img_prev"])
        XCTAssertFalse(pushed.contains("img_full"), "a held ref must not be marked pushed")
    }

    func testHeldMediaGoesOutOnceTheLinkImproves() {
        var pushed = Set<String>()
        _ = OwnMediaPush.pick(refs, alreadyPushed: &pushed, budget: 10, eligible: { _ in true },
                              mayMoveOverLink: { self.satelliteSafe.contains($0) })
        let later = OwnMediaPush.pick(refs, alreadyPushed: &pushed, budget: 10, eligible: { _ in true },
                                      mayMoveOverLink: { _ in true })
        XCTAssertEqual(later, ["img_full", "img_other"])
        XCTAssertTrue(pushed.isSuperset(of: refs))
    }

    func testBudgetCountsOnlySentRefsAndIneligibleRefsAreSkipped() {
        var pushed: Set<String> = ["img_full"]
        let picked = OwnMediaPush.pick(["img_full", "img_gone", "a", "b", "c"], alreadyPushed: &pushed, budget: 2,
                                       eligible: { $0 != "img_gone" }, mayMoveOverLink: { _ in true })
        XCTAssertEqual(picked, ["a", "b"])
    }
}
