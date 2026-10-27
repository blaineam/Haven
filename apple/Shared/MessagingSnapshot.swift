import Foundation

/// The privacy-filtered, Foundation-only view of Haven's direct-message threads that the car (CarPlay
/// list) and Siri (the Intents extension) are allowed to see.
///
/// Two consumers, one rule set:
///   * the CarPlay scene runs inside the app and builds rows from live `FeedStore` data;
///   * the **Intents extension** is a separate process with no engine and no identity, so the app
///     mirrors a small, already-filtered snapshot into the App Group (`MessagingSnapshotStore`) for it.
///
/// Both go through `MessagingThread` -> `MessagingPrivacy.preview`, so a locked or privacy-restricted
/// conversation can never leak text on one surface that the other hides.
///
/// Privacy rules (docs/CARPLAY.md):
///   * a biometric-locked conversation NEVER carries message text - only the word "Locked";
///   * the user's notification-privacy setting (`SharedNotificationPrivacy.Detail`) caps the text:
///     `.full` shows the message, `.privateDetail` shows only "Sent you a message", `.minimal` shows
///     "New activity" and nothing about who or what.
/// Every user-visible phrase the car and Siri may speak or show, localized from the `Messaging` string
/// table (shipped in the app, the Intents extension and the notification extension). Without a table
/// (host-less tests) the English key comes back.
enum MessagingText {
    private static func t(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Messaging") }
    static var locked: String { t("Locked") }
    static var newActivity: String { t("New activity") }
    static var unsent: String { t("Message unsent") }
    static var sentAMessage: String { t("Sent you a message") }
    static var youSentAMessage: String { t("You sent a message") }
    static var photo: String { t("Sent a photo") }
    static var video: String { t("Sent a video") }
    static var voice: String { t("Sent a voice note") }
    static var file: String { t("Sent a file") }
    static var song: String { t("Shared a song") }
    static var attachment: String { t("Sent an attachment") }
    static var groupPhoto: String { t("Sent the group a photo") }
    static var groupVoice: String { t("Sent the group a voice note") }
    static var groupMessage: String { t("Messaged the group") }

    // CarPlay screens
    static var tabMessages: String { t("Messages") }
    static var tabCalls: String { t("Calls") }
    static var noConversations: String { t("No conversations yet") }
    static var noConversationsHint: String { t("Say \u{201C}Hey Siri, send a message with Haven\u{201D} once you have someone to talk to.") }
    static var openOnPhone: String { t("Open Haven on your iPhone") }
    static var openOnPhoneHint: String { t("Finish setting up to see your conversations.") }
    static var turnedOff: String { t("Turned off") }
    static var turnedOffHint: String { t("Turn on CarPlay and Siri messages in Haven Settings on your iPhone.") }
    static var noOneToCall: String { t("No one to call yet") }
    static var noOneToCallHint: String { t("Conversations you can call appear here.") }
    static var audioCall: String { t("Haven audio call") }

    // CarPlay conversation screen + spoken summaries
    static var readNew: String { t("Read new messages") }
    static var readToMe: String { t("Read to me") }
    static var readHint: String { t("Haven reads them aloud") }
    static var reply: String { t("Reply") }
    static var replyHint: String { t("Say your message to Siri") }
    static var callOnHaven: String { t("Call on Haven") }
    static var recentMessages: String { t("Recent messages") }
    static var noMessagesYet: String { t("No messages yet") }
    static var you: String { t("You") }
    static var lockedHint: String { t("Unlock this conversation in Haven on your iPhone.") }
    static var hiddenHint: String { t("Message text is hidden by your notification privacy setting.") }
    static var nothingToSpeak: String { t("Nothing to read right now.") }
    static func oneNewMessage(from name: String) -> String { String(format: String(localized: "One new message from %@.", table: "Messaging"), name) }
    static func newMessages(_ n: Int, from name: String) -> String { String(format: String(localized: "%lld new messages from %@.", table: "Messaging"), n, name) }
    static func recentFrom(_ name: String) -> String { String(format: String(localized: "Recent messages from %@.", table: "Messaging"), name) }
    static func noneYet(from name: String) -> String { String(format: String(localized: "No messages from %@ yet.", table: "Messaging"), name) }
    static func says(_ author: String, _ text: String) -> String { String(format: String(localized: "%1$@ says: %2$@", table: "Messaging"), author, text) }
}

struct MessagingMessage: Equatable {
    /// What a message carries besides (or instead of) text. Drives the spoken fallback, e.g. "Sent a photo".
    enum Attachment: Equatable { case none, photo, video, voice, file, song, other }

    var id: String
    var isMe: Bool
    var unsent: Bool
    /// Unix milliseconds.
    var createdAt: UInt64
    var body: String
    var hasAttachment: Bool
    /// Display name of the author ("" for my own messages).
    var author: String = ""
    /// Kind of attachment when `hasAttachment` (nil/`.none` with `hasAttachment` reads as "an attachment").
    var attachment: Attachment = .none

}

extension MessagingMessage.Attachment {
    /// Kind from the media refs' prefixes (the same `img_`/`vid_`/`aud_`/`file_` encoding the media layer
    /// uses - no IO). The first ref decides a mixed message.
    static func kind(mediaRefs: [String], hasMusic: Bool) -> MessagingMessage.Attachment {
        if let first = mediaRefs.first {
            if first.hasPrefix("img_") { return .photo }
            if first.hasPrefix("vid_") { return .video }
            if first.hasPrefix("aud_") { return .voice }
            if first.hasPrefix("file_") { return .file }
            return .other
        }
        return hasMusic ? .song : .none
    }
}

extension MessagingMessage {
    /// "Sent a photo" etc. for an attachment-only message; "" when there is no attachment.
    var attachmentPhrase: String {
        guard hasAttachment || attachment != .none else { return "" }
        switch attachment {
        case .photo: return MessagingText.photo
        case .video: return MessagingText.video
        case .voice: return MessagingText.voice
        case .file: return MessagingText.file
        case .song: return MessagingText.song
        case .none, .other: return MessagingText.attachment
        }
    }
}

struct MessagingThread: Equatable {
    var id: String
    var title: String
    /// Node ids of everyone but me. Siri resolves recipients against these.
    var memberHandles: [String]
    /// Other names this person is known by (their signed name vs your nickname for them), so a spoken
    /// "Tracy Miller" finds the thread you titled "Tracy M". Empty for groups.
    var aliases: [String] = []
    /// Any order; the builders sort.
    var messages: [MessagingMessage]
    /// Read watermark, unix ms. Inbound messages newer than this are unread.
    var watermark: UInt64
    var locked: Bool
}

enum MessagingPrivacy {
    static var lockedText: String { MessagingText.locked }
    static let previewLimit = 80

    /// Newest message (by `createdAt`, ties keep the later element).
    static func latest(_ messages: [MessagingMessage]) -> MessagingMessage? {
        var best: MessagingMessage?
        for m in messages where best == nil || m.createdAt >= best!.createdAt { best = m }
        return best
    }

    /// Inbound, not unsent, newer than the watermark.
    static func unreadCount(_ messages: [MessagingMessage], watermark: UInt64) -> Int {
        messages.filter { !$0.isMe && !$0.unsent && $0.createdAt > watermark }.count
    }

    /// Collapse whitespace/newlines and cut to `limit` characters (grapheme clusters, so emoji and
    /// combined characters are never split) with a trailing ellipsis.
    static func truncate(_ text: String, limit: Int = previewLimit) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > limit, limit > 1 else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "\u{2026}"
    }

    /// The line a surface may show for a thread whose newest message is `message`.
    /// Empty string = nothing to show (an empty thread).
    static func preview(of message: MessagingMessage?, locked: Bool, unread: Bool,
                        detail: SharedNotificationPrivacy.Detail) -> String {
        if locked { return lockedText }
        guard let message else { return "" }
        switch detail {
        case .minimal:
            return unread ? MessagingText.newActivity : ""
        case .privateDetail:
            if message.unsent { return MessagingText.unsent }
            return message.isMe ? MessagingText.youSentAMessage : MessagingText.sentAMessage
        case .full:
            if message.unsent { return MessagingText.unsent }
            let text = truncate(message.body)
            if !text.isEmpty { return text }
            return message.attachmentPhrase
        }
    }

    /// The text Siri may READ ALOUD for one message; "" means "say nothing about the content".
    static func spokenText(_ message: MessagingMessage, locked: Bool,
                           detail: SharedNotificationPrivacy.Detail) -> String {
        guard !locked, detail == .full, !message.unsent else { return "" }
        let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return message.attachmentPhrase
    }
}

/// What the Intents extension reads. Already filtered at write time: `text` is empty whenever the
/// conversation is locked or the privacy setting forbids content.
struct MessagingSnapshot: Codable, Equatable {
    struct Message: Codable, Equatable {
        var id: String
        var author: String
        var isMe: Bool
        var at: UInt64
        var text: String
        var unread: Bool
    }
    struct Conversation: Codable, Equatable {
        var id: String
        var title: String
        var memberHandles: [String]
        /// Other names for matching (optional so snapshots written before this field still decode).
        var aliases: [String]? = nil
        var locked: Bool
        var lastActivity: UInt64
        var unreadCount: Int
        var messages: [Message]   // oldest -> newest
    }
    var version = 1
    var generatedAt: UInt64
    /// The privacy level the snapshot was built under (the extension echoes it in Siri's wording).
    var detail: String
    var conversations: [Conversation]

    static let maxConversations = 12
    static let maxMessages = 6
    /// The most recently active conversations keep a deeper history so Siri can answer "read earlier
    /// messages from Tracy" (the only sanctioned way to scroll back from a car - see docs/CARPLAY.md).
    static let deepConversations = 3
    static let maxDeepMessages = 20

    static func build(threads: [MessagingThread], detail: SharedNotificationPrivacy.Detail,
                      now: UInt64) -> MessagingSnapshot {
        let activity: [String: UInt64] = Dictionary(uniqueKeysWithValues: threads.map {
            ($0.id, MessagingPrivacy.latest($0.messages)?.createdAt ?? 0)
        })
        let deep = Set(threads.filter { !$0.locked }.sorted { activity[$0.id]! > activity[$1.id]! }
            .prefix(deepConversations).map(\.id))
        let convs = threads.map { t -> Conversation in
            let newest = latest(t.messages)
            let unreadN = t.locked ? 0 : MessagingPrivacy.unreadCount(t.messages, watermark: t.watermark)
            var msgs: [Message] = []
            if !t.locked {
                let recent = t.messages.sorted { $0.createdAt < $1.createdAt }.suffix(deep.contains(t.id) ? maxDeepMessages : maxMessages)
                msgs = recent.map { m in
                    Message(id: m.id, author: m.isMe ? "" : m.author, isMe: m.isMe, at: m.createdAt,
                            text: MessagingPrivacy.spokenText(m, locked: false, detail: detail),
                            unread: !m.isMe && !m.unsent && m.createdAt > t.watermark)
                }
            }
            return Conversation(id: t.id, title: t.title, memberHandles: t.memberHandles,
                                aliases: t.aliases.isEmpty ? nil : t.aliases, locked: t.locked,
                                lastActivity: newest?.createdAt ?? 0, unreadCount: unreadN, messages: msgs)
        }
        let top = convs.sorted { ($0.lastActivity, $1.title) > ($1.lastActivity, $0.title) }.prefix(maxConversations)
        return MessagingSnapshot(generatedAt: now, detail: detail.rawValue, conversations: Array(top))
    }

    private static func latest(_ m: [MessagingMessage]) -> MessagingMessage? { MessagingPrivacy.latest(m) }

    /// Candidates for `ContactMatching`: the title first, then the aliases.
    var matchCandidates: [ContactMatching.Candidate] {
        conversations.map { .init(id: $0.id, names: [$0.title] + ($0.aliases ?? [])) }
    }

    /// Fuzzy resolution of what Siri heard (several spellings of one person are fine) to conversations.
    func resolution(queries: [String]) -> ContactMatching.Resolution {
        ContactMatching.resolve(queries: queries, candidates: matchCandidates)
    }

    /// Every plausible conversation for a spoken name, best first (see `resolution` for the verdict).
    /// A locked conversation can still be resolved for SENDING; callers refuse to read it.
    func resolve(name: String) -> [Conversation] {
        let ids: [String]
        switch resolution(queries: [name]) {
        case .none: ids = []
        case .confident(let m), .tentative(let m): ids = [m.id]
        case .ambiguous(let ms): ids = ms.map(\.id)
        }
        return ids.compactMap { conversation(id: $0) }
    }

    func conversation(id: String) -> Conversation? { conversations.first { $0.id == id } }

    /// A conversation whose members include this handle (node id) - 1:1 threads only.
    func conversation(handle: String) -> Conversation? {
        conversations.first { $0.memberHandles == [handle] }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// App Group storage for the snapshot, and the request queue the extension fills for the app.
enum MessagingSnapshotStore {
    static let appGroup = "group.com.blaineam.kith"
    nonisolated(unsafe) static var containerOverride: URL?

    private static var dir: URL? {
        let base = containerOverride ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        return base?.appendingPathComponent("Messaging", isDirectory: true)
    }
    private static var fileURL: URL? { dir?.appendingPathComponent("snapshot.json") }

    /// App side. Protected until first unlock so Siri can read it with the phone locked in a pocket
    /// (the car case) but not before the first unlock after boot.
    static func write(_ snapshot: MessagingSnapshot) {
        guard let dir, let fileURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read() -> MessagingSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MessagingSnapshot.self, from: data)
    }

    /// Factory reset / feature switched off: the text must not outlive the account.
    static func clear() {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

/// Requests Siri (the Intents extension) leaves for the app: send this text, mark this thread read.
/// One file per request, so two requests can never overwrite each other; the app drains in order.
/// The extension has no engine - it only enqueues; the app does the sealing and sending.
struct SiriRequest: Codable, Equatable {
    enum Kind: String, Codable { case send, markRead, call }
    var id: String
    var kind: Kind
    var conversationId: String
    var text: String
    /// Unix milliseconds the request was made.
    var createdAt: UInt64
}

enum SiriRequestQueue {
    nonisolated(unsafe) static var containerOverride: URL?
    static let maxTextLength = 4000

    private static var dir: URL? {
        let base = containerOverride ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MessagingSnapshotStore.appGroup)
        return base?.appendingPathComponent("SiriRequests", isDirectory: true)
    }

    /// Extension side. Returns false when the request is unusable (no container, empty/oversized text).
    @discardableResult
    static func enqueue(kind: SiriRequest.Kind, conversationId: String, text: String = "",
                        now: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let dir, conversationId.hasPrefix("dm:") else { return false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .send, body.isEmpty || body.count > maxTextLength { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let req = SiriRequest(id: UUID().uuidString, kind: kind, conversationId: conversationId,
                              text: kind == .send ? body : "", createdAt: now)
        guard let data = try? JSONEncoder().encode(req) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent("\(String(format: "%020llu", now))-\(req.id).json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    /// App side: every pending request, oldest first. Undecodable files are removed.
    static func pending() -> [(file: URL, request: SiriRequest)] {
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(URL, SiriRequest)] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(SiriRequest.self, from: data) {
                out.append((url, r))
            } else { try? FileManager.default.removeItem(at: url) }
        }
        return out
    }

    static func complete(_ file: URL) { try? FileManager.default.removeItem(at: file) }

    static func clear() { if let dir { try? FileManager.default.removeItem(at: dir) } }
}

/// Filtering for "read my messages" requests, kept pure so the rules are tested without SiriKit.
enum MessagingSearch {
    struct Query {
        var onlyUnread = false
        var onlyRead = false
        /// Every term must appear (case/diacritic-insensitive) in the message text.
        var terms: [String] = []
        var from: Date?
        var to: Date?
        /// How many messages one answer reads aloud.
        var limit = 10
    }

    /// Matching messages, OLDEST first, at most `limit`, taking the NEWEST ones that match - so a request
    /// bounded by `to` ("earlier than that") yields the page just before it.
    static func select(_ messages: [MessagingSnapshot.Message], _ q: Query) -> [MessagingSnapshot.Message] {
        let terms = q.terms.map(ContactMatching.normalize).filter { !$0.isEmpty }
        let hits = messages.filter { m in
            if m.isMe || m.text.isEmpty { return false }
            if q.onlyUnread && !m.unread { return false }
            if q.onlyRead && m.unread { return false }
            let at = Date(timeIntervalSince1970: Double(m.at) / 1000)
            if let from = q.from, at < from { return false }
            if let to = q.to, at > to { return false }
            if !terms.isEmpty {
                let text = ContactMatching.normalize(m.text)
                if !terms.allSatisfy({ text.contains($0) }) { return false }
            }
            return true
        }.sorted { $0.at < $1.at }
        return Array(hits.suffix(max(0, q.limit)))
    }
}

/// The names Siri should be able to hear for "call/message <name> on Haven": registered with
/// `INVocabulary` (user-specific `contactName`s) so Siri maps a spoken "Tracy M" - a title that exists
/// nowhere in the user's Contacts - to Haven instead of failing or guessing a Contacts neighbour
/// ("Tracy", "Troy", ...). Pure so the rules are tested on the host.
enum MessagingVocabulary {
    /// Siri accepts at most 100 strings per type.
    static let maxNames = 100

    /// Most-recent conversation first: every title and alias, then (after all full names, so a full name
    /// always outranks a bare first name) each distinct first name. Locked conversations contribute
    /// nothing - their names are part of what the lock hides. Duplicates (after folding) are dropped.
    static func names(threads: [MessagingThread]) -> [String] {
        let open = threads.filter { !$0.locked }.sorted {
            (MessagingPrivacy.latest($0.messages)?.createdAt ?? 0) > (MessagingPrivacy.latest($1.messages)?.createdAt ?? 0)
        }
        var seen = Set<String>(), out: [String] = []
        func add(_ raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ContactMatching.normalize(name)
            guard !key.isEmpty, name.count <= 60, seen.insert(key).inserted else { return }
            out.append(name)
        }
        for t in open { ([t.title] + t.aliases).forEach(add) }
        for t in open {
            for full in [t.title] + t.aliases where ContactMatching.tokens(full).count > 1 {
                if let first = full.split(whereSeparator: { $0.isWhitespace }).first { add(String(first)) }
            }
        }
        return Array(out.prefix(maxNames))
    }
}
