import XCTest

/// What the Watch does with each message the phone sends, and the offline demo scene it falls back to.
/// Messages are pushed through a property-list round trip first, exactly as WCSession would carry them.
final class WatchClientLogicTests: XCTestCase {

    private func overTheWire(_ dict: [String: Any]) throws -> [String: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: Inbound parsing

    func testSnapshotIsParsed() throws {
        let snap = WatchSnapshot(threads: [WatchThread(id: "dm:a", title: "A", subtitle: "hi", timestamp: 9, isDM: true, unread: 1)], generatedAt: 77)
        XCTAssertEqual(WatchInbound.parse(try overTheWire(WatchCodec.encode(.snapshot, snap))), .snapshot(snap))
    }

    func testThreadIsParsed() throws {
        let detail = WatchThreadDetail(threadId: "dm:a", title: "A", isDM: true, messages: [
            WatchMessage(id: "1", author: "A", isMe: false, body: "yo", timestamp: 1, hasMedia: false, reactions: "")])
        XCTAssertEqual(WatchInbound.parse(try overTheWire(WatchCodec.encode(.thread, detail))), .thread(detail))
    }

    func testNoticeIsParsed() throws {
        let n = WatchNotice(title: "Mom", body: "call me", dedupeKey: "k1")
        XCTAssertEqual(WatchInbound.parse(try overTheWire(WatchCodec.encode(.notify, n))), .notice(n))
    }

    func testRequestsMeantForThePhoneAreIgnoredOnTheWatch() throws {
        XCTAssertEqual(WatchInbound.parse(WatchCodec.encode(.requestSnapshot)), .ignored)
        XCTAssertEqual(WatchInbound.parse(try overTheWire(WatchCodec.encode(.requestThread, WatchThreadRequest(threadId: "x")))), .ignored)
        XCTAssertEqual(WatchInbound.parse(try overTheWire(WatchCodec.encode(.quickReply, WatchReply(threadId: "x", body: "b")))), .ignored)
        XCTAssertEqual(WatchInbound.parse(try overTheWire(WatchCodec.encode(.react, WatchReaction(threadId: "x", messageId: "m", emoji: "👍")))), .ignored)
    }

    func testMalformedMessagesAreIgnoredNotFatal() {
        XCTAssertEqual(WatchInbound.parse([:]), .ignored)
        XCTAssertEqual(WatchInbound.parse([WatchWire.kind: "bogus"]), .ignored)
        XCTAssertEqual(WatchInbound.parse([WatchWire.kind: WatchWire.Kind.snapshot.rawValue]), .ignored, "snapshot with no payload")
        XCTAssertEqual(WatchInbound.parse([WatchWire.kind: WatchWire.Kind.thread.rawValue, WatchWire.payload: Data("junk".utf8)]), .ignored)
        XCTAssertEqual(WatchInbound.parse([WatchWire.kind: WatchWire.Kind.notify.rawValue, WatchWire.payload: "not data"]), .ignored)
    }

    // MARK: Replies + notices

    func testReplyCleaning() {
        XCTAssertEqual(WatchReplyRules.cleaned("  On my way \n"), "On my way")
        XCTAssertNil(WatchReplyRules.cleaned(""))
        XCTAssertNil(WatchReplyRules.cleaned("  \n\t "))
        XCTAssertEqual(WatchReplyRules.cleaned("👍"), "👍")
    }

    func testNotificationIdReplacesRatherThanStacks() {
        let a = WatchNotice(title: "t", body: "b", dedupeKey: "msg-9")
        let b = WatchNotice(title: "t2", body: "b2", dedupeKey: "msg-9")
        XCTAssertEqual(WatchReplyRules.notificationId(for: a), "wmirror-msg-9")
        XCTAssertEqual(WatchReplyRules.notificationId(for: a), WatchReplyRules.notificationId(for: b))
    }

    // MARK: Demo scene

    private let now: UInt64 = 1_800_000_000_000
    private func stubMedia() -> [WatchMedia] {
        [WatchMedia(thumbnail: Data([1]), w: 160, h: 120, isVideo: false), WatchMedia(thumbnail: Data([2]), w: 120, h: 150, isVideo: false)]
    }

    func testSeedHasThreeThreadsWithDetailsForEach() {
        let s = WatchDemoStore.seed(now: now, media: stubMedia())
        XCTAssertEqual(s.threads.map(\.id), ["dm:ari", "dm:noa", "circle:trail"])
        XCTAssertEqual(Set(s.details.keys), Set(s.threads.map(\.id)), "every listed thread must open offline")
        XCTAssertEqual(s.threads.filter(\.isDM).count, 2)
        XCTAssertEqual(s.threads.first?.unread, 1)
        XCTAssertEqual(s.threads.map(\.timestamp), s.threads.map(\.timestamp).sorted(by: >), "most recent first")
        XCTAssertNotNil(s.details[WatchDemoStore.defaultOpenThreadId])
    }

    func testSeedUsesTheInjectedMedia() {
        let s = WatchDemoStore.seed(now: now, media: stubMedia())
        XCTAssertEqual(s.details["dm:ari"]?.messages.last?.media.count, 2)
        let story = s.details["circle:trail"]?.messages.first
        XCTAssertEqual(story?.isStory, true)
        XCTAssertEqual(story?.media.count, 1, "the story shows one frame")
        let empty = WatchDemoStore.seed(now: now, media: [])
        XCTAssertEqual(empty.details["dm:ari"]?.messages.last?.media.count, 0)
    }

    func testSeedTimestampsAreRelativeToNow() {
        let a = WatchDemoStore.seed(now: now, media: [])
        let b = WatchDemoStore.seed(now: now + 1000, media: [])
        XCTAssertEqual(b.threads[0].timestamp - a.threads[0].timestamp, 1000)
    }

    func testAppendEchoesIntoTheThread() throws {
        var s = WatchDemoStore.seed(now: now, media: [])
        let before = try XCTUnwrap(s.details["dm:ari"]).messages.count
        let msg = WatchMessage(id: "demo-1", author: "You", isMe: true, body: "ok", timestamp: now, hasMedia: false, reactions: "")
        let updated = try XCTUnwrap(s.append(msg, to: "dm:ari"))
        XCTAssertEqual(updated.messages.count, before + 1)
        XCTAssertEqual(s.details["dm:ari"]?.messages.last?.body, "ok")
        XCTAssertNil(s.append(msg, to: "dm:nobody"))
    }

    func testReactAddsOrExtendsTheSummary() throws {
        var s = WatchDemoStore.seed(now: now, media: [])
        // m2 has no reactions yet; m1 has "👍1".
        XCTAssertEqual(try XCTUnwrap(s.react(threadId: "dm:ari", messageId: "m2", emoji: "❤️")).messages[1].reactions, "❤️1")
        XCTAssertEqual(try XCTUnwrap(s.react(threadId: "dm:ari", messageId: "m1", emoji: "🔥")).messages[0].reactions, "👍1 🔥1")
        XCTAssertNil(s.react(threadId: "dm:ari", messageId: "missing", emoji: "👍"))
        XCTAssertNil(s.react(threadId: "nope", messageId: "m1", emoji: "👍"))
    }
}
