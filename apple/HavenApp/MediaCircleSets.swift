import Foundation

/// Which circles a media file was shared to, when ONE post went to several circles at once.
///
/// A media blob is content-addressed on its plaintext, so there is exactly one sealed blob (and one relay
/// key) per file. To make it readable in every circle the post went to, the file is sealed ONCE for the
/// whole set (`sealCircleMediaFileMulti`: one epoch entry per circle) and uploaded once; each circle still
/// gets its own backup job to scope the ref into that circle on the relays.
///
/// The set must be known before ANY of those jobs seals, or the first circle's job would seal for itself
/// alone and the others would reuse that seal. So it is recorded here, at post time, before the first job is
/// enqueued, and read by the seal step. A file that was only ever shared to one circle has no entry and
/// seals exactly as it always did.
final class MediaCircleSets: @unchecked Sendable {
    static let shared = MediaCircleSets()
    static let key = "media.circleSets"
    private static let cap = 500

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// ref → circle ids, origin (the circle the post was composed in) FIRST — it is the sealing primary, so
    /// every job produces the same bytes no matter which circle's job runs first.
    private var sets: [String: [String]]
    private var order: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        self.sets = raw?.sets ?? [:]
        self.order = raw?.order ?? []
    }

    private struct Stored: Codable { var sets: [String: [String]]; var order: [String] }

    /// Record that each of `refs` goes to `circleIds` (origin first). One-element sets are not recorded.
    func register(refs: [String], circleIds: [String]) {
        var seen = Set<String>()
        let ids = circleIds.filter { seen.insert($0).inserted }
        guard ids.count > 1 else { return }
        lock.lock(); defer { lock.unlock() }
        for ref in refs {
            // A later post of the same file to more circles widens the set; it never narrows one a pending
            // job is relying on.
            var merged = sets[ref] ?? []
            for id in ids where !merged.contains(id) { merged.append(id) }
            if sets[ref] == nil { order.append(ref) }
            sets[ref] = merged
        }
        while order.count > Self.cap { sets[order.removeFirst()] = nil }
        persist()
    }

    /// The circles to seal `ref` for when the job being run is for `circleId`: the recorded set when this
    /// circle is in it, otherwise just this circle (the unchanged single-circle behaviour).
    func sealSet(ref: String, circleId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let set = sets[ref], set.contains(circleId) else { return [circleId] }
        return set
    }

    /// Stable short tag for a seal set, used in the cached seal's filename so a seal made for fewer circles
    /// is never reused once the set has grown. Empty for a single circle (the legacy filename).
    static func tag(_ ids: [String]) -> String {
        guard ids.count > 1 else { return "" }
        var h: UInt64 = 0xcbf29ce484222325   // FNV-1a — a filename tag, not a security boundary
        for b in ids.joined(separator: "|").utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "-" + String(h, radix: 16)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Stored(sets: sets, order: order)) { defaults.set(data, forKey: Self.key) }
    }
}
