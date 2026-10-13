import XCTest
@testable import HavenUITestHost

/// The handshake: what a HELLO from a contact, a blocked person, a removed member or a third party
/// does to the circles, the pending-request list and the mailbox slot (consumed or left to retry).
@MainActor
final class FeedStoreHelloTests: XCTestCase {
    private func lp(_ d: Data) -> Data { Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)]) + d }
    private func lp(_ s: String) -> Data { lp(Data(s.utf8)) }
    private func hello(_ peer: Peer, circle: String, name: String = "Their circle") -> Data {
        lp(circle) + lp(name) + lp(peer.bundle)
    }
    private func uniq(_ p: String) -> String { "\(p)-\(UUID().uuidString.prefix(8).lowercased())" }

    func testAContactsHelloOnANewCreatesTheCircleAndAddsThem() async {
        let store = await Harness.feed()
        let ann = Peer(byte: 0x21, name: "Ann")
        await ann.befriend(store)
        let circle = uniq("ring")
        let consumed = await store.ingestInviteHello(hello(ann, circle: circle, name: "Climbing club"))
        XCTAssertTrue(consumed, "an applied handshake is consumed")
        XCTAssertTrue(store.circles.contains { $0.id == circle && $0.name == "Climbing club" }, "the circle they brought exists on our side")
        // A second hello inside the reply window changes nothing and is consumed again.
        let again = await store.ingestInviteHello(hello(ann, circle: circle, name: "Climbing club"))
        XCTAssertTrue(again)
        XCTAssertEqual(store.circles.filter { $0.id == circle }.count, 1, "a re-handshake never duplicates the circle")
        // The default circle is never "new".
        let onDefault = await store.ingestInviteHello(hello(ann, circle: "default"))
        XCTAssertTrue(onDefault)
    }

    func testADeletedCircleIsNotRecreatedByABareHandshake() async {
        let store = await Harness.feed()
        let bo = Peer(byte: 0x22, name: "Bo")
        await bo.befriend(store)
        let circle = uniq("gone")
        CircleDeletionStore.markDeleted(circle)
        defer { CircleDeletionStore.markRecreated(circle) }
        let consumed = await store.ingestInviteHello(hello(bo, circle: circle))
        XCTAssertTrue(consumed, "a deliberate drop is consumed, not retried forever")
        XCTAssertFalse(store.circles.contains { $0.id == circle })
    }

    func testADirectMessageCircleOnlyAdmitsItsTwoParties() async {
        let store = await Harness.feed()
        let cy = Peer(byte: 0x23, name: "Cy")
        let outsider = Peer(byte: 0x24, name: "Outsider")
        await cy.befriend(store)
        await outsider.befriend(store)
        // A DM between me and Cy: the outsider (a contact too) must not handshake their way in.
        let dm = store.dmCircleId(with: cy.hex)
        let intruded = await store.ingestInviteHello(hello(outsider, circle: dm))
        XCTAssertTrue(intruded, "a third party's DM hello is dropped as handled")
        XCTAssertFalse(store.cachedMembers(dm).contains(outsider.hex))
        let ok = await store.ingestInviteHello(hello(cy, circle: dm, name: "Cy"))
        XCTAssertTrue(ok)
        XCTAssertTrue(store.circles.contains { $0.id == dm }, "the real counterpart opens the thread")
    }

    func testAMemberIRemovedHasToAskAgainRatherThanAutoRejoin() async {
        let store = await Harness.feed()
        let dee = Peer(byte: 0x25, name: "Dee")
        await dee.befriend(store)
        ConnectionsStore.shared.removeFromCircle(dee.hex, circleId: "default")
        defer {
            ConnectionsStore.shared.clearCircleRemoval(dee.hex, circleId: "default")
            ConnectionsStore.shared.removePending(dee.hex)
        }
        ConnectionsStore.shared.removePending(dee.hex)
        let consumed = await store.ingestInviteHello(hello(dee, circle: "default"))
        XCTAssertFalse(consumed, "held for the user's decision: the grant riding it must survive")
        XCTAssertTrue(ConnectionsStore.shared.pending.contains { $0.idHex == dee.hex }, "…as a request, never a silent drop")

        // The same hello over the nearby mesh is only proximity: dropped, no request.
        ConnectionsStore.shared.removePending(dee.hex)
        store.deliverFrameForTesting(Data([0]) + hello(dee, circle: "default"), viaNearby: true)
        // Frames run in arrival order: a hello after it proves the nearby one has been judged.
        let probe = Peer(byte: 0x26, name: "Probe")
        store.deliverFrameForTesting(Data([0]) + hello(probe, circle: "default"))
        await Harness.until(store, "the probe's request surfaces") { ConnectionsStore.shared.pending.contains { $0.idHex == probe.hex } }
        XCTAssertFalse(ConnectionsStore.shared.pending.contains { $0.idHex == dee.hex }, "proximity alone never asks")
        ConnectionsStore.shared.removePending(probe.hex)
    }

    func testAHelloThatContradictsWhatWeVerifiedIsKeptForLater() async {
        let store = await Harness.feed()
        let eli = Peer(byte: 0x27, name: "Eli")
        ContactsStore.shared.add(name: "Eli", idHex: eli.hex, verificationHex: "not-their-real-verification")
        let consumed = await store.ingestInviteHello(hello(eli, circle: "default"))
        XCTAssertFalse(consumed, "a mismatch may be a stale local expectation: the slot stays for a later poll")
        if let c = ContactsStore.shared.contacts.first(where: { $0.idHex == eli.hex }) { ContactsStore.shared.remove(c) }
    }

    func testAContactsLiveHelloTeachesTheirDeviceAndMarksThemHeard() async {
        let store = await Harness.feed()
        let fay = Peer(byte: 0x28, name: "Fay")
        await fay.befriend(store)
        let device = String(repeating: "ab", count: 32)
        store.deliverFrameForTesting(Data([0]) + hello(fay, circle: "default"), viaNearby: true, senderDevice: device)
        await Harness.until(store, "the hello marks fay as heard") { store.lastHeard[fay.hex] != nil }
        func hints() -> [String] {
            ((UserDefaults.standard.dictionary(forKey: "haven.contact.deviceHints") as? [String: [String]]) ?? [:])[fay.hex] ?? []
        }
        XCTAssertTrue(hints().contains(device), "a direct hello is the reply-path bootstrap")
        // A short id is ignored and a known one is not stored twice.
        store.recordDeviceHints(accountHex: fay.hex, deviceIds: ["short", device])
        XCTAssertEqual(hints().filter { $0 == device }.count, 1, "hints are deduped")
    }

    func testMalformedHellosAreConsumed() async {
        let store = await Harness.feed()
        for body in [Data(), Data([1, 2, 3]), lp("default") + lp("x") + lp(Data([1, 2])), lp("") + lp("x") + lp(Data(repeating: 7, count: 40))] {
            let consumed = await store.ingestInviteHello(body)
            XCTAssertTrue(consumed, "a hello that can never apply is not retried forever")
        }
        XCTAssertNil(store.helloSenderHex(Data([9])))
        let ivy = Peer(byte: 0x29, name: "Ivy")
        XCTAssertEqual(store.helloSenderHex(hello(ivy, circle: "default")), ivy.hex)
    }
}
