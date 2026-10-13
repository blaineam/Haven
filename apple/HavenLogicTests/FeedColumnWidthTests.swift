import XCTest

/// The feed column cap, against real device sizes. Phones must come out unchanged.
final class FeedColumnWidthTests: XCTestCase {
    func testPhonesAreUncapped() {
        for w in [320, 375, 390, 393, 402, 430, 440] as [CGFloat] {   // SE .. Pro Max
            XCTAssertEqual(FeedColumnWidth.column(forAvailable: w), w)
            XCTAssertFalse(FeedColumnWidth.isCapped(forAvailable: w))
        }
    }

    func testWideCanvasesAreCappedAndCentered() {
        // iPad mini/11"/13" portrait + landscape, Duo inner panel, typical Mac window.
        for w in [744, 820, 1024, 1032, 1366, 951, 1200] as [CGFloat] {
            XCTAssertEqual(FeedColumnWidth.column(forAvailable: w), FeedColumnWidth.maxColumn)
            XCTAssertTrue(FeedColumnWidth.isCapped(forAvailable: w))
        }
    }

    func testBoundaryAndDegenerateInput() {
        XCTAssertEqual(FeedColumnWidth.column(forAvailable: FeedColumnWidth.maxColumn), FeedColumnWidth.maxColumn)
        XCTAssertFalse(FeedColumnWidth.isCapped(forAvailable: FeedColumnWidth.maxColumn))
        XCTAssertEqual(FeedColumnWidth.column(forAvailable: 0), FeedColumnWidth.maxColumn)
        XCTAssertEqual(FeedColumnWidth.column(forAvailable: .infinity), FeedColumnWidth.maxColumn)
    }
}
