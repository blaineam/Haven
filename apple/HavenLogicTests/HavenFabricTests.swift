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

    /// A DERP fabric with NO circle TURN must NOT reach for Google.
    ///
    /// The relay's path proxy serves the WebRTC hairpin, so media has a route that never touches a
    /// third party — a fabric counts as "a Haven relay is available", which is the whole rule.
    func testFabricWithoutTurnDoesNotUseGoogle() {
        UserDefaults.standard.set(["https://relay.example.com"], forKey: derpKey)
        let servers = HavenFabric.iceServersFromDefaults()
        let all = servers.flatMap { ($0["urls"] as? [String]) ?? [] }
        XCTAssertFalse(all.contains(where: { $0.contains("google") }),
                       "a fabric is an available relay — ICE must stay off third-party servers")
        XCTAssertTrue(HavenFabric.iceServerUrlsFromDefaults().isEmpty)
    }

    /// A PRIVATE circle TURN alongside a fabric: the TURN is used, its host doubles as STUN, and
    /// Google is still not added — the fabric makes a relay available regardless of the TURN's
    /// reachability. Two entries, not three.
    func testPrivateCircleTurnWithFabricStaysOffGoogle() {
        UserDefaults.standard.set(["https://relay.example.com"], forKey: derpKey)
        UserDefaults.standard.set(["turn:10.0.0.1:3478"], forKey: turnKey)
        UserDefaults.standard.set("haven", forKey: userKey)
        UserDefaults.standard.set("secret", forKey: passKey)
        let servers = HavenFabric.iceServersFromDefaults()
        XCTAssertEqual(servers.count, 2, "circle TURN + derived circle STUN, no fallback")
        XCTAssertTrue((servers[0]["urls"] as? [String] ?? []).contains("turn:10.0.0.1:3478"))
        XCTAssertTrue((servers[1]["urls"] as? [String] ?? []).contains("stun:10.0.0.1:3478"))
        let all = servers.flatMap { ($0["urls"] as? [String]) ?? [] }
        XCTAssertFalse(all.contains(where: { $0.contains("google") }))
    }

    /// The failure this fallback was written for, still covered: NO fabric and only an unreachable
    /// private TURN is not an available relay, so the last resort still applies. Without it both
    /// ends get host candidates only and the call connects with no media.
    func testPrivateTurnWithNoFabricStillFallsBack() {
        UserDefaults.standard.set(["turn:172.20.0.2:3478"], forKey: turnKey)
        UserDefaults.standard.set("haven", forKey: userKey)
        UserDefaults.standard.set("secret", forKey: passKey)
        let all = HavenFabric.iceServersFromDefaults().flatMap { ($0["urls"] as? [String]) ?? [] }
        XCTAssertTrue(all.contains(where: { $0.contains("stun.l.google.com") }),
                      "no fabric + unreachable TURN = no Haven relay; the fallback is the only path")
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
