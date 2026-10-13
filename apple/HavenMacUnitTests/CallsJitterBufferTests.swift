import XCTest
@testable import HavenUITestHost

/// The relay's audio reorder window: shallow on purpose (a voice call values latency over gap-free
/// playout), but it must never stall for good behind a frame that is not coming.
@MainActor
final class CallsJitterBufferTests: XCTestCase {
    func testTheJitterBufferHoldsUntilItHasADepthThenReleasesInOrder() {
        var j = JitterBuffer()
        XCTAssertTrue(j.push(seq: 10, payload: Data([10])).isEmpty)
        XCTAssertTrue(j.push(seq: 12, payload: Data([12])).isEmpty, "two frames are not yet enough to start playing")
        let out = j.push(seq: 11, payload: Data([11]))
        XCTAssertEqual(out, [Data([10]), Data([11]), Data([12])], "released in sequence order")
        XCTAssertEqual(j.push(seq: 13, payload: Data([13])), [Data([13])], "then each in-order frame plays at once")
    }

    func testALostFrameLeavesAGapTheBufferEventuallySkips() {
        var j = JitterBuffer()
        _ = j.push(seq: 1, payload: Data([1])); _ = j.push(seq: 2, payload: Data([2]))
        XCTAssertEqual(j.push(seq: 3, payload: Data([3])).count, 3)
        // Frame 4 never arrives; later frames pile up behind the hole…
        var released: [Data] = []
        for s in UInt16(5)...UInt16(20) { released += j.push(seq: s, payload: Data([UInt8(s)])) }
        XCTAssertFalse(released.isEmpty, "…until the window overflows and playback resumes past the gap")
        XCTAssertEqual(released.first, Data([5]))
        XCTAssertEqual(released.last, Data([20]))
    }

    func testTheSequenceNumberWrapsAround() {
        var j = JitterBuffer()
        _ = j.push(seq: 65534, payload: Data([1])); _ = j.push(seq: 65535, payload: Data([2]))
        XCTAssertEqual(j.push(seq: 0, payload: Data([3])), [Data([1]), Data([2]), Data([3])])
        XCTAssertEqual(j.push(seq: 1, payload: Data([4])), [Data([4])])
    }

    func testResetForgetsEverythingHeld() {
        var j = JitterBuffer()
        _ = j.push(seq: 1, payload: Data([1])); _ = j.push(seq: 2, payload: Data([2]))
        j.reset()
        XCTAssertTrue(j.push(seq: 100, payload: Data([9])).isEmpty, "a new stream starts from scratch")
    }

    func testALateOrDuplicateFrameBehindThePlayheadIsDropped() {
        var j = JitterBuffer()
        _ = j.push(seq: 1, payload: Data([1])); _ = j.push(seq: 2, payload: Data([2]))
        XCTAssertEqual(j.push(seq: 3, payload: Data([3])).count, 3)   // 1...3 played; the playhead is at 4
        XCTAssertTrue(j.push(seq: 2, payload: Data([2])).isEmpty, "a duplicate of a frame already played")
        XCTAssertTrue(j.push(seq: 1, payload: Data([1])).isEmpty, "a straggler older than the playhead")
        XCTAssertEqual(j.push(seq: 4, payload: Data([4])), [Data([4])], "…neither disturbs what follows")
        XCTAssertEqual(j.push(seq: 5, payload: Data([5])), [Data([5])])
    }
}
