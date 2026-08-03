#if os(iOS)
import Foundation
import Intents
import UIKit

/// Puts Haven's conversations in the row at the top of every app's share sheet — the same surface
/// Messages, Signal and Slack use.
///
/// iOS builds that row from **donated `INSendMessageIntent` interactions**, not from anything it can
/// ask us for at share time: the share sheet is drawn by another process, often while Haven isn't
/// running at all, so the only way a Haven thread can appear there is if we handed the system a
/// description of it earlier. We donate one interaction per conversation, keyed by the `dm:` circle
/// id as `conversationIdentifier`; when the user taps that suggestion, iOS launches
/// `HavenShareExtension` with the matching intent attached and the id comes straight back to us
/// (`ShareViewController.chosenConversationId`).
///
/// **What actually leaves Haven's own storage:** the conversation's display name, its participants'
/// display names + node ids, and their avatars. No message content is ever donated — the intent
/// carries no `content`, and every donation is `.outgoingMessageText` with an empty body. It lands
/// in the system's on-device suggestions store (never iCloud-synced by us, never uploaded), and
/// `forgetAll()` removes all of it. Three things are never donated at all:
///   * biometric-locked circles (same rule as Spotlight indexing — a locked circle's existence is
///     part of what the lock hides),
///   * anything when `SettingsStore.shareSuggestions` is off, and
///   * group *circles* — only DMs, because a share suggestion is a "send to a person" affordance.
@MainActor
enum ShareSuggestions {
    /// How many conversations we keep in the system's suggestion pool. The share sheet only ever
    /// draws a handful; donating the whole thread list would just spray names into the suggestions
    /// store for rows nobody sees.
    private static let maxSuggested = 8

    // MARK: - Donation

    /// Donate one conversation. Call after sending into a thread and after receiving in one — the
    /// system ranks by donation recency, which is exactly the "recent conversations" order we want.
    static func donate(circleId: String) {
        guard eligible(circleId) else { return }
        let store = FeedStore.shared
        let others = store.dmMemberHexes(circleId)
        guard !others.isEmpty else { return }   // a thread with nobody in it isn't shareable

        let recipients = others.map { person(hex: $0) }
        let title = store.displayName(forCircle: circleId)
        let isGroup = others.count > 1
        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: nil,                                   // never donate message text
            speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: title) : nil,
            conversationIdentifier: circleId,
            serviceName: "Haven",
            sender: me(),
            attachments: nil)
        // The avatar shown on the suggestion tile. For a 1:1 it's the other person's photo; a group
        // DM has no single face, so it gets the thread's own image slot.
        if let image = tileImage(circleId: circleId, others: others) {
            if isGroup {
                intent.setImage(image, forParameterNamed: \.speakableGroupName)
            } else {
                intent.setImage(image, forParameterNamed: \.recipients)
            }
        }
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        // Group id = circle id so `forget(circleId:)` can retract exactly this thread later.
        interaction.groupIdentifier = circleId
        interaction.donate { error in
            if let error { HavenLog.sync("share-suggest donate failed: \(error.localizedDescription)") }
        }
    }

    /// Re-donate the most recently active conversations. Called at launch and when the user turns
    /// the setting back on, so a fresh install (or a re-enable) doesn't have to wait for the next
    /// message before the share sheet knows anything.
    static func donateRecent() {
        publishDestinations()   // the extension's picker, refreshed on the same beat
        guard SettingsStore.shared.shareSuggestions else { return }
        let store = FeedStore.shared
        var ranked: [(id: String, at: UInt64)] = []
        for id in store.dmCircles.map(\.id) where eligible(id) {
            ranked.append((id: id, at: lastActivity(id)))
        }
        ranked.sort { $0.at > $1.at }
        for entry in ranked.prefix(maxSuggested) { donate(circleId: entry.id) }
    }

    private static func lastActivity(_ circleId: String) -> UInt64 {
        let stamps: [UInt64] = FeedStore.shared.messages(in: circleId).map(\.createdAt)
        return stamps.max() ?? 0
    }

    // MARK: - The extension's destination picker

    /// Mirror the destination list into the App Group so the **share extension** can draw its own
    /// picker (`SharedDestinations`). Independent of the suggestion setting: this isn't a system
    /// surface holding names on its own, it's Haven's own extension reading Haven's own container,
    /// and switching it off would leave the share sheet unable to ask where anything goes.
    ///
    /// Biometric-locked circles are omitted — the extension runs outside the app's Face ID gate.
    static func publishDestinations() {
        let store = FeedStore.shared
        var items: [SharedDestinations.Item] = []
        var avatars: [String: Data] = [:]

        // DMs only. Circles are deliberately NOT mirrored: a post goes through Haven's own composer
        // (which owns the circle picker, music and location), so the extension has no use for them
        // and there's no reason to keep circle names in a container a second process can read.
        for circle in store.dmCircles where !CircleSettingsStore.shared.biometricRequired(circle.id) {
            let name = store.dmPartnerName(circle.id)
            var item = SharedDestinations.Item(id: circle.id, name: name, isDM: true,
                                               lastActivity: lastActivity(circle.id))
            if let hex = store.dmPartnerHex(circle.id) {
                if let image = ContactsStore.shared.avatarImage(forNodePrefix: hex),
                   let data = image.jpegData(compressionQuality: 0.7) {
                    let file = SharedDestinations.avatarFileName(for: circle.id)
                    avatars[file] = data
                    item.avatarFile = file
                }
                item.emoji = ContactsStore.shared.emoji(forNodePrefix: hex) ?? ""
            }
            items.append(item)
        }
        SharedDestinations.write(items, avatars: avatars)
    }

    // MARK: - Retraction

    /// Drop one conversation's suggestion — deleting the thread, or locking its circle, must take it
    /// out of the share sheet too, or the name outlives the thread it belonged to.
    static func forget(circleId: String) {
        INInteraction.delete(with: [circleId]) { error in
            if let error { HavenLog.sync("share-suggest forget failed: \(error.localizedDescription)") }
        }
    }

    /// Erase every donation we've made (setting turned off, or the account was wiped).
    static func forgetAll() {
        INInteraction.deleteAll { error in
            if let error { HavenLog.sync("share-suggest wipe failed: \(error.localizedDescription)") }
        }
    }

    /// A factory reset must also drop the destination mirror — otherwise the share extension keeps
    /// offering the old account's conversations, complete with faces.
    static func forgetDestinations() { SharedDestinations.clear() }

    // MARK: - Eligibility

    /// Only unlocked DM threads, and only while the user wants suggestions at all.
    private static func eligible(_ circleId: String) -> Bool {
        guard SettingsStore.shared.shareSuggestions else { return false }
        guard circleId.hasPrefix("dm:") else { return false }
        guard !CircleSettingsStore.shared.biometricRequired(circleId) else { return false }
        return true
    }

    // MARK: - People

    /// Me, as the sender of the donated (outgoing) interaction.
    private static func me() -> INPerson {
        let hex = FeedStore.shared.myNodeHex
        let handle = INPersonHandle(value: hex.isEmpty ? "me" : hex, type: .unknown)
        let mine = ProfileStore.shared.displayName
        let name = mine.isEmpty ? "Me" : mine
        return INPerson(personHandle: handle, nameComponents: nil, displayName: name,
                        image: avatarImage(ProfileStore.shared.avatar),
                        contactIdentifier: nil, customIdentifier: hex)
    }

    /// A contact as an `INPerson`. `customIdentifier` is the node id so the system's matching is
    /// stable even when the user renames someone.
    private static func person(hex: String) -> INPerson {
        let name = ContactsStore.shared.name(forNodePrefix: hex) ?? "Someone"
        let handle = INPersonHandle(value: hex, type: .unknown)
        return INPerson(personHandle: handle, nameComponents: nil, displayName: name,
                        image: avatarImage(ContactsStore.shared.avatarImage(forNodePrefix: hex)),
                        contactIdentifier: nil, customIdentifier: hex)
    }

    /// The image for the suggestion tile: the one partner's avatar in a 1:1, and for a group the
    /// first participant who actually has a photo (better than a blank tile).
    private static func tileImage(circleId: String, others: [String]) -> INImage? {
        for hex in others {
            if let image = avatarImage(ContactsStore.shared.avatarImage(forNodePrefix: hex)) { return image }
        }
        return nil
    }

    /// Avatars are donated as small JPEGs — the tile is ~44pt, and `INImage(imageData:)` keeps a copy
    /// in the suggestions store, so there's no reason to hand it a full-size bitmap.
    private static func avatarImage(_ image: UIImage?) -> INImage? {
        guard let data = image?.jpegData(compressionQuality: 0.8) else { return nil }
        return INImage(imageData: data)
    }
}
#endif
