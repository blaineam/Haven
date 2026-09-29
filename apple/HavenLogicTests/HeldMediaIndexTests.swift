import XCTest

/// The held-media index answers "is this file on disk?" from memory for files it has seen, and
/// never claims a file is ABSENT without looking.
final class HeldMediaIndexTests: XCTestCase {
    func testPositiveAnswersAreRememberedNegativesAreNot() {
        let index = HeldMediaIndex()
        var probes = 0
        XCTAssertFalse(index.held("img_a.jpg") { probes += 1; return false })
        XCTAssertFalse(index.held("img_a.jpg") { probes += 1; return false })
        XCTAssertEqual(probes, 2, "a miss must re-check the disk every time — the file may have just landed")

        XCTAssertTrue(index.held("img_a.jpg") { probes += 1; return true })
        XCTAssertTrue(index.held("img_a.jpg") { probes += 1; return false })
        XCTAssertEqual(probes, 3, "once seen on disk, answered from memory")
    }

    func testRemoveAndResetForgetTheFile() {
        let index = HeldMediaIndex()
        index.insert("vid_b.mp4")
        index.insert("img_c.jpg")
        XCTAssertTrue(index.contains("vid_b.mp4"))
        index.remove("vid_b.mp4")
        XCTAssertFalse(index.held("vid_b.mp4") { false }, "a deleted blob must be looked for again")
        XCTAssertEqual(index.count, 1)
        index.removeAll()
        XCTAssertFalse(index.contains("img_c.jpg"))
    }

    func testConcurrentUse() {
        let index = HeldMediaIndex()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            index.insert("img_\(i % 100).jpg")
            _ = index.contains("img_\(i % 50).jpg")
            if i % 7 == 0 { index.remove("img_\(i % 100).jpg") }
        }
        XCTAssertLessThanOrEqual(index.count, 100)
    }
}
