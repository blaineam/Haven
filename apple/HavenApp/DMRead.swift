import Foundation

/// Per-conversation read watermarks for DMs — the basis for unread badges. A message is unread
/// when it's inbound, not unsent, and newer than the conversation's watermark; opening the thread
/// advances the watermark. Watermarks are monotonic (only ever move forward), which makes the
/// cross-device merge trivial and safe: per-key MAX — reading a thread on the phone clears its
/// badge on the Mac via self-sync, and no device can ever "un-read" another (see the removal-LWW
/// saga for why absence/overwrite merges are the dangerous kind).
@MainActor
final class DMReadStore: ObservableObject {
    static let shared = DMReadStore()

    private let d = UserDefaults.standard
    private let key = "haven.dm.lastRead"            // JSON [circleId: unix-ms watermark]
    private let seedKey = "haven.dm.lastRead.seededAt"

    @Published private(set) var lastRead: [String: UInt64]
    /// Watermark for conversations with no entry yet. Stamped ONCE on first run so the day this
    /// feature ships, pre-existing history doesn't light every conversation up as unread — only
    /// messages that arrive after the seed (or after the last real read) badge.
    private let seededAt: UInt64

    private init() {
        if let data = d.data(forKey: key), let m = try? JSONDecoder().decode([String: UInt64].self, from: data) {
            lastRead = m
        } else {
            lastRead = [:]
        }
        // Stored as a String — UserDefaults round-trips large integers through Double otherwise.
        if d.string(forKey: seedKey) == nil {
            d.set(String(UInt64(Date().timeIntervalSince1970 * 1000)), forKey: seedKey)
        }
        seededAt = UInt64(d.string(forKey: seedKey) ?? "0") ?? 0
    }

    func watermark(_ circleId: String) -> UInt64 { lastRead[circleId] ?? seededAt }

    /// Advance a conversation's watermark to "now or the newest visible message, whichever is
    /// later". Taking the message time into account absorbs sender clock skew — a message stamped
    /// slightly in our future would otherwise stay "unread" forever.
    func markRead(_ circleId: String, newestMessageAt: UInt64 = 0) {
        let mark = max(UInt64(Date().timeIntervalSince1970 * 1000), newestMessageAt)
        guard mark > (lastRead[circleId] ?? 0) else { return }
        lastRead[circleId] = mark
        persist()
    }

    /// Merge watermarks synced from my other devices: per-key MAX (monotonic — always safe).
    func applySynced(_ incoming: [String: UInt64]) {
        var merged = lastRead
        var changed = false
        for (k, v) in incoming where v > (merged[k] ?? 0) { merged[k] = v; changed = true }
        guard changed else { return }
        lastRead = merged
        persist()
    }

    /// Factory-reset this store.
    func wipe() {
        lastRead = [:]
        d.removeObject(forKey: key)
        d.removeObject(forKey: seedKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(lastRead) { d.set(data, forKey: key) }
    }
}
