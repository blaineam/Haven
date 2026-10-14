import XCTest
import AppKit
@testable import HavenUITestHost

/// The relay and bucket lanes end to end, over an in-process wire: what a post uploads, what a
/// friend's relay mailbox ingests, how media and device rosters move, how self-sync converges.
@MainActor
final class FakeWireTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayHex = String(repeating: "e1", count: 32)
    private let token = "fake-token"

    override func setUp() async throws {
        _ = await Harness.feed()
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        adoptRelay()
    }
    override func tearDown() async throws {
        let r = RelayMailboxStore.shared
        r.eraseNow(relayHex); r.dropErased(relayHex); r.unforget(relayHex)
        r.setDefault(nil)
        SharedMailboxStore.shared.clear()
        wire.uninstall()
    }

    private func adoptRelay(circle: String = "default") {
        let r = RelayMailboxStore.shared
        r.add(circleId: circle, nodeHex: relayHex)
        r.setHttpInterface(relayHex, urls: [FakeWire.relayBase], token: token)
        RelayEnrollment.confirm(relayHex)   // a plain relay, not one still waiting to enrol us
    }
    private func jpeg(_ tag: String) -> (ref: String, data: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var d = rep.representation(using: .jpeg, properties: [:])!
        d.append(contentsOf: (tag + UUID().uuidString).utf8)
        return (MediaStore.contentRef(.image, d), d)
    }
    private func controlFirst(_ envs: [Data]) -> [Data] {
        envs.sorted { a, b in
            func rank(_ d: Data) -> Int { d.first == 0x04 ? 0 : d.first == 0x03 ? 1 : 2 }
            return rank(a) < rank(b)
        }
    }
    private func until(_ what: String, timeout: TimeInterval = 45, _ cond: @escaping @MainActor () -> Bool) async {
        await Harness.until(FeedStore.shared, timeout: timeout, what, cond)
    }

    // MARK: Authoring goes out over the relay

    func testAPostIsUploadedAndAFriendCanOpenWhatLanded() async throws {
        let store = await Harness.feed()
        let ann = Peer(byte: 0xB1, name: "Ann")
        await ann.befriend(store)
        store.setActiveCircle("default")
        let body = "over the wire \(UUID().uuidString.prefix(6))"
        let id = await store.postNow(body)
        XCTAssertNotNil(id)
        await until("the post reaches the relay mailbox") {
            self.wire.relayKeys(prefix: "haven/mailbox/default/").count >= 1
        }
        await until("the mailbox holds a decryptable copy") {
            let envs = self.wire.relayKeys(prefix: "haven/mailbox/default/").compactMap { self.wire.relayData($0) }
            for env in self.controlFirst(envs) { _ = try? ann.engine.receive(circleId: "default", envelope: env) }
            return ann.engine.feed(circleId: "default", nowMs: UInt64(Date().timeIntervalSince1970 * 1000), viewerRetentionSecs: nil)
                .contains { $0.body == body }
        }
        XCTAssertTrue(wire.requests(method: "PUT", host: FakeWire.relayHost).allSatisfy(\.authorized), "every relay write is signed")
        XCTAssertTrue(RelayHealth.shared.provenAlive(relayHex, withinMs: 60_000), "a landed write is proof of life")
    }

    func testARefusingRelayIsReachableButNotAFailure() async {
        // Fresh bytes every run: a landed envelope is remembered as seen on disk, and a remembered
        // one is (rightly) never re-sent, which would turn this into a test of the memory.
        let refused = Data(UUID().uuidString.utf8)
        let outage = Data(UUID().uuidString.utf8)
        wire.refuse = true
        let ok = await SharedStore.uploadEvent(circleId: "default", env: refused)
        XCTAssertFalse(ok, "a 403 does not count as delivered")
        XCTAssertFalse(SharedStore.httpUrlBad(FakeWire.relayBase), "a refusal is not an outage: the URL isn't marked bad")
        wire.refuse = false
        wire.unreachable = true
        let down = await SharedStore.uploadEvent(circleId: "default", env: outage)
        XCTAssertFalse(down)
        XCTAssertTrue(SharedStore.httpUrlBad(FakeWire.relayBase), "a dead relay is skipped for a while")
        wire.unreachable = false
        // The store's own background polls share the fake relay: one that began during the outage
        // can finish AFTER the clear below and re-mark the URL bad, so a single clear-then-upload
        // is racy. Clear and retry, bounded, until the relay is seen to answer.
        var back = false
        for _ in 0..<20 where !back {
            SharedStore.clearAllHttpUrlBad()
            back = await SharedStore.uploadEvent(circleId: "default", env: outage)
            if !back { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertTrue(back, "…and recovers once it answers")
        XCTAssertEqual(wire.relayData(SharedStore.mailboxKeyHint(circleId: "default", env: outage)), outage)
        XCTAssertNil(wire.relayData(SharedStore.mailboxKeyHint(circleId: "default", env: refused)), "the refused envelope never landed")
    }

    // MARK: Pulling a friend's posts, hellos and rosters

    func testThePollIngestsAFriendsPostFromTheRelayExactlyOnce() async throws {
        let store = await Harness.feed()
        let bea = Peer(byte: 0xB2, name: "Bea")
        await bea.befriend(store)
        store.setActiveCircle("default")
        let body = "from bea \(UUID().uuidString.prefix(6))"
        _ = try bea.engine.post(circleId: "default", body: body, media: [], music: nil, retentionSecs: nil, story: false,
                                muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
        for env in bea.engine.syncEnvelopes(circleId: "default") {
            wire.putRelay(SharedStore.mailboxKeyHint(circleId: "default", env: env), env)
        }
        let first = await store.pullMailbox(circleIds: ["default"])
        XCTAssertGreaterThan(first, 0)
        await until("bea's post is in the feed") { store.items.contains { !$0.isMe && $0.body == body } }
        let listsBefore = wire.requests(method: "GET").filter { $0.path.hasPrefix("/l/") }.count
        let second = await store.pullMailbox(circleIds: ["default"])
        XCTAssertEqual(second, 0, "keys already ingested are not fetched again")
        XCTAssertGreaterThan(wire.requests(method: "GET").filter { $0.path.hasPrefix("/l/") }.count, listsBefore, "…but the relay is still asked")
    }

    func testAHelloInTheMailboxBecomesAConnectionRequestOnlyForItsRecipient() async {
        let store = await Harness.feed()
        let stranger = Peer(byte: 0xB3, name: "Hello stranger")
        func lp(_ d: Data) -> Data { Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)]) + d }
        let hello = lp(Data("default".utf8)) + lp(Data("Their circle".utf8)) + lp(stranger.bundle)
        ConnectionsStore.shared.removePending(stranger.hex)
        // Addressed to somebody else: left alone.
        let other = String(repeating: "0f", count: 32)
        wire.putRelay(SharedStore.helloMailboxKey(circleId: "default", toHex: other, fromHex: stranger.hex, body: hello), hello)
        _ = await store.pullMailbox(circleIds: ["default"])
        XCTAssertFalse(ConnectionsStore.shared.pending.contains { $0.idHex == stranger.hex })
        // Addressed to me: ingested.
        wire.putRelay(SharedStore.helloMailboxKey(circleId: "default", toHex: store.myNodeHex, fromHex: stranger.hex, body: hello), hello)
        _ = await store.pullMailbox(circleIds: ["default"])
        await until("the request surfaces") { ConnectionsStore.shared.pending.contains { $0.idHex == stranger.hex } }
        ConnectionsStore.shared.removePending(stranger.hex)
    }

    func testPublishingMyRosterAndLearningAFriendsFromTheRelay() async throws {
        let store = await Harness.feed()
        let cy = Peer(byte: 0xB4, name: "Cy")
        await cy.befriend(store)
        await store.publishOwnRosterNow()
        let mine = store.myNodeHex
        await until("my roster is on the relay") { self.wire.relayData("haven/devroster/\(mine)") != nil }

        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let observer = Engine(try HavenSocial(accountSeed: seed))
        cy.registerDevice()
        let cyRoster = try XCTUnwrap(cy.engine.exportOwnRoster().first)
        wire.putRelay("haven/devroster/\(cy.hex)", cyRoster.wire)
        await observer.run { s in
            s.createCircle(id: "default", name: "Your circle")
            _ = try? s.addContactBundle(circleId: "default", bundle: cy.bundle)
        }
        let learned = await SharedStore.fetchContactRoster(accountHex: cy.hex, engine: observer)
        XCTAssertTrue(learned, "a contact's signed roster is ingested from any relay that holds it")
        let none = await SharedStore.fetchContactRoster(accountHex: String(repeating: "dd", count: 32), engine: observer)
        XCTAssertFalse(none)
    }

    // MARK: Media

    func testMediaIsBackedUpToTheRelayAndRestoredAfterLocalDeletion() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let (ref, data) = jpeg("media")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        let id = await store.postNow("a photo", media: [ref])
        XCTAssertNotNil(id)
        await until("the blob is on the relay and the ledger knows") {
            self.wire.relayData("haven/media/\(ref)") != nil && MediaBackupLedger.hasAny(ref)
        }
        await until("the upload queue drains") { !MediaBackupQueue.shared.hasPending(ref) }
        XCTAssertNotEqual(wire.relayData("haven/media/\(ref)"), data, "the relay holds ciphertext, not the photo")

        MediaStore.shared.delete(ref)
        XCTAssertFalse(MediaStore.shared.hasLocalFile(ref))
        store.requestMedia(ref, circleId: "default")
        await until("the photo is restored from the relay") { MediaStore.shared.hasLocalFile(ref) }
        XCTAssertEqual(MediaStore.shared.rawBytes(ref), data, "…bit for bit")
    }

    // MARK: Self-sync over the relay

    func testSelfSyncPublishesMySlotAndMergesASiblingsWithNewerState() async throws {
        _ = await Harness.feed()
        let seed = try XCTUnwrap(AccountStore.storedSeed())
        let acct = AccountStore.currentNodeHex()
        let engine = Engine(try HavenSocial(accountSeed: seed))
        SelfSyncCoordinator.shared.reset()

        let sibling = Data(repeating: 0x5e, count: 32)
        let state = AccountStateHandle()
        let t = UInt64(Date().timeIntervalSince1970 * 1000) + 600_000
        func le8(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        _ = try state.set(key: "profile:name", value: Data("Sibling Sam".utf8), ts: t, device: sibling)
        _ = try state.set(key: "profile-at:name", value: le8(t), ts: t, device: sibling)
        let sealed = try sealAccountState(accountSeed: seed, state: state)
        let siblingKey = "haven/" + selfSyncSlotKey(accountNodeHex: acct, deviceNodeHex: sibling.map { String(format: "%02x", $0) }.joined())
        wire.putRelay(siblingKey, sealed)

        let changed = await SelfSyncCoordinator.shared.sync(engine: engine, force: true)
        XCTAssertTrue(changed, "the sibling's newer profile is merged")
        XCTAssertEqual(ProfileStore.shared.displayName, "Sibling Sam")
        let ownKey = "haven/" + selfSyncSlotKey(accountNodeHex: acct, deviceNodeHex: SelfSyncDevice.hex)
        XCTAssertNotNil(wire.relayData(ownKey), "my own slot is published for the sibling to read")
        let ownSlot = try XCTUnwrap(wire.relayData(ownKey))
        XCTAssertEqual(try openAccountState(accountSeed: seed, sealed: ownSlot).get(key: "profile:name"), Data("Sibling Sam".utf8))

        // The account lane carries arbitrary small records between my devices.
        let put = await SelfSyncCoordinator.shared.accountLanePut("haven/self/\(acct)/note", Data("hello".utf8))
        XCTAssertTrue(put)
        let got = await SelfSyncCoordinator.shared.accountLaneGet("haven/self/\(acct)/note")
        XCTAssertEqual(got, Data("hello".utf8))
        let listed = await SelfSyncCoordinator.shared.accountLaneList("haven/self/\(acct)/")
        XCTAssertTrue(listed.contains("haven/self/\(acct)/note"))
        XCTAssertTrue(SelfSyncCoordinator.shared.hasAccountLane)
        SelfSyncCoordinator.shared.reset()
    }

    // MARK: A bucket instead of a relay

    func testACircleWithOnlyABucketUploadsAndPollsThroughIt() async throws {
        let store = await Harness.feed()
        RelayMailboxStore.shared.eraseNow(relayHex)   // no relay for this test: the bucket is the mailbox
        SharedMailboxStore.shared.set(S3Config(endpoint: FakeWire.s3Host, region: "us-east-1", bucket: FakeWire.bucket,
                                               accessKey: "AK", secret: "SK"))
        XCTAssertTrue(SharedStore.isVolunteering)
        guard let cid = await store.createCircleNow(name: "Bucket circle") else { return XCTFail("circle") }
        let env = Data((0..<64).map { UInt8($0) })
        let ok = await SharedStore.uploadEvent(circleId: cid, env: env)
        XCTAssertTrue(ok)
        let key = SharedStore.mailboxKeyHint(circleId: cid, env: env)
        XCTAssertEqual(wire.bucketData(key), env, "the sealed envelope sits at its content address")
        XCTAssertTrue(wire.requests(host: FakeWire.s3Host).allSatisfy(\.authorized), "SigV4 headers on every bucket call")
        // What I uploaded is already seen; what a friend parks in the bucket is fetched.
        let ownPoll = await SharedStore.pollMailbox(circleIds: [cid])
        XCTAssertFalse(ownPoll.contains { $0.1 == key }, "my own upload is marked seen and is not fetched back")
        let friendEnv = Data((0..<48).map { UInt8($0 &+ 100) })
        let friendKey = SharedStore.mailboxKeyHint(circleId: cid, env: friendEnv)
        wire.putBucket(friendKey, friendEnv)
        let polled = await SharedStore.pollMailbox(circleIds: [cid])
        XCTAssertTrue(polled.contains { $0.1 == friendKey && $0.2 == friendEnv })

        let client = try XCTUnwrap(SharedStore.mailboxClient())
        let present = await client.headObject(key: key)
        XCTAssertTrue(present)
        let absent = await client.headObject(key: "haven/none")
        XCTAssertFalse(absent)
        let url = try XCTUnwrap(client.presignedURL(method: "GET", key: key))
        XCTAssertTrue(url.absoluteString.contains("X-Amz-Signature="))
        store.setActiveCircle(cid); store.leaveActiveCircle()
    }

    // MARK: Housekeeping that talks to the relay

    func testApprovingAFriendLeavesAHelloOnTheRelayAndSyncKeepsGreeting() async throws {
        let store = await Harness.feed()
        let dot = Peer(byte: 0xB5, name: "Dot")
        await dot.befriend(store)
        await until("a hello for dot is parked in the mailbox") {
            !self.wire.relayKeys(prefix: "haven/mailbox/default/__hello__/\(dot.hex.lowercased())/").isEmpty
        }
        let hellos = wire.relayKeys(prefix: "haven/mailbox/default/__hello__/\(dot.hex.lowercased())/")
        XCTAssertTrue(hellos.allSatisfy { $0.contains("/\(store.myNodeHex.lowercased())/") }, "…and it is from me")
        // Housekeeping triggers: none of them may disturb the feed, and the greeting is idempotent.
        store.forceSync()
        store.syncWithContacts(force: true)
        store.rebroadcastProfile()
        store.reannounceOwnRelay()
        store.broadcastRelayNode(relayHex)
        store.enrollMembers(circleId: "default", force: true)
        store.backfillMailbox(circleIds: ["default"])
        store.backfillMailboxMedia(circleIds: ["default"])
        store.verifyHeldMedia()
        store.nudgeMediaPrefetchNow()
        store.heavyWorkLifted()
        store.noteNetworkPathChanged()
        store.noteFabricUrlsChanged(["https://derp.fake.test"])
        store.pullActivity()
        store.callActivityChanged(true); store.callActivityChanged(false)
        store.setForeground(false); store.setForeground(true)
        await Harness.until(store, "enrolment reaches the relay") {
            !self.wire.relayKeys().isEmpty
        }
        XCTAssertTrue(store.isConfigured)
        XCTAssertGreaterThanOrEqual(wire.relayKeys(prefix: "haven/mailbox/default/__hello__/\(dot.hex.lowercased())/").count, hellos.count,
                                    "a hello already parked is never taken back")
    }

    func testAFriendsPhotoIsFetchedFromTheRelayWhenItsPostArrives() async throws {
        let store = await Harness.feed()
        store.debugAssumeTransport = true
        defer { store.debugAssumeTransport = false }
        let eve = Peer(byte: 0xB6, name: "Eve")
        await eve.befriend(store)
        store.setActiveCircle("default")
        let (ref, data) = jpeg("friend-photo")
        XCTAssertFalse(MediaStore.shared.hasLocalFile(ref))
        // Eve seals the photo to the circle and parks it on the relay, then posts it.
        wire.putRelay("haven/media/\(ref)", try eve.engine.sealCircleMedia(circleId: "default", data: data))
        let body = "eve's photo \(UUID().uuidString.prefix(6))"
        await eve.post(body, into: store, media: [ref])
        await until("the post shows") { store.items.contains { !$0.isMe && $0.body == body } }
        store.nudgeMediaPrefetchNow()
        await until("the photo is pulled down from the relay", timeout: 60) { MediaStore.shared.hasLocalFile(ref) }
        XCTAssertEqual(MediaStore.shared.rawBytes(ref), data, "…bit for bit")
        XCTAssertTrue(wire.requests(method: "GET").contains { $0.path == "/k/haven/media/\(ref)" })
        MediaStore.shared.delete(ref)
    }
}
