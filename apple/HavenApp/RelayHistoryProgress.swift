import Foundation

// Pure state behind "Load history from your relays" (RelayHistoryResync.swift) — Foundation only,
// so HavenLogicTests covers it on the host Mac with no FeedStore and no FFI.
//
// The pass reads every circle's FULL relay mailbox, fetches what this device never ingested, and
// then pulls the photos and videos those posts name. Its progress has to be honest in the same way
// the rest of SyncProgress.swift is: every number counts work that really happened, a phase that has
// nothing to do says so, and the summary never claims more than the relays could give back.

/// Snapshot of one run, published to the settings row and the QA dump.
struct RelayHistoryProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        /// Listing and fetching circle mailboxes (first pass, control plane then posts).
        case scanning
        /// Second look at envelopes that were waiting for a key from a later circle.
        case retrying
        /// Downloading the photos and videos the feed now names.
        case media
        case done
        case cancelled
    }

    var phase: Phase = .idle
    /// Circles (and DM threads) scanned of the total.
    var circlesDone = 0
    var circlesTotal = 0
    /// Mailbox entries the relays listed that this device had never ingested, and how many of them
    /// have been fetched and fed to the engine so far.
    var entriesFound = 0
    var entriesChecked = 0
    /// Posts, messages, comments and reactions that are NEW on this device (engine event count after
    /// minus before) — not "envelopes processed", which double-counts duplicates.
    var postsAdded = 0
    /// Envelopes the relays still hold that can no longer be opened (a key long since rotated away).
    var unreadable = 0
    /// Envelopes still waiting on a key at the end of the run (they open on their own if it arrives).
    var waiting = 0
    var mediaDone = 0
    var mediaTotal = 0
    /// Media the relays did not have (or would not hand over) — counted, never retried in this run.
    var mediaMissing = 0
    /// Relays that could not be listed at all (unreachable or refusing this device).
    var relayErrors = 0
    /// The run stopped early because the device got too hot / went offline, not because it finished.
    var mediaDeferred = false
    var startedAtMs: UInt64 = 0
    var finishedAtMs: UInt64 = 0

    var running: Bool { phase == .scanning || phase == .retrying || phase == .media }

    /// 0…1 for a determinate bar: the scan is the first 60%, media the rest. A phase with nothing to
    /// do contributes its share at once rather than holding the bar still.
    var fraction: Double {
        func part(_ done: Int, _ total: Int) -> Double { total <= 0 ? 1 : min(1, Double(done) / Double(total)) }
        switch phase {
        case .idle: return 0
        case .scanning: return 0.6 * part(circlesDone, circlesTotal) * 0.95
        case .retrying: return 0.57 + 0.03 * part(entriesChecked, entriesFound)
        case .media: return 0.6 + 0.4 * part(mediaDone, mediaTotal)
        case .done, .cancelled: return 1
        }
    }

    /// Which closing line the summary shows. Separate from the copy so the rule is testable.
    enum Outcome: Equatable, Sendable {
        /// Something new arrived.
        case added(posts: Int, media: Int)
        /// Every post the relays hold was already on this device.
        case upToDate
        /// No relay answered — nothing could be checked.
        case unreachable
    }

    var outcome: Outcome {
        if postsAdded > 0 || mediaDone > 0 { return .added(posts: postsAdded, media: mediaDone) }
        if relayErrors > 0 && entriesFound == 0 && circlesTotal > 0 && relayErrors >= circlesTotal { return .unreachable }
        return .upToDate
    }

    /// Whether the finished summary carries the caveat that relays are a mailbox, not an archive. A
    /// relay sweeps entries nobody has refreshed for 30 days, so "everything the relays hold" is never
    /// provably "everything you ever posted" — the line shows on every finished run, and it is the
    /// only line when nothing came back at all.
    var showsRetentionCaveat: Bool { phase == .done }
}

/// Pure planning helpers for the resync driver.
enum RelayHistoryPlan {
    /// Merge several relays' plans for one circle into one fetch list: each key once, with every relay
    /// that listed it (in relay preference order) to try in turn. Order is stable — first relay's keys
    /// first — so a resumed run walks the same way.
    static func merge(_ perRelay: [(node: String, keys: [String])]) -> [(key: String, nodes: [String])] {
        var order: [String] = []
        var nodes: [String: [String]] = [:]
        for (node, keys) in perRelay {
            for k in keys {
                if nodes[k] == nil { order.append(k); nodes[k] = [] }
                if !(nodes[k]!.contains(node)) { nodes[k]!.append(node) }
            }
        }
        return order.map { ($0, nodes[$0] ?? []) }
    }

    /// Split into fixed-size batches (the unit of fetch → ingest → save). `size` ≥ 1.
    static func batches<T>(_ items: [T], size: Int) -> [[T]] {
        let n = max(1, size)
        return stride(from: 0, to: items.count, by: n).map { Array(items[$0..<min($0 + n, items.count)]) }
    }

    /// The media a resync downloads for one post: everything it names that is real bytes and that the
    /// user has not deliberately evicted — except on a constrained link, where only the small
    /// companions (thumbs, posters, previews) come down and full-size waits for a tap, exactly like
    /// the feed's own prefetch. `small` is the subset of `refs` that are those companions.
    static func wanted(refs: [String], small: Set<String>, have: (String) -> Bool, evicted: (String) -> Bool,
                       synthetic: (String) -> Bool, constrained: Bool) -> [String] {
        var seen = Set<String>()
        return refs.filter { r in
            guard !synthetic(r), !have(r), !evicted(r), seen.insert(r).inserted else { return false }
            return !constrained || small.contains(r)
        }
    }

    /// One media ref the feed names, tagged with the user-visible ITEM it belongs to: its primary
    /// ref. A small companion (thumb / preview / poster) names its primary through its marker.
    struct MediaCandidate: Equatable, Sendable {
        let ref: String
        let circle: String
        let small: Bool
        let item: String
    }

    /// Every candidate one circle's raw feed refs name (posts + comments, markers included): the
    /// refs themselves plus their small companions, deduped, each tagged with its item.
    static func mediaCandidates(circle: String, refs: [String]) -> [MediaCandidate] {
        var primary: [String: String] = [:]
        for r in refs {
            if let t = MediaVariants.parseThumb(r) { primary[t.thumb] = primary[t.thumb] ?? t.content }
            if let p = MediaVariants.parsePreview(r) { primary[p.preview] = primary[p.preview] ?? p.content }
            if let p = MediaVariants.parsePoster(r) { primary[p.poster] = primary[p.poster] ?? p.video }
        }
        let smallList = MediaVariants.allThumbs(in: refs) + MediaVariants.allPosters(in: refs) + MediaVariants.allPreviews(in: refs)
        let small = Set(smallList)
        var seen = Set<String>()
        return (refs + smallList).compactMap { r in
            guard seen.insert(r).inserted else { return nil }
            return MediaCandidate(ref: r, circle: circle, small: small.contains(r), item: primary[r] ?? r)
        }
    }

    /// The media phase's plan. The summary counts user-visible ITEMS, never refs: a photo, its thumb
    /// and its preview are one item. An item counts as done once ANY of its refs landed — on a
    /// constrained link only companions are considered at all, so the companion alone is the item; on
    /// a normal link a thumb that lands before the full-size file already shows the photo.
    struct MediaPlan {
        /// Items new to the feed (not in `before` — a recovered post or comment named them) that
        /// already have something on disk: done up front, whichever path fetched them.
        var landed = 0
        /// `landed` + items with something to fetch.
        var total = 0
        /// Refs to fetch, small companions first (fetching stays per ref).
        var want: [MediaCandidate] = []
        fileprivate(set) var counted = Set<String>()
    }

    /// `before` = every ref the feed named when the run STARTED. Same rules as `wanted`: synthetic
    /// refs never, evicted refs not fetched, constrained links only small companions.
    static func mediaPlan(_ candidates: [MediaCandidate], before: Set<String>, constrained: Bool,
                          have: (String) -> Bool, evicted: (String) -> Bool, synthetic: (String) -> Bool) -> MediaPlan {
        var order: [String] = []
        var present: [String: Bool] = [:]
        var missing: [String: [MediaCandidate]] = [:]
        var taken = Set<String>()
        for c in candidates {
            guard !synthetic(c.ref), !constrained || c.small, taken.insert(c.ref).inserted else { continue }
            if present[c.item] == nil { order.append(c.item); present[c.item] = false }
            if have(c.ref) { present[c.item] = true } else if !evicted(c.ref) { missing[c.item, default: []].append(c) }
        }
        var plan = MediaPlan()
        var want: [MediaCandidate] = []
        for item in order {
            let m = missing[item] ?? []
            if present[item] == true && !before.contains(item) {
                plan.landed += 1
                plan.total += 1
                plan.counted.insert(item)
            } else if !m.isEmpty {
                plan.total += 1
            }
            want += m
        }
        // Small companions first (stable): they make the feed look right long before full-size lands.
        plan.want = want.filter(\.small) + want.filter { !$0.small }
        return plan
    }
}

/// Per-ref fetch results → per-item counts: an item is done at its first ref that lands, missing once
/// every one of its refs failed; an item counted up front never counts again.
struct RelayHistoryMediaTally {
    private var pending: [String: Int] = [:]
    private var counted: Set<String>

    init(_ plan: RelayHistoryPlan.MediaPlan) {
        counted = plan.counted
        for w in plan.want { pending[w.item, default: 0] += 1 }
    }

    mutating func record(item: String, ok: Bool) -> (done: Int, missing: Int) {
        let left = max(0, (pending[item] ?? 0) - 1)
        pending[item] = left
        if counted.contains(item) { return (0, 0) }
        if ok { counted.insert(item); return (1, 0) }
        if left == 0 { counted.insert(item); return (0, 1) }
        return (0, 0)
    }
}
