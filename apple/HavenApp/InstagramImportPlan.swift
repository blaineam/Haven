import Foundation

/// The decisions and bookkeeping behind an Instagram import (`InstagramImporter`), without the
/// media store, the engine, Shazam or SwiftUI: which items an import covers and in what order, the
/// resume checkpoint, the "already published" ledger, the identities, the song policy, and the
/// per-item timeout. Foundation only so it runs in the host-less logic tests.

/// Everything needed to pick a half-finished import back up after the app is killed.
///
/// The archive is stored as a security-scoped BOOKMARK, not a path: the file lives outside the
/// sandbox (Files, iCloud Drive, a download) and a bare path would be unreadable on the next
/// launch. `done` is an index into the deterministic item order — see `InstagramArchive.read`,
/// which sorts with a tiebreak precisely so this index means the same thing on every run.
struct InstagramImportCheckpoint: Codable, Equatable {
    var bookmark: Data
    var circleId: String
    var includeStories: Bool
    /// Defaulted so a checkpoint written before song matching existed still decodes.
    var matchSongs: Bool = false
    /// Name the song in reels via Shazam (default on — needs no MusicKit authorization).
    var identifySongs: Bool = true
    var done: Int

    init(bookmark: Data, circleId: String, includeStories: Bool,
         matchSongs: Bool = false, identifySongs: Bool = true, done: Int) {
        self.bookmark = bookmark
        self.circleId = circleId
        self.includeStories = includeStories
        self.matchSongs = matchSongs
        self.identifySongs = identifySongs
        self.done = done
    }

    static let defaultsKey = "haven.instagram.import.pending"

    static func load(from d: UserDefaults) -> InstagramImportCheckpoint? {
        guard let raw = d.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(InstagramImportCheckpoint.self, from: raw)
    }

    func save(to d: UserDefaults) {
        guard let raw = try? JSONEncoder().encode(self) else { return }
        d.set(raw, forKey: Self.defaultsKey)
    }

    static func clear(from d: UserDefaults) { d.removeObject(forKey: defaultsKey) }
}

enum InstagramImportPlan {
    /// The items an import covers. Stories are OFF unless asked for, and that default is
    /// load-bearing: an Instagram archive holds EVERY story ever posted (no highlight flag in the
    /// export), so importing them by default would resurrect years of stories the user let expire.
    static func selectable(_ items: [InstagramArchive.Item], includeStories: Bool) -> [InstagramArchive.Item] {
        includeStories ? items : items.filter { $0.kind != .story }
    }

    /// NEWEST FIRST. The feed is newest-first, so importing oldest-first made every published post
    /// newer than all before it — inserted at the TOP, shoving the reader's page down hundreds of
    /// times. Reversed, each post is OLDER than the last and lands below the reader.
    static func importOrder(_ items: [InstagramArchive.Item], includeStories: Bool) -> [InstagramArchive.Item] {
        selectable(items, includeStories: includeStories).reversed().map { $0 }
    }

    /// Which of the two song jobs applies to a post. Decided by whether the post already makes a sound.
    enum SongPlan: Equatable {
        /// Has its own audio: use the Shazam result (if any) as a CREDIT; never layer a guess on it.
        case credit
        /// Silent and the user opted in: suggest one (Apple Music, genre + era).
        case suggest
        case none
    }

    static func songPlan(hasAudio: Bool, identifySongs: Bool, matchSongs: Bool) -> SongPlan {
        if hasAudio { return identifySongs ? .credit : .none }
        return matchSongs ? .suggest : .none
    }

    /// Identity for the "already published" ledger: the archive's own first media path plus the
    /// capture time, so the same export yields the same identity on every run and device. Distinct
    /// from `keptIdentity`, which is a KeptStories key and must keep its existing shape.
    static func importIdentity(_ item: InstagramArchive.Item) -> String {
        "ig:\(item.mediaNames.first ?? "-"):\(item.createdAt)"
    }

    /// Stable id for a kept story, derived from the archive entry it came from, so re-importing the
    /// same export is idempotent instead of doubling every story.
    static func keptIdentity(_ item: InstagramArchive.Item) -> String {
        "ig:" + (item.mediaNames.first ?? "\(item.createdAt)")
    }

    static func fileExtension(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.isEmpty ? "mp4" : e
    }

    static func isVideo(_ name: String) -> Bool {
        ["mp4", "mov", "m4v"].contains(fileExtension(name))
    }

    /// How long one video may take to stage before the import moves on. Generous — a large clip on a
    /// slow device legitimately takes a while — but bounded, which is the part that was missing.
    static let videoStageTimeout: Double = 180

    /// Run `work`, giving up after `seconds`. One item must never be able to wedge a 372-item import.
    /// Losing the race does not kill the underlying work; it stops the LOOP waiting on it.
    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Every archive item this device has already published, so importing the same export twice is a
/// no-op instead of a duplicate feed. Recorded only AFTER the post is authored, so a kill mid-item
/// re-imports that item rather than losing it.
final class InstagramImportLedger: @unchecked Sendable {
    static let shared = InstagramImportLedger(defaults: .shared)
    static let defaultsKey = "haven.instagram.imported.ids"

    private let defaults: SpilledDefaults
    private let lock = NSLock()
    private var cache: Set<String>?

    init(defaults: SpilledDefaults) { self.defaults = defaults }

    private func load() -> Set<String> {
        if let c = cache { return c }
        let c = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        cache = c
        return c
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load().contains(id)
    }

    func record(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var c = load()
        guard c.insert(id).inserted else { return }
        cache = c
        defaults.set(Array(c), forKey: Self.defaultsKey)
    }

    /// How many of these the device has already published — what the preview screen reports so
    /// "nothing happened" is never the whole message.
    func alreadyImported(_ ids: [String]) -> Int {
        lock.lock(); defer { lock.unlock() }
        let c = load()
        return ids.reduce(0) { $0 + (c.contains($1) ? 1 : 0) }
    }

    /// Deliberate re-import: forget this archive's items so they publish again.
    func forget(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        var c = load()
        for id in ids { c.remove(id) }
        cache = c
        defaults.set(Array(c), forKey: Self.defaultsKey)
    }
}
