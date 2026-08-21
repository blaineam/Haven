import Foundation
import UserNotifications

/// "The picture you reacted to has arrived." (`docs/PREVIEW-TIER-DESIGN.md` §4.4)
///
/// On a constrained link a post can arrive complete in every way that matters — real, signed, sealed,
/// with a readable 512px preview — while its full-resolution copy is still queued on the sender's
/// phone. People can and should react and reply to it anyway; that interaction is text, and text
/// crosses. But then the full picture lands silently, and the person who engaged with it never finds
/// out they can now actually see it.
///
/// So: remember what someone engaged with *while it was incomplete*, and tell them once — and only
/// once — when the real bytes turn up.
///
/// **Entirely device-local.** Nothing here is sent, synced, or sealed into anything. What you looked
/// at and reacted to is not information anyone else acquires; the store exists purely so this device
/// can notice a state change on its own behalf.
@MainActor
final class IncompleteInterestStore: ObservableObject {
    static let shared = IncompleteInterestStore()

    private struct Interest: Codable {
        let circleId: String
        let postId: String
        /// What the person was looking at when they engaged, for the notification's wording.
        let circleName: String
    }

    private static let key = "haven.incompleteInterest.v1"
    private var interests: [String: Interest] = {
        guard let raw = UserDefaults.standard.data(forKey: IncompleteInterestStore.key),
              let decoded = try? JSONDecoder().decode([String: Interest].self, from: raw)
        else { return [:] }
        return decoded
    }()

    private init() {}

    /// Record that this device engaged with `postId` while `refs` had not arrived.
    ///
    /// Bounded: an enthusiastic reactor on a slow link should not accumulate an unbounded ledger.
    /// Oldest entries fall off, which at worst means a missed notification — never a wrong one.
    func note(missing refs: [String], postId: String, circleId: String, circleName: String) {
        guard !refs.isEmpty else { return }
        for ref in refs where interests[ref] == nil {
            interests[ref] = Interest(circleId: circleId, postId: postId, circleName: circleName)
        }
        if interests.count > 500 {
            interests = Dictionary(uniqueKeysWithValues: Array(interests.suffix(250)))
        }
        save()
    }

    /// A blob just landed. If someone engaged with its post while it was missing, say so — once.
    ///
    /// Clearing before posting is deliberate: a ref that arrives, is evicted, and arrives again must
    /// not produce a second notification for the same interaction.
    func mediaArrived(_ ref: String) {
        guard let interest = interests.removeValue(forKey: ref) else { return }
        save()
        notify(interest)
    }

    /// Drop interest without notifying — for a post that was deleted or unsent before its media
    /// caught up. There is nothing to go and look at, so a notification would be a dead end.
    func forget(_ refs: [String]) {
        var changed = false
        for ref in refs where interests.removeValue(forKey: ref) != nil { changed = true }
        if changed { save() }
    }

    private func notify(_ interest: Interest) {
        let content = UNMutableNotificationContent()
        content.title = interest.circleName
        content.body = "A photo you reacted to has finished arriving."
        content.userInfo = ["c": interest.circleId, "p": interest.postId]
        content.sound = nil   // not news; it is a thing becoming viewable. A banner is enough.
        let req = UNNotificationRequest(identifier: "haven.mediaComplete.\(interest.postId)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(interests) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
