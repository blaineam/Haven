import Foundation

/// Pure model behind the CarPlay conversation list: threads in, display rows out. No CarPlay, no
/// FeedStore - so ordering, truncation, unread and the locked/privacy rules are unit-tested on the
/// host (`CarPlayConversationsTests`). `CarPlaySceneDelegate` maps `Row` onto `CPMessageListItem`.
enum CarPlayConversations {
    struct Row: Equatable {
        /// The DM circle id. Handed back to the Intents extension by Siri as `conversationIdentifier`.
        var conversationId: String
        var title: String
        var detail: String
        /// Short time of the newest message ("" when the thread is empty).
        var trailing: String
        var unread: Bool
        var locked: Bool
    }

    /// One callable person/group in the Calls tab.
    struct CallRow: Equatable {
        var conversationId: String
        var title: String
    }

    /// CarPlay's list cap varies by head unit (`CPListTemplate.maximumItemCount`); the delegate passes
    /// the live value, this is the fallback/upper bound.
    static let defaultLimit = 12

    static func rows(threads: [MessagingThread], detail: SharedNotificationPrivacy.Detail,
                     now: Date, calendar: Calendar = .current, locale: Locale = .current,
                     limit: Int = defaultLimit) -> [Row] {
        let built = threads.map { t -> (row: Row, at: UInt64) in
            let newest = MessagingPrivacy.latest(t.messages)
            let unread = !t.locked && MessagingPrivacy.unreadCount(t.messages, watermark: t.watermark) > 0
            let text = MessagingPrivacy.preview(of: newest, locked: t.locked, unread: unread, detail: detail)
            let at = newest?.createdAt ?? 0
            let trailing = (at == 0 || t.locked) ? "" : timeLabel(ms: at, now: now, calendar: calendar, locale: locale)
            return (Row(conversationId: t.id, title: MessagingPrivacy.truncate(t.title, limit: 60), detail: text,
                        trailing: trailing, unread: unread, locked: t.locked), at)
        }
        let sorted = built.sorted { a, b in
            a.at != b.at ? a.at > b.at : a.row.title.localizedCaseInsensitiveCompare(b.row.title) == .orderedAscending
        }
        return sorted.prefix(max(0, limit)).map(\.row)
    }

    /// Who can be called from the car: recent conversations, locked ones left out entirely (no Face ID on
    /// a head unit, and a locked name is not shown), empty groups left out (nobody to ring).
    static func callRows(threads: [MessagingThread], limit: Int = defaultLimit) -> [CallRow] {
        let callable = threads.filter { !$0.locked && !$0.memberHandles.isEmpty }
        let sorted = callable.sorted { a, b in
            let x = MessagingPrivacy.latest(a.messages)?.createdAt ?? 0, y = MessagingPrivacy.latest(b.messages)?.createdAt ?? 0
            return x != y ? x > y : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        return sorted.prefix(max(0, limit)).map { CallRow(conversationId: $0.id, title: MessagingPrivacy.truncate($0.title, limit: 60)) }
    }

    // MARK: Conversation screen (tap a row)

    /// One message line on the conversation screen.
    struct Line: Equatable {
        var id: String
        var text: String
        /// "Maya - 3:41 PM" / "You - Yesterday".
        var byline: String
        var unread: Bool
    }

    /// What tapping a conversation shows: the recent messages (newest first) plus what may be done with
    /// them. Built from the SAME privacy filter as the list rows, so nothing appears here that the row
    /// or a banner would hide.
    struct Detail: Equatable {
        var conversationId: String
        var title: String
        var locked: Bool
        var lines: [Line]
        var unreadCount: Int
        /// Haven may read this conversation aloud (unlocked and the privacy setting allows content).
        var canSpeak: Bool
        /// The privacy setting hides message text: say so instead of showing a blank list.
        var textHidden: Bool
        /// Someone to ring (not locked, has a member).
        var callable: Bool
    }

    static let maxDetailLines = 8
    static let detailTextLimit = 200

    static func detail(thread t: MessagingThread, detail: SharedNotificationPrivacy.Detail, now: Date,
                       calendar: Calendar = .current, locale: Locale = .current,
                       limit: Int = maxDetailLines) -> Detail {
        let multi = t.memberHandles.count > 1
        guard !t.locked else {
            return Detail(conversationId: t.id, title: t.title, locked: true, lines: [], unreadCount: 0,
                          canSpeak: false, textHidden: false, callable: false)
        }
        let newestFirst = t.messages.sorted { $0.createdAt > $1.createdAt }
        var lines: [Line] = []
        for m in newestFirst {
            let unread = !m.isMe && !m.unsent && m.createdAt > t.watermark
            let text = lineText(m, unread: unread, detail: detail)
            guard !text.isEmpty else { continue }
            let who = m.isMe ? MessagingText.you : (multi && !m.author.isEmpty ? m.author : "")
            let when = timeLabel(ms: m.createdAt, now: now, calendar: calendar, locale: locale)
            lines.append(Line(id: m.id, text: text, byline: [who, when].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "), unread: unread))
            if lines.count >= limit { break }
        }
        return Detail(conversationId: t.id, title: t.title, locked: false, lines: lines,
                      unreadCount: MessagingPrivacy.unreadCount(t.messages, watermark: t.watermark),
                      canSpeak: detail == .full, textHidden: detail != .full,
                      callable: !t.memberHandles.isEmpty)
    }

    /// Longer than the row preview (the screen exists to be read), same privacy tiers.
    private static func lineText(_ m: MessagingMessage, unread: Bool, detail: SharedNotificationPrivacy.Detail) -> String {
        guard detail == .full else { return MessagingPrivacy.preview(of: m, locked: false, unread: unread, detail: detail) }
        if m.unsent { return MessagingText.unsent }
        let text = MessagingPrivacy.truncate(m.body, limit: detailTextLimit)
        return text.isEmpty ? m.attachmentPhrase : text
    }

    /// What Haven reads aloud for "Read new messages" / "Read to me": an intro, then the unread inbound
    /// messages oldest first (or, with nothing unread, the latest few). Empty when nothing may be spoken
    /// (locked, or the privacy setting forbids content). Attachments are spoken as their phrase
    /// ("Sent a photo") - there is no content description of an image in the car.
    static let maxSpoken = 5

    static func spokenScript(thread t: MessagingThread, detail: SharedNotificationPrivacy.Detail) -> [String] {
        guard !t.locked, detail == .full else { return [] }
        let multi = t.memberHandles.count > 1
        let inbound = t.messages.filter { !$0.isMe && !$0.unsent }.sorted { $0.createdAt < $1.createdAt }
        let unread = inbound.filter { $0.createdAt > t.watermark }
        let pool = Array((unread.isEmpty ? inbound : unread).suffix(maxSpoken))
        let name = t.title
        guard !pool.isEmpty else { return [MessagingText.noneYet(from: name)] }
        var out: [String] = []
        if unread.isEmpty { out.append(MessagingText.recentFrom(name)) }
        else if unread.count == 1 { out.append(MessagingText.oneNewMessage(from: name)) }
        else { out.append(MessagingText.newMessages(unread.count, from: name)) }
        for m in pool {
            let text = MessagingPrivacy.spokenText(m, locked: false, detail: detail)
            guard !text.isEmpty else { continue }
            out.append(multi && !m.author.isEmpty ? MessagingText.says(m.author, text) : text)
        }
        return out
    }

    /// Today -> "3:41 PM"; yesterday -> "Yesterday"; this week -> weekday; older -> short date.
    static func timeLabel(ms: UInt64, now: Date, calendar: Calendar, locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            f.timeStyle = .short; f.dateStyle = .none
        } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return "Yesterday"
        } else if let w = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= w, date <= now {
            f.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            f.timeStyle = .none; f.dateStyle = .short
        }
        return f.string(from: date)
    }
}
