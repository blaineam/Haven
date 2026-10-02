import XCTest

/// `VoipPushPolicy`: every VoIP push maps to an action that reports a call to CallKit — PushKit
/// terminates the app (`_terminateAppIfThereAreUnhandledVoIPPushes`) for any push that doesn't.
final class VoipPushPolicyTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let myDevice = String(repeating: "d", count: 64)
    private let bob = String(repeating: "b", count: 64)
    private let carol = String(repeating: "c", count: 64)

    private func state(active: Bool = false, roster: Set<String> = [], callKit: Bool = false,
                       ended: Set<String> = []) -> VoipPushCallState {
        VoipPushCallState(active: active, roster: roster, myHex: me, myDeviceHex: myDevice,
                          reportedToCallKit: callKit, recentlyEndedPeers: ended)
    }
    private func bobCalling() -> VoipPushCaller { VoipPushCaller(name: "Bob", peerHex: bob) }

    func testIdleValidPushRings() {
        XCTAssertEqual(VoipPushPolicy.decide(caller: bobCalling(), state: state()), .ring(bobCalling()))
    }

    func testMalformedPayloadsReportAndEnd() {
        XCTAssertEqual(VoipPushPolicy.decide(caller: nil, state: state()), .reportAndEnd(.malformed),
                       "undecryptable / unsigned / '_' payload")
        XCTAssertEqual(VoipPushPolicy.decide(caller: VoipPushCaller(name: "X", peerHex: ""), state: state()),
                       .reportAndEnd(.malformed))
        XCTAssertEqual(VoipPushPolicy.decide(caller: VoipPushCaller(name: "X", peerHex: "abc"), state: state()),
                       .reportAndEnd(.malformed))
        // A malformed push during a live call still has to be reported — and must not touch it.
        XCTAssertEqual(VoipPushPolicy.decide(caller: nil, state: state(active: true, roster: [bob, me], callKit: true)),
                       .reportAndEnd(.malformed))
    }

    func testOwnAccountOrDeviceNeverRings() {
        XCTAssertEqual(VoipPushPolicy.decide(caller: VoipPushCaller(name: "Me", peerHex: me), state: state()),
                       .reportAndEnd(.ownAccount))
        XCTAssertEqual(VoipPushPolicy.decide(caller: VoipPushCaller(name: "Me", peerHex: myDevice), state: state()),
                       .reportAndEnd(.ownAccount))
    }

    /// The crash: the sealed iroh invite beats the push, so the push finds us already ringing for
    /// the same call. That path used to return without reporting anything.
    func testPushForTheCallAlreadyRingingIsReported() {
        XCTAssertEqual(VoipPushPolicy.decide(caller: bobCalling(), state: state(active: true, roster: [bob, me], callKit: true)),
                       .reReportExisting)
        // Same call, but CallKit doesn't know it (simulator in-app ring) → a placeholder instead.
        XCTAssertEqual(VoipPushPolicy.decide(caller: bobCalling(), state: state(active: true, roster: [bob, me], callKit: false)),
                       .reportAndEnd(.duplicate))
    }

    func testPushFromSomeoneElseDuringACallIsBusy() {
        XCTAssertEqual(VoipPushPolicy.decide(caller: bobCalling(), state: state(active: true, roster: [carol, me], callKit: true)),
                       .reportAndEnd(.busy))
    }

    func testLatePushForAnEndedCallDoesNotReRing() {
        XCTAssertEqual(VoipPushPolicy.decide(caller: bobCalling(), state: state(ended: [bob])),
                       .reportAndEnd(.recentlyEnded))
        XCTAssertEqual(VoipPushPolicy.decide(caller: bobCalling(), state: state(ended: [carol])), .ring(bobCalling()))
    }

    func testParseOpenedPayload() {
        let ok = Data(#"{"t":"Bob","h":"\#(bob)"}"#.utf8)
        XCTAssertEqual(VoipPushCaller.parse(opened: ok), bobCalling())
        XCTAssertEqual(VoipPushCaller.parse(opened: Data(#"{"h":"\#(bob)"}"#.utf8))?.name, "Someone")
        XCTAssertEqual(VoipPushCaller.parse(opened: Data(#"{"t":"","h":"x"}"#.utf8))?.name, "Someone")
        XCTAssertNil(VoipPushCaller.parse(opened: Data("not json".utf8)))
        XCTAssertNil(VoipPushCaller.parse(opened: Data("[1,2]".utf8)))
        // Non-string fields don't make the whole push unparseable — the policy rejects the bad id.
        let weird = VoipPushCaller.parse(opened: Data(#"{"t":5,"h":7}"#.utf8))
        XCTAssertEqual(weird, VoipPushCaller(name: "Someone", peerHex: ""))
        XCTAssertEqual(VoipPushPolicy.decide(caller: weird, state: state()), .reportAndEnd(.malformed))
    }
}
