import XCTest
import AppKit
import CryptoKit
@testable import HavenUITestHost

/// Wire frames delivered straight to the store's inbound dispatcher (no transport), the way a
/// nearby link or relay would hand them over.
@MainActor
final class FeedStoreInboundTests: XCTestCase {
    private func lp(_ d: Data) -> Data { Data([UInt8(d.count & 0xff), UInt8(d.count >> 8)]) + d }
    private func lp(_ s: String) -> Data { lp(Data(s.utf8)) }
    private func frame(_ type: UInt8, _ payload: Data) -> Data { Data([type]) + payload }
    private func u32(_ v: Int) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
    private func jpeg(_ tag: String) -> (ref: String, data: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var d = rep.representation(using: .jpeg, properties: [:])!
        d.append(contentsOf: (tag + UUID().uuidString).utf8)
        return (MediaStore.contentRef(.image, d), d)
    }

    func testLiveEventFramesLandInTheFeed() async {
        let store = await Harness.feed()
        let ann = Peer(byte: 0x71, name: "Ann")
        await ann.befriend(store)
        store.setActiveCircle("default")
        _ = try? ann.engine.post(circleId: "default", body: "live from ann", media: [], music: nil, retentionSecs: nil,
                                 story: false, muteVideo: false, createdAt: UInt64(Date().timeIntervalSince1970 * 1000))
        for env in ann.engine.syncEnvelopes(circleId: "default") {
            store.deliverFrameForTesting(frame(1, lp("default") + env), viaNearby: true)
        }
        await Harness.until(store, "live event applied") { store.items.contains { !$0.isMe && $0.body == "live from ann" } }
        XCTAssertTrue(store.nearbyActive, "a nearby frame proves the nearby link works")
        // Malformed event frames are dropped without a trace.
        store.deliverFrameForTesting(frame(1, Data()))
        store.deliverFrameForTesting(frame(1, lp("") + Data([1, 2, 3])))
        store.deliverFrameForTesting(frame(1, lp("default")))
        store.deliverFrameForTesting(Data())
    }

    func testAStrangersHelloBecomesAConnectionRequestUntilBlocked() async {
        let store = await Harness.feed()
        let stranger = Peer(byte: 0x72, name: "Stranger")
        let hello = lp("default") + lp("Their circle") + lp(stranger.bundle)
        ConnectionsStore.shared.removePending(stranger.hex)
        store.deliverFrameForTesting(frame(0, hello))
        await Harness.until(store, "request surfaces") { ConnectionsStore.shared.pending.contains { $0.idHex == stranger.hex } }
        XCTAssertFalse(ContactsStore.shared.contacts.contains { $0.idHex == stranger.hex }, "a stranger is not a contact until approved")
        XCTAssertFalse(store.cachedMembers("default").contains(stranger.hex))

        // Blocking drops the request and every later hello from them.
        store.blockConnection(stranger.hex)
        ConnectionsStore.shared.removePending(stranger.hex)
        store.deliverFrameForTesting(frame(0, hello))
        _ = await store.ingestInviteHello(hello)
        XCTAssertFalse(ConnectionsStore.shared.pending.contains { $0.idHex == stranger.hex }, "a blocked sender can't re-add themselves")
        ConnectionsStore.shared.unblock(stranger.hex)
    }

    func testAHelloFromMyOwnAccountIsNotAConnectionRequest() async {
        let store = await Harness.feed()
        let mine = store.inviteHelloBody()!
        let consumed = await store.ingestInviteHello(mine)
        XCTAssertTrue(consumed)
        XCTAssertFalse(ConnectionsStore.shared.pending.contains { $0.idHex == store.myNodeHex }, "never 'connect with yourself'")
        let malformed = await store.ingestInviteHello(Data([1, 2, 3]))
        XCTAssertTrue(malformed, "malformed hellos are consumed, not retried forever")
    }

    func testOwnDeviceMediaChunksReassembleIntoTheStore() async throws {
        let store = await Harness.feed()
        let (ref, data) = jpeg("chunks")
        XCTAssertFalse(MediaStore.shared.hasLocalFile(ref))
        let key = try XCTUnwrap(FeedStore.ownMediaKey())
        let size = 32 * 1024
        var chunks = stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
        if chunks.isEmpty { chunks = [data] }
        // A chunk sealed under the WRONG key is never written.
        let bogus = try AES.GCM.seal(Data("not the media".utf8), using: SymmetricKey(size: .bits256)).combined!
        store.deliverFrameForTesting(frame(5, lp(ref) + u32(0) + u32(chunks.count) + bogus))
        for (i, c) in chunks.enumerated().reversed() {      // out of order is fine
            let sealed = try AES.GCM.seal(c, using: key).combined!
            store.deliverFrameForTesting(frame(5, lp(ref) + u32(i) + u32(chunks.count) + sealed))
        }
        await Harness.until(store, timeout: 30, "media reassembled") { MediaStore.shared.hasLocalFile(ref) }
        XCTAssertEqual(MediaStore.shared.rawBytes(ref), data)
        store.deliverFrameForTesting(frame(5, Data([0])))                              // too short
        store.deliverFrameForTesting(frame(5, lp(ref) + u32(0) + u32(0) + Data([1])))  // zero total
        MediaStore.shared.delete(ref)
    }

    func testMediaRequestsServeWhatWeHoldAndIgnoreTheRest() async {
        let store = await Harness.feed()
        let pal = Peer(byte: 0x73, name: "Pal")
        await pal.befriend(store)
        let (ref, data) = jpeg("serve")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        store.deliverFrameForTesting(frame(3, Data(pal.hex.utf8) + Data(ref.utf8)))
        store.deliverFrameForTesting(frame(3, Data(pal.hex.utf8) + Data("img_\(String(repeating: "0", count: 64))".utf8)))
        store.deliverFrameForTesting(frame(3, Data("short".utf8)))
        store.deliverFrameForTesting(frame(33, Data(pal.hex.utf8) + lp(ref) + Data([0xff])))
        store.deliverFrameForTesting(frame(34, Data("bogus history request".utf8)))
        store.deliverFrameForTesting(frame(31, Data("bogus wanted".utf8)))
        store.deliverFrameForTesting(frame(32, Data("bogus available".utf8)))
        MediaStore.shared.delete(ref)
    }

    func testRelayAnnounceAdoptsTheRelayAndItsInterface() async throws {
        let store = await Harness.feed()
        let friend = Peer(byte: 0x74, name: "Relay friend")
        await friend.befriend(store)
        await friend.post("so the epoch key is known", into: store)
        let relayHex = String(repeating: "3d", count: 32)
        let announce: [String: Any] = ["node": relayHex, "urls": ["https://relay.example.com"], "token": "tok123",
                                       "derp": "https://derp.example.com", "turn": ["turn:turn.example.com:3478"],
                                       "turnUser": "u", "turnPass": "p"]
        let json = try JSONSerialization.data(withJSONObject: announce)
        let sealed = try friend.engine.sealCircleMedia(circleId: "default", data: json)
        store.deliverFrameForTesting(frame(19, lp("default") + sealed))
        await Harness.until(store, "relay adopted") { RelayMailboxStore.shared.relays(forCircle: "default").contains(relayHex) }
        let entry = RelayMailboxStore.shared.entries[relayHex]
        XCTAssertEqual(entry?.httpUrls, ["https://relay.example.com"])
        XCTAssertEqual(entry?.httpToken, "tok123")
        XCTAssertEqual(entry?.derpUrl, "https://derp.example.com")
        XCTAssertEqual(entry?.turnUrls, ["turn:turn.example.com:3478"])
        // A bare 64-hex announce (legacy) adds another.
        let legacyHex = String(repeating: "4e", count: 32)
        store.deliverFrameForTesting(frame(19, lp("default") + (try friend.engine.sealCircleMedia(circleId: "default", data: Data(legacyHex.utf8)))))
        await Harness.until(store, "legacy relay adopted") { RelayMailboxStore.shared.relays(forCircle: "default").contains(legacyHex) }
        // A relay the user deleted is never resurrected by an announce.
        RelayMailboxStore.shared.forget(nodeHex: legacyHex)
        store.deliverFrameForTesting(frame(19, lp("default") + (try friend.engine.sealCircleMedia(circleId: "default", data: Data(legacyHex.utf8)))))
        // Frames are handled in arrival order, so once a LATER announce lands the forgotten one has been judged.
        let thirdHex = String(repeating: "5f", count: 32)
        store.deliverFrameForTesting(frame(19, lp("default") + (try friend.engine.sealCircleMedia(circleId: "default", data: Data(thirdHex.utf8)))))
        await Harness.until(store, "later announce lands") { RelayMailboxStore.shared.relays(forCircle: "default").contains(thirdHex) }
        XCTAssertFalse(RelayMailboxStore.shared.isActive(legacyHex))
        XCTAssertFalse(RelayMailboxStore.shared.relays(forCircle: "default").contains(legacyHex))
        store.deliverFrameForTesting(frame(19, lp("default") + Data([1, 2, 3])))   // unopenable
        for h in [relayHex, legacyHex, thirdHex] { RelayMailboxStore.shared.eraseNow(h); RelayMailboxStore.shared.dropErased(h) }
    }

    func testEveryFrameTypeToleratesGarbage() async {
        let store = await Harness.feed()
        let garbage = Data((0..<48).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        for type in UInt8(0)...UInt8(40) where type != HistoryHandoff.nudgeFrame {
            store.deliverFrameForTesting(frame(type, garbage))
            store.deliverFrameForTesting(frame(type, Data()))
        }
        store.deliverFrameForTesting(frame(200, garbage))
        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.internetActive, "any frame over the internet path marks it live")
    }
}
