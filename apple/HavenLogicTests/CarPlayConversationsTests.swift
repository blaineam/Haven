import XCTest

/// The CarPlay list rows + the Siri snapshot: ordering, truncation, unread, and above all the
/// privacy rules - a locked conversation never carries text, and the notification-privacy setting
/// caps what any car/Siri surface may say.
final class CarPlayConversationsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()
    private let locale = Locale(identifier: "en_US_POSIX")
    // 2026-10-26 12:00:00 UTC
    private lazy var now = Date(timeIntervalSince1970: 1_793_016_000)
    private func ms(_ minutesAgo: Double) -> UInt64 { UInt64((now.timeIntervalSince1970 - minutesAgo * 60) * 1000) }

    private func msg(_ id: String, mins: Double, mine: Bool = false, body: String = "hi",
                     unsent: Bool = false, att: Bool = false, author: String = "Maya") -> MessagingMessage {
        MessagingMessage(id: id, isMe: mine, unsent: unsent, createdAt: ms(mins), body: body,
                         hasAttachment: att, author: author)
    }
    private func thread(_ id: String, _ title: String, _ messages: [MessagingMessage],
                        watermark: UInt64 = 0, locked: Bool = false) -> MessagingThread {
        MessagingThread(id: id, title: title, memberHandles: ["h-\(id)"], messages: messages,
                        watermark: watermark, locked: locked)
    }
    private func rows(_ t: [MessagingThread], _ d: SharedNotificationPrivacy.Detail = .full, limit: Int = 12) -> [CarPlayConversations.Row] {
        CarPlayConversations.rows(threads: t, detail: d, now: now, calendar: cal, locale: locale, limit: limit)
    }

    func testOrdersNewestFirstThenTitle() {
        let r = rows([thread("dm:a", "Zed", [msg("1", mins: 30)]),
                      thread("dm:b", "Amy", [msg("2", mins: 5)]),
                      thread("dm:c", "Bob", [msg("3", mins: 30)]),
                      thread("dm:d", "Empty", [])])
        XCTAssertEqual(r.map(\.conversationId), ["dm:b", "dm:c", "dm:a", "dm:d"])
    }

    func testLimitCapsRows() {
        let t = (0..<20).map { thread("dm:\($0)", "P\($0)", [msg("m\($0)", mins: Double($0))]) }
        XCTAssertEqual(rows(t, limit: 5).count, 5)
        XCTAssertEqual(rows(t, limit: 0).count, 0)
        XCTAssertEqual(rows(t).first?.conversationId, "dm:0")
    }

    func testPreviewCollapsesWhitespaceAndTruncatesByCharacter() {
        let long = String(repeating: "word ", count: 40)
        let r = rows([thread("dm:a", "A", [msg("1", mins: 1, body: "line1\n\n  line2\t" + long)])])
        XCTAssertLessThanOrEqual(r[0].detail.count, MessagingPrivacy.previewLimit)
        XCTAssertTrue(r[0].detail.hasPrefix("line1 line2 word"))
        XCTAssertTrue(r[0].detail.hasSuffix("\u{2026}"))
        // Emoji / combined characters are never split.
        let fam = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 200)
        let cut = MessagingPrivacy.truncate(fam, limit: 10)
        XCTAssertEqual(cut.count, 10)
        XCTAssertEqual(String(cut.dropLast()), String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 9))
    }

    func testShortTextUntouched() {
        XCTAssertEqual(MessagingPrivacy.truncate("  hello  world "), "hello world")
    }

    func testUnreadUsesWatermarkAndIgnoresMineAndUnsent() {
        let wm = ms(10)
        let unread = thread("dm:a", "A", [msg("1", mins: 5)], watermark: wm)
        let read = thread("dm:b", "B", [msg("2", mins: 20)], watermark: wm)
        let mine = thread("dm:c", "C", [msg("3", mins: 5, mine: true)], watermark: wm)
        let unsent = thread("dm:d", "D", [msg("4", mins: 5, unsent: true)], watermark: wm)
        let r = Dictionary(uniqueKeysWithValues: rows([unread, read, mine, unsent]).map { ($0.conversationId, $0.unread) })
        XCTAssertEqual(r, ["dm:a": true, "dm:b": false, "dm:c": false, "dm:d": false])
    }

    func testAttachmentAndUnsentWording() {
        XCTAssertEqual(rows([thread("dm:a", "A", [msg("1", mins: 1, body: "", att: true)])])[0].detail, "Attachment")
        XCTAssertEqual(rows([thread("dm:a", "A", [msg("1", mins: 1, unsent: true)])])[0].detail, "Message unsent")
        XCTAssertEqual(rows([thread("dm:a", "A", [])])[0].detail, "")
    }

    func testLockedNeverShowsTextOrTimeOrUnread() {
        let t = thread("dm:a", "Locked chat", [msg("1", mins: 1, body: "secret plans")], watermark: 0, locked: true)
        for d in [SharedNotificationPrivacy.Detail.full, .privateDetail, .minimal] {
            let r = rows([t], d)[0]
            XCTAssertEqual(r.detail, "Locked")
            XCTAssertFalse(r.detail.contains("secret"))
            XCTAssertEqual(r.trailing, "")
            XCTAssertFalse(r.unread)
            XCTAssertTrue(r.locked)
        }
    }

    func testNotificationPrivacyCapsText() {
        let t = thread("dm:a", "A", [msg("1", mins: 1, body: "dinner at 7?")])
        XCTAssertEqual(rows([t], .full)[0].detail, "dinner at 7?")
        XCTAssertEqual(rows([t], .privateDetail)[0].detail, "Sent you a message")
        XCTAssertEqual(rows([t], .minimal)[0].detail, "New activity")   // unread (watermark 0)
        let readT = thread("dm:a", "A", [msg("1", mins: 1, body: "dinner at 7?")], watermark: ms(0))
        XCTAssertEqual(rows([readT], .minimal)[0].detail, "")
        let mine = thread("dm:a", "A", [msg("1", mins: 1, mine: true, body: "secret")])
        XCTAssertEqual(rows([mine], .privateDetail)[0].detail, "You sent a message")
    }

    func testTimeLabels() {
        // ICU 72+ puts a NARROW NO-BREAK SPACE before AM/PM; compare with it normalised.
        XCTAssertEqual(CarPlayConversations.timeLabel(ms: ms(60), now: now, calendar: cal, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " "), "11:00 AM")
        XCTAssertEqual(CarPlayConversations.timeLabel(ms: ms(24 * 60), now: now, calendar: cal, locale: locale), "Yesterday")
        XCTAssertEqual(CarPlayConversations.timeLabel(ms: ms(3 * 24 * 60), now: now, calendar: cal, locale: locale), "Friday")
        XCTAssertEqual(CarPlayConversations.timeLabel(ms: ms(30 * 24 * 60), now: now, calendar: cal, locale: locale), "9/26/26")
    }

    // MARK: Snapshot (Siri)

    func testSnapshotFiltersTextByPrivacyAndLock() {
        let open = thread("dm:a", "Maya", [msg("1", mins: 3, body: "hello"), msg("2", mins: 2, mine: true, body: "yo")], watermark: ms(10))
        let lock = thread("dm:b", "Theo", [msg("3", mins: 1, body: "secret")], locked: true)
        let full = MessagingSnapshot.build(threads: [open, lock], detail: .full, now: 1)
        XCTAssertEqual(full.conversations.map(\.id), ["dm:b", "dm:a"])
        XCTAssertEqual(full.conversation(id: "dm:a")?.messages.map(\.text), ["hello", "yo"])
        XCTAssertEqual(full.conversation(id: "dm:a")?.unreadCount, 1)
        XCTAssertEqual(full.conversation(id: "dm:b")?.messages, [])
        XCTAssertTrue(full.conversation(id: "dm:b")!.locked)
        let priv = MessagingSnapshot.build(threads: [open], detail: .privateDetail, now: 1)
        XCTAssertEqual(priv.conversation(id: "dm:a")?.messages.map(\.text), ["", ""])
        let data = String(data: try! JSONEncoder().encode(MessagingSnapshot.build(threads: [lock], detail: .full, now: 1)), encoding: .utf8)!
        XCTAssertFalse(data.contains("secret"), "locked text must never reach the App Group file")
    }

    func testSnapshotCapsAndOrdersMessages() {
        let many = (0..<20).map { msg("m\($0)", mins: Double(20 - $0)) }
        let s = MessagingSnapshot.build(threads: [thread("dm:a", "A", many)], detail: .full, now: 1)
        let ids = s.conversations[0].messages.map(\.id)
        XCTAssertEqual(ids.count, MessagingSnapshot.maxMessages)
        XCTAssertEqual(ids.last, "m19")
        let threads = (0..<30).map { thread("dm:\($0)", "P\($0)", [msg("x", mins: Double($0))]) }
        XCTAssertEqual(MessagingSnapshot.build(threads: threads, detail: .full, now: 1).conversations.count, MessagingSnapshot.maxConversations)
    }

    func testResolveByName() {
        let s = MessagingSnapshot.build(threads: [thread("dm:a", "Maya Chen", [msg("1", mins: 1)]),
                                                  thread("dm:b", "Théo", [msg("2", mins: 2)]),
                                                  thread("dm:c", "Maya", [msg("3", mins: 3)])], detail: .full, now: 1)
        XCTAssertEqual(s.resolve(name: "maya").map(\.id), ["dm:c"], "exact beats partial")
        XCTAssertEqual(s.resolve(name: "chen").map(\.id), ["dm:a"])
        XCTAssertEqual(s.resolve(name: "theo").map(\.id), ["dm:b"], "diacritics folded")
        XCTAssertEqual(s.resolve(name: "  ").count, 0)
        XCTAssertEqual(s.resolve(name: "nobody").count, 0)
        XCTAssertEqual(s.conversation(handle: "h-dm:b")?.id, "dm:b")
    }

    // MARK: Storage + queue

    func testSnapshotStoreAndRequestQueueRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("msg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        MessagingSnapshotStore.containerOverride = root
        SiriRequestQueue.containerOverride = root
        defer { MessagingSnapshotStore.containerOverride = nil; SiriRequestQueue.containerOverride = nil }

        XCTAssertNil(MessagingSnapshotStore.read())
        let snap = MessagingSnapshot.build(threads: [thread("dm:a", "A", [msg("1", mins: 1)])], detail: .full, now: 7)
        MessagingSnapshotStore.write(snap)
        XCTAssertEqual(MessagingSnapshotStore.read(), snap)
        MessagingSnapshotStore.clear()
        XCTAssertNil(MessagingSnapshotStore.read())

        XCTAssertFalse(SiriRequestQueue.enqueue(kind: .send, conversationId: "dm:a", text: "   "))
        XCTAssertFalse(SiriRequestQueue.enqueue(kind: .send, conversationId: "circle-1", text: "hi"), "DMs only")
        XCTAssertFalse(SiriRequestQueue.enqueue(kind: .send, conversationId: "dm:a", text: String(repeating: "x", count: 5000)))
        XCTAssertTrue(SiriRequestQueue.enqueue(kind: .send, conversationId: "dm:a", text: " first ", now: 100))
        XCTAssertTrue(SiriRequestQueue.enqueue(kind: .markRead, conversationId: "dm:b", now: 50))
        XCTAssertTrue(SiriRequestQueue.enqueue(kind: .send, conversationId: "dm:a", text: "second", now: 200))
        let p = SiriRequestQueue.pending()
        XCTAssertEqual(p.map(\.request.kind), [.markRead, .send, .send], "oldest first")
        XCTAssertEqual(p.map(\.request.text), ["", "first", "second"])
        SiriRequestQueue.complete(p[0].file)
        XCTAssertEqual(SiriRequestQueue.pending().count, 2)
        SiriRequestQueue.clear()
        XCTAssertEqual(SiriRequestQueue.pending().count, 0)
    }
}

/// Which conversation a Siri/CarPlay "call X" means - and, as importantly, which it must refuse.
final class SiriCallTargetTests: XCTestCase {
    private let dms = [
        SiriCallTarget.DM(id: "dm:maya", members: ["AA11"], locked: false),
        SiriCallTarget.DM(id: "dm:vault", members: ["BB22"], locked: true),
        SiriCallTarget.DM(id: "dm:group", members: ["CC33", "DD44"], locked: false),
        SiriCallTarget.DM(id: "dm:empty", members: [], locked: false),
    ]

    func testExplicitConversationWins() {
        let info: [AnyHashable: Any] = [SiriCallTarget.conversationKey: "dm:group"]
        XCTAssertEqual(SiriCallTarget.resolve(userInfo: info, contactHandle: "aa11", dms: dms), "dm:group")
    }

    func testLockedAndEmptyAndUnknownAreRefused() {
        for id in ["dm:vault", "dm:empty", "dm:nope"] {
            XCTAssertNil(SiriCallTarget.resolve(userInfo: [SiriCallTarget.conversationKey: id], contactHandle: nil, dms: dms), id)
        }
    }

    func testHandleMatchesOnlyOneToOneThreadsCaseInsensitively() {
        XCTAssertEqual(SiriCallTarget.resolve(userInfo: nil, contactHandle: "aa11", dms: dms), "dm:maya")
        XCTAssertNil(SiriCallTarget.resolve(userInfo: nil, contactHandle: "bb22", dms: dms), "locked")
        XCTAssertNil(SiriCallTarget.resolve(userInfo: nil, contactHandle: "cc33", dms: dms), "group member alone is ambiguous")
        XCTAssertNil(SiriCallTarget.resolve(userInfo: nil, contactHandle: nil, dms: dms))
        XCTAssertNil(SiriCallTarget.resolve(userInfo: nil, contactHandle: "", dms: dms))
    }
}
