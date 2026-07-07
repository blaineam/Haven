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
    /// People we deliberately did NOT share past history with — they see new posts only.
    @Published private(set) var noHistory: Set<String> = []

    /// People explicitly removed from a specific circle, keyed "<circleId>|<nodeHex>". Unlike a global
    /// block, this only bans them from that one circle — and crucially it survives their handshakes, so
    /// a removed member can't auto-rejoin the circle on their next Hello.
    @Published private(set) var circleRemovals: Set<String> = []
    /// Removals we deliberately CLEARED (re-added the person). Kept — not deleted — so self-sync can
    /// publish the clear as an explicit LWW write (removal:<key> = 0) that supersedes the stale
    /// removal record on our other devices. Without this, a sibling's grow-only removal record
    /// re-severed a re-added friend on every sync pass, forever.
    private(set) var clearedCircleRemovals: Set<String> = []

    private let d = UserDefaults.standard
    private let blockedKey = "haven.blocked"
    private let noHistoryKey = "haven.noHistory"
    private let circleRemovalsKey = "haven.circleRemovals"
    private let clearedRemovalsKey = "haven.circleRemovals.cleared"
    private func removalKey(_ circleId: String, _ idHex: String) -> String { "\(circleId)|\(idHex)" }

    private init() {
        if let arr = d.array(forKey: blockedKey) as? [String] { blocked = Set(arr) }
        if let arr = d.array(forKey: noHistoryKey) as? [String] { noHistory = Set(arr) }
        if let arr = d.array(forKey: circleRemovalsKey) as? [String] { circleRemovals = Set(arr) }
        if let arr = d.array(forKey: clearedRemovalsKey) as? [String] { clearedCircleRemovals = Set(arr) }
    }

    /// Factory-reset this store — clear in-memory + persisted state.
    func wipe() {
        pending = []; blocked = []; noHistory = []; circleRemovals = []; clearedCircleRemovals = []
        [blockedKey, noHistoryKey, circleRemovalsKey, clearedRemovalsKey].forEach { d.removeObject(forKey: $0) }
    }

    /// Mark a member as removed from a circle (prevents handshake re-add).
    func removeFromCircle(_ idHex: String, circleId: String) {
        circleRemovals.insert(removalKey(circleId, idHex))
        clearedCircleRemovals.remove(removalKey(circleId, idHex))
        d.set(Array(circleRemovals), forKey: circleRemovalsKey)
        d.set(Array(clearedCircleRemovals), forKey: clearedRemovalsKey)
    }
    /// Was this member explicitly removed from this circle?
    func isRemovedFromCircle(_ idHex: String, circleId: String) -> Bool {
        circleRemovals.contains(removalKey(circleId, idHex))
    }
    /// Every node hex explicitly removed from a given circle (for hiding their posts + not dialing them).
    func removedHexes(inCircle circleId: String) -> Set<String> {
        let prefix = circleId + "|"
        return Set(circleRemovals.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
    /// Re-allow a member into a circle (clears the removal) — e.g. when you deliberately re-add them.
    /// The key moves to `clearedCircleRemovals` (even when THIS device holds no removal record — a
    /// sibling device might) so the clear propagates via self-sync as an explicit newer write instead
    /// of silently losing to a stale removal record.
    func clearCircleRemoval(_ idHex: String, circleId: String) {
        let key = removalKey(circleId, idHex)
        circleRemovals.remove(key)
        clearedCircleRemovals.insert(key)
        d.set(Array(circleRemovals), forKey: circleRemovalsKey)
        d.set(Array(clearedCircleRemovals), forKey: clearedRemovalsKey)
    }

    func setNoHistory(_ idHex: String) {
        noHistory.insert(idHex); d.set(Array(noHistory), forKey: noHistoryKey)
    }
    func sharesHistory(_ idHex: String) -> Bool { !noHistory.contains(idHex) }

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
                                .font(.subheadline.weight(.medium)).tint(HavenTheme.pink)
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
        NavigationStack {
            ZStack {
                HavenBackground()
                if connections.pending.isEmpty {
                    Text("No pending requests.").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(connections.pending) { req in
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
            .confirmationDialog("Share your past posts with \(approveTarget?.name ?? "them")?",
                                isPresented: Binding(get: { approveTarget != nil }, set: { if !$0 { approveTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Add & share history") { if let r = approveTarget { store.approveConnection(r, shareHistory: true) } }
                Button("Add — new posts only") { if let r = approveTarget { store.approveConnection(r, shareHistory: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose whether they can see what you've already shared, or only what you post from now on.")
            }
        }
    }
}
