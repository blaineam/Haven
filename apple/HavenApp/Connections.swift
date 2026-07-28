import SwiftUI

/// A pending connection request — someone reached you through your invite. You approve
/// (after checking the safety words match) or block them. This replaces the old
/// "both must scan + silent auto-add" with: one person scans, the other gets asked.
struct ConnectionRequest: Identifiable, Equatable {
    let idHex: String
    let name: String
    let bundle: Data
    let safetyWords: [String]
    var id: String { idHex }
}

/// Holds incoming connection requests + the blocklist. The blocklist persists and is
/// checked at the inbound gate so a blocked person's posts, messages, calls, and
/// handshakes are all dropped — and they can't silently re-add themselves.
@MainActor
final class ConnectionsStore: ObservableObject {
    static let shared = ConnectionsStore()

    @Published private(set) var pending: [ConnectionRequest] = []
    @Published private(set) var blocked: Set<String> = []

    /// Circle-member removal state as LAST-WRITER-WINS: `removedAt[key]` is when the member was removed
    /// from a circle, `readdedAt[key]` when they were deliberately re-added; a member is currently
    /// removed iff their removal is NEWER than any re-add. Timestamps (ms) are the fix for the two ways
    /// this broke: a fresh removal now always beats a stale "re-added elsewhere" record (so removals
    /// sync + stick), and a fresh re-add beats an old removal (so a sibling's stale removal can't
    /// re-sever a friend you just re-added). Keyed "<circleId>|<nodeHex>". Mirrors the relay-removal LWW.
    private(set) var removedAt: [String: UInt64] = [:]
    private(set) var readdedAt: [String: UInt64] = [:]
    /// Derived: keys currently removed (removal newer than any re-add). Published for UI filters.
    @Published private(set) var circleRemovals: Set<String> = []

    private let d = UserDefaults.standard
    private let blockedKey = "haven.blocked"
    private let removedAtKey = "haven.circleRemovedAt.v2"
    private let readdedAtKey = "haven.circleReaddedAt.v2"
    // Legacy (pre-LWW) sets, read once to migrate.
    private let legacyRemovalsKey = "haven.circleRemovals"
    private let legacyClearedKey = "haven.circleRemovals.cleared"
    private func removalKey(_ circleId: String, _ idHex: String) -> String { "\(circleId)|\(idHex)" }
    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    private init() {
        if let arr = d.array(forKey: blockedKey) as? [String] { blocked = Set(arr) }
        removedAt = (d.dictionary(forKey: removedAtKey) as? [String: NSNumber])?.mapValues { $0.uint64Value } ?? [:]
        readdedAt = (d.dictionary(forKey: readdedAtKey) as? [String: NSNumber])?.mapValues { $0.uint64Value } ?? [:]
        // One-time migration from the legacy bare sets → LWW timestamps. Old removals/clears carry no
        // time, so they land at ts=1 ("long ago") and any real, later action supersedes them.
        if removedAt.isEmpty && readdedAt.isEmpty {
            if let arr = d.array(forKey: legacyRemovalsKey) as? [String] { for k in arr { removedAt[k] = 1 } }
            if let arr = d.array(forKey: legacyClearedKey) as? [String] { for k in arr { readdedAt[k] = 1 } }
            if !removedAt.isEmpty || !readdedAt.isEmpty { persistRemovalState() }
        }
        recomputeRemovals()
    }

    private func persistRemovalState() {
        d.set(removedAt.mapValues { NSNumber(value: $0) }, forKey: removedAtKey)
        d.set(readdedAt.mapValues { NSNumber(value: $0) }, forKey: readdedAtKey)
    }
    private func recomputeRemovals() {
        var s = Set<String>()
        for (k, t) in removedAt where t > (readdedAt[k] ?? 0) { s.insert(k) }
        circleRemovals = s
    }

    /// Factory-reset this store — clear in-memory + persisted state.
    func wipe() {
        pending = []; blocked = []; circleRemovals = []; removedAt = [:]; readdedAt = [:]
        [blockedKey, removedAtKey, readdedAtKey, legacyRemovalsKey, legacyClearedKey].forEach { d.removeObject(forKey: $0) }
    }

    /// Mark a member as removed from a circle NOW (LWW — supersedes any older re-add).
    func removeFromCircle(_ idHex: String, circleId: String) {
        removedAt[removalKey(circleId, idHex)] = nowMs()
        persistRemovalState(); recomputeRemovals()
    }
    /// Was this member explicitly removed from this circle? (removal newer than any re-add)
    func isRemovedFromCircle(_ idHex: String, circleId: String) -> Bool {
        let k = removalKey(circleId, idHex)
        return (removedAt[k] ?? 0) > (readdedAt[k] ?? 0)
    }
    /// Every node hex currently removed from a given circle (for hiding their posts + not dialing them).
    func removedHexes(inCircle circleId: String) -> Set<String> {
        let prefix = circleId + "|"
        return Set(circleRemovals.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
    /// Re-allow a member into a circle NOW (LWW — supersedes any older removal).
    func clearCircleRemoval(_ idHex: String, circleId: String) {
        readdedAt[removalKey(circleId, idHex)] = nowMs()
        persistRemovalState(); recomputeRemovals()
    }

    /// Apply a REMOTE removal/re-add timestamp (from self-sync), keeping the newer per key. Returns
    /// whether this key's current verdict is "removed" after the merge (so the caller can sync the
    /// engine tombstone accordingly).
    @discardableResult func mergeRemovedAt(_ key: String, ms: UInt64) -> Bool {
        if ms > (removedAt[key] ?? 0) { removedAt[key] = ms; persistRemovalState(); recomputeRemovals() }
        return (removedAt[key] ?? 0) > (readdedAt[key] ?? 0)
    }
    @discardableResult func mergeReaddedAt(_ key: String, ms: UInt64) -> Bool {
        if ms > (readdedAt[key] ?? 0) { readdedAt[key] = ms; persistRemovalState(); recomputeRemovals() }
        return (removedAt[key] ?? 0) > (readdedAt[key] ?? 0)
    }

    /// Circle membership grants circle history — always. Kept as a constant rather than deleted so
    /// any straggling call site reads true instead of silently reintroducing a gate we no longer
    /// honour anywhere. See `approveConnection` for why the choice was withdrawn.
    func sharesHistory(_ idHex: String) -> Bool { true }

    func isBlocked(_ idHex: String) -> Bool { blocked.contains(idHex) }

    func block(_ idHex: String) {
        blocked.insert(idHex)
        d.set(Array(blocked), forKey: blockedKey)
        pending.removeAll { $0.idHex == idHex }
    }
    func unblock(_ idHex: String) {
        blocked.remove(idHex)
        d.set(Array(blocked), forKey: blockedKey)
    }

    func addPending(_ req: ConnectionRequest) {
        guard !isBlocked(req.idHex), !pending.contains(where: { $0.idHex == req.idHex }) else { return }
        pending.append(req)
    }
    func removePending(_ idHex: String) { pending.removeAll { $0.idHex == idHex } }
}

/// Manage blocked people — unblock anyone you've blocked.
struct BlockedPeopleView: View {
    @ObservedObject private var connections = ConnectionsStore.shared

    var body: some View {
        ZStack {
            HavenBackground()
            if connections.blocked.isEmpty {
                ContentUnavailableView("No one's blocked", systemImage: "hand.raised",
                                       description: Text("People you block show up here so you can unblock them."))
            } else {
                List {
                    ForEach(Array(connections.blocked).sorted(), id: \.self) { idHex in
                        HStack {
                            Circle().fill(.secondary.opacity(0.4)).frame(width: 34, height: 34)
                                .overlay(Image(systemName: "person.fill").font(.caption).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ContactsStore.shared.name(forNodePrefix: idHex) ?? "Blocked person").font(.subheadline.weight(.medium))
                                Text(String(idHex.prefix(16)) + "…").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unblock") { connections.unblock(idHex) }
                                .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Blocked")
        .havenInlineNavTitle()
    }
}

/// Review incoming requests: verify the safety words out-of-band, then Add or Block.
struct ConnectionRequestsView: View {
    @ObservedObject private var connections = ConnectionsStore.shared
    @ObservedObject private var store = FeedStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var approveTarget: ConnectionRequest?

    var body: some View {
        Group {
            #if os(macOS)
            // A NavigationStack toolbar puts Done on a gray system band here (and doubled up with the
            // sheet's own close), so macOS gets the sheet scaffold + a plain column instead of a List.
            HavenMacSheet("Connection requests") {
                if connections.pending.isEmpty {
                    Text("No pending requests.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(connections.pending) { req in requestCard(req) }
                    }
                }
            }
            #else
            iosBody
            #endif
        }
        // No "new posts only" option — see `approveConnection`. A circle is keyed by a SHARED epoch,
        // so joining one grants the key that opens its content; the choice could be honoured in the
        // UI and never in the cryptography. Say what actually happens instead of offering a boundary
        // that does not exist.
        .confirmationDialog("Add \(approveTarget?.name ?? "them") to your circle?",
                            isPresented: Binding(get: { approveTarget != nil }, set: { if !$0 { approveTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Add to circle") { if let r = approveTarget { store.approveConnection(r) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be able to see what you've shared with this circle, including past posts.")
        }.havenPausesPostAudio()
    }

    #if !os(macOS)
    private var iosBody: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                if connections.pending.isEmpty {
                    Text("No pending requests.").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(connections.pending) { req in
                            requestCard(req)
                                .padding(.vertical, 6)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Connection requests")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmTrailing) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }
    }
    #endif

    private func requestCard(_ req: ConnectionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(req.name).font(.headline)
            Text(req.safetyWords.joined(separator: " · "))
                .font(.caption.monospaced()).foregroundStyle(HavenTheme.pink)
            Text("Check these safety words match what they see before adding.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { approveTarget = req } label: {
                    Label("Add", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.white)   // white label+symbol on the filled pink, not a pink glyph
                }
                .buttonStyle(.borderedProminent).tint(HavenTheme.pink)
                Button(role: .destructive) { store.blockConnection(req.idHex) } label: {
                    Label("Block", systemImage: "hand.raised.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent).tint(.red)   // filled red; no ambient tint flipping to iOS blue
            }
        }
    }
}
