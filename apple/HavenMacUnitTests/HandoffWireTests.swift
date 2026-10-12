import XCTest
@testable import HavenUITestHost

/// The history handoff between two devices of one account, over the account lane of an in-process
/// relay: this device as the SOURCE of a new device's request, and as the TARGET of a sibling's pages.
@MainActor
final class HandoffWireTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayHex = String(repeating: "e2", count: 32)

    /// Another device of the same account: same master seed, its own device key, registered in the roster.
    private struct Sibling {
        let engine: HavenSocial
        let deviceHex: String
        let roster: Data
        /// `adopting`: the roster this account already has on the first device. A real linked device
        /// starts from it (a roster of version 1 would be a rollback the first device ignores).
        init(seed: Data, deviceByte: UInt8, adopting existing: Data? = nil) throws {
            engine = try HavenSocial(accountSeed: seed)
            if let existing { _ = engine.ingestRosterWire(wire: existing) }
            let deviceSeed = Data((0..<32).map { UInt8($0) &+ deviceByte })
            _ = engine.useDeviceIdentity(deviceSeed: deviceSeed)
            let device = try Account.fromSeed(seed: deviceSeed)
            deviceHex = device.nodeIdHex()
            _ = engine.registerDevice(deviceBundle: device.publicBundle(), name: "Sibling",
                                      createdAt: UInt64(Date().timeIntervalSince1970))
            engine.createCircle(id: "default", name: "Your circle")
            roster = try XCTUnwrap(engine.exportOwnRoster().first).wire
        }
    }

    override func setUp() async throws {
        _ = await Harness.feed()
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        let r = RelayMailboxStore.shared
        r.add(circleId: "default", nodeHex: relayHex)
        r.setHttpInterface(relayHex, urls: [FakeWire.relayBase], token: "tok")
        HistoryHandoff.shared.reset()
    }
    override func tearDown() async throws {
        HistoryHandoff.shared.reset()
        let r = RelayMailboxStore.shared
        r.eraseNow(relayHex); r.dropErased(relayHex); r.unforget(relayHex)
        wire.uninstall()
    }

    private func controlFirst(_ envs: [Data]) -> [Data] {
        envs.sorted { a, b in
            func rank(_ d: Data) -> Int { d.first == 0x04 ? 0 : d.first == 0x03 ? 1 : 2 }
            return rank(a) < rank(b)
        }
    }

    func testThisDeviceServesItsHistoryToANewDevice() async throws {
        let store = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let acct = AccountStore.currentNodeHex()
        let me = DeviceKeyStore.deviceNodeHex().lowercased()
        store.setActiveCircle("default")
        let tag = UUID().uuidString.prefix(6)
        for i in 0..<3 { _ = await store.postNow("history \(tag) \(i)") }

        let sib = try Sibling(seed: seed, deviceByte: 0x70, adopting: await store.ownRosterWire())
        let at = HistoryHandoffWire.nowMs()
        let req = HistoryHandoffWire.Request(device: sib.deviceHex, at: at, roster: sib.roster.base64EncodedString())
        wire.putRelay(HistoryHandoffWire.requestKey(acct, sib.deviceHex), try JSONEncoder().encode(req))

        let did = await HistoryHandoff.shared.serve(until: Date().addingTimeInterval(120))
        XCTAssertTrue(did)
        let manifestRaw = try XCTUnwrap(wire.relayData(HistoryHandoffWire.manifestKey(acct, sib.deviceHex, me)))
        let m = try JSONDecoder().decode(HistoryHandoffWire.Manifest.self, from: manifestRaw)
        XCTAssertEqual(m.forRequest, at)
        XCTAssertGreaterThan(m.pages, 0)
        XCTAssertTrue(m.complete, "every circle's history was paged out")
        XCTAssertEqual(m.servedEvents, m.totalEvents.map { min($0, m.servedEvents ?? 0) } ?? m.servedEvents)
        XCTAssertEqual(HistoryHandoff.shared.handoffTargets, [sib.deviceHex.lowercased()])

        // The new device reads the pages back and ends up with the posts.
        for n in 0..<m.pages {
            let blob = try XCTUnwrap(wire.relayData(HistoryHandoffWire.pageKey(acct, sib.deviceHex, me, m.run, n)))
            let page = try XCTUnwrap(HistoryHandoffWire.decodePage(blob))
            sib.engine.createCircle(id: page.circleId, name: page.circleId)
            for env in controlFirst(page.envelopes) { _ = try? sib.engine.receive(circleId: page.circleId, envelope: env) }
        }
        let bodies = sib.engine.feed(circleId: "default", nowMs: HistoryHandoffWire.nowMs() + 60_000, viewerRetentionSecs: nil).map(\.body)
        for i in 0..<3 { XCTAssertTrue(bodies.contains("history \(tag) \(i)"), "post \(i) arrived on the new device") }

        // The new device finishes: the source drops the run and stops serving it.
        let done = HistoryHandoffWire.Request(device: sib.deviceHex, at: at, done: true)
        wire.putRelay(HistoryHandoffWire.requestKey(acct, sib.deviceHex), try JSONEncoder().encode(done))
        _ = await HistoryHandoff.shared.serve(until: Date().addingTimeInterval(30))
        XCTAssertTrue(HistoryHandoff.shared.handoffTargets.isEmpty)

        // Forgetting everything (identity switch / factory reset) also forgets "I just sent something".
        XCTAssertEqual(HistoryHandoff.shared.status.phase, .sending, "a source that just served is still sending media")
        HistoryHandoff.shared.reset()
        XCTAssertEqual(HistoryHandoff.shared.status.phase, .idle, "…until the run is forgotten")
        XCTAssertFalse(HistoryHandoff.shared.transferActive)
    }

    func testAnAskCancelledByTheNewDeviceIsDroppedByTheSource() async throws {
        let store = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let acct = AccountStore.currentNodeHex()
        let sib = try Sibling(seed: seed, deviceByte: 0x71, adopting: await store.ownRosterWire())
        let at = HistoryHandoffWire.nowMs()
        let req = HistoryHandoffWire.Request(device: sib.deviceHex, at: at, roster: sib.roster.base64EncodedString())
        wire.putRelay(HistoryHandoffWire.requestKey(acct, sib.deviceHex), try JSONEncoder().encode(req))
        _ = await HistoryHandoff.shared.serve(until: Date().addingTimeInterval(120))
        XCTAssertFalse(HistoryHandoff.shared.handoffTargets.isEmpty)

        var cancel = HistoryHandoffWire.Request(device: sib.deviceHex, at: at)
        cancel.cancelled = true
        wire.putRelay(HistoryHandoffWire.requestKey(acct, sib.deviceHex), try JSONEncoder().encode(cancel))
        _ = await HistoryHandoff.shared.serve(until: Date().addingTimeInterval(30))
        XCTAssertTrue(HistoryHandoff.shared.handoffTargets.isEmpty, "the stopped run is dropped")
        XCTAssertEqual(HistoryHandoff.shared.status.phase == .cancelled || HistoryHandoff.shared.status.phase == .idle, true)
    }

    func testThisDevicePullsASiblingsPagesAndFinishesTheRequest() async throws {
        let store = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let acct = AccountStore.currentNodeHex()
        let me = DeviceKeyStore.deviceNodeHex().lowercased()
        // A circle of its own: the device pair share nothing else, so the page is the only way in.
        guard let cid = await store.createCircleNow(name: "Handoff pull") else { return XCTFail("circle") }
        let sib = try Sibling(seed: seed, deviceByte: 0x72, adopting: await store.ownRosterWire())
        // The sibling is a linked device: it holds this circle's state before it authors anything
        // (a brand-new circle of its own would have an epoch this device has no reason to trust).
        _ = await store.ingestOwnDeviceRoster(sib.roster)
        sib.engine.createCircle(id: cid, name: "Handoff pull")
        if let mine = await store.exportHistoryPage(circleId: cid, before: HistoryHandoffWire.nowMs() + 60_000, limit: 500) {
            for env in controlFirst(mine.envelopes) { _ = try? sib.engine.receive(circleId: cid, envelope: env) }
        }
        let tag = UUID().uuidString.prefix(6)
        for i in 0..<2 {
            _ = try sib.engine.post(circleId: cid, body: "sibling \(tag) \(i)", media: [], music: nil, retentionSecs: nil,
                                    story: false, muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000) + UInt64(i))
        }

        HistoryHandoff.shared.requestHistory(reason: "unit test")
        XCTAssertTrue(HistoryHandoff.shared.isWaiting)
        await Harness.until(store, "the ask is published on the lane") {
            self.wire.relayData(HistoryHandoffWire.requestKey(acct, me)) != nil
        }

        let page = sib.engine.exportHistoryPage(circleId: cid, beforeMs: HistoryHandoffWire.nowMs() + 60_000, limit: 120)
        XCTAssertGreaterThan(page.events, 0)
        let run = "1700000000000"
        let now = HistoryHandoffWire.nowMs()
        let manifest = HistoryHandoffWire.Manifest(run: run, source: sib.deviceHex, forRequest: now + 10_000, pages: 1, complete: true,
                                                   updatedAt: now, totalEvents: Int(page.events), servedEvents: Int(page.events))
        wire.putRelay(HistoryHandoffWire.pageKey(acct, me, sib.deviceHex, run, 0),
                      HistoryHandoffWire.encodePage(circleId: cid, envelopes: page.envelopes, media: []))
        wire.putRelay(HistoryHandoffWire.manifestKey(acct, me, sib.deviceHex), try JSONEncoder().encode(manifest))

        let moved = await HistoryHandoff.shared.pull(until: Date().addingTimeInterval(60))
        XCTAssertTrue(moved)
        await Harness.until(store, "the sibling's posts are in the feed") {
            store.items.filter { $0.body.hasPrefix("sibling \(tag)") }.count == 2
        }
        XCTAssertFalse(HistoryHandoff.shared.isWaiting, "the request is complete")
        XCTAssertEqual(HistoryHandoff.shared.status.phase, .received)
        let done = try JSONDecoder().decode(HistoryHandoffWire.Request.self,
                                            from: try XCTUnwrap(wire.relayData(HistoryHandoffWire.requestKey(acct, me))))
        XCTAssertEqual(done.done, true, "the source is told it can stop")
        HistoryHandoff.shared.dismissReceived()
        XCTAssertEqual(HistoryHandoff.shared.status.phase, .idle)
        store.setActiveCircle(cid); store.leaveActiveCircle()
    }

    func testCancellingMyAskIsPublishedForTheSource() async throws {
        let store = await Harness.feed()
        let acct = AccountStore.currentNodeHex()
        let me = DeviceKeyStore.deviceNodeHex().lowercased()
        HistoryHandoff.shared.requestHistory(reason: "unit test")
        await Harness.until(store, "ask published") { self.wire.relayData(HistoryHandoffWire.requestKey(acct, me)) != nil }
        HistoryHandoff.shared.cancelTransfer()
        await HistoryHandoff.shared.publishPendingCancels()
        let body = try XCTUnwrap(wire.relayData(HistoryHandoffWire.requestKey(acct, me)))
        let req = try JSONDecoder().decode(HistoryHandoffWire.Request.self, from: body)
        XCTAssertEqual(req.cancelled, true, "the stop signal rides the same lane the source watches")
        XCTAssertEqual(HistoryHandoff.shared.status.phase, .cancelled)
    }
}
