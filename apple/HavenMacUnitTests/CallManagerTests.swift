import XCTest
import Combine
import WebRTC
@testable import HavenUITestHost

/// The call signalling state machine, driven by the frames FeedStore dispatches to it. No media,
/// no mic: only the invite / decline / end-elsewhere decisions that never reach WebRTC.
@MainActor
final class CallManagerTests: XCTestCase {
    private func lp(_ s: String) -> Data {
        let d = Data(s.utf8)
        var out = Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)])
        out.append(d); return out
    }
    private var cm: CallManager { CallManager.shared }

    override func setUp() async throws {
        if cm.inCall || cm.ringing || cm.connecting { cm.endCall() }
    }
    override func tearDown() async throws {
        if cm.inCall || cm.ringing || cm.connecting { cm.endCall() }
    }

    /// "The iPhone took a long time to show connected after it connected": `mediaConnected` reads
    /// `lastPeerState` / `hairpinPeers`, which are not @Published, so the label only caught up when
    /// something else republished. A change to either must announce itself to the call screen.
    func testPeerMediaStateChangesRepublishTheCallScreen() {
        var fired = 0
        let sub = cm.objectWillChange.sink { fired += 1 }
        defer { sub.cancel(); cm.lastPeerState = [:]; cm.hairpinPeers = [] }
        cm.lastPeerState = [:]; cm.hairpinPeers = []
        fired = 0
        XCTAssertFalse(cm.mediaConnected)
        cm.lastPeerState["peer"] = .connected
        XCTAssertTrue(cm.mediaConnected)
        XCTAssertEqual(fired, 1, "the ICE-connected write must re-render the screen")
        cm.lastPeerState["peer"] = .connected                       // no change → no churn
        XCTAssertEqual(fired, 1)
        cm.lastPeerState["peer"] = nil
        XCTAssertFalse(cm.mediaConnected)
        XCTAssertEqual(fired, 2)
        cm.hairpinPeers.insert("peer")                               // relayed media counts as connected
        XCTAssertTrue(cm.mediaConnected)
        XCTAssertEqual(fired, 3)
        cm.hairpinPeers.remove("peer")
        XCTAssertFalse(cm.mediaConnected)
        XCTAssertEqual(fired, 4)
    }

    func testStrangersAndMalformedInvitesNeverRing() async {
        _ = await Harness.feed()
        let stranger = String(repeating: "ab", count: 32)
        cm.handleInvite(Data(stranger.utf8) + Data("Mallory".utf8))
        XCTAssertFalse(cm.ringing)
        cm.handleInvite(Data("short".utf8))
        cm.handleInvite(Data())
        XCTAssertFalse(cm.ringing)
        cm.handleGroupInvite(Data(stranger.utf8) + lp("sid") + lp("Group") + lp(stranger))
        XCTAssertFalse(cm.ringing)
        cm.handleGroupInvite(Data("short".utf8))
        cm.handleAccept(Data(stranger.utf8))                 // no call to answer
        cm.handleHangup(Data(stranger.utf8))                 // no call to end
        cm.handleOffer(Data("junk".utf8)); cm.handleAnswer(Data("junk".utf8)); cm.handleIce(Data("junk".utf8))
        cm.handleAudio(Data()); cm.handleVideo(Data())
        cm.handleCameraState(Data("junk".utf8))
        cm.handleEndedElsewhere(Data("short".utf8))
        cm.handleHandledElsewhere(Data("short".utf8))
        XCTAssertFalse(cm.inCall); XCTAssertFalse(cm.connecting)
    }

    func testAContactRingsAndDecliningStopsItForGood() async {
        let store = await Harness.feed()
        let caller = Peer(byte: 0x61, name: "Caller")
        await caller.befriend(store)
        let sid = "legacy:\(caller.hex)"
        cm.handleInvite(Data(caller.hex.utf8) + Data("Me".utf8))
        XCTAssertTrue(cm.ringing, "a known contact's invite rings")
        XCTAssertFalse(cm.inCall)
        XCTAssertTrue(cm.participants.contains(caller.hex))
        XCTAssertEqual(cm.peerName, cm.displayName(for: caller.hex))
        // The same invite arriving again while ringing only merges the roster.
        cm.handleInvite(Data(caller.hex.utf8) + Data("Me".utf8))
        XCTAssertTrue(cm.ringing)
        // "Handled on another of my devices" from a stranger (not my account) must not silence it.
        cm.handleHandledElsewhere(Data(caller.hex.utf8) + lp(sid))
        XCTAssertTrue(cm.ringing)
        let snap = cm.qaSnapshot()
        XCTAssertEqual(snap["ringing"] as? Bool, true)
        XCTAssertEqual(snap["session"] as? String, sid)

        cm.decline()
        XCTAssertFalse(cm.ringing)
        XCTAssertFalse(cm.inCall)
        // A retransmitted invite from the call we just declined must not ring again.
        cm.handleInvite(Data(caller.hex.utf8) + Data("Me".utf8))
        XCTAssertFalse(cm.ringing, "declined sessions are remembered")
    }

    func testMyOwnAccountCanSilenceARingingCall() async {
        let store = await Harness.feed()
        let caller = Peer(byte: 0x62, name: "Caller2")
        await caller.befriend(store)
        let sid = "legacy:\(caller.hex)"
        cm.handleInvite(Data(caller.hex.utf8) + Data("Me".utf8))
        XCTAssertTrue(cm.ringing)
        // Another device of mine answered: only a frame from MY account carrying THIS session counts.
        cm.handleHandledElsewhere(Data(store.myNodeHex.utf8) + lp("someone-elses-session"))
        XCTAssertTrue(cm.ringing, "a different session id is ignored")
        cm.handleHandledElsewhere(Data(store.myNodeHex.utf8) + lp(sid))
        XCTAssertFalse(cm.ringing, "answered elsewhere: stand down")
        cm.handleInvite(Data(caller.hex.utf8) + Data("Me".utf8))
        XCTAssertFalse(cm.ringing, "…and a late retransmit can't re-ring")
    }

    func testGroupInviteMergesRosterAndEndedElsewhereTearsDown() async {
        let store = await Harness.feed()
        let host = Peer(byte: 0x63, name: "Host"), other = Peer(byte: 0x64, name: "Other")
        await host.befriend(store); await other.befriend(store)
        let sid = "grp-\(UUID().uuidString.prefix(8))"
        let ts = String(Date().timeIntervalSince1970)
        cm.handleGroupInvite(Data(host.hex.utf8) + lp(sid) + lp("Weekend") + lp(host.hex) + lp(ts))
        XCTAssertTrue(cm.ringing)
        // The same session learns of another participant.
        cm.handleGroupInvite(Data(host.hex.utf8) + lp(sid) + lp("Weekend") + lp("\(host.hex),\(other.hex)") + lp(ts))
        XCTAssertTrue(cm.participants.contains(other.hex))
        XCTAssertTrue(cm.participants.contains(host.hex))
        XCTAssertEqual(cm.peerName, cm.displayName(for: host.hex), "the title was fixed by the first invite for this session")
        // Ended on another device of mine, same session → tear down even though not answered here.
        cm.handleEndedElsewhere(Data(store.myNodeHex.utf8) + lp("other-session"))
        XCTAssertTrue(cm.ringing, "a different session is ignored")
        cm.handleEndedElsewhere(Data(store.myNodeHex.utf8) + lp(sid))
        XCTAssertFalse(cm.ringing)
    }

    func testStaleAndEmptyGroupInvitesAreDropped() async {
        let store = await Harness.feed()
        let host = Peer(byte: 0x65, name: "Host2")
        await host.befriend(store)
        let old = String(Date().timeIntervalSince1970 - 3_600)
        cm.handleGroupInvite(Data(host.hex.utf8) + lp("stale-\(UUID().uuidString.prefix(6))") + lp("Old") + lp(host.hex) + lp(old))
        XCTAssertFalse(cm.ringing, "a replayed invite older than the dialing window must not ring")
        cm.handleGroupInvite(Data(host.hex.utf8) + lp("") + lp("NoSession") + lp(host.hex))
        XCTAssertFalse(cm.ringing, "an invite without a session id is meaningless")
    }

    func testMediaStateDefaultsAreQuietWhenIdle() {
        XCTAssertFalse(cm.videoOn); XCTAssertFalse(cm.screenShareOn); XCTAssertFalse(cm.muted)
        XCTAssertTrue(cm.remoteVideoTracks.isEmpty)
        XCTAssertFalse(cm.mediaConnected)
        cm.qaNoteCallEvent("unit-test")
        XCTAssertEqual(cm.qaSnapshot()["last_event"] as? String, "unit-test")
    }
}
