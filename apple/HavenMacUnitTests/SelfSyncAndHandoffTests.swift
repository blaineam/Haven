import XCTest
@testable import HavenUITestHost

@MainActor
final class SelfSyncTests: XCTestCase {
    private func le8(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    private let device = Data(repeating: 9, count: 32)

    func testPeerSlotMergesProfileSettingsContactsBlocksAndCircles() async throws {
        _ = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let engine = Engine(try HavenSocial(accountSeed: seed))
        let friend = Peer(byte: 0x44, name: "Friend")
        let blockedHex = String(repeating: "7a", count: 32)
        let circleId = "synced-\(UUID().uuidString.prefix(6))"
        let relayHex = String(repeating: "5c", count: 32)
        let t = nowMs() + 600_000          // newer than any local edit

        let h = AccountStateHandle()
        func put(_ k: String, _ v: Data) { XCTAssertNoThrow(try h.set(key: k, value: v, ts: t, device: device)) }
        put("profile:name", Data("Synced Sam".utf8)); put("profile-at:name", le8(t))
        put("profile:bio", Data("synced bio".utf8)); put("profile-at:bio", le8(t))
        put("profile:link", Data("sam.example".utf8)); put("profile-at:link", le8(t))
        put("profile:emoji", Data("🦊".utf8)); put("profile-at:emoji", le8(t))
        put("setting:saveToPhotos", Data([1])); put("setting-at:" + SettingsStore.shared.tsKeySave, le8(t))
        put("setting:autoOptimize", Data([0])); put("setting:saveOthersToPhotos", Data([1]))
        put("setting-at:" + SettingsStore.shared.tsKeySaveOthers, le8(t))
        var days = Int32(45)
        put("setting:retentionDays", withUnsafeBytes(of: &days) { Data($0) })
        put("setting-at:" + SettingsStore.shared.tsKeyRet, le8(t))
        put("setting:pinnedDMs", Data("dm:aaa\ndm:bbb".utf8))
        put("setting:dmLastRead", try JSONEncoder().encode(["dm:aaa": UInt64(123)]))
        put("setting:activitySeenAt", le8(t))
        let contact = Contact(name: "Friend", idHex: friend.hex)
        put("contact:\(friend.hex)", try JSONEncoder().encode(contact))
        put("blocked:\(blockedHex)", Data([1]))
        put("relay-removal:\(relayHex)", le8(t))
        let memberBundle = friend.bundle
        put("circle:\(circleId)", encodeCircleSync(name: "Synced Circle", memberBundles: [memberBundle], relays: [relayHex], creator: nil))
        put("circle-deleted:gone-\(circleId)", le8(t))
        let sealed = try sealAccountState(accountSeed: seed, state: h)

        let changed = await SelfSyncCoordinator.shared.ingestPeerSlot(sealed, engine: engine)
        XCTAssertTrue(changed, "a slot with new state reports a change")
        let p = ProfileStore.shared
        XCTAssertEqual(p.displayName, "Synced Sam")
        XCTAssertEqual(p.bio, "synced bio")
        XCTAssertEqual(p.link, "sam.example")
        XCTAssertEqual(p.emoji, "🦊")
        XCTAssertEqual(SettingsStore.shared.retentionDays, 45)
        XCTAssertTrue(SettingsStore.shared.saveOthersToPhotos)
        XCTAssertTrue(ConnectionsStore.shared.blocked.contains(blockedHex))
        XCTAssertTrue(ContactsStore.shared.contacts.contains { $0.idHex == friend.hex })
        XCTAssertTrue(DMPinStore.shared.isPinned("dm:aaa"))
        let circles = await engine.run(readOnly: true) { $0.circles() }
        XCTAssertEqual(circles.first { $0.id == circleId }?.name, "Synced Circle", "the synced circle is rebuilt locally")
        let members = await engine.run(readOnly: true) { $0.contactNodeIds(circleId: circleId) }
        XCTAssertTrue(members.contains(friend.hex))
        XCTAssertTrue(RelayMailboxStore.shared.explicitRelays(forCircle: circleId).isEmpty,
                      "a relay with a newer local-less deletion tombstone is not re-added")

        // A second ingest of the same slot has nothing new.
        let again = await SelfSyncCoordinator.shared.ingestPeerSlot(sealed, engine: engine)
        XCTAssertFalse(again)

        // The removal side: the sibling later UNBLOCKS and the circle is deleted.
        let h2 = AccountStateHandle()
        h2.merge(other: h)
        _ = try h2.remove(key: "blocked:\(blockedHex)", ts: t + 10, device: device)
        _ = try h2.set(key: "circle-deleted:\(circleId)", value: le8(t + 20), ts: t + 20, device: device)
        let sealed2 = try sealAccountState(accountSeed: seed, state: h2)
        _ = await SelfSyncCoordinator.shared.ingestPeerSlot(sealed2, engine: engine)
        XCTAssertFalse(ConnectionsStore.shared.blocked.contains(blockedHex))
        let after = await engine.run(readOnly: true) { $0.circles() }
        XCTAssertFalse(after.contains { $0.id == circleId }, "a newer deletion removes the circle")
        CircleDeletionStore.markRecreated(circleId)
        if let c = ContactsStore.shared.contacts.first(where: { $0.idHex == friend.hex }) { ContactsStore.shared.remove(c) }
    }

    func testUnreadableSlotsAreIgnored() async throws {
        _ = await Harness.feed()
        let bad = await SelfSyncCoordinator.shared.ingestPeerSlot(Data("not a sealed slot".utf8), engine: nil)
        XCTAssertFalse(bad)
        // A slot sealed by a DIFFERENT account must not be opened.
        let other = AccountStateHandle()
        _ = try other.set(key: "profile:name", value: Data("Intruder".utf8), ts: nowMs() + 1_000_000, device: device)
        let foreign = try sealAccountState(accountSeed: Data(repeating: 3, count: 32), state: other)
        let r = await SelfSyncCoordinator.shared.ingestPeerSlot(foreign, engine: nil)
        XCTAssertFalse(r)
        XCTAssertNotEqual(ProfileStore.shared.displayName, "Intruder")
    }

    func testOwnSlotRoundTripsAndSyncWithoutTransportsIsANoOp() async throws {
        _ = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        ProfileStore.shared.displayName = "Slot Owner"
        let engine = Engine(try HavenSocial(accountSeed: seed))
        let slot = await SelfSyncCoordinator.shared.sealedLocalSlot(engine: engine)
        let sealed = try XCTUnwrap(slot)
        let opened = try openAccountState(accountSeed: seed, sealed: sealed)
        XCTAssertEqual(opened.get(key: "profile:name").flatMap { String(data: $0, encoding: .utf8) }, "Slot Owner")

        XCTAssertFalse(SelfSyncCoordinator.shared.hasAccountLane)
        let put = await SelfSyncCoordinator.shared.accountLanePut("haven/self/x/y", Data([1]))
        XCTAssertFalse(put)
        let got = await SelfSyncCoordinator.shared.accountLaneGet("haven/self/x/y")
        XCTAssertNil(got)
        let listed = await SelfSyncCoordinator.shared.accountLaneList("haven/self/")
        XCTAssertEqual(listed, [])
        let synced = await SelfSyncCoordinator.shared.sync(engine: engine, force: true)
        XCTAssertFalse(synced, "no relay or bucket: nothing to converge with")
        await SelfSyncCoordinator.shared.publishEpochGrants()
        SelfSyncCoordinator.shared.reset()
        XCTAssertEqual(SelfSyncDevice.id.count, 32)
        XCTAssertEqual(SelfSyncDevice.hex.count, 64)
    }
}

@MainActor
final class HistoryHandoffTests: XCTestCase {
    override func tearDown() async throws { HistoryHandoff.shared.reset() }

    func testAskingWaitsThenCancellingStopsAndCanRestart() async {
        let store = await Harness.feed()
        _ = store
        let h = HistoryHandoff.shared
        h.reset()
        XCTAssertEqual(h.status.phase, .idle)
        XCTAssertFalse(h.isWaiting)
        h.requestHistory(reason: "unit test")
        XCTAssertTrue(h.isWaiting)
        XCTAssertEqual(h.status.phase, .waitingForSource)
        XCTAssertNil(h.status.fraction, "nothing is known about the size yet")

        h.cancelTransfer()
        XCTAssertFalse(h.isWaiting, "a cancelled request never resumes")
        XCTAssertEqual(h.status.phase, .cancelled)
        XCTAssertFalse(h.status.cancelledRemotely)
        h.dismissReceived()
        XCTAssertEqual(h.status.phase, .idle)

        h.requestHistory(reason: "asking again after a cancel")
        XCTAssertEqual(h.status.phase, .waitingForSource, "a cancelled transfer may always start again")
        h.retryRequest()
        XCTAssertTrue(h.isWaiting)
        h.reset()
        XCTAssertEqual(h.status.phase, .idle)
        XCTAssertTrue(h.handoffTargets.isEmpty)
    }

    func testTickWithNothingToDoMovesNothing() async {
        _ = await Harness.feed()
        HistoryHandoff.shared.reset()
        let moved = await HistoryHandoff.shared.tick(budget: 1)
        XCTAssertFalse(moved)
        HistoryHandoff.shared.noteSending(ref: "img_x")   // not serving: ignored
        XCTAssertFalse(HistoryHandoff.shared.transferActive)
        HistoryHandoff.shared.noteMediaLanded("img_x")
    }

    func testStatusFractionWeighsPostsAndMediaEqually() {
        var s = HistoryHandoff.Status()
        XCTAssertNil(s.fraction)
        s.total = 10; s.done = 5
        XCTAssertEqual(s.fraction, 0.5)
        s.mediaTotal = 10; s.mediaDone = 10
        XCTAssertEqual(s.fraction, 0.75)
        s.done = 99
        XCTAssertEqual(s.fraction, 1, "never beyond complete")
    }

    func testHistoryPagesExportFromOneStoreAndLandInAnother() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        for i in 0..<3 { _ = await store.postNow("history post \(i)") }
        let page = await store.exportHistoryPage(circleId: "default", before: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000,
                                                 limit: HistoryHandoff.pageEvents)
        let p = try XCTUnwrap(page)
        XCTAssertFalse(p.envelopes.isEmpty)
        let count = await store.historyEventCount(circleIds: ["default"])
        XCTAssertGreaterThanOrEqual(count, 3)
        // The wire framing round-trips exactly what a source uploads.
        let wire = HistoryHandoffWire.encodePage(circleId: "default", envelopes: p.envelopes,
                                                 media: [HistoryHandoffWire.MediaItem(ref: "img_aa", size: 5)])
        let decoded = try XCTUnwrap(HistoryHandoffWire.decodePage(wire))
        XCTAssertEqual(decoded.circleId, "default")
        XCTAssertEqual(decoded.envelopes, p.envelopes)
        XCTAssertEqual(decoded.media, [HistoryHandoffWire.MediaItem(ref: "img_aa", size: 5)])
        // Replaying our own page is idempotent: nothing new lands.
        let before = store.items.filter { $0.body.hasPrefix("history post") }.count
        let applied = await store.ingestHandoffPage(circleId: "default", envelopes: p.envelopes)
        XCTAssertNotNil(applied)
        XCTAssertEqual(store.items.filter { $0.body.hasPrefix("history post") }.count, before, "a replayed page adds no duplicates")
        let unknown = await store.ingestHandoffPage(circleId: "no-such-circle", envelopes: p.envelopes)
        XCTAssertNil(unknown)
    }
}
