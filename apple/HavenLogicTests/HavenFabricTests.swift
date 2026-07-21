import XCTest
@testable import Haven

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

    func testFabricWithoutTurnHasNoGoogle() {
        UserDefaults.standard.set(["https://relay.example.com"], forKey: derpKey)
        let servers = HavenFabric.iceServersFromDefaults()
        XCTAssertTrue(servers.isEmpty, "fabric on without TURN must not use Google STUN")
        let urls = HavenFabric.iceServerUrlsFromDefaults()
        XCTAssertTrue(urls.isEmpty)
    }

    func testFabricWithTurnUsesCircleOnly() {
        UserDefaults.standard.set(["https://relay.example.com"], forKey: derpKey)
        UserDefaults.standard.set(["turn:10.0.0.1:3478"], forKey: turnKey)
        UserDefaults.standard.set("haven", forKey: userKey)
        UserDefaults.standard.set("secret", forKey: passKey)
        let servers = HavenFabric.iceServersFromDefaults()
        XCTAssertEqual(servers.count, 1)
        let urls = servers[0]["urls"] as? [String] ?? []
        XCTAssertTrue(urls.contains("turn:10.0.0.1:3478"))
        XCTAssertFalse(urls.contains(where: { $0.contains("google") }))
        XCTAssertEqual(servers[0]["username"] as? String, "haven")
    }

    func testHairpinUrlFromFabricBase() {
        let u = CallHairpin.hairpinURL(fromPublicBase: "https://abc.trycloudflare.com")
        XCTAssertEqual(u?.scheme, "wss")
        XCTAssertEqual(u?.host, "abc.trycloudflare.com")
        XCTAssertEqual(u?.path, "/webrtc/hairpin")
    }
}
