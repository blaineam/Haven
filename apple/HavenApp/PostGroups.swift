import Foundation

/// Which per-circle copies of ONE multi-circle post belong together, so an edit made to any copy can be
/// authored into every sibling circle too.
///
/// LOCAL ONLY — no wire or core change. A multi-circle post is N independent events (circles have separate
/// keys); this index is written at post time on the author's device and never leaves it. Posts made before
/// the index existed, and single-circle posts, have no group and edit exactly as they always did.
final class PostGroups: @unchecked Sendable {
    static let shared = PostGroups()
    static let key = "post.groups"
    static let cap = 500

    struct Member: Codable, Equatable, Hashable, Sendable {
        let circleId: String
        let eventId: String
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Oldest first; the oldest group is evicted past `cap`.
    private var groups: [[Member]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.groups = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([[Member]].self, from: $0) } ?? []
    }

    /// Record a group. Ignored unless it spans more than one distinct circle.
    func register(_ members: [Member]) {
        var seen = Set<String>()
        let unique = members.filter { !$0.eventId.isEmpty && seen.insert($0.circleId).inserted }
        guard unique.count > 1 else { return }
        lock.lock(); defer { lock.unlock() }
        groups.append(unique)
        if groups.count > Self.cap { groups.removeFirst(groups.count - Self.cap) }
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: Self.key) }
    }

    /// The other copies of the post that lives in (`circleId`, `eventId`); empty when it has no group.
    /// `liveCircleIds`, when given, drops siblings whose circle no longer exists.
    func siblings(circleId: String, eventId: String, liveCircleIds: Set<String>? = nil) -> [Member] {
        lock.lock(); defer { lock.unlock() }
        guard let g = groups.last(where: { $0.contains(Member(circleId: circleId, eventId: eventId)) }) else { return [] }
        return g.filter { $0.circleId != circleId && (liveCircleIds?.contains($0.circleId) ?? true) }
    }

    /// Distinct created_at per copy: the event id is BLAKE3(author‖created_at‖kind), so copies (or fanned-out
    /// edits) authored in the same millisecond would collide. Index 0 keeps `base`.
    static func stagger(base: UInt64, index: Int) -> UInt64 { base + UInt64(index) }
}
