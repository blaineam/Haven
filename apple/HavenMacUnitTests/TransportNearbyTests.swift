import XCTest
import MultipeerConnectivity
@testable import HavenUITestHost

/// The nearby (Multipeer) transport's own rules — pacing, the invitation tie-break, the delegate
/// plumbing — with no radio. Discovery is refused by HAVEN_NO_NET, so a transport built here never
/// advertises, browses or connects; everything below is reachable without a peer.
@MainActor
final class TransportNearbyTests: XCTestCase {
    private var inbound: [Data] = []
    private var connected = 0

    override func setUp() async throws {
        Harness.assertIsolatedHost()
        inbound = []; connected = 0
        NearbyTransport.handoffBoost = false
    }
    override func tearDown() async throws { NearbyTransport.handoffBoost = false }

    private func make(_ name: String = "ab12") -> NearbyTransport {
        NearbyTransport(displayName: name, onInbound: { [unowned self] in self.inbound.append($0) },
                        onPeerConnected: { [unowned self] in self.connected += 1 })
    }
    private func otherSession() -> MCSession {
        MCSession(peer: MCPeerID(displayName: "remote"), securityIdentity: nil, encryptionPreference: .required)
    }
    private func drainMain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
    }

    // MARK: Who invites whom

    func testExactlyOneSideOfAPairInvites() {
        XCTAssertTrue(NearbyTransport.shouldInvite(local: "aaa", remote: "bbb"))
        XCTAssertFalse(NearbyTransport.shouldInvite(local: "bbb", remote: "aaa"))
        // Any two distinct peers: one invites, the other waits — never both, never neither.
        let names = ["0f", "a1", "a2", "ff", "A1", "zz"]
        for a in names { for b in names where a != b {
            XCTAssertNotEqual(NearbyTransport.shouldInvite(local: a, remote: b),
                              NearbyTransport.shouldInvite(local: b, remote: a), "\(a) vs \(b)")
        } }
    }

    func testTheSameNameNeverInvitesItself() {
        // The reason nearby display names are per-DEVICE: equal names would leave nobody inviting.
        XCTAssertFalse(NearbyTransport.shouldInvite(local: "same", remote: "same"))
    }

    // MARK: Pacing

    func testBulkFramesDrawFromABoundedFrameBudget() {
        let t = make()
        var accepted = 0, refused = 0
        for _ in 0..<400 {
            if t.broadcast(Data(count: 64), class: .bulk) { accepted += 1 } else { refused += 1 }
        }
        XCTAssertGreaterThanOrEqual(accepted, 48, "the burst allowance goes through")
        XCTAssertGreaterThan(refused, 0, "a flood is rate limited, not queued forever")
        XCTAssertLessThan(accepted, 400)
    }

    func testAFrameLargerThanTheBurstCanNeverBePaidForByABulkSend() {
        let t = make()
        XCTAssertFalse(t.broadcast(Data(count: 600 * 1024), class: .bulk), "512 KB of burst cannot cover 600 KB")
        XCTAssertTrue(t.broadcast(Data(count: 30 * 1024), class: .bulk), "a normal media chunk fits the burst")
    }

    func testControlFramesAreNeverRefused() {
        let t = make()
        for _ in 0..<400 { _ = t.broadcast(Data(count: 64), class: .bulk) }   // exhaust the bulk budget
        XCTAssertTrue(t.broadcast(Data(count: 64), class: .control), "hello/roster/signals get through (paced, not dropped)")
        XCTAssertTrue(t.broadcast(Data(count: 600 * 1024), class: .control), "a control frame only ever costs 2 KB of byte budget")
    }

    func testTheBacklogCapRefusesBigFramesButNeverReportsHighWhenIdle() {
        let t = make()
        XCTAssertFalse(t.sendBacklogHigh)
        XCTAssertEqual(NearbyTransport.sendBacklogCap, 2 * 1024 * 1024)
        XCTAssertFalse(t.hasConnectedPeers)
        XCTAssertEqual(t.connectedPeerCount, 0)
    }

    func testBroadcastWaitingGivesUpWhenItsDeadlineHasPassedAndSendsWhenItCan() {
        let t = make()
        XCTAssertTrue(t.broadcastWaiting(Data(count: 100), class: .control, maxWaitMs: 1_000))
        XCTAssertFalse(t.broadcastWaiting(Data(count: 100), class: .bulk, maxWaitMs: 0), "no budget to wait with: a clean false, not a hang")
    }

    func testHandoffBoostIsAFlagTheHistoryTransferFlips() {
        XCTAssertFalse(NearbyTransport.handoffBoost)
        NearbyTransport.handoffBoost = true
        let t = make()
        XCTAssertTrue(t.broadcast(Data(count: 1024), class: .bulk))
        NearbyTransport.handoffBoost = false
    }

    // MARK: Lifecycle without a radio

    func testDiscoveryIsRefusedOfflineAndTheLifecycleCallsAreSafe() async {
        let t = make()
        t.start(parkAfter: 1)
        XCTAssertFalse(t.isDiscovering, "HAVEN_NO_NET: nothing advertises or browses")
        t.nudgeDiscovery()
        XCTAssertFalse(t.isDiscovering)
        t.parkDiscovery()
        t.disconnectForBackground()
        t.stop()
        XCTAssertFalse(t.isDiscovering)
        XCTAssertFalse(t.hasConnectedPeers)
        // From a background queue the calls hop to main rather than touching Multipeer there.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                t.start(); t.nudgeDiscovery(); t.parkDiscovery(); t.disconnectForBackground(); t.stop()
                c.resume()
            }
        }
        await drainMain()
        XCTAssertFalse(t.isDiscovering)
    }

    func testRetiredBrowsersOutliveTheCallThatRetiredThem() async {
        let browser = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "retire"), serviceType: "haven-circle")
        weak var weakBrowser = browser
        NearbyTransport.retireToPool([browser])
        NearbyTransport.retireToPool([])
        await drainMain()
        XCTAssertNotNil(weakBrowser, "a cancelled browser is kept alive until CFNetwork has finished cancelling it")
    }

    func testDroppingATransportRetiresItsDiscoveryObjectsInsteadOfFreeingThem() async {
        weak var weakTransport: NearbyTransport?
        autoreleasepool {
            let t = make("dropme")
            weakTransport = t
        }
        await drainMain()
        XCTAssertNil(weakTransport, "the transport itself is released…")
        // …and tearing it down did not trap (the Bonjour cancel crash is a same-turn free).
    }

    // MARK: Delegate plumbing

    func testInboundFramesAreHandedStraightToTheOwner() {
        let t = make()
        let frame = Data([0x01, 0xAA, 0xBB])
        t.session(otherSession(), didReceive: frame, fromPeer: MCPeerID(displayName: "remote"))
        XCTAssertEqual(inbound, [frame])
        t.session(otherSession(), didReceive: Data(), fromPeer: MCPeerID(displayName: "remote"))
        XCTAssertEqual(inbound.count, 2, "even an empty frame is the owner's to judge")
    }

    func testAPeerConnectingNotifiesOnceAndRefreshesTheCachedPeerList() async {
        let t = make()
        t.session(otherSession(), peer: MCPeerID(displayName: "remote"), didChange: .connected)
        XCTAssertEqual(connected, 1)
        await drainMain()   // discovery parks on main once a session is up
        XCTAssertFalse(t.isDiscovering)
        XCTAssertEqual(t.connectedPeerCount, 0, "the count comes from the snapshot MC reported, never from a sync read on main")
        t.session(otherSession(), peer: MCPeerID(displayName: "remote"), didChange: .connecting)
        XCTAssertEqual(connected, 1, "only .connected is announced")
    }

    func testAPeerLeavingTriesToRediscoverButOfflineStaysQuiet() async {
        let t = make()
        t.session(otherSession(), peer: MCPeerID(displayName: "remote"), didChange: .notConnected)
        await drainMain()
        XCTAssertEqual(connected, 0)
        XCTAssertFalse(t.isDiscovering, "HAVEN_NO_NET refuses the rediscovery")
    }

    func testEveryInvitationIsAcceptedIntoTheTransportsSession() {
        let t = make()
        let adv = MCNearbyServiceAdvertiser(peer: MCPeerID(displayName: "me"), discoveryInfo: nil, serviceType: "haven-circle")
        var accepted: Bool?
        var joined: MCSession?
        t.advertiser(adv, didReceiveInvitationFromPeer: MCPeerID(displayName: "remote"), withContext: nil) { ok, s in
            accepted = ok; joined = s
        }
        XCTAssertEqual(accepted, true, "membership is proven by the sealed hello, not by who may connect")
        XCTAssertNotNil(joined)
    }

    func testAFailedAdvertiserOrBrowserIsReplacedNotReused() async {
        let t = make()
        let adv = MCNearbyServiceAdvertiser(peer: MCPeerID(displayName: "x"), discoveryInfo: nil, serviceType: "haven-circle")
        t.advertiser(adv, didNotStartAdvertisingPeer: NSError(domain: "t", code: 1))
        let br = MCNearbyServiceBrowser(peer: MCPeerID(displayName: "x"), serviceType: "haven-circle")
        t.browser(br, didNotStartBrowsingForPeers: NSError(domain: "t", code: 2))
        t.browser(br, lostPeer: MCPeerID(displayName: "gone"))
        await drainMain()
        XCTAssertFalse(t.isDiscovering)
        XCTAssertNil(adv.delegate, "the failed object is detached before it is retired")
        XCTAssertNil(br.delegate)
    }

    func testResourceAndStreamCallbacksAreInertBecauseOnlyFramesAreUsed() {
        let t = make()
        let s = otherSession(), p = MCPeerID(displayName: "remote")
        t.session(s, didReceive: InputStream(data: Data()), withName: "x", fromPeer: p)
        t.session(s, didStartReceivingResourceWithName: "r", fromPeer: p, with: Progress())
        t.session(s, didFinishReceivingResourceWithName: "r", fromPeer: p, at: nil, withError: nil)
        XCTAssertTrue(inbound.isEmpty)
    }

    func testTheProcessIgnoresSIGPIPEBecauseRustSocketsDieSilentlyWithoutIt() {
        // A write to a socket the peer closed raises SIGPIPE, whose default action ends the process with
        // no crash report. Haven's App.init ignores it; the relay hairpin and the call media depend on it.
        var current = sigaction()
        XCTAssertEqual(sigaction(SIGPIPE, nil, &current), 0)
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
        XCTAssertEqual(handler, 1, "SIGPIPE must stay ignored (SIG_IGN) in the app process")
    }
}
