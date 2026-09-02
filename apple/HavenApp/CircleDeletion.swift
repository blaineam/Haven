import Foundation

/// LAST-WRITER-WINS deletion tombstone for whole circles / DM threads. Self-sync re-creates any circle
/// present in another device's slot (`createCircle` in the `circle:` apply), so deleting a DM or circle
/// never stuck on a multi-device account — the sibling's copy resurrected it every sync. These
/// timestamps make a deletion a real decision: `deletedAt` (when you deleted it) vs `recreatedAt` (when
/// it was explicitly re-made or re-opened by a new message); the newest wins. A circle is currently
/// deleted iff its deletion is newer than any re-creation. Mirrors the contact / circle-member LWW.
enum CircleDeletionStore {
    private static let d = UserDefaults.standard
    private static let deletedKey = "haven.circleDeletedAt.v1"
    private static let recreatedKey = "haven.circleRecreatedAt.v1"
    private static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    static private(set) var deletedAt: [String: UInt64] =
        (UserDefaults.standard.dictionary(forKey: deletedKey) as? [String: NSNumber])?.mapValues { $0.uint64Value } ?? [:]
    static private(set) var recreatedAt: [String: UInt64] =
        (UserDefaults.standard.dictionary(forKey: recreatedKey) as? [String: NSNumber])?.mapValues { $0.uint64Value } ?? [:]

    private static func persist() {
        d.set(deletedAt.mapValues { NSNumber(value: $0) }, forKey: deletedKey)
        d.set(recreatedAt.mapValues { NSNumber(value: $0) }, forKey: recreatedKey)
    }

    /// Currently deleted? (deletion newer than any re-creation) — the self-sync `circle:` apply skips these.
    static func isDeleted(_ id: String) -> Bool { (deletedAt[id] ?? 0) > (recreatedAt[id] ?? 0) }
    /// Every currently-deleted id — a value snapshot for an engine pass that runs off the main actor.
    static func deletedIds() -> Set<String> { Set(deletedAt.keys.filter(isDeleted)) }

    /// The user deleted this circle/DM NOW.
    static func markDeleted(_ id: String) { deletedAt[id] = nowMs(); persist() }
    /// The circle/DM was explicitly (re-)created or re-opened by a new message NOW — lifts the deletion.
    static func markRecreated(_ id: String) { recreatedAt[id] = nowMs(); persist() }

    /// Merge a remote deletion/recreation timestamp (self-sync LWW), keeping the newer per id.
    @discardableResult static func mergeDeletedAt(_ id: String, ms: UInt64) -> Bool {
        if ms > (deletedAt[id] ?? 0) { deletedAt[id] = ms; persist() }
        return isDeleted(id)
    }
    @discardableResult static func mergeRecreatedAt(_ id: String, ms: UInt64) -> Bool {
        if ms > (recreatedAt[id] ?? 0) { recreatedAt[id] = ms; persist() }
        return isDeleted(id)
    }

    static func wipe() { deletedAt = [:]; recreatedAt = [:]; [deletedKey, recreatedKey].forEach { d.removeObject(forKey: $0) } }
}
