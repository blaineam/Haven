import Foundation
import Network
import Combine

/// Low-data mode: watch the path, tell the core how constrained it is, and answer "may I send this?"
///
/// The POLICY is not here. `haven_p2p::transport::allowance` is the single table both this and the
/// Android client consult (`docs/SATELLITE-DESIGN.md` §5) — this file only decides which
/// `LinkConstraint` the current path deserves and forwards it. Anything that looks like a policy
/// decision in Swift is a bug: it would let the two platforms drift.
///
/// Detection uses the ultra-constrained path family Apple shipped in iOS 26 / macOS 26. There is no
/// satellite framework and nothing to wait for in 27 — see `docs/SATELLITE-DESIGN.md` §2.1. The
/// deployment floor here is iOS 17, so every 26-era call is behind `#available` with a pre-26
/// fallback that treats `isConstrained` as the strongest hint available.
@MainActor
final class LowDataMonitor: ObservableObject {
    static let shared = LowDataMonitor()

    /// What the user asked for, independent of what the network is doing.
    enum Preference: Int, CaseIterable, Identifiable {
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

    /// The constraint the OS reports for the current path, before the user's preference is applied.
    @Published private(set) var detected: LinkConstraint = .normal
    /// The constraint actually in force — what the core is told and what the UI describes.
    @Published private(set) var effective: LinkConstraint = .normal
    /// True when the path is a satellite-class bearer, so the UI can say so specifically rather than
    /// saying "low data" for something far more restrictive than Low Data Mode.
    @Published private(set) var isUltraConstrained = false
    /// Coarse link quality, when the OS offers it (iOS 26+). Drives how deeply a sync pass drains.
    @Published private(set) var linkQualityDescription: String?

    @Published var preference: Preference {
        didSet {
            guard preference != oldValue else { return }
            UserDefaults.standard.set(preference.rawValue, forKey: Self.kPreference)
            recompute()
        }
    }

    private static let kPreference = "haven.lowData.preference"
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.blaineam.haven.lowdata")

    private init() {
        let raw = UserDefaults.standard.object(forKey: Self.kPreference) as? Int
        preference = Preference(rawValue: raw ?? 0) ?? .automatic
    }

    /// Begin watching. Idempotent; safe to call from app launch.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let detected = Self.classify(path)
            let quality = Self.qualityDescription(path)
            Task { @MainActor in self?.apply(detected: detected, quality: quality) }
        }
        monitor.start(queue: queue)
        // Seed from the current path so the first send before any callback isn't misclassified.
        apply(detected: Self.classify(monitor.currentPath),
              quality: Self.qualityDescription(monitor.currentPath))
    }

    /// Map a path to the constraint level it deserves.
    ///
    /// `isUltraConstrained` is the satellite signal; `isConstrained` has meant Low Data Mode and
    /// metered interfaces since iOS 13. Checked strongest-first — an ultra-constrained path is also
    /// reported as constrained, and collapsing the two would lose the distinction that matters most.
    nonisolated private static func classify(_ path: NWPath) -> LinkConstraint {
        guard path.status != .unsatisfied else { return .normal }
        if #available(iOS 26, macOS 26, watchOS 26, tvOS 26, visionOS 26, *) {
            if path.isUltraConstrained { return .ultra }
        }
        if path.isConstrained { return .low }
        return .normal
    }

    nonisolated private static func qualityDescription(_ path: NWPath) -> String? {
        guard #available(iOS 26, macOS 26, watchOS 26, tvOS 26, visionOS 26, *) else { return nil }
        switch path.linkQuality {
        case .minimal: return "minimal"
        case .moderate: return "moderate"
        case .good: return "good"
        default: return nil
        }
    }

    private func apply(detected: LinkConstraint, quality: String?) {
        self.detected = detected
        self.linkQualityDescription = quality
        recompute()
    }

    private func recompute() {
        let resolved: LinkConstraint
        #if DEBUG
        if let forced = debugForced {
            applyResolved(forced)
            return
        }
        #endif
        switch preference {
        case .automatic:
            resolved = detected
        case .always:
            // "Always on" means the Low profile everywhere; it must never *weaken* a genuinely
            // ultra-constrained path down to Low.
            resolved = detected == .ultra ? .ultra : .low
        case .off:
            // The user opted out. Honour it — but a satellite bearer is not a preference we can
            // pretend away: the OS will refuse the traffic regardless, so stay at ultra and let the
            // UI explain rather than fail mysteriously.
            resolved = detected == .ultra ? .ultra : .normal
        }
        applyResolved(resolved)
    }

    /// Publish a resolved constraint: tell the core, update the UI, and — when the link IMPROVED —
    /// complete the work that was held back.
    private func applyResolved(_ resolved: LinkConstraint) {
        let previous = effective
        effective = resolved
        isUltraConstrained = resolved == .ultra
        // Tell the core. Every allowance question is answered against this.
        setLinkConstraint(link: resolved)

        // The link just got BETTER — this is the moment the media held back on a constrained link
        // should complete itself, rather than waiting for whatever refreshes the feed next. Someone
        // who posted a preview-only photo off-grid and walked back into coverage expects the full
        // copy to follow on its own (`docs/PREVIEW-TIER-DESIGN.md` §4.3).
        if Self.severity(resolved) < Self.severity(previous) {
            FeedStore.shared.nudgeMediaPrefetchNow()
        }
    }

    #if DEBUG
    /// QA override for the link constraint (`docs/QA.md`, op `link_constraint`).
    ///
    /// The satellite tier is otherwise UNTESTABLE anywhere but a real satellite bearer: `Ultra`
    /// comes only from `NWPath.isUltraConstrained`, which a simulator never reports, and the user
    /// preference deliberately cannot escalate to it (§ "Off" is honoured except on a genuine
    /// ultra-constrained link). Without this the preview tier would ship unverified on the exact
    /// path it exists for.
    ///
    /// DEBUG-only by construction, so no release build can be pushed into a state the network is
    /// not actually in.
    private(set) var debugForced: LinkConstraint?

    func debugForce(_ level: LinkConstraint?) {
        debugForced = level
        recompute()
    }
    #endif

    /// Ordering for "did the link improve?" — higher is more constrained.
    private static func severity(_ l: LinkConstraint) -> Int {
        switch l {
        case .normal: return 0
        case .low: return 1
        case .ultra: return 2
        }
    }

    // MARK: - Asking permission

    /// May this kind of traffic go out right now, with no further prompting?
    func permits(_ traffic: Traffic) -> Bool {
        lowDataAllowance(traffic: traffic) == .allow
    }

    /// The full ruling, for call sites that can offer the user an explicit "send anyway".
    func allowance(_ traffic: Traffic) -> Allowance {
        lowDataAllowance(traffic: traffic)
    }

    /// True when media must not be fetched without the user asking for this specific item.
    var mediaNeedsExplicitTap: Bool {
        lowDataAllowance(traffic: .media) != .allow
    }

    /// One line describing the current state, for the settings screen and the banner.
    var statusDescription: String {
        switch effective {
        case .ultra:
            let q = linkQualityDescription.map { " (link \($0))" } ?? ""
            return "Satellite or ultra-constrained link\(q) — text only."
        case .low:
            return preference == .always
                ? "Low data mode is on for every network."
                : "This network is metered or in Low Data Mode."
        case .normal:
            return "Full speed. Nothing is being held back."
        }
    }
}
