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
        let counts = Dictionary(uniqueKeysWithValues: rows([unread, read, mine, unsent]).map { ($0.conversationId, $0.unreadCount) })
        XCTAssertEqual(counts, ["dm:a": 1, "dm:b": 0, "dm:c": 0, "dm:d": 0], "driving mode shows this count instead of any text")
    }

    func testAttachmentAndUnsentWording() {
        XCTAssertEqual(rows([thread("dm:a", "A", [msg("1", mins: 1, body: "", att: true)])])[0].detail, "Sent an attachment")
        XCTAssertEqual(rows([thread("dm:a", "A", [msg("1", mins: 1, unsent: true)])])[0].detail, "Message unsent")
        XCTAssertEqual(rows([thread("dm:a", "A", [])])[0].detail, "")
    }

    func testAttachmentOnlyMessagesSayWhatTheyAre() {
        func phrase(_ kind: MessagingMessage.Attachment) -> String {
            var m = msg("1", mins: 1, body: "", att: true); m.attachment = kind
            return rows([thread("dm:a", "A", [m])])[0].detail
        }
        XCTAssertEqual(phrase(.photo), "Sent a photo")
        XCTAssertEqual(phrase(.video), "Sent a video")
        XCTAssertEqual(phrase(.voice), "Sent a voice note")
        XCTAssertEqual(phrase(.file), "Sent a file")
        XCTAssertEqual(phrase(.song), "Shared a song")
        // Caption text wins over the attachment phrase.
        var m = msg("1", mins: 1, body: "look!", att: true); m.attachment = .photo
        XCTAssertEqual(rows([thread("dm:a", "A", [m])])[0].detail, "look!")
        // ... and the spoken line for Siri is the same phrase, but only at Full privacy.
        var p = msg("2", mins: 1, body: "", att: true); p.attachment = .photo
        XCTAssertEqual(MessagingPrivacy.spokenText(p, locked: false, detail: .full), "Sent a photo")
        XCTAssertEqual(MessagingPrivacy.spokenText(p, locked: false, detail: .privateDetail), "")
        XCTAssertEqual(MessagingPrivacy.spokenText(p, locked: true, detail: .full), "")
    }

    func testAttachmentKindFromMediaRefs() {
        typealias A = MessagingMessage.Attachment
        XCTAssertEqual(A.kind(mediaRefs: ["img_ab"], hasMusic: false), .photo)
        XCTAssertEqual(A.kind(mediaRefs: ["vid_ab", "img_cd"], hasMusic: false), .video, "first ref decides")
        XCTAssertEqual(A.kind(mediaRefs: ["aud_ab"], hasMusic: false), .voice)
        XCTAssertEqual(A.kind(mediaRefs: ["file_ab"], hasMusic: false), .file)
        XCTAssertEqual(A.kind(mediaRefs: ["zzz"], hasMusic: false), .other)
        XCTAssertEqual(A.kind(mediaRefs: [], hasMusic: true), .song)
        XCTAssertEqual(A.kind(mediaRefs: [], hasMusic: false), .none)
    }

    func testLockedNeverShowsTextOrTimeOrUnread() {
        let t = thread("dm:a", "Locked chat", [msg("1", mins: 1, body: "secret plans")], watermark: 0, locked: true)
        for d in [SharedNotificationPrivacy.Detail.full, .privateDetail, .minimal] {
            let r = rows([t], d)[0]
            XCTAssertEqual(r.detail, "Locked")
            XCTAssertFalse(r.detail.contains("secret"))
            XCTAssertEqual(r.trailing, "")
            XCTAssertFalse(r.unread)
            XCTAssertEqual(r.unreadCount, 0)
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

    func testCallRowsExcludeLockedAndEmptyGroupsAndOrderByRecency() {
        let t = [thread("dm:old", "Old", [msg("1", mins: 90)]),
                 thread("dm:new", "New", [msg("2", mins: 2)]),
                 thread("dm:lock", "Vault", [msg("3", mins: 1)], locked: true),
                 MessagingThread(id: "dm:solo", title: "Solo", memberHandles: [], messages: [msg("4", mins: 1)], watermark: 0, locked: false)]
        let r = CarPlayConversations.callRows(threads: t)
        XCTAssertEqual(r.map(\.conversationId), ["dm:new", "dm:old"])
        XCTAssertEqual(CarPlayConversations.callRows(threads: t, limit: 1).count, 1)
        XCTAssertEqual(CarPlayConversations.callRows(threads: t, limit: 0).count, 0)
    }

    func testSnapshotCarriesAliasesForMatching() {
        var t = thread("dm:t", "Tracy M", [msg("1", mins: 1)])
        t.aliases = ["Tracy Miller"]
        let s = MessagingSnapshot.build(threads: [t], detail: .full, now: 1)
        XCTAssertEqual(s.conversations[0].aliases, ["Tracy Miller"])
        XCTAssertEqual(s.resolve(name: "Tracy Miller").map(\.id), ["dm:t"])
        let round = try! JSONDecoder().decode(MessagingSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
        // A snapshot written before aliases existed still decodes.
        let legacy = #"{"version":1,"generatedAt":1,"detail":"full","conversations":[{"id":"dm:a","title":"A","memberHandles":["h"],"locked":false,"lastActivity":0,"unreadCount":0,"messages":[]}]}"#
        XCTAssertNil(try! JSONDecoder().decode(MessagingSnapshot.self, from: Data(legacy.utf8)).conversations[0].aliases)
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

    func testSnapshotCapsMessagesAndKeepsDeeperHistoryForTheMostRecentThree() {
        let many = { (id: String, base: Double) in (0..<30).map { self.msg("\(id)\($0)", mins: base + Double(30 - $0)) } }
        let threads = (0..<5).map { thread("dm:\($0)", "P\($0)", many("m\($0)-", Double($0) * 100)) }
        let s = MessagingSnapshot.build(threads: threads, detail: .full, now: 1)
        let depth = Dictionary(uniqueKeysWithValues: s.conversations.map { ($0.id, $0.messages.count) })
        XCTAssertEqual(depth["dm:0"], MessagingSnapshot.maxDeepMessages)
        XCTAssertEqual(depth["dm:2"], MessagingSnapshot.maxDeepMessages)
        XCTAssertEqual(depth["dm:3"], MessagingSnapshot.maxMessages, "older conversations stay shallow")
        XCTAssertEqual(s.conversation(id: "dm:0")?.messages.last?.id, "m0-29", "oldest -> newest")
        let lock = MessagingThread(id: "dm:L", title: "L", memberHandles: ["h"], messages: many("l", 0), watermark: 0, locked: true)
        XCTAssertEqual(MessagingSnapshot.build(threads: [lock], detail: .full, now: 1).conversations[0].messages.count, 0)
        let more = (0..<30).map { thread("dm:\($0)", "P\($0)", [msg("x\($0)", mins: Double($0))]) }
        XCTAssertEqual(MessagingSnapshot.build(threads: more, detail: .full, now: 1).conversations.count, MessagingSnapshot.maxConversations)
    }

    // MARK: Search ("read earlier messages from Tracy")

    private func snap(_ n: Int) -> [MessagingSnapshot.Message] {
        (0..<n).map { i in
            .init(id: "m\(i)", author: "Tracy", isMe: i % 7 == 6, at: UInt64(1_800_000_000_000 + i * 60_000),
                  text: i % 5 == 0 ? "lunch at noon? #\(i)" : "note \(i)", unread: i >= n - 3)
        }
    }

    func testSearchPagesBackwardsFromAnUpperBound() {
        let all = snap(20)
        var q = MessagingSearch.Query(); q.limit = 5
        let newest = MessagingSearch.select(all, q)
        XCTAssertEqual(newest.count, 5)
        XCTAssertEqual(newest.map(\.at), newest.map(\.at).sorted(), "oldest first")
        // Earlier than the oldest message just read.
        q.to = Date(timeIntervalSince1970: Double(newest[0].at) / 1000 - 1)
        let earlier = MessagingSearch.select(all, q)
        XCTAssertEqual(earlier.count, 5)
        XCTAssertLessThan(earlier.last!.at, newest[0].at, "the page before, no overlap")
    }

    func testSearchTermsDatesAndUnread() {
        let all = snap(20)
        var q = MessagingSearch.Query(); q.terms = ["LUNCH"]
        XCTAssertEqual(MessagingSearch.select(all, q).map(\.id), ["m0", "m5", "m10", "m15"])
        q.terms = ["lunch", "noon", "zebra"]
        XCTAssertTrue(MessagingSearch.select(all, q).isEmpty, "every term must match")
        q = MessagingSearch.Query(); q.onlyUnread = true
        XCTAssertEqual(MessagingSearch.select(all, q).map(\.id), ["m17", "m18", "m19"])
        q = MessagingSearch.Query(); q.onlyRead = true; q.limit = 100
        XCTAssertFalse(MessagingSearch.select(all, q).contains { $0.unread })
        q = MessagingSearch.Query(); q.limit = 100
        q.from = Date(timeIntervalSince1970: Double(all[10].at) / 1000)
        q.to = Date(timeIntervalSince1970: Double(all[12].at) / 1000)
        XCTAssertEqual(MessagingSearch.select(all, q).map(\.id), ["m10", "m11", "m12"])
        XCTAssertFalse(MessagingSearch.select(all, MessagingSearch.Query(limit: 100)).contains { $0.isMe }, "never reads my own messages back")
        XCTAssertTrue(MessagingSearch.select(all, MessagingSearch.Query(limit: 0)).isEmpty)
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
    // MARK: conversation screen + spoken script

    private func detail(_ t: MessagingThread, _ d: SharedNotificationPrivacy.Detail = .full) -> CarPlayConversations.Detail {
        CarPlayConversations.detail(thread: t, detail: d, now: now, calendar: cal, locale: locale)
    }

    func testDetailListsRecentMessagesNewestFirstWithAuthorAndTime() {
        var t = thread("dm:a", "Tracy M", [msg("1", mins: 90, mine: true, body: "where are you"), msg("2", mins: 5, body: "On my way"),
                                          msg("3", mins: 2, body: "", att: true)], watermark: ms(10))
        t.memberHandles = ["h1"]
        let d = detail(t)
        XCTAssertEqual(d.lines.map(\.id), ["3", "2", "1"])
        XCTAssertEqual(d.lines[0].text, MessagingText.attachment, "attachment-only message is described, not blank")
        XCTAssertEqual(d.lines[1].text, "On my way")
        XCTAssertEqual(d.lines[2].byline.hasPrefix("You"), true)
        XCTAssertEqual(d.lines.map(\.mine), [false, false, true], "drives the right-hand bubble glyph")
        XCTAssertEqual(d.unreadCount, 2)
        XCTAssertTrue(d.lines[0].unread && d.lines[1].unread && !d.lines[2].unread)
        XCTAssertTrue(d.canSpeak && d.callable && !d.locked && !d.textHidden)
    }

    func testDetailTextIsLongerThanTheRowPreviewButBounded() {
        let long = String(repeating: "word ", count: 80)
        let d = detail(thread("dm:a", "A", [msg("1", mins: 1, body: long)]))
        XCTAssertGreaterThan(d.lines[0].text.count, MessagingPrivacy.previewLimit)
        XCTAssertLessThanOrEqual(d.lines[0].text.count, CarPlayConversations.detailTextLimit)
    }

    func testDetailRespectsLockAndPrivacyLevels() {
        let t = thread("dm:a", "A", [msg("1", mins: 1, body: "secret plans"), msg("2", mins: 50, mine: true, body: "mine")])
        let locked = detail(thread("dm:a", "A", [msg("1", mins: 1, body: "secret")], locked: true))
        XCTAssertTrue(locked.locked)
        XCTAssertTrue(locked.lines.isEmpty && !locked.canSpeak && !locked.callable)
        for level in [SharedNotificationPrivacy.Detail.privateDetail, .minimal] {
            let d = detail(t, level)
            XCTAssertTrue(d.textHidden && !d.canSpeak, "\(level)")
            XCTAssertFalse(d.lines.contains { $0.text.contains("secret") || $0.text.contains("mine") }, "\(level) leaks text")
        }
        XCTAssertEqual(detail(t, .privateDetail).lines.first?.text, MessagingText.sentAMessage)
    }

    func testDetailCapsLines() {
        let t = thread("dm:a", "A", (0..<30).map { msg("m\($0)", mins: Double($0)) })
        XCTAssertEqual(detail(t).lines.count, CarPlayConversations.maxDetailLines)
        XCTAssertEqual(detail(t).lines.first?.id, "m0")
    }

    func testSpokenScriptIntroThenUnreadOldestFirst() {
        let t = thread("dm:a", "Tracy M", [msg("1", mins: 30, body: "old, read"), msg("2", mins: 9, body: "first new"),
                                          msg("3", mins: 4, body: "", att: true), msg("4", mins: 3, mine: true, body: "my reply")],
                       watermark: ms(20))
        XCTAssertEqual(CarPlayConversations.spokenScript(thread: t, detail: .full),
                       [MessagingText.newMessages(2, from: "Tracy M"), "first new", MessagingText.attachment])
        let one = thread("dm:a", "Tracy M", [msg("2", mins: 9, body: "only")], watermark: ms(20))
        XCTAssertEqual(CarPlayConversations.spokenScript(thread: one, detail: .full), [MessagingText.oneNewMessage(from: "Tracy M"), "only"])
    }

    func testSpokenScriptWithNothingUnreadReadsTheLatestAndWithNothingAtAllSaysSo() {
        let t = thread("dm:a", "Tracy M", [msg("1", mins: 30, body: "one"), msg("2", mins: 20, body: "two")], watermark: ms(1))
        XCTAssertEqual(CarPlayConversations.spokenScript(thread: t, detail: .full), [MessagingText.recentFrom("Tracy M"), "one", "two"])
        XCTAssertEqual(CarPlayConversations.spokenScript(thread: thread("dm:a", "Tracy M", []), detail: .full), [MessagingText.noneYet(from: "Tracy M")])
    }

    func testSpokenScriptIsCappedAndNamesGroupAuthors() {
        var t = thread("dm:g", "Crew", (0..<12).map { msg("m\($0)", mins: Double(20 - $0), body: "m\($0)", author: "Maya") })
        t.memberHandles = ["h1", "h2"]
        let s = CarPlayConversations.spokenScript(thread: t, detail: .full)
        XCTAssertEqual(s.count, 1 + CarPlayConversations.maxSpoken)
        XCTAssertEqual(s[1], MessagingText.says("Maya", "m7"), "the newest five, oldest first, with the speaker named in a group")
    }

    func testNothingIsSpokenWhenLockedOrPrivate() {
        let t = thread("dm:a", "A", [msg("1", mins: 1, body: "secret")])
        XCTAssertTrue(CarPlayConversations.spokenScript(thread: t, detail: .privateDetail).isEmpty)
        XCTAssertTrue(CarPlayConversations.spokenScript(thread: t, detail: .minimal).isEmpty)
        XCTAssertTrue(CarPlayConversations.spokenScript(thread: thread("dm:a", "A", [msg("1", mins: 1)], locked: true), detail: .full).isEmpty)
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
