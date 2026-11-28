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
        MediaKeysSender.shared.reset()
        SharedStore.clearAllHttpUrlBad()
        let r = RelayMailboxStore.shared
        r.add(circleId: "default", nodeHex: relayHex)
        r.setHttpInterface(relayHex, urls: [FakeWire.relayBase], token: "tok")
        HistoryHandoff.shared.reset()
    }
    override func tearDown() async throws {
        MediaKeysSender.shared.reset()
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

    /// DECISIONS D27, the iPhone's half end to end: a friend's media from before a linked device
    /// existed, one blob whole and one in two chunks on the relay. The app reads only their ends,
    /// sends the keys, and a device WITHOUT the account key opens both with them.
    func testThisDeviceSendsALinkedDeviceTheKeysToOlderMedia() async throws {
        let store = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let acct = AccountStore.currentNodeHex()
        let me = DeviceKeyStore.deviceNodeHex().lowercased()
        let tag = UUID().uuidString.prefix(8).lowercased()
        let friend = Peer(byte: 0xD7, name: "Old photos")
        await friend.befriend(store)

        let small = Data(repeating: 7, count: 150_000)
        let large = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        let smallRef = "img_d27small\(tag)", largeRef = "vid_d27large\(tag)", goneRef = "img_d27gone\(tag)"
        let sealedSmall = try friend.engine.sealCircleMedia(circleId: "default", data: small)
        let sealedLarge = try friend.engine.sealCircleMedia(circleId: "default", data: large)
        wire.putRelay("haven/media/\(smallRef)", sealedSmall)
        // Two chunks, the second far shorter than the tail: the entries run back into the first.
        let cut = sealedLarge.count - 900
        let manifestBody = try JSONSerialization.data(withJSONObject:
            ["v": 1, "chunks": 2, "total": sealedLarge.count, "sizes": [cut, 900]])
        wire.putRelay("haven/media/\(largeRef)", SharedStore.manifestMagic + manifestBody)
        wire.putRelay("haven/media/\(largeRef).p/0", Data(sealedLarge.prefix(cut)))
        wire.putRelay("haven/media/\(largeRef).p/1", Data(sealedLarge.suffix(900)))
        let longAgo = HistoryHandoffWire.nowMs() - 90 * 24 * 3_600_000
        await friend.post("before the browser \(tag)", into: store, createdAt: longAgo,
                          media: [smallRef, largeRef, goneRef])

        // The linked device: enrolled in the account's roster, holding no account key.
        let deviceByte: UInt8 = 0x73
        let sib = try Sibling(seed: seed, deviceByte: deviceByte, adopting: await store.ownRosterWire())
        _ = await store.ingestOwnDeviceRoster(sib.roster)
        let accountBundle = try XCTUnwrap(store.myPublicBundle())
        let browser = try HavenSocial.newSeedless(accountPublicBundle: accountBundle,
                                                  deviceSeed: Data((0..<32).map { UInt8($0) &+ deviceByte }))
        browser.createCircle(id: "default", name: "Your circle")
        XCTAssertNil(browser.openCircleMedia(circleId: "default", sealed: sealedSmall), "no way in before the keys")

        let at = HistoryHandoffWire.nowMs()
        let ask = HistoryHandoffWire.KeysRequest(device: sib.deviceHex.lowercased(), at: at)
        wire.putRelay(HistoryHandoffWire.keysRequestKey(acct, sib.deviceHex), try JSONEncoder().encode(ask))
        let manifestKey = HistoryHandoffWire.keysManifestKey(acct, sib.deviceHex, me)
        var progress: HistoryHandoffWire.KeysManifest?
        // By the clock, not by a count: while a pass the app started itself is still running,
        // `serve` returns at once, and twenty such returns were over before it had finished.
        let giveUp = Date().addingTimeInterval(60)
        while progress?.complete != true, Date() < giveUp {
            if !(await MediaKeysSender.shared.serve(until: Date().addingTimeInterval(120))) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            progress = try wire.relayData(manifestKey).map { try JSONDecoder().decode(HistoryHandoffWire.KeysManifest.self, from: $0) }
        }
        let m = try XCTUnwrap(progress)
        XCTAssertTrue(m.complete)
        XCTAssertEqual(m.forRequest, at)
        XCTAssertEqual(m.done, m.total)
        XCTAssertGreaterThanOrEqual(m.missing, 1, "the blob no relay holds is counted, not waited for")

        var received: UInt32 = 0
        for n in 0..<m.batches {
            let grant = try XCTUnwrap(wire.relayData(HistoryHandoffWire.keysBatchKey(acct, sib.deviceHex, me, m.run, n)))
            received += browser.receiveItemKeys(grant: grant)
        }
        XCTAssertGreaterThanOrEqual(received, 2)
        XCTAssertEqual(browser.openCircleMedia(circleId: "default", sealed: sealedSmall), small)
        XCTAssertEqual(browser.openCircleMedia(circleId: "default", sealed: sealedLarge), large)

        // Only the ends were read: ranged GETs, and never a whole blob or chunk of either.
        let mine = wire.rangedReads.filter { $0.path.contains(tag) }
        XCTAssertTrue(mine.contains { $0.path == "haven/media/\(smallRef)" }, "\(mine)")
        XCTAssertTrue(mine.contains { $0.path == "haven/media/\(largeRef).p/0" }, "\(mine)")
        XCTAssertTrue(mine.allSatisfy { $0.bytes <= HistoryHandoffWire.keyTailBytes })

        XCTAssertTrue(MediaKeysSender.shared.hasJobs == false, "a sent job asks for no more background time")
        var done = ask
        done.done = true
        wire.putRelay(HistoryHandoffWire.keysRequestKey(acct, sib.deviceHex), try JSONEncoder().encode(done))
        let again = await MediaKeysSender.shared.serve(until: Date().addingTimeInterval(30))
        XCTAssertFalse(again)

        // A relay that cannot be reached is not one that holds nothing: the job waits, and
        // "Cancel transfer" then stops it for good.
        wire.dropMedia = true
        wire.removeRelay(prefix: manifestKey)
        let second = HistoryHandoffWire.KeysRequest(device: sib.deviceHex.lowercased(), at: at + 1)
        wire.putRelay(HistoryHandoffWire.keysRequestKey(acct, sib.deviceHex), try JSONEncoder().encode(second))
        _ = await MediaKeysSender.shared.serve(until: Date().addingTimeInterval(60))
        // (The failed read also parks that relay's address, so no progress goes up either.)
        XCTAssertTrue(MediaKeysSender.shared.hasJobs, "the job is kept for a later pass")
        XCTAssertEqual(MediaKeysSender.shared.progress?.done, 0, "nothing was given up on")
        XCTAssertTrue(wire.relayKeys(prefix: HistoryHandoffWire.lane(acct) + "media-keys/")
            .allSatisfy { $0.contains("/\(m.run)/") }, "no batch for the waiting job")
        MediaKeysSender.shared.cancel()
        XCTAssertFalse(MediaKeysSender.shared.hasJobs)
        wire.dropMedia = false
        SharedStore.clearAllHttpUrlBad()
        wire.removeRelay(prefix: manifestKey)
        let afterCancel = await MediaKeysSender.shared.serve(until: Date().addingTimeInterval(30))
        XCTAssertFalse(afterCancel)
        XCTAssertNil(wire.relayData(manifestKey))
    }

    /// One relay that never answers must not hold back the keys for everything else, and what only
    /// it might hold must not be written off as having no key.
    func testARelayThatNeverAnswersDoesNotHoldBackTheOtherKeys() async throws {
        let store = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let acct = AccountStore.currentNodeHex()
        let me = DeviceKeyStore.deviceNodeHex().lowercased()
        let tag = UUID().uuidString.prefix(8).lowercased()
        let friend = Peer(byte: 0xD8, name: "Half a library")
        await friend.befriend(store)

        let second = String(repeating: "e3", count: 32)
        let r = RelayMailboxStore.shared
        r.add(circleId: "default", nodeHex: second)
        r.setHttpInterface(second, urls: [FakeWire.relay2Base], token: "tok2")
        defer { r.eraseNow(second); r.dropErased(second); r.unforget(second) }
        wire.unreachable2 = true

        let photo = Data(repeating: 9, count: 90_000)
        let heldRef = "img_d27held\(tag)", strandedRef = "img_d27stranded\(tag)"
        let sealed = try friend.engine.sealCircleMedia(circleId: "default", data: photo)
        wire.putRelay("haven/media/\(heldRef)", sealed)
        // The stranded one is newer, so it is looked up first.
        let now = HistoryHandoffWire.nowMs()
        await friend.post("held \(tag)", into: store, createdAt: now - 60_000, media: [heldRef])
        await friend.post("stranded \(tag)", into: store, createdAt: now - 1_000, media: [strandedRef])

        let deviceByte: UInt8 = 0x74
        let sib = try Sibling(seed: seed, deviceByte: deviceByte, adopting: await store.ownRosterWire())
        _ = await store.ingestOwnDeviceRoster(sib.roster)
        let accountBundle = try XCTUnwrap(store.myPublicBundle())
        let browser = try HavenSocial.newSeedless(accountPublicBundle: accountBundle,
                                                  deviceSeed: Data((0..<32).map { UInt8($0) &+ deviceByte }))
        browser.createCircle(id: "default", name: "Your circle")

        let ask = HistoryHandoffWire.KeysRequest(device: sib.deviceHex.lowercased(), at: now)
        wire.putRelay(HistoryHandoffWire.keysRequestKey(acct, sib.deviceHex), try JSONEncoder().encode(ask))
        let manifestKey = HistoryHandoffWire.keysManifestKey(acct, sib.deviceHex, me)
        func manifest() -> HistoryHandoffWire.KeysManifest? {
            wire.relayData(manifestKey).flatMap { try? JSONDecoder().decode(HistoryHandoffWire.KeysManifest.self, from: $0) }
        }
        var taken = 0
        func takeKeys() {
            guard let m = manifest() else { return }
            while taken < m.batches,
                  let grant = wire.relayData(HistoryHandoffWire.keysBatchKey(acct, sib.deviceHex, me, m.run, taken)) {
                _ = browser.receiveItemKeys(grant: grant)
                taken += 1
            }
        }
        for _ in 0..<20 where browser.openCircleMedia(circleId: "default", sealed: sealed) == nil {
            _ = await MediaKeysSender.shared.serve(until: Date().addingTimeInterval(60))
            takeKeys()
        }
        XCTAssertEqual(browser.openCircleMedia(circleId: "default", sealed: sealed), photo,
                       "the key behind the unanswerable one still went")
        let waiting = try XCTUnwrap(manifest())
        XCTAssertFalse(waiting.complete, "what the silent relay may hold is not written off")
        XCTAssertLessThan(waiting.done, waiting.total)
        XCTAssertTrue(MediaKeysSender.shared.hasJobs)

        // It answers again (it holds nothing): now those count as having no key, in the same run.
        wire.unreachable2 = false
        var last = waiting
        for _ in 0..<20 where !last.complete {
            SharedStore.clearAllHttpUrlBad()
            _ = await MediaKeysSender.shared.serve(until: Date().addingTimeInterval(60))
            last = try XCTUnwrap(manifest())
        }
        XCTAssertTrue(last.complete)
        XCTAssertEqual(last.run, waiting.run)
        XCTAssertEqual(last.done, last.total)
        XCTAssertGreaterThanOrEqual(last.missing, 1)
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
