#if os(iOS)
import Foundation
import Intents

/// Teaches Siri the names of Haven's conversations, so "call Tracy M on Haven" and "message Tracy on
/// Haven" reach the app instead of dying in Siri's own contact matching.
///
/// Why this exists: Siri resolves a spoken name BEFORE the Intents extension sees it. A conversation
/// title ("Tracy M", a nickname) is not in the user's Contacts, so without help Siri either fails
/// ("I can't find Tracy M") or offers phonetic Contacts neighbours ("Tracy", "Troy", ...) that mean
/// nothing to Haven. Messages worked only because the share-suggestion donations
/// (`ShareSuggestions`) happened to teach Siri those names; calls had nothing. Two registrations fix it:
///   * user-specific vocabulary (`INVocabulary` `.contactName`) - the conversation titles, aliases and
///     first names (`MessagingVocabulary`), most recent first;
///   * `INStartCallIntent` donations for the recently active unlocked conversations, carrying the node id
///     as `customIdentifier` so a spoken name arrives at the extension already tied to its conversation.
///
/// Privacy: the same rules as every car/Siri surface - biometric-locked conversations contribute nothing,
/// everything is off (and erased) with the CarPlay-and-Siri switch or an account reset, and only names
/// and node ids are registered, never message text. Lives in the on-device Siri store, never synced by us.
@MainActor
enum SiriContactVocabulary {
    /// How many conversations get a call donation (Siri only needs the recent ones).
    static let maxDonatedCalls = 8
    private static let kDonated = "haven.siri.donatedCallGroups"
    private static let kFingerprint = "haven.siri.vocabularyFingerprint"

    static func sync(threads: [MessagingThread]) {
        guard SettingsStore.shared.carPlayAndSiri else { forget(); return }
        let names = MessagingVocabulary.names(threads: threads)
        let callable = threads.filter { !$0.locked && !$0.memberHandles.isEmpty }
            .sorted { (MessagingPrivacy.latest($0.messages)?.createdAt ?? 0) > (MessagingPrivacy.latest($1.messages)?.createdAt ?? 0) }
            .prefix(maxDonatedCalls)
        // One fingerprint for names + who is donated: the publish runs on every feed change, but the
        // Siri stores only need touching when a name or the recent set actually changed.
        let fingerprint = (names + callable.map(\.id)).joined(separator: "\u{1F}")
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: kFingerprint) != fingerprint else { return }
        defaults.set(fingerprint, forKey: kFingerprint)

        INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: names), of: .contactName)

        // Retract donations for conversations that fell out of the recent set (or got locked).
        let keep = Set(callable.map { groupId($0.id) })
        let previous = Set(defaults.stringArray(forKey: kDonated) ?? [])
        let stale = Array(previous.subtracting(keep))
        if !stale.isEmpty { INInteraction.delete(with: stale) { _ in } }
        for t in callable { donate(t.id, title: t.title, handles: t.memberHandles) }
        defaults.set(Array(keep), forKey: kDonated)
    }

    /// A call was just placed (Siri, CarPlay or the app): the strongest "this is who 'call X' means" signal.
    static func donateCall(conversationId: String) {
        guard SettingsStore.shared.carPlayAndSiri, conversationId.hasPrefix("dm:"),
              !CircleSettingsStore.shared.biometricRequired(conversationId) else { return }
        let store = FeedStore.shared
        let handles = store.dmMemberHexes(conversationId)
        guard !handles.isEmpty else { return }
        donate(conversationId, title: store.dmPartnerName(conversationId), handles: handles)
        var groups = Set(UserDefaults.standard.stringArray(forKey: kDonated) ?? [])
        groups.insert(groupId(conversationId))
        UserDefaults.standard.set(Array(groups), forKey: kDonated)
    }

    /// Switch off / account reset: drop the vocabulary and every call donation we made.
    static func forget() {
        let defaults = UserDefaults.standard
        INVocabulary.shared().removeAllVocabularyStrings()
        let groups = defaults.stringArray(forKey: kDonated) ?? []
        if !groups.isEmpty { INInteraction.delete(with: groups) { _ in } }
        defaults.removeObject(forKey: kDonated)
        defaults.removeObject(forKey: kFingerprint)
    }

    private static func groupId(_ conversationId: String) -> String { "call:" + conversationId }

    /// The same `INPerson` the extension hands back from `resolveContacts` (`IntentMessaging.people`):
    /// a 1:1 carries its partner's node id, a group the conversation id.
    private static func donate(_ conversationId: String, title: String, handles: [String]) {
        let handle = handles.count == 1 ? handles[0] : conversationId
        let person = INPerson(personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil,
                              displayName: title, image: nil, contactIdentifier: nil, customIdentifier: handle)
        let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                                       destinationType: .normal, contacts: [person], callCapability: .audioCall)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = groupId(conversationId)
        interaction.donate { error in
            if let error { HavenLog.sync("siri call donate failed: \(error.localizedDescription)") }
        }
    }
}
#endif
