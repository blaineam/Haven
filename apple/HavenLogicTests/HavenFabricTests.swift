import XCTest
@testable import HavenLogicTests

/// Locks Haven-first WebRTC ICE: Google STUN is fallback-only when no fabric is known.
final class HavenFabricTests: XCTestCase {
    private let derpKey = "haven.fabric.derpUrls"
    private let turnKey = "haven.fabric.turnUrls"
    private let userKey = "haven.fabric.turnUser"
    private let passKey = "haven.fabric.turnPass"

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        d.removeObject(forKey: derpKey)
        d.removeObject(forKey: turnKey)
        d.removeObject(forKey: userKey)
        d.removeObject(forKey: passKey)
    }

    override func tearDown() {
        let d = UserDefaults.standard
        d.removeObject(forKey: derpKey)
        d.removeObject(forKey: turnKey)
        d.removeObject(forKey: userKey)
        d.removeObject(forKey: passKey)
        super.tearDown()
    }

    func testNoFabricUsesGoogleStun() {
        let servers = HavenFabric.iceServersFromDefaults()
        XCTAssertEqual(servers.count, 1)
        let urls = servers[0]["urls"] as? [String] ?? []
        XCTAssertTrue(urls.contains(where: { $0.contains("stun.l.google.com") }))
    }

    /// A DERP fabric with NO circle TURN still falls back to public STUN.
    ///
    /// This test used to assert the opposite ("fabric on without TURN must not use Google STUN").
    /// The implementation deliberately changed — see iceServersFromDefaults: without STUN two home
    /// NATs can never pair, so connectivity was chosen over purity — and this test could not report
    /// the change because the target had stopped compiling. Asserting the behaviour that actually
    /// ships means the next change to it is visible.
    ///
    /// The tradeoff is real and worth re-deciding deliberately, not by drift: the fallback discloses
    /// the caller's IP to a third party during ICE. A publicly-reachable circle TURN avoids it
    /// entirely (see testCircleTurnThatIsPubliclyReachableAvoidsGoogle).
    func testFabricWithoutTurnFallsBackToPublicStun() {
        UserDefaults.standard.set(["https://relay.example.com"], forKey: derpKey)
        let servers = HavenFabric.iceServersFromDefaults()
        XCTAssertEqual(servers.count, 1, "no circle TURN → the public STUN fallback is the only entry")
        let urls = servers[0]["urls"] as? [String] ?? []
        XCTAssertTrue(urls.contains(where: { $0.contains("stun.l.google.com") }))
    }

    /// A PRIVATE circle TURN (10.x) is used, and its host doubles as STUN — but because the open
    /// internet cannot reach it, the public STUN fallback is still added. Three entries: TURN,
    /// derived circle STUN, fallback. The old expectation of exactly one predates that rule.
    func testPrivateCircleTurnStillGetsThePublicStunFallback() {
        UserDefaults.standard.set(["https://relay.example.com"], forKey: derpKey)
        UserDefaults.standard.set(["turn:10.0.0.1:3478"], forKey: turnKey)
        UserDefaults.standard.set("haven", forKey: userKey)
        UserDefaults.standard.set("secret", forKey: passKey)
        let servers = HavenFabric.iceServersFromDefaults()
        XCTAssertEqual(servers.count, 3, "TURN + derived circle STUN + public fallback")
        let turnUrls = servers[0]["urls"] as? [String] ?? []
        XCTAssertTrue(turnUrls.contains("turn:10.0.0.1:3478"))
        XCTAssertEqual(servers[0]["username"] as? String, "haven")
        // The circle's own host serves STUN on the same socket — no credentials, no third party.
        let circleStun = servers[1]["urls"] as? [String] ?? []
        XCTAssertTrue(circleStun.contains("stun:10.0.0.1:3478"))
    }

    /// The case that keeps a call entirely on circle infrastructure: a PUBLICLY reachable circle
    /// TURN. No fallback is added, so nothing is disclosed to a third party.
    func testCircleTurnThatIsPubliclyReachableAvoidsGoogle() {
        UserDefaults.standard.set(["https://relay.example.com"], forKey: derpKey)
        UserDefaults.standard.set(["turn:turn.example.com:3478"], forKey: turnKey)
        UserDefaults.standard.set("haven", forKey: userKey)
        UserDefaults.standard.set("secret", forKey: passKey)
        let servers = HavenFabric.iceServersFromDefaults()
        let all = servers.flatMap { ($0["urls"] as? [String]) ?? [] }
        XCTAssertFalse(all.contains(where: { $0.contains("google") }),
                       "a reachable circle TURN must keep ICE on our own infrastructure")
    }

    func testHairpinUrlFromFabricBase() {
        let u = HavenHairpin.hairpinURL(fromPublicBase: "https://abc.trycloudflare.com")
        XCTAssertEqual(u?.scheme, "wss")
        XCTAssertEqual(u?.host, "abc.trycloudflare.com")
        XCTAssertEqual(u?.path, "/webrtc/hairpin")
    }
}
