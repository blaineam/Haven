import XCTest
import AppKit
@testable import HavenUITestHost

/// What a push wake does with the relay: fetch the exact mailbox key a push named, or sweep the
/// mailboxes in the slim background pass, and land the friend's post in the feed.
@MainActor
final class FeedStorePushWakeTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayHex = String(repeating: "e4", count: 32)

    override func setUp() async throws {
        _ = await Harness.feed()
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        let r = RelayMailboxStore.shared
        r.add(circleId: "default", nodeHex: relayHex)
        r.setHttpInterface(relayHex, urls: [FakeWire.relayBase], token: "tok")
        RelayEnrollment.confirm(relayHex)
    }
    override func tearDown() async throws {
        let r = RelayMailboxStore.shared
        r.eraseNow(relayHex); r.dropErased(relayHex); r.unforget(relayHex)
        wire.uninstall()
    }

    /// The friend's whole history for the circle, key commit first, parked where a relay would hold it.
    private func park(_ friend: Peer) -> [String] {
        let envs = friend.engine.syncEnvelopes(circleId: "default").sorted { a, b in
            func rank(_ d: Data) -> Int { d.first == 0x04 ? 0 : d.first == 0x03 ? 1 : 2 }
            return rank(a) < rank(b)
        }
        return envs.map { env in
            let key = SharedStore.mailboxKeyHint(circleId: "default", env: env)
            wire.putRelay(key, env)
            return key
        }
    }

    func testAPushNamingAMailboxKeyIsFetchedAndIngestedBeforeTheBanner() async throws {
        let store = await Harness.feed()
        let ann = Peer(byte: 0x37, name: "Ann")
        await ann.befriend(store)
        store.setActiveCircle("default")
        let body = "pushed \(UUID().uuidString.prefix(6))"
        _ = try ann.engine.post(circleId: "default", body: body, media: [], music: nil, retentionSecs: nil, story: false,
                                muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
        let keys = park(ann)
        XCTAssertGreaterThan(keys.count, 1, "a key commit and the post")
        for key in keys { await store.prefetchPush(circleId: "default", mailboxKey: key, mediaRefs: []) }
        await Harness.until(store, "the pushed post is in the feed") { store.items.contains { !$0.isMe && $0.body == body } }
        XCTAssertTrue(wire.requests(method: "GET").contains { $0.path.hasPrefix("/k/haven/mailbox/default/") }, "targeted GETs, no LIST needed")

        // Unknown circle, empty key: nothing to do and nothing fetched.
        let gets = wire.requests(method: "GET").count
        await store.prefetchPush(circleId: "not-a-circle", mailboxKey: keys[0], mediaRefs: [])
        await store.prefetchPush(circleId: "default", mailboxKey: "", mediaRefs: [])
        XCTAssertEqual(wire.requests(method: "GET").count, gets)
    }

    func testAPushThatNamesMediaStartsItsFetchRightAway() async throws {
        let store = await Harness.feed()
        store.debugAssumeTransport = true
        defer { store.debugAssumeTransport = false }
        let bo = Peer(byte: 0x38, name: "Bo")
        await bo.befriend(store)
        store.setActiveCircle("default")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var data = rep.representation(using: .jpeg, properties: [:])!
        data.append(contentsOf: UUID().uuidString.utf8)
        let ref = MediaStore.contentRef(.image, data)
        defer { MediaStore.shared.delete(ref) }
        wire.putRelay("haven/media/\(ref)", try bo.engine.sealCircleMedia(circleId: "default", data: data))
        await bo.post("pic \(UUID().uuidString.prefix(6))", into: store, media: [ref])
        await store.prefetchPush(circleId: "default", mailboxKey: nil, mediaRefs: [ref])
        await Harness.until(store, timeout: 60, "the named media is fetched") { MediaStore.shared.hasLocalFile(ref) }
        XCTAssertEqual(MediaStore.shared.rawBytes(ref), data)
    }

    func testTheSlimBackgroundPassSweepsTheMailboxAndSaysWhetherAnythingArrived() async throws {
        let store = await Harness.feed()
        let cy = Peer(byte: 0x39, name: "Cy")
        await cy.befriend(store)
        store.setActiveCircle("default")
        let quiet = await store.slimBackgroundSync(allowMailboxPull: true)
        XCTAssertFalse(quiet, "an empty sweep ends the wake early")

        let body = "woke for \(UUID().uuidString.prefix(6))"
        _ = try cy.engine.post(circleId: "default", body: body, media: [], music: nil, retentionSecs: nil, story: false,
                               muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
        _ = park(cy)
        let noPull = await store.slimBackgroundSync(allowMailboxPull: false)
        XCTAssertFalse(noPull, "a refresh wake without a backlog never LISTs the mailboxes")
        XCTAssertFalse(store.items.contains { $0.body == body })
        let got = await store.slimBackgroundSync(allowMailboxPull: true)
        XCTAssertTrue(got, "something new arrived")
        await Harness.until(store, "the post lands") { store.items.contains { !$0.isMe && $0.body == body } }
    }

    func testPushHintsLeftByThePushHandlerDriveTheSlimWakeWithoutAMailboxList() async throws {
        let store = await Harness.feed()
        let dee = Peer(byte: 0x3A, name: "Dee")
        await dee.befriend(store)
        store.setActiveCircle("default")
        let body = "hinted \(UUID().uuidString.prefix(6))"
        _ = try dee.engine.post(circleId: "default", body: body, media: [], music: nil, retentionSecs: nil, story: false,
                                muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
        // The push handler appends one hint per key it was told about; the wake drains them.
        for key in park(dee) { SharedPushHintWriter.append(c: "default", mk: key, mr: nil, p: nil) }
        SharedPushHintWriter.append(c: "", mk: "ignored-without-a-circle", mr: nil, p: nil)
        func mailboxLists() -> Int { wire.requests(method: "GET").filter { $0.path.hasPrefix("/l/haven/mailbox/") }.count }
        let lists = mailboxLists()
        let got = await store.slimBackgroundSync(allowMailboxPull: false)
        XCTAssertTrue(got, "the hinted envelopes were fetched and ingested")
        XCTAssertEqual(mailboxLists(), lists, "targeted GETs, not a LIST of the mailbox")
        await Harness.until(store, "the hinted post lands") { store.items.contains { !$0.isMe && $0.body == body } }
        let again = await store.slimBackgroundSync(allowMailboxPull: false)
        XCTAssertFalse(again, "hints are consumed once")
    }
}
