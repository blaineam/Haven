#if os(iOS)
import Foundation

/// Reads Haven's live DM state into the Foundation-only `MessagingThread` model that the CarPlay
/// list and the Siri snapshot are built from. The only place app stores meet the car/Siri privacy
/// rules, so both surfaces stay in lockstep.
@MainActor
enum MessagingThreads {
    /// The user's notification-privacy level. Car/Siri surfaces are never looser than a banner.
    static var privacyDetail: SharedNotificationPrivacy.Detail { SharedNotificationPrivacy.detail }

    static let maxPerThread = MessagingSnapshot.maxDeepMessages

    static func current() -> [MessagingThread] {
        let store = FeedStore.shared
        guard store.isConfigured else { return [] }
        let reads = DMReadStore.shared
        return store.dmCircles.map { circle in
            // A conversation behind Face ID/Touch ID is "Locked" in the car regardless of whether it
            // was unlocked on the phone this session: nobody can authenticate on a head unit, and
            // a dashboard is visible to passengers.
            let locked = CircleSettingsStore.shared.biometricRequired(circle.id)
            let members = store.dmMemberHexes(circle.id)
            // feed() is newest-first; only the latest few matter to a car/Siri surface, and mapping a
            // long thread on every feed change would be wasted work.
            let items = Array(store.messages(in: circle.id).prefix(maxPerThread))
            let messages: [MessagingMessage] = locked ? [] : items.map { item in
                MessagingMessage(id: item.id, isMe: item.isMe, unsent: item.unsent, createdAt: item.createdAt,
                                 body: item.body, hasAttachment: !item.media.isEmpty || item.music != nil,
                                 author: item.isMe ? "" : (ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? "Someone"),
                                 attachment: .kind(mediaRefs: item.media, hasMusic: item.music != nil))
            }
            // Names this person is known by besides the thread title (your nickname vs their signed
            // name), so a spoken "Tracy Miller" finds the thread you titled "Tracy M".
            var aliases: [String] = []
            if members.count == 1, let contact = ContactsStore.shared.contact(forNodePrefix: members[0]) {
                aliases = [contact.name, contact.authoritativeName, contact.nickname].compactMap { $0 }.filter { !$0.isEmpty }
            }
            var thread = MessagingThread(id: circle.id, title: store.dmPartnerName(circle.id), memberHandles: members,
                                         aliases: aliases, messages: messages, watermark: reads.watermark(circle.id), locked: locked)
            // A locked thread keeps its newest TIME (so it sorts sensibly) but no text: a content-free
            // placeholder carries the stamp.
            if locked, let newest = items.map(\.createdAt).max() {
                thread.messages = [MessagingMessage(id: "", isMe: true, unsent: false, createdAt: newest,
                                                    body: "", hasAttachment: false)]
            }
            return thread
        }
    }
}
#endif
