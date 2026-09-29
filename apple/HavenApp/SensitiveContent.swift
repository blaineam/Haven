import SwiftUI
import SensitiveContentAnalysis

/// On-device sensitive-content detection (Apple's `SensitiveContentAnalysis`, iOS 17 / macOS 14).
/// It runs ONLY when the user has turned on "Sensitive Content Warning" in system Settings, and
/// everything happens on the device — nothing about the media leaves Haven. We use it to blur
/// **incoming** photos/videos that are flagged until the viewer chooses to reveal them.
///
/// Apple-platforms only — Android/Windows/Linux have no equivalent system API and would need a
/// bundled on-device model.
@MainActor
final class SensitiveContentScanner: ObservableObject {
    static let shared = SensitiveContentScanner()

    /// Results cached by media ref so the feed never re-analyzes the same item.
    private var cache: [String: Bool] = [:]

    /// True only when the user has enabled "Sensitive Content Warning" system-wide. When off we do
    /// no analysis at all (zero cost, and we never blur).
    ///
    /// Answered from a cache when it has one. `analysisPolicy` is a SYNCHRONOUS XPC round trip to
    /// the analysis service (a semaphore wait inside SensitiveContentAnalysis), and every media
    /// tile's guard asked it on appear — measured as a 0.5 s main-thread stall on a feed scroll in
    /// the simulator. The setting changes only in system Settings, so a value at most
    /// `policyTTL` old is plenty.
    var isEnabled: Bool {
        if let cached = cachedEnabled, Date().timeIntervalSince(cachedAt) < Self.policyTTL { return cached }
        let v = SCSensitivityAnalyzer().analysisPolicy != .disabled
        cachedEnabled = v; cachedAt = Date()
        return v
    }
    /// `isEnabled` with the policy read (on a miss) done OFF the main actor.
    func isEnabledAsync() async -> Bool {
        if let cached = cachedEnabled, Date().timeIntervalSince(cachedAt) < Self.policyTTL { return cached }
        let v = await Task.detached(priority: .utility) { SCSensitivityAnalyzer().analysisPolicy != .disabled }.value
        cachedEnabled = v; cachedAt = Date()
        return v
    }
    private var cachedEnabled: Bool?
    private var cachedAt = Date.distantPast
    private static let policyTTL: TimeInterval = 60

    /// Whether the media at `ref` is flagged sensitive. Cheap + cached; returns false when the
    /// feature is off, the media isn't loaded yet, or analysis fails.
    func isSensitive(ref: String) async -> Bool {
        if let cached = cache[ref] { return cached }
        guard await isEnabledAsync() else { return false }
        let analyzer = SCSensitivityAnalyzer()
        // Analyze a downsampled still decoded OFF-main (a video's is its poster frame — the same
        // thumbnail the tile shows). This used to take `item(ref).image?.cgImage`: the full-res
        // original, decoded on the main thread just to be handed to the analyzer.
        guard let cg = await MediaStore.shared.thumbnailAsync(ref, maxDimension: 1024)?.cgImage else { return false }
        var result = false
        do { result = try await analyzer.analyzeImage(cg).isSensitive }
        catch { result = false }   // never block content on an analyzer error
        cache[ref] = result
        return result
    }
}

/// Blurs a piece of media until the viewer taps to reveal it, IF the system "Sensitive Content
/// Warning" setting is on and the on-device analyzer flags it. Apply to **received** media only
/// (`scan: !item.isMe`) — you don't need warning about your own posts.
struct SensitiveContentGuard: ViewModifier {
    let ref: String
    /// The circle this media belongs to — federated flags are per-circle.
    let circleId: String
    /// Only scan received media; pass `false` for the viewer's own content.
    var scan: Bool = true
    var cornerRadius: CGFloat = 10

    @ObservedObject private var scanner = SensitiveContentScanner.shared
    /// The federated flags change rarely; the store they live in publishes constantly. Observe
    /// only the flag signal — one of these guards wraps every media tile on screen.
    @ObservedObject private var flags = SensitiveFlagsSignal.shared
    private var feed: FeedStore { FeedStore.shared }
    @State private var localSensitive = false
    @State private var revealed = false

    /// Sensitive if MY device's SCA flagged it OR any circle member flagged it (the federated set —
    /// this is what protects viewers whose platform has no SCA).
    private var sensitive: Bool {
        localSensitive || feed.sensitiveRefs(circleId: circleId).contains(ref)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if sensitive && !revealed {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        VStack(spacing: 5) {
                            Image(systemName: "eye.slash.fill").font(.title3)
                            Text("Sensitive Content").font(.caption.weight(.semibold))
                            Text("Tap to view").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { revealed = true } }
                    .transition(.opacity)
                }
            }
            .task(id: ref) {
                guard scan, await scanner.isEnabledAsync() else { return }
                if await scanner.isSensitive(ref: ref) {
                    localSensitive = true
                    // Tell the whole circle so members without SCA blur it too (deduped).
                    feed.flagSensitive(circleId: circleId, ref: ref)
                }
            }
    }
}

extension View {
    /// Blur sensitive media until tapped — flagged either by this device's Sensitive Content
    /// Analysis or by any circle member's federated flag. See `SensitiveContentGuard`.
    func sensitiveContentGuard(ref: String, circleId: String, scan: Bool, cornerRadius: CGFloat = 10) -> some View {
        modifier(SensitiveContentGuard(ref: ref, circleId: circleId, scan: scan, cornerRadius: cornerRadius))
    }
}
