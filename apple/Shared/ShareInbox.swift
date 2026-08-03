import Foundation

/// Hand-off between the Share Extension and the main app via the shared App Group container. The
/// extension can't run the P2P stack (no identity in a short-lived extension process), so it drops
/// the shared items here along with the user's routing decision; the app imports them into
/// MediaStore and posts / sends / opens a composer. (Distinct from `SharedInbox`, which is the NSE
/// push queue.)
///
/// **It is a QUEUE, one directory per share.** It used to be a single `payload.json` with the media
/// beside it, which meant sharing twice before opening Haven silently destroyed the first share:
/// the second write replaced the manifest, and the app only ever saw the last one. Each share now
/// gets its own `<uuid>/` holding its own manifest and its own media, so two shares can't collide
/// no matter how many pile up before the app next runs.
enum ShareInbox {
    static let appGroup = "group.com.blaineam.kith"

    /// One shared item: inline text/link, or a media file (image/video/document) by name within the
    /// share's own directory.
    struct Item: Codable {
        enum Kind: String, Codable { case text, image, video, file }
        var kind: Kind
        var text: String = ""     // for .text
        var file: String = ""     // for .image / .video / .file — file name within the share dir
        /// The name the source app gave the document, for `.file` — the stored name is uniquified,
        /// so this is what the recipient should see on the attachment.
        var name: String = ""
    }

    /// What the user decided in the extension.
    ///
    /// `post` and `story` deliberately mean "open Haven's real composer with this loaded", not
    /// "publish it". Those composers own music, location, circle choice and story layout — routing
    /// around them would quietly drop features the in-app flow has. `dm` is the one the extension
    /// can finish itself, because a message is just a recipient and some words.
    enum Route: String, Codable { case undecided, post, dm, story }

    struct Payload: Codable {
        var items: [Item] = []
        /// The conversation the user picked — from the share sheet's suggestion row, or from the
        /// extension's own picker.
        var targetCircleId: String = ""
        var route: Route = .undecided
        /// What the user typed in the extension's composer.
        var caption: String = ""
    }

    /// A queued share: its directory id and its manifest.
    struct Queued {
        let id: String
        let payload: Payload
    }

    private static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    private static func shareDir(_ id: String) -> URL? {
        root?.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Extension side

    /// Start a new share. Returns its id; media is written with `fileURL(_:in:)` and the manifest is
    /// committed with `commit(_:in:)` only once the user actually taps Send.
    static func begin() -> String {
        let id = UUID().uuidString
        if let dir = shareDir(id) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return id
    }

    /// Absolute URL for a media file name inside a specific share (used by both sides).
    static func fileURL(_ name: String, in id: String) -> URL? {
        shareDir(id)?.appendingPathComponent(name)
    }

    /// Commit the manifest — this is what makes the share visible to the app.
    static func commit(_ payload: Payload, in id: String) {
        guard let dir = shareDir(id) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: dir.appendingPathComponent("payload.json"))
        }
    }

    /// Throw away a share that was never committed (the user cancelled), media and all.
    static func discard(_ id: String) {
        guard let dir = shareDir(id) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - App side

    /// Every committed share, oldest first, so a burst is replayed in the order it was made.
    static func drain() -> [Queued] {
        guard let root,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [(at: Date, queued: Queued)] = []
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let manifest = dir.appendingPathComponent("payload.json")
            // No manifest = a share still being composed, or one abandoned mid-extraction. Leave
            // it: an extension that is still running owns that directory.
            guard let data = try? Data(contentsOf: manifest),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  !payload.items.isEmpty else { continue }
            let at = (try? manifest.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            out.append((at: at, queued: Queued(id: name, payload: payload)))
        }
        out.sort { $0.at < $1.at }
        return out.map(\.queued)
    }

    /// Remove one share once it's been imported (or was un-deliverable).
    static func clear(_ id: String) { discard(id) }

    /// Remove everything — a factory reset, or a wipe.
    static func clearAll() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Sweep directories that were never committed and are old enough that no extension can still
    /// be filling them. Without this, a cancelled share leaves its media in the container forever.
    static func sweepAbandoned(olderThan seconds: TimeInterval = 3600) {
        guard let root,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("payload.json").path) else { continue }
            let at = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if at < cutoff { try? FileManager.default.removeItem(at: dir) }
        }
    }
}
