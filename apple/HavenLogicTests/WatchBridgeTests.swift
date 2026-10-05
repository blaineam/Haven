import XCTest

/// The iPhone ↔ Watch wire. WCSession only carries property-list types, so every message is pushed
/// through PropertyListSerialization here exactly as the transport would, then decoded on the
/// "other side".
final class WatchBridgeTests: XCTestCase {

    private func overTheWire(_ dict: [String: Any]) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testSnapshotRoundTripsThroughAPlist() throws {
        let snap = WatchSnapshot(threads: [
            WatchThread(id: "dm:abc", title: "Mom", subtitle: "see you 💜", timestamp: 1_700_000_000_000, isDM: true, unread: 2),
            WatchThread(id: "fam", title: "Family", subtitle: "", timestamp: 1, isDM: false, unread: 0),
        ], generatedAt: 42)
        let wire = try overTheWire(WatchCodec.encode(.snapshot, snap))
        XCTAssertEqual(WatchCodec.kind(of: wire), .snapshot)
        XCTAssertEqual(WatchCodec.decode(WatchSnapshot.self, from: wire), snap)
    }

    func testThreadDetailWithMediaRoundTrips() throws {
        let msg = WatchMessage(id: "p1", author: "You", isMe: true, body: "pic", timestamp: 5, hasMedia: true,
                               reactions: "❤️2", media: [WatchMedia(thumbnail: Data([0xFF, 0xD8, 0x00]), w: 400, h: 300, isVideo: false)],
                               isStory: true)
        let detail = WatchThreadDetail(threadId: "fam", title: "Family", isDM: false, messages: [msg])
        let wire = try overTheWire(WatchCodec.encode(.thread, detail))
        let back = try XCTUnwrap(WatchCodec.decode(WatchThreadDetail.self, from: wire))
        XCTAssertEqual(back, detail)
        XCTAssertEqual(back.messages[0].media[0].thumbnail, Data([0xFF, 0xD8, 0x00]))
    }

    func testReplyCarriesTheCommentTargetOnlyWhenSet() throws {
        let comment = try overTheWire(WatchCodec.encode(.quickReply, WatchReply(threadId: "fam", body: "nice", targetId: "p1")))
        XCTAssertEqual(WatchCodec.decode(WatchReply.self, from: comment)?.targetId, "p1")
        let dm = try overTheWire(WatchCodec.encode(.quickReply, WatchReply(threadId: "dm:x", body: "ok")))
        XCTAssertNil(WatchCodec.decode(WatchReply.self, from: dm)?.targetId)
    }

    func testBareKindHasNoPayload() throws {
        let wire = try overTheWire(WatchCodec.encode(.requestSnapshot))
        XCTAssertEqual(WatchCodec.kind(of: wire), .requestSnapshot)
        XCTAssertNil(WatchCodec.decode(WatchSnapshot.self, from: wire))
    }

    func testUnknownKindsAndWrongPayloadsDecodeToNil() {
        XCTAssertNil(WatchCodec.kind(of: [WatchWire.kind: "selfDestruct"]))
        XCTAssertNil(WatchCodec.kind(of: [:]))
        XCTAssertNil(WatchCodec.decode(WatchSnapshot.self, from: [WatchWire.payload: Data("nope".utf8)]))
        // A reaction payload must not decode as a reply.
        let react = WatchCodec.encode(.react, WatchReaction(threadId: "t", messageId: "m", emoji: "🔥"))
        XCTAssertNil(WatchCodec.decode(WatchSnapshot.self, from: react))
        XCTAssertEqual(WatchCodec.decode(WatchReaction.self, from: react)?.emoji, "🔥")
    }

    func testMediaAspectIsClampedAndDefaultsToSquare() {
        XCTAssertEqual(WatchMedia(thumbnail: Data(), w: 400, h: 300, isVideo: false).aspect, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(WatchMedia(thumbnail: Data(), w: 4000, h: 100, isVideo: false).aspect, 2.0)
        XCTAssertEqual(WatchMedia(thumbnail: Data(), w: 100, h: 4000, isVideo: false).aspect, 0.5)
        XCTAssertEqual(WatchMedia(thumbnail: Data(), w: 0, h: 300, isVideo: true).aspect, 1)
    }

    func testRelativeTime() {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        XCTAssertEqual(watchRelativeTime(0), "")
        XCTAssertEqual(watchRelativeTime(now), "now")
        XCTAssertEqual(watchRelativeTime(now - 2 * 3_600_000 - 1000), "2h")
        XCTAssertEqual(watchRelativeTime(now - 3 * 86_400_000 - 1000), "3d")
        XCTAssertEqual(watchRelativeTime(now - 15 * 86_400_000), "2w")
    }
}
