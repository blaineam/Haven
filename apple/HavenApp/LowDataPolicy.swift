import Foundation

/// The user-facing rules of Low Data Mode, without the network monitor or the core: how the user's
/// preference combines with what the path reports, whether a change is an improvement (which releases
/// held-back media), and the status line. The ALLOWANCE policy itself lives in the core
/// (`haven_p2p::transport::allowance`) and is deliberately not duplicated here.

/// What the user asked for, independent of what the network is doing.
enum LowDataPreference: Int, CaseIterable, Identifiable {
    /// Follow the network: on when the OS says the path is constrained. The default.
    case automatic = 0
    /// Always save data, even on good Wi-Fi.
    case always = 1
    /// Never save data, even on satellite. The user's call; we still show what it costs.
    case off = 2

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .always: return "Always on"
        case .off: return "Off"
        }
    }
}

/// How constrained a link is, mirroring the core's `LinkConstraint` (the monitor maps between them).
enum LowDataLevel: Int, Comparable, CaseIterable {
    case normal = 0, low = 1, ultra = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum LowDataPolicy {
    /// The constraint actually in force for `detected` under `preference`.
    ///
    /// "Always on" means the Low profile everywhere but must never WEAKEN a genuinely ultra-constrained
    /// path down to Low. "Off" is honoured except on a satellite bearer: the OS will refuse the traffic
    /// regardless, so stay at ultra and let the UI explain rather than fail mysteriously.
    static func resolve(preference: LowDataPreference, detected: LowDataLevel) -> LowDataLevel {
        switch preference {
        case .automatic: return detected
        case .always: return detected == .ultra ? .ultra : .low
        case .off: return detected == .ultra ? .ultra : .normal
        }
    }

    /// Did the link just get BETTER? That is the moment media held back on a constrained link should
    /// complete itself.
    static func improved(from previous: LowDataLevel, to resolved: LowDataLevel) -> Bool {
        resolved < previous
    }

    /// One line describing the current state, for the settings screen and the banner.
    static func status(effective: LowDataLevel, preference: LowDataPreference, linkQuality: String?) -> String {
        switch effective {
        case .ultra:
            let q = linkQuality.map { " (link \($0))" } ?? ""
            return "Satellite or ultra-constrained link\(q) — text only."
        case .low:
            return preference == .always
                ? "Low data mode is on for every network."
                : "This network is metered or in Low Data Mode."
        case .normal:
            return "Full speed. Nothing is being held back."
        }
    }

    /// The stored preference, tolerating a missing or unknown raw value (an older/newer build).
    static func preference(fromStored raw: Int?) -> LowDataPreference {
        LowDataPreference(rawValue: raw ?? 0) ?? .automatic
    }
}
