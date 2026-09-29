import XCTest

/// `RosterEcho`: a byte-identical device roster re-delivered by every hello reply must read as
/// "nothing new" — it used to cost a whole-engine export, an own-device fan-out and a push each time.
final class RosterEchoTests: XCTestCase {
    private let roster = Data([0x04] + Array(repeating: UInt8(7), count: 64))

    func testFirstCopyIsNewRepeatsAreNot() {
        var e = RosterEcho()
        XCTAssertFalse(e.isRepeat(roster), "the first copy goes to the engine")
        XCTAssertTrue(e.isRepeat(roster))
        XCTAssertTrue(e.isRepeat(roster))
        var resigned = roster; resigned[5] = 9
        XCTAssertFalse(e.isRepeat(resigned), "a re-signed roster is new bytes")
    }

    func testForgetLetsARefusedCopyBeRetried() {
        var e = RosterEcho()
        XCTAssertFalse(e.isRepeat(roster))
        e.forget(roster)
        XCTAssertFalse(e.isRepeat(roster), "a refused receive must not blacklist the bytes")
    }

    func testBoundedOldestForgottenFirst() {
        var e = RosterEcho()
        let first = Data([0x04, 0, 0, 0])
        XCTAssertFalse(e.isRepeat(first))
        for i in 0..<RosterEcho.cap {
            XCTAssertFalse(e.isRepeat(Data([0x04, 1, UInt8(i & 0xff), UInt8(i >> 8)])))
        }
        XCTAssertFalse(e.isRepeat(first), "evicted past the cap → treated as new again")
    }
}
