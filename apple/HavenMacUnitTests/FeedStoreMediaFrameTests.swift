import XCTest
import AppKit
@testable import HavenUITestHost

/// The sealed "media wanted" / "media is back" frames between an author and the people who can't
/// open a post's photo: the author re-uploads to a relay, the asker is told and fetches.
@MainActor
final class FeedStoreMediaFrameTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayHex = String(repeating: "e3", count: 32)

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
        FeedStore.shared.debugAssumeTransport = false
        wire.uninstall()
    }

    private func lp(_ d: Data) -> Data { Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)]) + d }
    private func lp(_ s: String) -> Data { lp(Data(s.utf8)) }
    private func jpeg(_ tag: String) -> (ref: String, data: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var d = rep.representation(using: .jpeg, properties: [:])!
        d.append(contentsOf: (tag + UUID().uuidString).utf8)
        return (MediaStore.contentRef(.image, d), d)
    }
    /// A call-class frame as `peer` would put it on the wire: sealed to me, signed by them.
    private func sealed(_ type: UInt8, from peer: Peer, to store: FeedStore, _ body: Data) throws -> Data {
        Data([type]) + (try peer.engine.sealCallFrame(recipientNodeHex: store.myNodeHex, frameType: type, data: Data(peer.hex.utf8) + body))
    }
    private func until(_ what: String, timeout: TimeInterval = 60, _ cond: @escaping @MainActor () -> Bool) async {
        await Harness.until(FeedStore.shared, timeout: timeout, what, cond)
    }

    func testAFriendAsksForPhotoIHoldAndIPutItBackOnTheRelay() async throws {
        let store = await Harness.feed()
        let ann = Peer(byte: 0x33, name: "Ann")
        await ann.befriend(store)
        let (ref, data) = jpeg("wanted")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        defer { MediaStore.shared.delete(ref) }
        XCTAssertNil(wire.relayData("haven/media/\(ref)"))

        store.deliverFrameForTesting(try sealed(31, from: ann, to: store, lp(ref) + lp("default") + lp("post-1")))
        await until("the author re-uploads what was asked for") { self.wire.relayData("haven/media/\(ref)") != nil }
        XCTAssertNotEqual(wire.relayData("haven/media/\(ref)"), data, "ciphertext only")
        XCTAssertTrue(MediaBackupLedger.has(relayHex, ref))

        // Asked again right away: answered without a second upload.
        let puts = wire.requests(method: "PUT", host: FakeWire.relayHost).count
        store.deliverFrameForTesting(try sealed(31, from: ann, to: store, lp(ref) + lp("default") + lp("post-1")))
        // A frame for something I don't hold, and one from outside the circle, change nothing.
        let (otherRef, _) = jpeg("not-mine")
        store.deliverFrameForTesting(try sealed(31, from: ann, to: store, lp(otherRef) + lp("default") + lp("")))
        store.deliverFrameForTesting(try sealed(31, from: ann, to: store, lp(ref) + lp("some-other-circle") + lp("")))
        store.deliverFrameForTesting(try sealed(31, from: ann, to: store, lp("") + lp("") + lp("")))
        // Frames are judged in arrival order: a later, answerable one proves the earlier ones were.
        let (ref2, data2) = jpeg("wanted-2")
        XCTAssertTrue(MediaStore.shared.store(ref2, data2))
        defer { MediaStore.shared.delete(ref2) }
        store.deliverFrameForTesting(try sealed(31, from: ann, to: store, lp(ref2) + lp("default") + lp("")))
        await until("the second ask is answered") { self.wire.relayData("haven/media/\(ref2)") != nil }
        XCTAssertNil(wire.relayData("haven/media/\(otherRef)"))
        XCTAssertGreaterThan(wire.requests(method: "PUT", host: FakeWire.relayHost).count, puts)
    }

    func testAStrangersMediaAskIsIgnored() async throws {
        let store = await Harness.feed()
        let stranger = Peer(byte: 0x34, name: "Stranger")
        // Not befriended: the store has no keys to open a frame from them, and they are no contact.
        stranger.engine.createCircle(id: "default", name: "x")
        let (ref, data) = jpeg("not-for-strangers")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        defer { MediaStore.shared.delete(ref) }
        if let mine = store.myPublicBundle() { _ = try? stranger.engine.addContactBundle(circleId: "default", bundle: mine) }
        store.deliverFrameForTesting(try sealed(31, from: stranger, to: store, lp(ref) + lp("default") + lp("")))
        // Prove the stranger's frame has been judged by following it with a real friend's.
        let friend = Peer(byte: 0x35, name: "Friend")
        await friend.befriend(store)
        let (ref2, data2) = jpeg("for-friends")
        XCTAssertTrue(MediaStore.shared.store(ref2, data2))
        defer { MediaStore.shared.delete(ref2) }
        store.deliverFrameForTesting(try sealed(31, from: friend, to: store, lp(ref2) + lp("default") + lp("")))
        await until("the friend's ask is answered") { self.wire.relayData("haven/media/\(ref2)") != nil }
        XCTAssertNil(wire.relayData("haven/media/\(ref)"), "a non-contact can't make me upload anything")
    }

    func testTheAuthorSayingItIsBackMakesMeFetchItFromTheRelay() async throws {
        let store = await Harness.feed()
        store.debugAssumeTransport = true
        let bea = Peer(byte: 0x36, name: "Bea")
        await bea.befriend(store)
        store.setActiveCircle("default")
        let (ref, data) = jpeg("back")
        XCTAssertFalse(MediaStore.shared.hasLocalFile(ref))
        defer { MediaStore.shared.delete(ref) }
        wire.putRelay("haven/media/\(ref)", try bea.engine.sealCircleMedia(circleId: "default", data: data))

        // An unsolicited "it's on a relay now" announcement prefetches it.
        store.deliverFrameForTesting(try sealed(32, from: bea, to: store, lp(ref) + lp("default") + lp("p-1")))
        await until("the announced photo is prefetched", timeout: 60) { MediaStore.shared.hasLocalFile(ref) }
        XCTAssertEqual(MediaStore.shared.rawBytes(ref), data)

        // A photo I had asked for is cleared from the wanted list and fetched when the author says so.
        let (ref2, data2) = jpeg("back-2")
        defer { MediaStore.shared.delete(ref2) }
        wire.putRelay("haven/media/\(ref2)", try bea.engine.sealCircleMedia(circleId: "default", data: data2))
        MediaWantedStore.shared.add(ref2, manual: true)
        XCTAssertTrue(MediaWantedStore.shared.isWanted(ref2))
        store.deliverFrameForTesting(try sealed(32, from: bea, to: store, lp(ref2) + lp("default") + lp("p-2")))
        await until("the wanted photo is fetched", timeout: 60) { MediaStore.shared.hasLocalFile(ref2) }
        XCTAssertFalse(MediaWantedStore.shared.isWanted(ref2), "the ask is answered")
    }

    func testAPhotoNobodyHasUploadedYetWaitsForTheSenderAndArrivesWhenTheyPutItBack() async throws {
        let store = await Harness.feed()
        store.debugAssumeTransport = true
        let cat = Peer(byte: 0x40, name: "Cat")
        await cat.befriend(store)
        store.setActiveCircle("default")
        let (ref, data) = jpeg("late")
        defer { MediaStore.shared.delete(ref) }
        let body = "late photo \(UUID().uuidString.prefix(6))"
        await cat.post(body, into: store, media: [ref])
        await until("the post shows") { store.items.contains { !$0.isMe && $0.body == body } }
        store.nudgeMediaPrefetchNow()
        await until("the relay answered 'not here' and the card says it is waiting for the sender") {
            store.waitingForSenderMedia.contains(ref)
        }
        XCTAssertFalse(MediaStore.shared.hasLocalFile(ref))
        XCTAssertTrue(wire.requests(method: "GET").contains { $0.path == "/k/haven/media/\(ref)" }, "the relay was actually asked")

        // The author's device wakes, uploads, and says so.
        wire.putRelay("haven/media/\(ref)", try cat.engine.sealCircleMedia(circleId: "default", data: data))
        store.deliverFrameForTesting(try sealed(32, from: cat, to: store, lp(ref) + lp("default") + lp("")))
        await until("the photo arrives once it is back", timeout: 60) { MediaStore.shared.hasLocalFile(ref) }
        XCTAssertFalse(store.waitingForSenderMedia.contains(ref), "no longer waiting")
    }
}
