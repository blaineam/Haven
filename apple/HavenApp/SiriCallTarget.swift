import Foundation

/// Which Haven conversation a Siri / CarPlay "call X" request means. Foundation-only so the rule is
/// covered by host tests; `SiriCallRouter` (iOS) feeds it the live DM list and places the call.
enum SiriCallTarget {
    /// Key the Intents extension puts in the continuation activity's userInfo.
    static let conversationKey = "havenConversationId"

    struct DM: Equatable {
        var id: String
        /// Everyone but me.
        var members: [String]
        var locked: Bool
    }

    /// The conversation id to call, or nil when the request can't (or must not) be honoured: unknown
    /// conversation, group of nobody, or a biometric-locked thread (no Face ID in a car).
    /// An explicit conversation id wins; otherwise a contact handle (node id) must match a 1:1 thread.
    static func resolve(userInfo: [AnyHashable: Any]?, contactHandle: String?, dms: [DM]) -> String? {
        if let id = userInfo?[conversationKey] as? String {
            return dms.first { $0.id == id && !$0.locked && !$0.members.isEmpty }?.id
        }
        guard let handle = contactHandle?.lowercased(), !handle.isEmpty else { return nil }
        return dms.first { !$0.locked && $0.members.count == 1 && $0.members[0].lowercased() == handle }?.id
    }
}
