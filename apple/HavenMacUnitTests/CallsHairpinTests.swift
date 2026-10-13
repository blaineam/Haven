import XCTest
@testable import HavenUITestHost

/// The call-media hairpin's own rules: how a relay control line pairs a remote, what happens to a
/// binary frame, and where the public origin comes from. No socket is opened (HAVEN_NO_NET).
@MainActor
final class CallsHairpinTests: XCTestCase {
    private var hairpin: CallHairpin { CallHairpin.shared }
    private let remote = String(repeating: "9d", count: 32)
    private let me = String(repeating: "1f", count: 32)
    private let derpKey = "haven.fabric.derpUrls"
    private var savedDerp: Any?
    private var paired: [String] = []
    private var binary: [(String, Data)] = []

    override func setUp() async throws {
        Harness.assertIsolatedHost()
        savedDerp = UserDefaults.standard.object(forKey: derpKey)
        hairpin.closeAll()
        paired = []; binary = []
        hairpin.onPaired = { [unowned self] in self.paired.append($0) }
        hairpin.onBinary = { [unowned self] r, d in self.binary.append((r, d)) }
    }
    override func tearDown() async throws {
        hairpin.closeAll()
        hairpin.onPaired = nil; hairpin.onBinary = nil; hairpin.outboundTap = nil
        if let savedDerp { UserDefaults.standard.set(savedDerp, forKey: derpKey) }
        else { UserDefaults.standard.removeObject(forKey: derpKey) }
    }

    func testAPairedLineMarksTheRemotePairedOnceAndFiresTheCallbackOnce() {
        XCTAssertFalse(hairpin.isPaired(remote))
        hairpin.handleMessage(.string(#"{"paired":true}"#), remote: remote)
        XCTAssertTrue(hairpin.isPaired(remote))
        XCTAssertEqual(paired, [remote])
        hairpin.handleMessage(.string(#"{"paired":true}"#), remote: remote)
        XCTAssertEqual(paired, [remote], "the media bridge starts pushing frames exactly once")
    }

    func testAnOkWithoutWaitingPairsButAnOkThatIsWaitingDoesNot() {
        hairpin.handleMessage(.string(#"{"ok":true,"waiting":true}"#), remote: remote)
        XCTAssertFalse(hairpin.isPaired(remote), "the relay joined us but the far side is not there yet")
        hairpin.handleMessage(.string(#"{"ok":true}"#), remote: remote)
        XCTAssertTrue(hairpin.isPaired(remote))
        let other = String(repeating: "aa", count: 32)
        hairpin.handleMessage(.string(#"{"ok":true,"waiting":false}"#), remote: other)
        XCTAssertTrue(hairpin.isPaired(other))
        XCTAssertEqual(Set(paired), [remote, other])
    }

    func testErrorsGarbageAndOtherShapesNeverPair() {
        hairpin.handleMessage(.string(#"{"err":"session full"}"#), remote: remote)
        hairpin.handleMessage(.string("not json"), remote: remote)
        hairpin.handleMessage(.string("[1,2]"), remote: remote)
        hairpin.handleMessage(.string(#"{"paired":"yes"}"#), remote: remote)
        hairpin.handleMessage(.string(#"{"ok":false}"#), remote: remote)
        XCTAssertFalse(hairpin.isPaired(remote))
        XCTAssertTrue(paired.isEmpty)
    }

    func testBinaryFramesAreHandedToTheMediaBridgeUntouched() {
        let frame = Data([2, 0, 1, 0, 0, 0, 0, 0xFF])
        hairpin.handleMessage(.data(frame), remote: remote)
        XCTAssertEqual(binary.count, 1)
        XCTAssertEqual(binary.first?.0, remote)
        XCTAssertEqual(binary.first?.1, frame)
        hairpin.onBinary = nil
        hairpin.handleMessage(.data(frame), remote: remote)   // nobody listening: dropped, no crash
    }

    func testSendsGoOnlyToAPairedRemoteButTheTapSeesEveryAttempt() {
        var tapped: [String] = []
        hairpin.outboundTap = { r, _ in tapped.append(r) }
        hairpin.send(remote: remote, Data([1]))     // not paired, no task: silently dropped
        hairpin.handleMessage(.string(#"{"paired":true}"#), remote: remote)
        hairpin.send(remote: remote, Data([2]))     // paired but no socket (offline): still dropped, never a crash
        XCTAssertEqual(tapped, [remote, remote])
    }

    func testClosingForgetsPairingAndCloseAllForgetsEveryone() {
        let other = String(repeating: "bb", count: 32)
        hairpin.handleMessage(.string(#"{"paired":true}"#), remote: remote)
        hairpin.handleMessage(.string(#"{"paired":true}"#), remote: other)
        hairpin.close(remote: remote)
        XCTAssertFalse(hairpin.isPaired(remote))
        XCTAssertTrue(hairpin.isPaired(other))
        hairpin.closeAll()
        XCTAssertFalse(hairpin.isPaired(other))
        hairpin.close(remote: "never-opened")
    }

    func testOpeningIsRefusedOfflineAndOnABadRoster() {
        hairpin.open(sessionId: "s", me: me, remote: remote)
        hairpin.openForRoster(sessionId: "s", me: me, others: [remote, me, ""])
        hairpin.open(sessionId: "", me: me, remote: remote)
        hairpin.open(sessionId: "s", me: me, remote: me)
        XCTAssertFalse(hairpin.isPaired(remote), "HAVEN_NO_NET: no WSS to the path proxy")
    }

    func testThePublicOriginIsTheFirstHttpFabricUrl() {
        UserDefaults.standard.removeObject(forKey: derpKey)
        XCTAssertNil(CallHairpin.fabricBase())
        UserDefaults.standard.set(["relay-only-id", "wss://nope.example.com", "https://derp.example.com", "http://second.example.com"], forKey: derpKey)
        XCTAssertEqual(CallHairpin.fabricBase(), "https://derp.example.com")
        UserDefaults.standard.set(["ftp://x"], forKey: derpKey)
        XCTAssertNil(CallHairpin.fabricBase())
        UserDefaults.standard.set(["http://lan.example.com"], forKey: derpKey)
        XCTAssertEqual(CallHairpin.fabricBase(), "http://lan.example.com")
    }

    func testOpeningTracksOneSocketPerRemoteUntilItIsClosed() {
        // A closed loopback port: nothing is ever reached, so the socket never pairs — but `open` has
        // built the join, started reading, and must keep one socket per remote.
        UserDefaults.standard.set(["http://127.0.0.1:1"], forKey: derpKey)
        CallHairpin.testAllowOffline = true
        defer { CallHairpin.testAllowOffline = false }
        hairpin.open(sessionId: "s", me: me, remote: remote)
        XCTAssertEqual(hairpin.qaOpenRemotes, [remote], "the socket is tracked while it opens")
        hairpin.open(sessionId: "s", me: me, remote: remote)   // already open: kept, not duplicated
        XCTAssertEqual(hairpin.qaOpenRemotes, [remote])
        let other = String(repeating: "cc", count: 32)
        hairpin.openForRoster(sessionId: "s", me: me, others: [other, me])   // never dials itself
        XCTAssertEqual(hairpin.qaOpenRemotes, [remote, other])
        XCTAssertFalse(hairpin.isPaired(remote))
        hairpin.close(remote: remote)
        XCTAssertEqual(hairpin.qaOpenRemotes, [other])
        hairpin.closeAll()
        XCTAssertTrue(hairpin.qaOpenRemotes.isEmpty)
    }

    func testNothingIsDialledWithoutAFabricOrigin() {
        UserDefaults.standard.removeObject(forKey: derpKey)
        CallHairpin.testAllowOffline = true
        defer { CallHairpin.testAllowOffline = false }
        hairpin.openForRoster(sessionId: "s", me: me, others: [remote, me, ""])
        XCTAssertTrue(hairpin.qaOpenRemotes.isEmpty, "no public HTTPS origin: no hairpin")
        hairpin.open(sessionId: "", me: me, remote: remote)
        hairpin.open(sessionId: "s", me: "", remote: remote)
        hairpin.open(sessionId: "s", me: me, remote: "")
        hairpin.open(sessionId: "s", me: me, remote: me)
        XCTAssertTrue(hairpin.qaOpenRemotes.isEmpty)
    }
}
