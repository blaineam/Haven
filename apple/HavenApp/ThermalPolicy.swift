import Foundation

/// One place that answers "how hard may background sync work right now?" from the device's
/// thermal state. The individual gates grew up scattered across FeedView/SharedStore call sites
/// (each re-switching on `ProcessInfo.thermalState`), which made the policy impossible to reason
/// about — and easy to miss when adding a new radio loop. Policy:
///
///   .fair      → skip the self-sync pass, skip the putHello mailbox fan-out, HALVE media
///                budgets, double timer intervals (the existing adaptiveInterval stretch).
///   .serious+  → park media retries and the mailbox poll entirely (existing parks stay).
///   suspend    → .serious+, ANY call, or Low Power Mode (`HeavyWorkPolicy`): also park peer media
///                serving, backfill uploads, full-size prefetch, history handoff.
///
/// Cross-platform: `thermalState` exists on macOS too (a hosting Mac under load reports .fair),
/// so the gates apply everywhere; explicit user actions bypass them via their own `force` paths.
enum ThermalPolicy {
    static var state: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }

    /// Warm or worse — the "stop doing optional radio work" line.
    static var isFairOrWorse: Bool {
        switch state {
        case .fair, .serious, .critical: return true
        default: return false
        }
    }
    /// Hot — the "park everything that can wait" line.
    static var isSeriousOrWorse: Bool {
        switch state {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// Hot, in ANY call (Haven or cellular/FaceTime), or in Low Power Mode — the heavy-media-I/O
    /// gate (`HeavyWorkPolicy.Conditions.suspendHeavyIO`, sampled by `HeavyWorkMonitor`). Peer media
    /// serving, backfill uploads, full-size prefetch, history handoff and self-sync all wait on it.
    static var suspendHeavyIO: Bool { isSeriousOrWorse || HeavyWorkMonitor.current.suspendHeavyIO }

    /// .fair+ (or suspended): the multi-transport self-sync LIST/FETCH/merge pass is deferrable heat.
    static var skipSelfSync: Bool { isFairOrWorse || suspendHeavyIO }
    /// .fair+: the per-contact HELLO mailbox PUT fan-out is deferrable heat.
    static var skipHelloFanOut: Bool { isFairOrWorse }
    /// .serious+ (or suspended): media retry loops park until the gate lifts (a push still wakes them).
    static var parkMediaRetries: Bool { suspendHeavyIO }

    /// Halve a media-work budget at .fair+ (never below 1 so progress can't fully stall).
    static func mediaBudget(_ base: Int) -> Int {
        isFairOrWorse ? max(1, base / 2) : base
    }

    /// Timer-interval stretch factor — the existing adaptiveInterval thermal doubling, centralized.
    static var intervalMultiplier: UInt64 {
        switch state {
        case .serious, .critical: return 4
        case .fair: return 2
        default: return 1
        }
    }
}
