import XCTest

/// The bell's pull window on a demo launch. HAVEN_DEMO seeds a new synthetic engine each launch with
/// events stamped relative to now (the "coffee after?" DM is 295 minutes old); restoring the
/// watermark some earlier run left on disk asked that engine only for the last hour before it, so
/// Activity lost every DM row (HavenUITests.testActivityRowOpensDMAfterItWasOpenedAndPopped).
final class ActivityPersistenceTests: XCTestCase {
    private let minute: UInt64 = 60_000

    func testDemoLaunchIsEphemeral() {
        XCTAssertFalse(ActivityPersistence.isPersistent(isDemo: true))
        XCTAssertTrue(ActivityPersistence.isPersistent(isDemo: false))
    }

    func testDemoLaunchPullsTheSeededBacklogDespiteAFreshWatermarkOnDisk() {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let lastRunWatermark = Double(now - 6 * minute)   // an e2e / earlier run moments ago
        let seededDM = now - 295 * minute

        let demo = ActivityPersistence.restoredWatermark(
            stored: lastRunWatermark, persistent: ActivityPersistence.isPersistent(isDemo: true))
        XCTAssertEqual(demo, 0)
        XCTAssertLessThanOrEqual(ActivityPersistence.pullSince(watermark: demo), seededDM,
                                 "a demo launch must ask its fresh engine for the seeded DM")

        // The real account keeps its incremental window (and that window would have missed it).
        let real = ActivityPersistence.restoredWatermark(stored: lastRunWatermark, persistent: true)
        XCTAssertEqual(real, UInt64(lastRunWatermark))
        XCTAssertGreaterThan(ActivityPersistence.pullSince(watermark: real), seededDM)
    }

    func testPullWindowOverlapsAnHourAndNeverUnderflows() {
        XCTAssertEqual(ActivityPersistence.pullSince(watermark: 0), 0)
        XCTAssertEqual(ActivityPersistence.pullSince(watermark: 30 * minute), 0)
        XCTAssertEqual(ActivityPersistence.pullSince(watermark: 200 * minute), 140 * minute)
        XCTAssertEqual(ActivityPersistence.restoredWatermark(stored: -5, persistent: true), 0)
    }
}
