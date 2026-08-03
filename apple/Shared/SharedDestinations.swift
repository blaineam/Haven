import Foundation

/// Where a share can go, mirrored into the App Group so the **Share Extension** can draw its own
/// picker.
///
/// The extension can't ask the engine anything: it doesn't link HavenFFI, has no identity, and dies
/// in seconds. But it can read a small snapshot the app leaves behind. That snapshot is what lets
/// the share sheet show a real destination list — conversations and circles, with faces — instead
/// of bouncing the user into the app to find out where their photo went.
///
/// Deliberately thin: a name, an id, a kind, a recency stamp, and a tiny avatar. **No message
/// content, and no locked circles** — a biometric-locked circle is omitted at write time, because
/// the extension runs outside the app's Face ID gate and listing one there would name a circle the
/// lock is supposed to hide.
enum SharedDestinations {
    static let appGroup = "group.com.blaineam.kith"

    struct Item: Codable, Identifiable, Equatable {
        /// Circle id — a `dm:` thread or a feed circle.
        var id: String
        var name: String
        /// A conversation (send a message) rather than a circle (publish a post).
        var isDM: Bool
        /// Newest message time, for ordering. 0 = nothing said yet.
        var lastActivity: UInt64
        /// File name of a small JPEG in the mirror dir, or "" when there's no photo.
        var avatarFile: String = ""
    }

    private static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("ShareDestinations", isDirectory: true)
    }

    private static var listURL: URL? { dir?.appendingPathComponent("destinations.json") }

    static func avatarURL(_ file: String) -> URL? {
        guard !file.isEmpty else { return nil }
        return dir?.appendingPathComponent(file)
    }

    /// App side: replace the snapshot. Avatars are written alongside as `av-<id hash>.jpg`, and any
    /// avatar no longer referenced is swept, so a removed contact's face doesn't linger in a
    /// container the extension can read.
    static func write(_ items: [Item], avatars: [String: Data]) {
        guard let dir, let listURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (file, data) in avatars {
            try? data.write(to: dir.appendingPathComponent(file))
        }
        let keep = Set(items.map(\.avatarFile).filter { !$0.isEmpty })
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in existing where name.hasPrefix("av-") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: listURL) }
    }

    /// Extension side: the destinations to offer, most recently active first.
    static func read() -> [Item] {
        guard let listURL, let data = try? Data(contentsOf: listURL),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Wipe the mirror — the account was reset, or the user turned share suggestions off.
    static func clear() {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Stable avatar file name for a destination id (ids contain ':' and '-', which are fine in a
    /// file name, but a `dm:` id is 130 characters — hash it instead of using it raw).
    static func avatarFileName(for id: String) -> String {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return "av-\(String(hash, radix: 16)).jpg"
    }
}
