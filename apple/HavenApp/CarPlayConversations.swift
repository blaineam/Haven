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
