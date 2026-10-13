import XCTest
@testable import HavenUITestHost

/// The embedded relay host's own rules. Starting it needs a live iroh node (the relay attaches to the
/// messaging endpoint), which an offline host never has — so these pin everything around that edge:
/// what an idle host reports, the retention it hands the store, the URL lists it announces, and the
/// accessors that must answer "nothing" rather than crash when no store is attached.
@MainActor
final class RelayHostTests: XCTestCase {
    private var host: RelayHost { RelayHost.shared }
    private let ageKey = "haven.relay.host.mediaMaxAgeDays"
    private let bytesKey = "haven.relay.host.mediaMaxBytes"
    private let publicKey = "haven.relay.publicURL"
    private let enabledKey = "haven.relay.host.enabled"
    private var savedPublic: Any?

    override func setUp() async throws {
        Harness.assertIsolatedHost()
        savedPublic = UserDefaults.standard.object(forKey: publicKey)
        UserDefaults.standard.removeObject(forKey: publicKey)
    }
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: ageKey)
        UserDefaults.standard.removeObject(forKey: bytesKey)
        if let savedPublic { UserDefaults.standard.set(savedPublic, forKey: publicKey) }
        else { UserDefaults.standard.removeObject(forKey: publicKey) }
        if host.enabled { host.setEnabled(false) }
    }

    // MARK: Retention handed to the store

    func testRetentionHasGenerousButFiniteDefaults() {
        XCTAssertEqual(host.mediaMaxAgeDays, 30)
        XCTAssertEqual(host.mediaMaxBytes, 32 * 1024 * 1024 * 1024)
        XCTAssertEqual(RelayHost.defaultMediaMaxAgeDays, 30)
        XCTAssertEqual(RelayHost.defaultMediaMaxBytes, 32 * 1024 * 1024 * 1024)
    }

    func testRetentionChoicesPersistAndPublish() {
        var fired = 0
        let bag = host.objectWillChange.sink { fired += 1 }
        defer { bag.cancel() }
        host.mediaMaxAgeDays = 7
        host.mediaMaxBytes = 5 * 1024 * 1024 * 1024
        XCTAssertEqual(host.mediaMaxAgeDays, 7)
        XCTAssertEqual(host.mediaMaxBytes, 5 * 1024 * 1024 * 1024)
        XCTAssertEqual(fired, 2, "the Relays screen re-reads after each change")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: ageKey), 7)
        // 0 means "no limit" for that dimension and must survive the round trip rather than read as unset.
        host.mediaMaxAgeDays = 0
        host.mediaMaxBytes = 0
        XCTAssertEqual(host.mediaMaxAgeDays, 0)
        XCTAssertEqual(host.mediaMaxBytes, 0)
    }

    // MARK: Idle host

    func testAnIdleHostIsNotServingAndHasNoStoreBehindTheLocalAccessors() {
        XCTAssertFalse(host.serving)
        XCTAssertEqual(host.nodeId, "")
        XCTAssertFalse(host.frontDoorSettled)
        XCTAssertFalse(host.localPut("haven/mailbox/x/y", Data([1])), "not hosting: nothing is stored")
        XCTAssertFalse(host.localHas("haven/mailbox/x/y"))
        XCTAssertNil(host.localGet("haven/mailbox/x/y"))
        XCTAssertEqual(host.localList("haven/"), [])
        XCTAssertEqual(host.localTouch(["a", "b"]), [], "a stopped relay never asks for a local re-upload storm")
        XCTAssertNil(host.mediaHttpPort)
    }

    func testTheDesktopClassAndLoginItemFlagsDescribeThisMac() {
        XCTAssertTrue(host.isDesktopClass, "native macOS is an always-on-capable host")
        XCTAssertTrue(host.loginItemSupported)
        _ = host.startsAtLogin   // reads SMAppService only; registering would change the owner's login items
    }

    func testMeshAndMembershipTicksDoNothingWhileNotServing() {
        host.meshSyncTick()
        host.authorizeMembership()
        host.updateSleepAssertion()
        XCTAssertFalse(PlatformIdle.disabled, "no keep-awake assertion without a serving relay")
        host.detachForFabricRebind()
        XCTAssertFalse(host.serving)
        host.reattachAfterFabricRebind()   // not enabled: returns without arming its retry timer
        XCTAssertFalse(host.serving)
    }

    func testTurningHostingOnOfflineRecordsTheChoiceButNeverServes() {
        host.setEnabled(true)
        XCTAssertTrue(host.enabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: enabledKey), "the choice survives a relaunch")
        XCTAssertFalse(host.serving, "hosting is inbound network: HAVEN_NO_NET refuses it")
        XCTAssertEqual(host.nodeId, "")
        host.startIfEnabled()
        XCTAssertFalse(host.serving)
        host.setEnabled(true)   // toggling on again while enabled-but-not-serving restarts cleanly
        XCTAssertTrue(host.enabled)
        host.setEnabled(false)
        XCTAssertFalse(host.enabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: enabledKey))
        XCTAssertFalse(host.serving)
        XCTAssertNil(host.mediaHttpPort)
    }

    // MARK: Announced URLs

    func testTheAnnounceListIsTheLanAddressesWhenNoPublicOriginIsKnown() {
        let urls = RelayHost.announceHttpUrls(mediaPort: 8674)
        XCTAssertEqual(urls, RelayHost.lanIPv4s().map { "http://\($0):8674" })
        XCTAssertEqual(RelayHost.reachableHttpUrls(port: 8674), urls)
        XCTAssertEqual(Set(urls).count, urls.count, "no duplicates")
    }

    func testAConfiguredPublicOriginComesFirstAndLanFollows() {
        UserDefaults.standard.set("  relay.example.com/ ", forKey: publicKey)
        let urls = RelayHost.announceHttpUrls(mediaPort: 9000)
        XCTAssertEqual(urls.first, "https://relay.example.com", "scheme added, whitespace and trailing slash trimmed")
        XCTAssertEqual(Array(urls.dropFirst()), RelayHost.lanIPv4s().map { "http://\($0):9000" },
                       "peers on this network can still use the LAN address")
    }

    func testAnUnusablePublicOriginIsIgnored() {
        UserDefaults.standard.set("not-a-host", forKey: publicKey)   // no dot: not a hostname
        XCTAssertFalse(RelayHost.announceHttpUrls(mediaPort: 1).contains { $0.hasPrefix("https://") })
    }

    func testLanAddressesAreRealRoutableIPv4sAndCachedBriefly() {
        let ips = RelayHost.lanIPv4s()
        for ip in ips {
            let parts = ip.split(separator: ".").compactMap { UInt8($0) }
            XCTAssertEqual(parts.count, 4, "\(ip) is a dotted quad")
            XCTAssertNotEqual(parts.first, 127, "loopback is never announced")
            XCTAssertFalse(ip.hasPrefix("169.254."), "link-local is never announced")
        }
        XCTAssertEqual(Set(ips).count, ips.count)
        XCTAssertEqual(RelayHost.lanIPv4s(), ips, "a second read inside the TTL answers from the cache")
    }

    func testOnlyAPublicHttpsHostCanBeTheDerpOrigin() {
        XCTAssertEqual(RelayHost.publicDerpCandidate(["https://relay.example.com"]), "https://relay.example.com")
        // The media list carries LAN addresses; the DERP fabric must take the public entry or none.
        XCTAssertEqual(RelayHost.publicDerpCandidate(["http://192.168.1.5:8674", "https://derp.example.org"]),
                       "https://derp.example.org")
        XCTAssertNil(RelayHost.publicDerpCandidate(["http://relay.example.com"]), "plain http is not a DERP origin")
        for private4 in ["https://10.0.0.4", "https://127.0.0.1", "https://192.168.0.9", "https://172.16.3.3",
                         "https://172.31.255.1", "https://169.254.10.10", "https://mac.local"] {
            XCTAssertNil(RelayHost.publicDerpCandidate([private4]), "\(private4) is LAN, never DERP")
        }
        XCTAssertEqual(RelayHost.publicDerpCandidate(["https://172.32.0.1"]), "https://172.32.0.1",
                       "172.32 is outside the private 172.16/12 block")
        XCTAssertEqual(RelayHost.publicDerpCandidate(["https://8.8.4.4"]), "https://8.8.4.4")
        XCTAssertNil(RelayHost.publicDerpCandidate([]))
    }

    // MARK: Cached relay clients

    func testNoRelayClientIsDialledOffline() async {
        let client = await RelayClients.client(String(repeating: "ab", count: 32))
        XCTAssertNil(client, "HAVEN_NO_NET: no dial, no health strike")
        XCTAssertTrue(RelayHealth.shared.available(String(repeating: "ab", count: 32)))
        RelayClients.forget(String(repeating: "ab", count: 32))
        RelayClients.clearAll()
    }

    // MARK: Value types

    func testRelayEntriesRoundTripThroughTheirPersistedForm() throws {
        var e = RelayEntry(hex: String(repeating: "5a", count: 32), name: "Basement NAS", active: true,
                           lastSeenMs: 42, isS3: false)
        e.httpUrls = ["https://relay.example.com"]; e.httpToken = "t"; e.derpUrl = "https://derp.example.com"
        e.turnUrls = ["turn:relay.example.com:3478"]; e.turnUser = "haven"; e.turnPass = "p"; e.addedAtMs = 7
        let erased = ErasedRelay(entry: e, circles: ["default", "club"], wasDefault: true, erasedAt: 99)
        let back = try JSONDecoder().decode(ErasedRelay.self, from: JSONEncoder().encode(erased))
        XCTAssertEqual(back, erased)
        XCTAssertEqual(back.id, e.hex)
        XCTAssertEqual(back.entry.id, e.hex)
        // A state file written before the optional fields existed still loads.
        let legacy = Data(#"{"hex":"aa","name":"Old","active":false,"lastSeenMs":1,"isS3":true}"#.utf8)
        let old = try JSONDecoder().decode(RelayEntry.self, from: legacy)
        XCTAssertNil(old.httpUrls); XCTAssertNil(old.addedAtMs); XCTAssertTrue(old.isS3)
    }

    func testHealthSnapshotsReportBackoffForTheQaDump() {
        let h = RelayHealth.shared
        let node = String(repeating: "7e", count: 32)
        defer { h.forget(node); h.qaResetPeak() }
        h.qaResetPeak()
        h.recordFailure(node)
        let snap = h.qaSnapshot()
        let rows = snap["relays"] as? [[String: Any]] ?? []
        let mine = rows.first { $0["relay"] as? String == node }
        XCTAssertEqual(mine?["fails"] as? Int, 1)
        XCTAssertEqual(mine?["reason"] as? String, "failure")
        XCTAssertGreaterThan(mine?["backoff_remaining_ms"] as? UInt64 ?? 0, 0)
        XCTAssertGreaterThan(snap["peak_backoff_ms"] as? UInt64 ?? 0, 0)
        let row = h.qaRow(node)
        XCTAssertEqual(row["fails"] as? Int, 1)
        XCTAssertEqual(row["reachable"] as? Bool, false)
        h.recordSuccess(node)
        let healed = h.qaRow(node)
        XCTAssertEqual(healed["fails"] as? Int, 0)
        XCTAssertEqual(healed["reachable"] as? Bool, true)
        XCTAssertEqual(healed["reason"] as? String, "")
        XCTAssertEqual(h.qaRow("unknown")["fails"] as? Int, 0, "an unknown relay reads as healthy and unproven")
        h.qaResetPeak()
        XCTAssertEqual(h.qaSnapshot()["peak_backoff_ms"] as? UInt64, 0)
    }

    // MARK: QA authorize list

    func testTheQaAuthorizeFileListsExtraMembersTheStubShouldServe() throws {
        let dir = try XCTUnwrap(QaFiles.dir)
        let file = dir.appendingPathComponent("qa-authorize-members.txt")
        let saved = try? Data(contentsOf: file)
        defer { if let saved { try? saved.write(to: file) } else { try? FileManager.default.removeItem(at: file) } }
        try? FileManager.default.removeItem(at: file)
        XCTAssertEqual(RelayHost.qaAuthorizeMembers(), [], "no file, no extras")
        let a = String(repeating: "AB", count: 32), b = String(repeating: "0f", count: 32)
        let text = [a, "  " + b + "  ", a.lowercased(), "too-short", String(repeating: "zz", count: 32), "", b].joined(separator: "\n")
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(RelayHost.qaAuthorizeMembers(), [a.lowercased(), b], "lowercased, trimmed, valid 64-hex only, each once, in file order")
        try "garbage only".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(RelayHost.qaAuthorizeMembers(), [])
    }
}
