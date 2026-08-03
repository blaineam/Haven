import Foundation

/// Hand-off between the Share Extension and the main app via the shared App Group container. The
/// extension can't run the P2P stack (no identity in a short-lived extension process), so it just
/// drops the raw shared items here and opens `haven://share`; the app imports them into MediaStore
/// and routes to a DM / post / story. (Distinct from `SharedInbox`, which is the NSE push queue.)
enum ShareInbox {
    static let appGroup = "group.com.blaineam.kith"

    private static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    /// One shared item: inline text/link, or a media file (image/video/document) by name within the
    /// inbox dir.
    struct Item: Codable {
        enum Kind: String, Codable { case text, image, video, file }
        var kind: Kind
        var text: String = ""     // for .text
        var file: String = ""     // for .image / .video / .file — file name within the inbox dir
        /// The name the source app gave the document, for `.file` — the inbox name is uniquified,
        /// so this is what the recipient should see on the attachment.
        var name: String = ""
    }
    struct Payload: Codable {
        var items: [Item] = []
        /// The conversation the user picked in the share sheet's suggestion row, if any — the `dm:`
        /// circle id we donated as `INSendMessageIntent.conversationIdentifier`. The app skips the
        /// "where should this go" step and opens straight into that thread's composer.
        var targetCircleId: String = ""
    }

    /// Absolute URL for a media file name inside the inbox (used by both sides).
    static func fileURL(_ name: String) -> URL? { dir?.appendingPathComponent(name) }

    static func ensureDir() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Extension side: persist the manifest (media bytes are written separately via `fileURL`).
    static func writePayload(_ payload: Payload) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: dir.appendingPathComponent("payload.json"))
        }
    }

    /// App side: read the pending payload, if any.
    static func read() -> Payload? {
        guard let dir,
              let data = try? Data(contentsOf: dir.appendingPathComponent("payload.json")),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.items.isEmpty else { return nil }
        return payload
    }

    /// App side: remove the inbox once consumed (or cancelled).
    static func clear() {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
