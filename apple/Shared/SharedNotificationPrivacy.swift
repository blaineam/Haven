import Foundation

/// How much detail Haven may put on a notification the user can see without unlocking.
///
/// Recipient-side only — the sender always seals both a full body and a private body; the
/// NSE on *this* device picks which to show based on:
/// 1. iOS **Show Previews** (Settings → Notifications → Show Previews), and
/// 2. this Haven preference.
///
/// Stored in the App Group so the Notification Service Extension (separate process, often
/// running on the lock screen) can read it without talking to the main app.
enum SharedNotificationPrivacy {
    static let appGroup = "group.com.blaineam.kith"
    private static let key = "haven.notification.previewDetail"

    /// What the user wants Haven to expose in banners.
    enum Detail: String, CaseIterable {
        /// Full sender-built body (message preview, reaction emoji, comment text).
        /// Still subject to iOS Show Previews on the lock screen.
        case full
        /// Sender name + kind only — no message text, no comment quote, no emoji.
        /// e.g. "Sent you a message", "Reacted to your post".
        case privateDetail = "private"
        /// Just "Haven" / "New activity" — maximum lock-screen silence.
        case minimal
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var detail: Detail {
        get {
            guard let raw = defaults.string(forKey: key),
                  let d = Detail(rawValue: raw) else { return .full }
            return d
        }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    /// Human labels for Settings.
    static func label(_ d: Detail) -> String {
        switch d {
        case .full:          return "Full previews"
        case .privateDetail: return "Name and type only"
        case .minimal:       return "Minimal"
        }
    }

    static func footer(_ d: Detail) -> String {
        switch d {
        case .full:
            return "Show message text, reaction emoji, and comment previews. iOS Show Previews still hides them on the lock screen if you set that system-wide."
        case .privateDetail:
            return "Banners say who and what kind of activity (message, reaction, story) without quoting content. Best default if others can see your lock screen."
        case .minimal:
            return "Only “Haven — New activity”. Open the app to see what happened."
        }
    }

    /// Pick which body to show. Pure so the NSE and unit tests share one implementation
    /// without linking the main app's `PushBanner` type.
    static func displayBody(full: String, privateBody: String?, kind: String?,
                            detail: Detail) -> (titleUsesName: Bool, body: String) {
        switch detail {
        case .full:
            return (true, full)
        case .privateDetail:
            if let p = privateBody, !p.isEmpty { return (true, p) }
            return (true, fallbackPrivateBody(kind: kind))
        case .minimal:
            return (false, "New activity")
        }
    }

    static func fallbackPrivateBody(kind: String?) -> String {
        switch kind {
        case "story":   return "Shared a story"
        case "react":   return "Reacted to your post"
        case "comment": return "Left a comment"
        case "dm":      return "Sent you a message"
        case "edit":    return "Edited a message"
        case "unsend":  return "Unsent a message"
        case "post":    return "Shared something"
        case "call":    return "Incoming call"
        default:        return "New activity"
        }
    }

    /// Stricter of two levels (minimal < private < full).
    static func stricter(_ a: Detail, _ b: Detail) -> Detail {
        let rank: (Detail) -> Int = {
            switch $0 {
            case .minimal: return 0
            case .privateDetail: return 1
            case .full: return 2
            }
        }
        return rank(a) <= rank(b) ? a : b
    }
}
