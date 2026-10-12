import XCTest
@testable import HavenUITestHost

/// Relay adoption, device enrolment and history paging on FeedStore.
@MainActor
final class FeedStoreAdminTests: XCTestCase {
    private func lp(_ d: Data) -> Data { Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)]) + d }
    private func lp(_ s: String) -> Data { lp(Data(s.utf8)) }
    private func hex() -> String { (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
    private var relays: RelayMailboxStore { RelayMailboxStore.shared }
    private var made: [String] = []

    override func tearDown() async throws {
        for h in made { relays.eraseNow(h); relays.dropErased(h); relays.unforget(h) }
        made.removeAll()
        relays.setDefault(nil)
    }

    func testAdoptingARelayFromItsInterfaceBlob() async throws {
        let store = await Harness.feed()
        let node = hex(); made.append(node)
        let blob = try JSONSerialization.data(withJSONObject: [
            "node": node, "urls": ["https://relay.example.org", "ftp://ignored"], "token": "secret-token",
            "derp": "https://derp.example.org/", "turn": "turn:turn.example.org:3478"])
        store.adoptRelayNode(String(decoding: blob, as: UTF8.self), circleIds: ["default"], setDefault: true)
        XCTAssertEqual(relays.defaultNodeHex, node)
        XCTAssertTrue(relays.relays(forCircle: "default").contains(node))
        let e = relays.entries[node]
        XCTAssertEqual(e?.httpUrls, ["https://relay.example.org"], "only http(s) interfaces are kept")
        XCTAssertEqual(e?.httpToken, "secret-token")
        XCTAssertEqual(e?.derpUrl, "https://derp.example.org")
        XCTAssertEqual(e?.turnUrls, ["turn:turn.example.org:3478"])
        XCTAssertEqual(e?.turnUser, "haven", "TURN defaults to the shared user…")
        XCTAssertEqual(e?.turnPass, "secret-token", "…and the relay token as its password")

        // Per-circle toggles do not disturb other circles.
        guard let cid = await store.createCircleNow(name: "Relay circle") else { return XCTFail("circle") }
        store.setCircleRelay(node, circleId: cid, on: true)
        XCTAssertTrue(relays.explicitRelays(forCircle: cid).contains(node))
        store.setCircleRelay(node, circleId: cid, on: false)
        XCTAssertFalse(relays.explicitRelays(forCircle: cid).contains(node))

        // Deleting then restoring is a deliberate re-adoption.
        store.forgetRelay(node)
        XCTAssertFalse(relays.isActive(node))
        store.restoreDeletedRelay(node)
        XCTAssertTrue(relays.isActive(node))
        XCTAssertFalse(relays.isForgotten(node))

        // Garbage is refused.
        store.adoptRelayNode("not-a-node", circleIds: ["default"], setDefault: false)
        store.adoptRelayNode("{\"node\":\"short\"}", circleIds: ["default"], setDefault: false)
        XCTAssertNil(relays.entries["not-a-node"])
        store.setActiveCircle(cid); store.leaveActiveCircle()
    }

    func testRelayLinksCarryTheCirclesMembers() async {
        let store = await Harness.feed()
        let pal = Peer(byte: 0x81, name: "Pal")
        await pal.befriend(store)
        await Harness.until(store, "member cached") { store.cachedMembers("default").contains(pal.hex) }
        let single = store.relayLink(forCircle: "default")
        XCTAssertNotNil(single)
        let all = store.relayLinkForAllCircles()
        XCTAssertNotNil(all)
        XCTAssertNotEqual(single, all, "a multi-circle link is a different grant")
        XCTAssertNotNil(store.relayLink())
    }

    func testSharedBucketConfigArrivesSealedToTheCircle() async throws {
        let store = await Harness.feed()
        let owner = Peer(byte: 0x82, name: "Bucket owner")
        await owner.befriend(store)
        await owner.post("so we share an epoch", into: store)
        SharedMailboxStore.shared.clear()
        let cfg = S3Config(endpoint: "https://s3.example.net", region: "eu-west-1", bucket: "shared-bucket", accessKey: "AKIA", secret: "S3CRET")
        let sealed = try owner.engine.sealCircleMedia(circleId: "default", data: try JSONEncoder().encode(cfg))
        store.deliverFrameForTesting(Data([14]) + lp("default") + sealed)
        await Harness.until(store, "bucket adopted") { SharedMailboxStore.shared.config != nil }
        XCTAssertEqual(SharedMailboxStore.shared.config?.bucket, "shared-bucket")
        SharedMailboxStore.shared.clear()
        store.deliverFrameForTesting(Data([14]) + lp("default") + Data([1, 2, 3]))   // not openable: ignored
    }

    func testHistoryPagingIsOnlyAnsweredForMembers() async {
        let store = await Harness.feed()
        let kid = Peer(byte: 0x83, name: "Kid")
        await kid.befriend(store)
        store.setActiveCircle("default")
        for i in 0..<3 { _ = await store.postNow("paged \(i)") }
        await Harness.until(store, "posts visible") { store.items.filter { $0.body.hasPrefix("paged") }.count >= 3 }
        store.requestOlderHistory()
        store.requestOlderHistory()          // same cursor: not asked twice
        var before = UInt64(Date().timeIntervalSince1970 * 1000)
        var ask = Data(kid.hex.utf8)
        withUnsafeBytes(of: &before) { ask.append(contentsOf: $0) }
        ask.append(Data("default".utf8))
        store.deliverFrameForTesting(Data([34]) + ask)       // a member: served
        var stranger = Data(String(repeating: "9a", count: 32).utf8)
        withUnsafeBytes(of: &before) { stranger.append(contentsOf: $0) }
        stranger.append(Data("default".utf8))
        store.deliverFrameForTesting(Data([34]) + stranger)  // a stranger: ignored
        store.deliverFrameForTesting(Data([34]) + Data(kid.hex.utf8))   // too short
    }

    func testDeviceRosterAnnounceFromAFriendIsIngested() async throws {
        let store = await Harness.feed()
        let friend = Peer(byte: 0x84, name: "Roster friend")
        await friend.befriend(store)
        let own = friend.engine.exportOwnRoster()
        for r in own { store.deliverFrameForTesting(Data([27]) + r.wire) }
        store.deliverFrameForTesting(Data([27]) + Data([1, 2, 3]))
        XCTAssertFalse(store.dialTargets("default").isEmpty)
        store.recordDeviceHints(accountHex: friend.hex, deviceIds: [String(repeating: "c1", count: 32), "short"])
        store.forgiveDials(accountHex: friend.hex)
        store.resolveMissingDeviceIds(for: [])
        XCTAssertTrue(store.dialTargets("default").contains(String(repeating: "c1", count: 32)),
                      "an invite hint is dialable until the signed roster lands")
    }

    func testPrimaryDeviceEnrolmentAndSeedlessTicket() async throws {
        let store = await Harness.feed()
        DeviceRosterManager.shared.stepDown()
        defer { DeviceRosterManager.shared.stepDown() }
        store.enableDeviceRoster()
        await Harness.until(store, "roster enabled") { DeviceRosterManager.shared.isEnabled }
        let ticket = store.mintEnrollTicket()
        XCTAssertNotNil(ticket, "a seed holder can advertise an enrolment QR")
        XCTAssertFalse(ticket?.secret.isEmpty ?? true)
        let ownRoster = await store.ownRosterWire()
        XCTAssertNotNil(ownRoster)
        await store.publishOwnRosterNow()
        // A new device asks to be linked (frame 24): the primary authorises it.
        let phone = Account.generate()
        let req = lp(phone.publicBundle()) + lp("Test phone") + lp(phone.nodeIdHex())
        store.deliverFrameForTesting(Data([24]) + req)
        await Harness.until(store, "phone linked") { DeviceRosterManager.shared.devices.contains { $0.nodeHex == phone.nodeIdHex() } }
        store.revokeDevice(phone.nodeIdHex())
        await Harness.until(store, "phone revoked") { !DeviceRosterManager.shared.devices.contains { $0.nodeHex == phone.nodeIdHex() } }
        store.stepDownAsPrimary()
        XCTAssertFalse(DeviceRosterManager.shared.isEnabled)
        store.declineSeedlessEnroll()
        XCTAssertNil(store.pendingEnrollRequest)
        // A frame-28 request without the secret's MAC is not an authorisation.
        store.deliverFrameForTesting(Data([28]) + Data(repeating: 1, count: 40))
        store.deliverFrameForTesting(Data([25]) + Data(repeating: 1, count: 40))
        store.deliverFrameForTesting(Data([26]) + Data(repeating: 1, count: 40))
    }

    func testCircleAdminGrantRequiresAMemberOfAnOwnedCircle() async {
        let store = await Harness.feed()
        let adm = Peer(byte: 0x85, name: "Admin to be")
        await adm.befriend(store)
        guard let cid = await store.createCircleNow(name: "Admins", memberIds: [adm.hex]) else { return XCTFail("circle") }
        let ok = await store.promoteToCircleAdmin(adm.hex, in: cid)
        XCTAssertTrue(ok)
        let bad = await store.promoteToCircleAdmin(adm.hex, in: "no-such-circle")
        XCTAssertFalse(bad)
        let upgradable = await store.circleIsUpgradable(cid)
        XCTAssertFalse(upgradable, "an owned circle needs no upgrade")
        let legacyDefault = await store.circleIsUpgradable("default")
        XCTAssertFalse(legacyDefault)
        let pending = await store.pendingUpgrades(cid)
        XCTAssertTrue(pending.isEmpty)
        store.setActiveCircle(cid); store.leaveActiveCircle()
    }

    func testSeedlessEnrolmentNeedsTheTicketSecretAndTheUsersConfirmation() async throws {
        let store = await Harness.feed()
        DeviceRosterManager.shared.stepDown()
        defer { DeviceRosterManager.shared.stepDown() }
        let ticket = try XCTUnwrap(store.mintEnrollTicket())
        let phone = Account.generate()

        // A request MACed with the wrong secret is not an authorisation.
        let forged = try enrollBuildRequest(secret: Data(repeating: 7, count: 32), deviceBundle: phone.publicBundle(),
                                            name: "Mallory", ts: UInt64(Date().timeIntervalSince1970))
        store.deliverFrameForTesting(Data([28]) + forged)
        XCTAssertNil(store.pendingEnrollRequest)

        // A genuine one only raises the sheet; nothing is granted until the user confirms.
        let wire = try enrollBuildRequest(secret: ticket.secret, deviceBundle: phone.publicBundle(), name: "My new Mac",
                                          ts: UInt64(Date().timeIntervalSince1970))
        store.deliverFrameForTesting(Data([28]) + wire)
        await Harness.until(store, "the confirmation sheet is up") { store.pendingEnrollRequest != nil }
        XCTAssertEqual(store.pendingEnrollRequest?.name, "My new Mac")
        XCTAssertEqual(store.pendingEnrollRequest?.deviceHex, phone.nodeIdHex())
        XCTAssertFalse(DeviceRosterManager.shared.devices.contains { $0.nodeHex == phone.nodeIdHex() })
        store.deliverFrameForTesting(Data([28]) + wire)     // a repeat doesn't stack a second sheet

        let request = try XCTUnwrap(store.pendingEnrollRequest)
        store.confirmSeedlessEnroll(request)
        XCTAssertNil(store.pendingEnrollRequest)
        await Harness.until(store, "the device is in the roster") {
            DeviceRosterManager.shared.devices.contains { $0.nodeHex == phone.nodeIdHex() }
        }
        // The ticket is single-use: the same request can't be confirmed twice.
        store.deliverFrameForTesting(Data([28]) + wire)
        XCTAssertNil(store.pendingEnrollRequest)
    }
}
