import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit   // UIApplication.beginBackgroundTask for the media-upload drain (no-op path on macOS)
#endif

/// The "volunteer as tribute" shared circle store. A member who turns this on keeps a
/// sealed copy of the circle's media in their own S3 bucket and re-serves it to anyone
/// who's missing it — so memories survive even when the original sender is offline.
///
/// Security: every blob is sealed to the *circle* (seal_circle_media), so the bucket
/// host stores only opaque bytes it cannot read, and a fetched blob is verified against
/// the circle roster before it's opened. No credentials are ever shared between members
/// — the volunteer simply acts as a durable, always-available media source over the
/// existing P2P media protocol. Keys live only in the device Keychain.
/// The circle's shared relay bucket, received (sealed) from whoever volunteered theirs.
/// Distinct from StorageStore (your *own* bucket). Secret lives only in the Keychain.
@MainActor
final class SharedMailboxStore: ObservableObject {
    static let shared = SharedMailboxStore()
    @Published private(set) var config: S3Config?

    private let d = UserDefaults.standard
    private let key = "haven.sharedMailbox"

    private init() {
        if let data = d.data(forKey: key), var c = try? JSONDecoder().decode(S3Config.self, from: data) {
            c.secret = Keychain.get("sharedMailboxSecret") ?? ""
            config = c
        }
    }

    func set(_ c: S3Config) {
        var stored = c; stored.secret = ""   // keep the secret out of UserDefaults
        d.set(try? JSONEncoder().encode(stored), forKey: key)
        Keychain.set(c.secret, for: "sharedMailboxSecret")
        config = c
    }
    func clear() {
        d.removeObject(forKey: key)
        Keychain.set("", for: "sharedMailboxSecret")
        config = nil
    }
}

/// Serializes media backups so they don't all load full files into memory at once. backfillMailboxMedia
/// and the per-post backup sites used to spawn a Task PER media ref concurrently — each loading + sealing a
/// full file (2× in RAM) — which ballooned memory to ~3.4GB and jetsam-killed iOS once a device held a lot
/// of media. Process ONE at a time so peak memory is ~one media file, not the whole library.
///
/// Uploads a freshly-posted media blob to the circle's relay(s). Hardened to match `BackgroundUploader`
/// (which handles the post ENVELOPE): the queue is PERSISTED, the drain holds a background-task
/// assertion so it finishes after the app leaves the foreground, and a failed upload is RETRIED rather
/// than dropped. Without all three, posting a story and immediately locking the phone (the whole point of
/// a story) suspended the app mid-upload — the envelope reached the relay (viewers saw the story) but the
/// BLOB never did, so it "failed to load from a relay". The in-memory queue was also lost on app kill, so
/// only whatever happened to finish while foregrounded (the most recent items) ever landed.
@MainActor
final class MediaBackupQueue {
    static let shared = MediaBackupQueue()
    /// `at` (authored ms, priority lane only) lets the drain announce a FRESH post's media to the
    /// circle the moment it lands (frame 32) — optional so old persisted queues still decode.
    private struct Job: Codable, Equatable { let ref: String; let cid: String; var at: UInt64? }
    private let key = "haven.mediaBackupQueue"
    private let hiKey = "haven.mediaBackupQueue.hi"
    private var pending: [Job]
    /// High-priority lane, drained FIRST: media of just-authored posts. Without it a fresh story's
    /// blob queued behind a long historical backfill and friends saw the post minutes before its
    /// media could possibly land.
    private var priorityPending: [Job]
    private var draining = false
    /// Jobs a drain pass has taken off the lanes and is uploading RIGHT NOW, per lane. Keeps
    /// `hasPending` honest (upload indicator), the enqueue dedup tight, and `save()` complete
    /// (the disk copy must never lose an in-flight job to a kill mid-pass) while a pass owns them.
    private var inFlightHi: [Job] = []
    private var inFlightLo: [Job] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Job].self, from: d) {
            pending = list
        } else {
            pending = []
        }
        if let d = UserDefaults.standard.data(forKey: hiKey), let list = try? JSONDecoder().decode([Job].self, from: d) {
            priorityPending = list
        } else {
            priorityPending = []
        }
    }
    private func save() {
        // In-flight jobs lead their lane on disk: a kill mid-pass relaunches with them queued first.
        if let d = try? JSONEncoder().encode(inFlightLo + pending) { UserDefaults.standard.set(d, forKey: key) }
        if let d = try? JSONEncoder().encode(inFlightHi + priorityPending) { UserDefaults.standard.set(d, forKey: hiKey) }
    }

    /// Whether a specific blob is still waiting to reach a relay (drives the post upload indicator).
    func hasPending(_ ref: String) -> Bool {
        inFlightHi.contains { $0.ref == ref } || inFlightLo.contains { $0.ref == ref }
            || pending.contains { $0.ref == ref } || priorityPending.contains { $0.ref == ref }
    }

    /// `priority`: a just-authored event's media — drained before any backfill backlog. Callers
    /// enqueue in the media list's order (thumbs/posters ride before the video), which the lane
    /// preserves, so a poster is on the relay before its (much larger) video starts.
    func enqueue(_ ref: String, circleId: String, social: HavenSocial, priority: Bool = false) {
        if MediaStore.isSynthetic(ref) { return }   // geo: pins et al. carry no bytes — never relay-storable
        let queued = (inFlightHi + inFlightLo).contains(where: { $0.ref == ref && $0.cid == circleId })
            || pending.contains(where: { $0.ref == ref && $0.cid == circleId })
            || priorityPending.contains(where: { $0.ref == ref && $0.cid == circleId })
        if !queued {
            if priority {
                priorityPending.append(Job(ref: ref, cid: circleId,
                                           at: UInt64(Date().timeIntervalSince1970 * 1000)))
                if priorityPending.count > 500 { priorityPending.removeFirst(priorityPending.count - 500) }
            } else {
                pending.append(Job(ref: ref, cid: circleId, at: nil))
                if pending.count > 10_000 { pending.removeFirst(pending.count - 10_000) }   // bound the queue itself
            }
            save()
        }
        drain(social: social)
    }

    /// Kick a drain for anything persisted from a prior session — call on launch so media that was
    /// mid-upload when the app was killed still reaches the relay.
    func drainPersisted(social: HavenSocial) { drain(social: social) }

    private func drain(social: HavenSocial) {
        guard !draining, !pending.isEmpty || !priorityPending.isEmpty else { return }
        draining = true
        Task { @MainActor in
            // Keep the upload alive after the app backgrounds (iOS suspends otherwise). No-op on macOS.
            #if canImport(UIKit)
            let bgId = UIApplication.shared.beginBackgroundTask(withName: "haven.media-backup")
            defer { if bgId != .invalid { UIApplication.shared.endBackgroundTask(bgId) } }
            #endif
            // BUDGETED pass. A Mac hosting a circle relay with a large library used to seal+upload
            // every pending ref in one go (videos × 2 in RAM) → multi‑GB footprint and beachball.
            // Failures + leftovers stay queued; we re-arm after a short rest so the UI can breathe.
            // Priority lane (just-authored posts) drains FIRST; backfill takes what's left.
            //
            // The taken jobs come OFF the live lanes for the duration of the pass (inFlight covers
            // them for hasPending/dedup). The previous shape — snapshot the leftovers up front,
            // assign the snapshot back after the awaits — silently DROPPED any job enqueued while
            // the pass was in flight: a fresh video post authored during a retry/backfill pass had
            // its blob clobbered out of the queue, and the post's media never uploaded until the
            // 2-min backfill stumbled on it. The disk copy keeps the full pre-pass set until the
            // end-of-pass save, so a kill mid-pass still restores the in-flight jobs on relaunch.
            let budget = 5
            let hiWork = Array(priorityPending.prefix(budget))
            let loWork = Array(pending.prefix(budget - hiWork.count))
            priorityPending.removeFirst(hiWork.count)
            pending.removeFirst(loWork.count)
            inFlightHi = hiWork
            inFlightLo = loWork
            var failedHi: [Job] = []
            var failedLo: [Job] = []
            for (job, isPriority) in hiWork.map({ ($0, true) }) + loWork.map({ ($0, false) }) {
                // Own hosted store: if the blob is already local under the media key, ledger it and
                // skip the expensive seal path for that dest (backup still mirrors to remote peers).
                let ok = await SharedStore.backup(ref: job.ref, circleId: job.cid, social: social)
                if !ok {
                    HavenLog.sync("media-backup RETRY ref=\(job.ref.prefix(16)) circle=\(job.cid.prefix(12)) lane=\(isPriority ? "hi" : "lo") — pass failed, requeued")
                    if isPriority { failedHi.append(job) } else { failedLo.append(job) }
                } else if isPriority, let at = job.at,
                          UInt64(Date().timeIntervalSince1970 * 1000) &- at < 600_000 {
                    // A FRESH post's blob just landed on a relay — tell the circle so their devices
                    // prefetch NOW instead of on their next missing-media sweep (frame 32).
                    FeedStore.shared.announceMediaLanded(ref: job.ref, circleId: job.cid)
                }
                // Yield between large jobs so SwiftUI / Multipeer can run.
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            inFlightHi = []
            inFlightLo = []
            // Failures rejoin the BACK of their lane (no head-of-line starvation) — and only if the
            // same ref+circle wasn't re-enqueued while this pass ran.
            priorityPending.append(contentsOf: failedHi.filter { j in
                !priorityPending.contains(where: { $0.ref == j.ref && $0.cid == j.cid })
            })
            pending.append(contentsOf: failedLo.filter { j in
                !pending.contains(where: { $0.ref == j.ref && $0.cid == j.cid })
            })
            save()
            draining = false
            if !pending.isEmpty || !priorityPending.isEmpty {
                // Continue later without stacking concurrent drains.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    MediaBackupQueue.shared.drainPersisted(social: social)
                }
            }
        }
    }
}

/// Records which media blobs we've CONFIRMED are on which destination (relay node id, or "s3"), so
/// the every-2-min backfill stops re-uploading — or even re-reading/re-sealing — a blob the relay
/// already has. Media keys are content-addressed (`haven/media/<ref>`), so a blob never changes: once
/// it's on a relay it's there for good, making this a permanent, staleness-free cache. Before this,
/// the ONLY dedup was a live `has()`/`head()` round-trip, which fails over a flaky transport and made
/// the device re-upload the whole blob every cycle — "the iPhone constantly sends media the relay
/// already possesses." Keyed "dest|ref".
@MainActor
enum MediaBackupLedger {
    private static let defaultsKey = "haven.media.backedUp"
    private static var set: Set<String> = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    static func has(_ dest: String, _ ref: String) -> Bool { set.contains("\(dest)|\(ref)") }
    /// Confirmed on ANY destination (relay node or s3), INCLUDING our own in-process relay.
    static func hasAny(_ ref: String) -> Bool { set.contains { $0.hasSuffix("|\(ref)") } }

    /// Confirmed somewhere a DIFFERENT DEVICE can read it — what "backed up" should have meant.
    ///
    /// `hasAny` counts our own in-process relay, and writing to that is a LOCAL FILE COPY: it never
    /// crosses the network and cannot fail. So a post whose media only ever reached this device's own
    /// relay showed a confident "backed up to a relay" tick while no one else could fetch it. That is
    /// precisely what happened tonight — a user watched checked-cloud icons on every post while their
    /// friends saw nothing, because the only relay the media reached was the one running inside their
    /// own app. An indicator that cannot distinguish "safe" from "only I have it" is worse than none:
    /// it is the reason the failure went unnoticed for hours.
    ///
    /// Our own relay is excluded even though it may be reachable by others (LAN, or a public URL),
    /// because we cannot tell from here — and the honest failure is to under-claim, not over-claim.
    static func hasAnyRemote(_ ref: String, ownRelayHex: String) -> Bool {
        set.contains { entry in
            guard entry.hasSuffix("|\(ref)") else { return false }
            let dest = String(entry.dropLast(ref.count + 1))
            return dest != ownRelayHex
        }
    }
    /// Every destination confirmed to hold `ref`.
    ///
    /// The ledger has always known this — it is keyed `dest|ref` — but nothing ever showed it, so
    /// "is my post actually anywhere?" could only be answered by reading logs. That question came up
    /// while debugging a delivery failure where the tick was green and no friend could fetch a thing.
    static func destinations(for ref: String) -> [String] {
        set.compactMap { entry in
            guard entry.hasSuffix("|\(ref)") else { return nil }
            return String(entry.dropLast(ref.count + 1))
        }
    }

    static func mark(_ dest: String, _ ref: String) {
        guard set.insert("\(dest)|\(ref)").inserted else { return }
        if set.count > 20_000 { set = Set(set.suffix(20_000)) }
        UserDefaults.standard.set(Array(set), forKey: defaultsKey)
    }
    /// Forget a destination's confirmations (e.g. a relay was wiped/forgotten) so we re-mirror to it.
    static func forgetDest(_ dest: String) {
        let before = set.count
        set = set.filter { !$0.hasPrefix("\(dest)|") }
        if set.count != before { UserDefaults.standard.set(Array(set), forKey: defaultsKey) }
    }
}

/// One-time recovery for media posted during the 1.0.7 device-signed-media bug. Media I authored then
/// was sealed under a device key and frozen (the blob is content-addressed + write-once), so friends
/// could never open it. This re-seals my OWN authored media under the fixed (account-signed) scheme and
/// OVERWRITES the frozen blob on every destination, so a friend's stuck media loads again. Only media I
/// still hold the plaintext for (the seal reads the original file); anything cleared by the storage
/// sweep is gone. Runs once, in the background, off-main — it re-uploads that media a single time.
enum MediaRecovery {
    private static let doneKey = "haven.media.reseal.1_0_8.done"
    private static let refsKey = "haven.media.reseal.1_0_8.refs"      // refs confirmed overwritten on ≥1 dest
    private static let attemptsKey = "haven.media.reseal.1_0_8.attempts"
    // A content-addressed blob can ONLY be repaired by the force-overwrite (the normal backfill sees the
    // frozen blob as "present" and skips it forever), and the overwrite lands only on destinations
    // reachable during the pass. So we RETRY across launches until every repairable ref is confirmed —
    // capped so a user with no reachable destination (nothing was ever uploaded, nothing to repair)
    // still stops after a bounded number of cheap passes.
    private static let maxAttempts = 10
    private static var inFlight = false

    static func runOnceIfNeeded(social: HavenSocial) {
        guard !UserDefaults.standard.bool(forKey: doneKey), !inFlight else { return }
        inFlight = true
        Task.detached(priority: .background) {
            defer { Task { @MainActor in inFlight = false } }
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            var owned: [(ref: String, cid: String)] = []
            var seen = Set<String>()
            for c in social.circles() {
                for item in social.feed(circleId: c.id, nowMs: nowMs, viewerRetentionSecs: nil) where item.isMe {
                    for r in item.media where seen.insert(r).inserted { owned.append((r, c.id)) }
                    for cm in item.comments where cm.isMe {
                        for r in cm.media where seen.insert(r).inserted { owned.append((r, c.id)) }
                    }
                }
            }
            // Only media I still hold the plaintext for — the re-seal reads the original file. Anything
            // the storage sweep cleared is gone and must not block the latch.
            var held: [(ref: String, cid: String)] = []
            for m in owned {
                if let u = await MediaStore.shared.storagePath(for: m.ref),
                   FileManager.default.fileExists(atPath: u.path) { held.append(m) }
            }
            var done = Set(UserDefaults.standard.stringArray(forKey: refsKey) ?? [])
            let todo = held.filter { !done.contains($0.ref) }
            for m in todo {
                if await SharedStore.backup(ref: m.ref, circleId: m.cid, social: social, force: true) {
                    done.insert(m.ref)   // a destination accepted the fresh blob → this ref is repaired
                }
            }
            UserDefaults.standard.set(Array(done), forKey: refsKey)
            let attempts = UserDefaults.standard.integer(forKey: attemptsKey) + 1
            UserDefaults.standard.set(attempts, forKey: attemptsKey)
            // Latch when every repairable ref is confirmed, or after enough tries that a still-failing
            // ref is almost certainly un-repairable (its destination is gone / was never reachable).
            if held.allSatisfy({ done.contains($0.ref) }) || attempts >= maxAttempts {
                UserDefaults.standard.set(true, forKey: doneKey)
            }
            if !todo.isEmpty {
                HavenLog.sync("media recovery: \(done.count)/\(held.count) authored blobs re-sealed + overwritten (attempt \(attempts))")
            }
        }
    }
}

/// Exponential backoff for media backups that keep FAILING to land on any destination. Without this,
/// the every-2-min `backfillMailboxMedia` re-reads, re-seals and re-uploads the same blob forever when
/// no relay can hold it (e.g. every relay is behind a NAT the iroh blob ALPN can't traverse and there's
/// no S3 bucket) — the "my posts get synced again and again" heat/traffic storm. Once a blob lands
/// anywhere the backoff is cleared; while it can't land the retry interval doubles 2min → … → ~1h, so a
/// genuinely-unreachable blob costs one attempt an hour instead of thirty. In-memory only: a fresh
/// launch is a legitimate reason to retry promptly (the transport may have changed).
@MainActor
enum MediaBackupBackoff {
    private static let baseMs: UInt64 = 2 * 60 * 1000        // first retry gap after a stall
    private static let capMs: UInt64 = 60 * 60 * 1000        // never wait longer than an hour
    private static var nextTry: [String: UInt64] = [:]       // ref → earliest retry (epoch ms)
    private static var fails: [String: Int] = [:]            // ref → consecutive stall count

    private static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// True if `ref` stalled recently and its backoff window hasn't elapsed — skip re-enqueueing it.
    static func shouldSkip(_ ref: String) -> Bool {
        guard let due = nextTry[ref] else { return false }
        return nowMs() < due
    }

    /// The blob reached at least one destination (or is fully confirmed) — stop backing off.
    static func recordLanded(_ ref: String) {
        nextTry[ref] = nil
        fails[ref] = nil
    }

    /// The blob reached NO destination this pass — grow the retry gap.
    static func recordStalled(_ ref: String) {
        let n = (fails[ref] ?? 0) + 1
        fails[ref] = n
        let shift = min(n - 1, 5)                            // 2,4,8,16,32,64 min → capped
        let gap = min(baseMs << UInt64(shift), capMs)
        nextTry[ref] = nowMs() + gap
        if nextTry.count > 20_000 {                          // bound memory on huge feeds
            nextTry.removeAll(); fails.removeAll()
        }
    }
}

@MainActor
enum SharedStore {
    /// The bucket to use for the circle's mailbox: the shared relay if one was set,
    /// otherwise your own bucket *if* you've opted in as the volunteer.
    static func mailboxClient() -> S3Client? {
        if let c = SharedMailboxStore.shared.config, c.isComplete { return S3Client(config: c) }
        if StorageStore.shared.shareCircleMedia { return S3Client(StorageStore.shared) }
        return nil
    }
    /// True when this device participates in a shared mailbox (own volunteer or received relay).
    static var isVolunteering: Bool { mailboxClient() != nil }

    private static func key(_ ref: String) -> String { "haven/media/\(ref)" }
    // Chunks live in a SIBLING directory "<ref>.p/", NOT nested under the manifest key. On a hierarchical
    // disk relay (blobstore local_put maps each key segment to a directory) the manifest key "haven/media/<ref>"
    // is a FILE, so chunks under "haven/media/<ref>/<i>" would force "<ref>" to be a directory too — a
    // file-vs-dir collision that fails the manifest write. "<ref>.p" is a distinct name → no collision.
    private static func chunkKey(_ ref: String, _ i: Int) -> String { "haven/media/\(ref).p/\(i)" }

    // MARK: - Chunked media transfer (large-blob fix)
    //
    // A relay/S3 blob is capped at MAX_BLOB = 256 MB (core/haven-net blobstore). Large videos
    // (600 MB+) sealed into ONE blob under "haven/media/<ref>" exceed that, so a GET truncates and
    // the receiver can't play them (photos, ~5 MB, worked). Fix: slice the SEALED bytes into 8 MB
    // chunks under "haven/media/<ref>.p/<i>" and store a tiny manifest under "haven/media/<ref>". On
    // download, fetch chunks IN ORDER and APPEND to a file on disk (streaming — never hold the full
    // sealed blob in RAM, which OOM-killed Android before). Small media (<= one chunk) stays a single
    // sealed blob (no manifest) for back-compat. This format is BYTE-IDENTICAL across iOS/macOS,
    // Android and desktop so they interoperate.
    static let mediaChunkBytes = 8 * 1024 * 1024   // 8 MB — well under MAX_BLOB, memory-safe
    /// Magic prefix that marks a manifest blob (a sealed envelope is JSON starting with '{', so it can
    /// never collide). Exactly these 9 bytes, then a JSON body.
    static let manifestMagic = Data("HVCHUNK1\n".utf8)

    /// Build the manifest blob for a sealed media of `sizes` chunk lengths.
    private static func makeManifest(sizes: [Int]) -> Data {
        let total = sizes.reduce(0, +)
        let json: [String: Any] = ["v": 1, "chunks": sizes.count, "total": total, "sizes": sizes]
        var out = manifestMagic
        out.append((try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
        return out
    }
    /// If `blob` is a chunk manifest, return the parsed chunk count; else nil (legacy/small single blob).
    private static func parseManifest(_ blob: Data) -> Int? {
        guard blob.count > manifestMagic.count, blob.prefix(manifestMagic.count) == manifestMagic else { return nil }
        let body = blob.suffix(from: blob.startIndex + manifestMagic.count)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let n = obj["chunks"] as? Int, n > 0 else { return nil }
        return n
    }

    // MARK: - Resumable chunked restore (.part bookkeeping)
    //
    // A chunked relay download used to be all-or-nothing: any chunk miss threw the temp file away,
    // so a 600 MB video over a flaky tunnel restarted from chunk 0 every retry — the mirror image
    // of the upload-resume problem (frame-33 peer resume already fixed the peer path). Chunks are
    // fetched IN ORDER and appended, so resume state is just "how many leading chunks are in the
    // .part file", persisted in a sidecar next to it. The manifest's chunk count keys validity: a
    // count mismatch (different seal uploaded meanwhile) discards the partial.
    nonisolated private static var restorePartsDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("haven-relay-parts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated private static func restorePartURL(_ ref: String) -> URL {
        let safe = SHA256.hash(data: Data(ref.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return restorePartsDir.appendingPathComponent("\(safe).part")
    }
    private struct RestorePartMeta: Codable { let chunks: Int; var got: Int }
    nonisolated private static func restoreMetaURL(_ ref: String) -> URL {
        restorePartURL(ref).appendingPathExtension("meta")
    }
    private static func loadRestorePart(_ ref: String, chunks: Int) -> Int {
        guard let d = try? Data(contentsOf: restoreMetaURL(ref)),
              let m = try? JSONDecoder().decode(RestorePartMeta.self, from: d),
              m.chunks == chunks, m.got > 0, m.got <= chunks,
              FileManager.default.fileExists(atPath: restorePartURL(ref).path) else { return 0 }
        return m.got
    }
    private static func saveRestorePart(_ ref: String, chunks: Int, got: Int) {
        if let d = try? JSONEncoder().encode(RestorePartMeta(chunks: chunks, got: got)) {
            try? d.write(to: restoreMetaURL(ref), options: .atomic)
        }
    }
    private static func clearRestorePart(_ ref: String) {
        try? FileManager.default.removeItem(at: restorePartURL(ref))
        try? FileManager.default.removeItem(at: restoreMetaURL(ref))
    }
    /// Reclaim abandoned partials (untouched > 7 days) — cheap, called opportunistically.
    private static var sweptRestoreParts = false
    private static func sweepRestorePartsOnce() {
        guard !sweptRestoreParts else { return }
        sweptRestoreParts = true
        let dir = restorePartsDir
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for url in items {
                if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(m) > 7 * 86_400 {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// The relay node ids serving a circle (the common path) — posts are mirrored to ALL of them
    /// and read from any (graceful fallback if one is down). Ordered so live public HTTP (Mac CF
    /// tunnel) is tried before a long-dead NAS that still sits in the active pool.
    private static func relayNodes(_ circleId: String) -> [String] {
        preferLiveRelays(RelayMailboxStore.shared.relays(forCircle: circleId))
    }

    /// Sort relays: own host → public HTTP → proven alive → others; mid-backoff last.
    private static func preferLiveRelays(_ nodes: [String]) -> [String] {
        let own = RelayHost.shared.serving ? RelayHost.shared.nodeId.lowercased() : ""
        func score(_ n: String) -> Int {
            var s = 0
            let nl = n.lowercased()
            if !own.isEmpty, nl == own { s += 1_000 }
            if let http = RelayMailboxStore.shared.httpInterface(n) {
                if http.urls.contains(where: { RelayMailboxStore.urlReachableByOthers($0) }) { s += 200 }
                else { s += 40 }
            }
            if RelayHealth.shared.provenAlive(n, withinMs: 900_000) { s += 100 }
            else if !RelayHealth.shared.available(n) { s -= 80 }
            return s
        }
        return nodes.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            return a < b
        }
    }
    /// First configured relay — for "does this circle have a relay at all" checks.
    private static func relayNode(_ circleId: String) -> String? {
        relayNodes(circleId).first
    }

    /// Relay node ids to MIRROR media to / FETCH media from — the circle's own relays PLUS every other
    /// known relay. Media keys (`haven/media/<ref>`) are content-addressed and NOT gated per circle,
    /// so a blob may safely live on ANY relay the members can reach — but since audit F4 they are no
    /// longer permission-FREE: `blob_forbidden` denies any peer it does not already know as a member
    /// of some circle it serves, media included. A device earns that only by publishing its
    /// account-signed roster (`publishDeviceRoster`). Treat a refusal from these relays as "publish
    /// the roster and retry" (`healForbiddenRelays`), never as "this relay is down" — conflating the
    /// two is what reported present-but-refused media as NOT FOUND. Mirroring to every known relay is what makes media land when a circle's own
    /// relays are all offline/NAT-unreachable but some OTHER relay (e.g. a hosted/NAS relay configured
    /// for a different circle) is reachable — that relay accepts the media even though it forbids the
    /// device's mailbox writes. Content-addressed keys make the extra puts idempotent, unreachable
    /// relays fail fast and back off, and mesh anti-entropy replicates the blob onto the circle's own
    /// relays once they return; a friend who shares any of these relays fetches it directly. `allRelays`
    /// is already active-only (deleted/forgotten relays excluded); s3: pseudo-nodes are handled by S3.
    private static func mediaDests(_ circleId: String) -> [String] {
        // relayNodes already preferLiveRelays; append other known relays the same way.
        var nodes = relayNodes(circleId).filter { !$0.hasPrefix("s3:") }
        var extra: [String] = []
        for r in RelayMailboxStore.shared.allRelays() where !r.hasPrefix("s3:") && !nodes.contains(r) {
            extra.append(r)
        }
        return nodes + preferLiveRelays(extra)
    }
    /// This device's OWN S3 bucket (the owner uses its credentials directly).
    static func ownerS3() -> S3Client? { S3Client(StorageStore.shared) }
    private static func isOwner(_ circleId: String) -> Bool {
        PresignStore.shared.ownedCircles.contains(circleId) && ownerS3() != nil
    }
    /// True when a circle has *some* mailbox — a Haven relay, a pre-signed pool, or raw S3 creds.
    static func hasMailbox(_ circleId: String) -> Bool {
        relayNode(circleId) != nil || isOwner(circleId) || PresignStore.shared.hasPool(circleId) || mailboxClient() != nil
    }

    /// Seal a locally-held media blob to the circle and store it in the circle's mailbox
    /// (relay if set, else S3) — idempotent.
    /// `force` (recovery only): re-seal and OVERWRITE the blob on every reachable destination,
    /// bypassing the "already has it" probe. A blob is content-addressed and write-once, so a blob
    /// sealed the wrong way (the 1.0.7 device-signed media bug) stays frozen — the normal path probes,
    /// sees the relay already holds THAT ref, and skips. Forcing re-uploads the correctly-sealed bytes
    /// to the same key (every PUT replaces by key), which is what recovers a friend's stuck media.
    /// Returns whether some destination now holds the blob (a probe hit, or — under `force` — accepted
    /// the freshly re-sealed overwrite). The recovery migration uses this to know a ref is repaired.
    @discardableResult
    static func backup(ref: String, circleId: String, social: HavenSocial, force: Bool = false) async -> Bool {
        if await backupOnce(ref: ref, circleId: circleId, social: social, force: force) { return true }
        // Nothing took the blob and at least one relay REFUSED it rather than being down: publish our
        // roster to the refusers and try once more, exactly as `restore` does for the read side. A
        // device that has never been authorized anywhere otherwise never gets its FIRST blob up — and
        // because that upload failure is invisible, the damage surfaces much later as a fetch that
        // genuinely 404s, an absence manufactured entirely by a permissions problem.
        guard await healForbiddenRelays(social: social) else { return false }
        return await backupOnce(ref: ref, circleId: circleId, social: social, force: force)
    }

    private static func backupOnce(ref: String, circleId: String, social: HavenSocial, force: Bool = false) async -> Bool {
        // Skip entirely if this blob is already confirmed on EVERY destination — before the expensive
        // file read + seal. Content-addressed keys never change, so a confirmed upload is permanent.
        // This is what stops the periodic backfill from re-sending media the relay already has.
        // mediaDests broadens beyond the circle's own (possibly all-NAT'd) relays to any reachable
        // shared relay, so a video isn't stranded when the circle's relay is offline.
        let destNodes = mediaDests(circleId)
        let s3 = mediaS3(for: circleId)
        let allConfirmed = !force
            && destNodes.allSatisfy { MediaBackupLedger.has($0, ref) }
            && (s3 == nil || MediaBackupLedger.has("s3", ref))
        if allConfirmed && (!destNodes.isEmpty || s3 != nil) { MediaBackupBackoff.recordLanded(ref); return true }
        guard let url = MediaStore.shared.storagePath(for: ref) else { return false }

        // ---- Probe phase: NO file read, NO seal. `key(ref)` is content-addressed — independent of
        // the sealed bytes — so every unconfirmed destination can be asked "do you already hold it?"
        // first. Sealing costs ~2× the file size in transient RAM (a 600 MB video → GBs), and doing it
        // only to find every unconfirmed relay unreachable/in backoff made EVERY backfill pass spike
        // memory for nothing. Only a destination that is REACHABLE and MISSING the blob justifies the
        // read+seal below; an unreachable one is retried on a later pass, after its backoff.
        enum Route { case ownRelay; case http(base: String, token: String); case dial(RelayClient) }
        var uploads: [(node: String, route: Route)] = []
        var s3Needs = false
        var landed = false   // some destination holds it (probe hit) or accepted it (upload)

        // S3/HTTP bucket — the DEFAULT media transport (see the upload ordering note below).
        if s3 != nil, force {
            s3Needs = true   // recovery: overwrite unconditionally, no head probe
        } else if let s3, !MediaBackupLedger.has("s3", ref) {
            switch await s3.headObjectExists(key: key(ref)) {
            case .some(true): MediaBackupLedger.mark("s3", ref); landed = true
            case .some(false): s3Needs = true
            case .none: break   // bucket unreachable — don't seal on its behalf
            }
        } else if s3 != nil { landed = true }

        for node in destNodes {
            if !force && MediaBackupLedger.has(node, ref) { landed = true; continue }   // already confirmed
            // Our OWN hosted relay: the local store answers instantly (no dial).
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                // localHas, NOT localGet != nil: this only asks "is it already there?", and localGet
                // reads the WHOLE blob to answer it — a full media file, hundreds of MB for a video,
                // pulled into memory on the MAIN ACTOR (RelayHost is @MainActor). The 2-minute media
                // backfill runs this for every ref the device knows, so hosting a relay meant reading
                // your entire media library into RAM on the main thread every two minutes. That is the
                // "my Mac became unresponsive after I enabled the relay" report: not the relay serving
                // peers, but the host's own backup check. localHas answers from the index.
                if !force, RelayHost.shared.localHas(key(ref)) { MediaBackupLedger.mark(node, ref); landed = true }
                else { uploads.append((node, .ownRelay)) }
                continue
            }
            // Plain-HTTP interface first (the reliable cross-NAT path). A reachable relay that
            // answers is authoritative — the iroh path serves the SAME store, so don't also dial.
            if let http = RelayMailboxStore.shared.httpInterface(node) {
                // Recovery: don't probe — queue an overwrite to the first good base and move on.
                if force {
                    if let base = http.urls.first(where: { !httpUrlBad($0) }) {
                        uploads.append((node, .http(base: base, token: http.token)))
                        continue
                    }
                }
                var resolved = false
                for base in http.urls where !httpUrlBad(base) {
                    switch await httpGet(base, http.token, key(ref)) {
                    case .success(let existing):
                        if existing != nil {
                            RelayMailboxStore.shared.markSeen(node)
                            MediaBackupLedger.mark(node, ref); landed = true
                        } else {
                            uploads.append((node, .http(base: base, token: http.token)))
                        }
                        resolved = true
                    case .failure(is RelayForbidden):
                        // Reachable and healthy — it just doesn't know us. Backing off here would
                        // strand our media on a relay that would happily store it once authorized.
                        noteRefused(node, "media probe")
                    case .failure:
                        markHttpUrlBad(base)
                    }
                    if resolved { break }
                }
                if resolved { continue }
            }
            // iroh fallback — RelayClients honors RelayHealth backoff (nil = skip WITHOUT sealing).
            guard let c = await RelayClients.client(node) else {
                HavenLog.sync("backup probe SKIP ref=\(ref) relay=\(node.prefix(8)) — unreachable/backing off (no http, no dial)")
                continue
            }
            if !force, await c.has(key: key(ref)) {
                RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                MediaBackupLedger.mark(node, ref); landed = true
            } else {
                uploads.append((node, .dial(c)))
            }
        }

        guard s3Needs || !uploads.isEmpty else {
            // Every unconfirmed destination either turned out to already hold the blob (now in the
            // ledger) or was unreachable/backing off — the file is never read or sealed this pass.
            if !landed { HavenLog.sync("backup NO-DEST ref=\(ref)"); MediaBackupBackoff.recordStalled(ref) }
            else { MediaBackupBackoff.recordLanded(ref) }
        // The ring's job is done the moment the ledger can answer; leaving the entry behind
        // would keep a finished upload showing as in-flight.
        if landed { MediaUploadProgress.shared.finish(ref) }
            return landed
        }

        // ---- Seal to a TEMP FILE, now known to be needed by at least one reachable destination.
        // File→file in NATIVE memory (seal_circle_media_file): a large video sealed via the in-memory
        // path forces the whole sealed envelope through one contiguous Swift `Data`, which TRAPS
        // (EXC_BREAKPOINT in __DataStorage.init) when the allocation can't be satisfied — the app
        // crashed the instant a big video was posted. Sealing to disk keeps the big buffers off the
        // managed heap; the uploads below then stream the sealed file in 8 MB windows (never whole).
        // OFF the main thread — the serial backup queue runs these back-to-back.
        let sealedURL = url.deletingLastPathComponent()
            .appendingPathComponent(".seal-\(ref).tmp")
        // REUSE an existing seal rather than making a new one per attempt. Two reasons, and the first
        // is a correctness bug, not an optimisation:
        //
        // 1. Sealing is NOT byte-stable. The envelope carries per-recipient key material, so its size
        //    moves as device rosters arrive (observed on one 297 MB video across retries: 297496263,
        //    297487820, 297498198 bytes) — and even with an identical recipient set the nonce differs,
        //    so the bytes change while the LENGTH stays the same. A resumed chunked upload skips the
        //    windows already stored and sends the rest from the NEW seal, producing a blob that
        //    reassembles to the right length and decrypts to nothing. The same-length case is the
        //    common one, so this would corrupt silently and look like "media won't open".
        // 2. Re-sealing 297 MB on every retry, every ~90s, for an upload that keeps failing, is a
        //    staggering amount of CPU and disk for no gain.
        //
        // `seal_circle_media_file` writes `<out>.part` and renames, so a file AT this path is a
        // COMPLETE seal — never a half-written one. Stale seals are bounded below.
        let existing = (try? sealedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]))
        var sealedOK = false
        if let existing, (existing.fileSize ?? 0) > 0,
           let made = existing.contentModificationDate,
           Date().timeIntervalSince(made) < 24 * 3600 {
            HavenLog.sync("backup ref=\(ref): reusing the existing seal (stable bytes → resume is safe)")
            sealedOK = true
        } else {
            if existing != nil { try? FileManager.default.removeItem(at: sealedURL) }   // stale → re-seal
            sealedOK = await Task.detached(priority: .utility) { () -> Bool in
                social.sealCircleMediaFile(circleId: circleId, inPath: url.path, outPath: sealedURL.path)
            }.value
        }
        guard sealedOK,
              let sealedSize = (try? FileManager.default.attributesOfItem(atPath: sealedURL.path)[.size] as? Int) ?? nil
        else { HavenLog.sync("backup SEAL-FAIL ref=\(ref)"); MediaBackupBackoff.recordStalled(ref); return false }
        let chunked = sealedSize > mediaChunkBytes
        // Identity of the exact bytes about to be uploaded. A destination's stored windows may only be
        // skipped if WE put them there from THESE bytes — the at-rest seal for a ref is not immutable
        // (a fresh nonce per seal, plus per-recipient key material that moves as rosters arrive), and
        // another device of this account may have uploaded the same ref from a seal of its own. Only
        // needed for the chunked path; a small blob is one whole PUT with nothing to resume.
        // Streamed and off the main actor: this is a hash of hundreds of MB.
        let sealFp: String = chunked
            ? await Task.detached(priority: .utility) { MediaUploadPlan.sealFingerprint(fileURL: sealedURL) ?? "" }.value
            : ""
        HavenLog.sync("backup ref=\(ref) size=\(sealedSize) chunked=\(chunked) dests=\(uploads.count + (s3Needs ? 1 : 0)) s3=\(s3Needs)")

        // 1) S3/HTTP bucket FIRST — the DEFAULT media transport. Plain HTTPS traverses any NAT,
        //    whereas the iroh blob ALPN (haven/blob/1) drops its outbound datagrams over a
        //    pure-relay cross-NAT path (noq/iroh fork bug), so blob transfers that must cross a NAT
        //    stall and die while messaging on the same relay path works.
        if s3Needs, let s3 {
            do {
                try await putMediaFile(ref: ref, dest: "s3", sealedURL: sealedURL, size: sealedSize,
                                       sealFp: sealFp, force: force,
                                       exists: { await s3.headObjectExists(key: $0) == true }) {
                    try await s3.putObject(key: $0, data: $1)
                }
                HavenLog.sync("backup s3-put OK ref=\(ref) size=\(sealedSize) chunked=\(chunked)")
                MediaBackupLedger.mark("s3", ref); landed = true
            }
            catch { HavenLog.sync("backup s3-put FAIL ref=\(ref): \(error.localizedDescription)") }
        }
        // 2) Mirror to every relay that probed reachable-and-missing (redundancy + the LAN/hosted
        //    fast-path). Content-addressed key → idempotent re-puts.
        for (node, route) in uploads {
            switch route {
            case .ownRelay:
                // Our OWN hosted relay: store directly in the local mailbox (no iroh self-dial).
                try? await putMediaFile(ref: ref, dest: node, sealedURL: sealedURL, size: sealedSize,
                                        sealFp: sealFp, force: force,
                                        exists: { RelayHost.shared.localHas($0) }) { _ = RelayHost.shared.localPut($0, $1) }
                MediaBackupLedger.mark(node, ref); landed = true
            case .http(let base, let token):
                do {
                    try await putMediaFile(
                        ref: ref, dest: node, sealedURL: sealedURL, size: sealedSize,
                        sealFp: sealFp, force: force,
                        exists: { k in
                            if case .success(let d) = await httpGet(base, token, k), let d, !d.isEmpty { return true }
                            return false
                        }) { k, d in
                        if case .failure(let e) = await httpPut(base, token, k, d) { throw e }
                    }
                    RelayMailboxStore.shared.markSeen(node)
                    HavenLog.sync("backup http-put OK ref=\(ref) relay=\(node.prefix(8))")
                    MediaBackupLedger.mark(node, ref); landed = true
                } catch is RelayForbidden {
                    // Reachable and healthy — it just doesn't know this device yet. Neither remedy below
                    // applies: backing the URL off strands the blob on a relay that would store it, and
                    // the blob dial goes through the SAME membership gate, so it only repeats the
                    // refusal. Record it and let the heal + retry in `backup` publish our roster first.
                    noteRefused(node, "media upload \(ref.prefix(10))")
                    HavenLog.sync("backup http-put REFUSED ref=\(ref) relay=\(node.prefix(8)) — not an outage; roster publish pending")
                } catch {
                    markHttpUrlBad(base)
                    HavenLog.sync("backup http-put FAIL ref=\(ref) relay=\(node.prefix(8)): \(error.localizedDescription) — trying blob dial")
                    // The HTTP interface died mid-upload — fall back to the iroh dial (same store).
                    guard let c = await RelayClients.client(node) else { continue }
                    do {
                        try await putMediaFile(ref: ref, dest: node, sealedURL: sealedURL, size: sealedSize,
                                               sealFp: sealFp, force: force,
                                               // `has` is an exact, cheap existence check here — no download.
                                               exists: { await c.has(key: $0) }) { try await c.put(key: $0, data: $1) }
                        RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                        HavenLog.sync("backup blob-dial OK ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize) — cross-NAT blob path WORKS")
                        MediaBackupLedger.mark(node, ref); landed = true
                    }
                    catch {
                        HavenLog.sync("backup blob-dial FAIL ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize): \(error.localizedDescription)")
                        RelayHealth.shared.recordFailure(node)   // backoff still applies; the CLIENT is kept — see below
                    }
                }
            case .dial(let c):
                do {
                    try await putMediaFile(ref: ref, dest: node, sealedURL: sealedURL, size: sealedSize,
                                           sealFp: sealFp, force: force,
                                           // `has` is an exact, cheap existence check here — no download.
                                           exists: { await c.has(key: $0) }) { try await c.put(key: $0, data: $1) }
                    RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                    HavenLog.sync("backup blob-dial OK ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize) — cross-NAT blob path WORKS")
                    MediaBackupLedger.mark(node, ref); landed = true
                }
                catch {
                    HavenLog.sync("backup blob-dial FAIL ref=\(ref) relay=\(node.prefix(8)) size=\(sealedSize): \(error.localizedDescription)")
                    RelayHealth.shared.recordFailure(node)   // backoff still applies; the CLIENT is kept — see below
                }
            }
        }
        if !landed { HavenLog.sync("backup NO-DEST ref=\(ref)"); MediaBackupBackoff.recordStalled(ref) }
        else { MediaBackupBackoff.recordLanded(ref) }
        // The ring's job is done the moment the ledger can answer; leaving the entry behind
        // would keep a finished upload showing as in-flight.
        if landed {
            MediaUploadProgress.shared.finish(ref)
            // Drop the seal ONLY on success. Deleting it on every exit (the old unconditional defer)
            // is what forced a fresh, byte-different seal on each retry. A failed attempt keeps it so
            // the next one resumes against identical bytes; the 24h staleness check above bounds it,
            // and the scratch sweep reclaims anything abandoned.
            try? FileManager.default.removeItem(at: sealedURL)
        }
        return landed
    }

    /// Publish this device's account-signed device roster to every known relay under
    /// `haven/devroster/<myAccountHex>`. A device connects to a relay AS its DEVICE id, but a HEADLESS
    /// relay only knows ACCOUNT ids (from the operator's link), so without this it `ERR forbidden`s
    /// every one of the account's devices' mailbox ops — "my own NAS relay rejects my phone". The wire
    /// (from `exportOwnRoster`) carries the account bundle + an account-SIGNED DeviceList, so the relay
    /// verifies it WITHOUT decrypting anything and then authorizes the account's device ids (see
    /// haven-net `verify_devroster`). The key is permission-free, so this write is allowed BEFORE
    /// authorization (it's the bootstrap). Idempotent + cheap; call on the sync timer so a restarted
    /// relay re-learns our devices promptly.
    /// Relays that already hold this exact roster, and when we confirmed it. A roster is ~30 KB (each
    /// device credential carries a hybrid PQ signature), and this ran on the sync tick against every
    /// relay — tens of KB every couple of minutes, per relay, forever, whether or not anything had
    /// changed. That is what was timing out (`relay put timed out` / ConnectionLost) and starving the
    /// rest of sync. Content is what matters, so key on the wire's hash: an unchanged roster is
    /// re-sent only after `ROSTER_REPUBLISH` as liveness, and any CHANGE republishes immediately.
    private static var rosterPublished: [String: (hash: Int, at: Date)] = [:]
    private static let rosterRepublish: TimeInterval = 1800   // 30 min

    static func publishDeviceRoster(social: HavenSocial, force: Bool = false) async {
        guard let r = social.exportOwnRoster().first else { HavenLog.sync("devroster SKIP — no own roster yet"); return }
        let key = "haven/devroster/\(r.accountHex)"
        let wire = r.wire
        let wireHash = wire.hashValue
        HavenLog.sync("devroster publish acct=\(r.accountHex.prefix(8)) size=\(wire.count) → \(RelayMailboxStore.shared.allRelays().count) relays")
        var skipped = 0
        for node in RelayMailboxStore.shared.allRelays() where !node.hasPrefix("s3:") {
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                _ = RelayHost.shared.localPut(key, wire); continue
            }
            // Already holds these exact bytes and confirmed recently → nothing to say.
            if !force, let seen = rosterPublished[node], seen.hash == wireHash,
               Date().timeIntervalSince(seen.at) < rosterRepublish {
                skipped += 1
                continue
            }
            // Plain-HTTP interface first (the cross-NAT path), else the iroh dial.
            if let http = RelayMailboxStore.shared.httpInterface(node) {
                var done = false
                for base in http.urls where !httpUrlBad(base) {
                    switch await httpPut(base, http.token, key, wire) {
                    case .success:
                        RelayMailboxStore.shared.markSeen(node)
                        rosterPublished[node] = (wireHash, Date())
                        HavenLog.sync("devroster http-put OK relay=\(node.prefix(8))")
                        done = true
                    case .failure(is RelayForbidden):
                        // The devroster key is permission-FREE, so a refusal here is the relay rejecting
                        // our SIGNATURE, not our membership — `noteRefused` would only schedule a heal
                        // that repeats this very publish. Still never back the URL off: this is the one
                        // write that authorizes all the others, and sealing it for two minutes is how a
                        // device stays unauthorized (and unable to upload) far longer than it needs to.
                        HavenLog.sync("devroster http-put REFUSED relay=\(node.prefix(8)) — signature rejected, trying dial")
                    case .failure:
                        markHttpUrlBad(base)
                    }
                    if done { break }
                }
                if done { continue }
            }
            guard let c = await RelayClients.client(node) else {
                HavenLog.sync("devroster SKIP relay=\(node.prefix(8)) — unreachable")
                continue
            }
            do {
                try await c.put(key: key, data: wire)
                RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                rosterPublished[node] = (wireHash, Date())
                HavenLog.sync("devroster blob-put OK relay=\(node.prefix(8)) — relay should now authorize our device")
            } catch {
                HavenLog.sync("devroster blob-put FAIL relay=\(node.prefix(8)): \(error.localizedDescription)")
                // Record it, like every OTHER failure path does. Without this a relay that never
                // answers accumulates no backoff from roster publishing, so the 120s backfill tick
                // re-attempts it forever — 9 of 22 failures in one 20-minute window came from here,
                // against a relay advertising a private address nobody outside its own LAN can reach.
                // `available()` is what gates the other paths, and it can only hold a relay off if
                // somebody tells it the relay is failing.
                RelayHealth.shared.recordFailure(node)
                await adoptNewerOwnRosterAndRetry(node: node, key: key, sent: wire, social: social, error: error)
            }
        }
        if skipped > 0 {
            HavenLog.sync("devroster: \(skipped) relay(s) already hold this exact roster — not re-sending \(wire.count) B each")
        }
    }

    /// Recover from a REFUSED publish of our own roster.
    ///
    /// `verify_devroster_put` applies a rollback defense: a validly-signed roster whose version is
    /// strictly older than the one already stored is refused. That is correct against replay, but it
    /// deadlocks a device that has simply fallen behind — say another of our devices published a newer
    /// version. The publish is the BOOTSTRAP that authorizes this device, so being refused means the
    /// device can never become authorized, and every later op (media PUT, media GET, frame-9 call
    /// forwarding) is forbidden too. Nothing else teaches us the newer roster: `fetchContactRoster`
    /// runs for CONTACTS, and self-sync doesn't cover a relay we can't yet write to.
    ///
    /// So adopt what we're being out-versioned by, then publish again at that version. Pulling our own
    /// roster is safe for the same reason the relay's check is: `ingestRosterWire` verifies the account
    /// signature, and only our account key could have produced it — a relay can serve it, never forge it.
    private static func adoptNewerOwnRosterAndRetry(node: String, key: String, sent: Data, social: HavenSocial, error: Error) async {
        guard error.localizedDescription.lowercased().contains("forbidden") else { return }
        guard let acct = social.exportOwnRoster().first?.accountHex else { return }
        HavenLog.sync("devroster refused by \(node.prefix(8)) — pulling the newer roster it holds and re-publishing")
        guard await fetchContactRoster(accountHex: acct, social: social) else {
            HavenLog.sync("devroster: could not read our own stored roster back from any relay — still unauthorized on \(node.prefix(8))")
            return
        }
        guard let fresh = social.exportOwnRoster().first, fresh.wire != sent else {
            HavenLog.sync("devroster: adopted roster is identical to the one refused — refusal is NOT a version rollback on \(node.prefix(8))")
            return
        }
        guard let c = await RelayClients.client(node) else { return }
        do {
            try await c.put(key: key, data: fresh.wire)
            RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
            HavenLog.sync("devroster blob-put OK relay=\(node.prefix(8)) after adopting its newer roster — this device is authorized again")
        } catch {
            HavenLog.sync("devroster STILL refused by \(node.prefix(8)) after adopting: \(error.localizedDescription)")
        }
    }

    /// PULL a CONTACT's device roster from the relays and ingest it — the missing half of
    /// `publishDeviceRoster`, which only ever pushed OUR OWN.
    ///
    /// The only other way to learn a contact's roster is frame 27, sent over a DIRECT iroh send on the
    /// periodic sweep. That never arrives when neither peer is directly reachable — two CGNAT networks,
    /// Starlink being the everyday case. Without their roster `accountForDevice` cannot map their
    /// signing device to their account, so every device-signed call frame they send us fails the
    /// declared-vs-signer check and is discarded as a forgery. That is precisely "the callee answers,
    /// the caller sits on Calling forever": their ACCEPT arrives and we throw it away. The relay has
    /// been holding their roster the whole time — nobody ever asked it for one.
    ///
    /// Safe against a hostile relay: `ingestRosterWire` verifies the ACCOUNT signature over the
    /// DeviceList itself and refuses anything that doesn't bind to the account named in the key, so a
    /// relay can serve these bytes but cannot forge or alter them.
    /// When each contact's roster was last ASKED for. A contact whose roster is on no relay never
    /// becomes resolvable, so without a backoff the caller retries them on every sync tick forever —
    /// every relay, every contact, HTTP timeouts overlapping — which is a dial storm, and iroh
    /// answers a dial storm with unbounded path-discovery churn. Ask rarely; the cost of being a few
    /// minutes late to a roster is nothing next to that.
    private static var rosterPullAt: [String: Date] = [:]
    private static let rosterPullBackoff: TimeInterval = 600   // 10 min

    static func rosterPullDue(_ accountHex: String) -> Bool {
        let k = accountHex.lowercased()
        guard let last = rosterPullAt[k] else { return true }
        return Date().timeIntervalSince(last) > rosterPullBackoff
    }
    static func noteRosterPullAttempt(_ accountHex: String) {
        rosterPullAt[accountHex.lowercased()] = Date()
        if rosterPullAt.count > 500 { rosterPullAt.removeAll() }
    }

    @discardableResult
    static func fetchContactRoster(accountHex: String, social: HavenSocial) async -> Bool {
        let acct = accountHex.lowercased()
        guard acct.count == 64 else { return false }
        let key = "haven/devroster/\(acct)"

        // Our own hosted store first — no dial, and a relay-hosting device usually already holds it.
        if RelayHost.shared.serving, let wire = RelayHost.shared.localGet(key), !wire.isEmpty,
           social.ingestRosterWire(wire: wire) {
            HavenLog.sync("devroster PULLED \(acct.prefix(8)) from own store — their devices are now resolvable")
            return true
        }
        for node in RelayMailboxStore.shared.allRelays() where !node.hasPrefix("s3:") {
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId { continue }
            if let http = RelayMailboxStore.shared.httpInterface(node) {
                for base in http.urls where !httpUrlBad(base) {
                    switch await httpGet(base, http.token, key) {
                    case .success(let wire):
                        if let wire, !wire.isEmpty, social.ingestRosterWire(wire: wire) {
                            RelayMailboxStore.shared.markSeen(node)
                            HavenLog.sync("devroster PULLED \(acct.prefix(8)) from relay \(node.prefix(8))")
                            return true
                        }
                    case .failure(is RelayForbidden):
                        noteRefused(node, "devroster read for \(acct.prefix(8))")
                    case .failure:
                        markHttpUrlBad(base)
                    }
                }
            }
            guard let c = await RelayClients.client(node) else { continue }
            if let wire = await c.get(key: key), !wire.isEmpty, social.ingestRosterWire(wire: wire) {
                RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node)
                HavenLog.sync("devroster PULLED \(acct.prefix(8)) from relay \(node.prefix(8)) (dial)")
                return true
            }
        }
        return false
    }

    /// The bucket used for MEDIA in this circle: the owner's own creds for a circle whose pre-signed
    /// pool we mint, else the shared/volunteer mailbox bucket. Same selection as `uploadEvent`.
    private static func mediaS3(for circleId: String) -> S3Client? {
        isOwner(circleId) ? ownerS3() : mailboxClient()
    }

    /// PUT one sealed media blob that lives in a FILE through a destination's key/value writer,
    /// STREAMING the file in 8 MB windows so the whole sealed blob is never resident on the managed
    /// heap (a large video's sealed envelope is hundreds of MB — holding it whole traps the allocator).
    /// Large → 8 MB chunk keys + a manifest; small → a single blob. Same wire format as `putMedia`.
    /// `exists` lets a destination say it already holds a chunk key, so an interrupted upload RESUMES
    /// instead of restarting.
    ///
    /// Without it, this loop re-sent every window from 0 on every attempt — and a phone only gets a
    /// foreground session plus ~30s of background time, while iOS suspends the app the moment the user
    /// leaves. So a 600 MB video (≈75 windows) would upload maybe 20 of them, get suspended, and start
    /// again at window 0 next time. It never converges: the blob is simply larger than what one
    /// uninterrupted session can push, and no amount of retrying fixes that when every retry throws away
    /// the progress. That is the difference between "slow" and "never", and it is why an upload could sit
    /// on the same indicator for hours.
    ///
    /// `exists` alone is NOT enough to make that safe, and this is the correctness half. "The
    /// destination holds window i" does not mean "window i was sliced from THESE bytes": sealing is not
    /// byte-stable, so a seal replaced part-way through an upload — or, routinely, ANOTHER DEVICE OF
    /// THIS ACCOUNT uploading the same ref from its own seal — leaves windows that all probe present
    /// and belong to a different envelope. Splicing them produces a blob of exactly the right length
    /// that decrypts to nothing. So `dest`/`sealFp` gate the probe: only the leading windows WE wrote
    /// to THIS destination from THESE bytes may be asked about at all. See `MediaUploadPlan`, and its
    /// Android (`MediaUploadPlan.kt`) and desktop (`mediaresume.rs`) twins.
    private static func putMediaFile(ref: String, dest: String, sealedURL: URL, size: Int,
                                     sealFp: String = "", force: Bool = false,
                                     exists: ((String) async -> Bool)? = nil,
                                     put: (String, Data) async throws -> Void) async throws {
        if size > mediaChunkBytes {
            guard let fh = try? FileHandle(forReadingFrom: sealedURL) else { throw URLError(.cannotOpenFile) }
            defer { try? fh.close() }
            let ranges = MediaUploadPlan.windows(size: size)
            // The upload already moves in 8 MB windows, so "how far along is this" was sitting here
            // unused while the UI could only say "pending" forever. Report it: a 600 MB video is 75
            // windows, and a post stuck at 3/75 is a visibly different thing from one at 74/75.
            await MainActor.run { MediaUploadProgress.shared.begin(ref, windows: max(1, ranges.count)) }
            // How many leading windows may be skipped: capped by our own high-water mark for this
            // destination under this exact fingerprint, then confirmed by the probe (a relay may have
            // swept the chunks since). Both must agree; with no record the probe is never consulted.
            let skip: Int
            if let exists, !sealFp.isEmpty {
                skip = await MediaUploadPlan.resumeSkip(
                    force: force, recorded: MediaUploadResume.progress(dest: dest, ref: ref),
                    currentFp: sealFp, total: ranges.count, probe: { await exists(chunkKey(ref, $0)) })
            } else {
                skip = 0
            }
            var sizes: [Int] = []
            for (i, range) in ranges.enumerated() {
                let length = range.1 - range.0
                if i < skip {
                    // Already on this destination, from these exact bytes — the manifest still has to be
                    // written at the end, but these bytes never need to cross the wire again. Not read
                    // from disk either: nothing here needs the slice.
                    sizes.append(length)
                } else {
                    try fh.seek(toOffset: UInt64(range.0))
                    guard let slice = (try? fh.read(upToCount: length)) ?? nil, slice.count == length else {
                        throw URLError(.cannotOpenFile)
                    }
                    try await put(chunkKey(ref, i), slice)
                    sizes.append(slice.count)
                }
                // Recorded AFTER the window is on the far side, never before: understating progress
                // costs a re-sent window, overstating it corrupts the blob.
                if !sealFp.isEmpty { MediaUploadResume.record(dest: dest, ref: ref, fp: sealFp, windows: i + 1) }
                await MainActor.run { MediaUploadProgress.shared.advance(ref, done: sizes.count) }
            }
            if skip > 0 {
                HavenLog.sync("backup ref=\(ref.prefix(12)): resumed on \(dest.prefix(8)), \(skip)/\(sizes.count) windows already stored from these bytes")
            }
            try await put(key(ref), makeManifest(sizes: sizes))
            // The manifest is what makes the blob readable, so its write is the moment the upload is
            // done. Nothing left to resume.
            MediaUploadResume.clear(dest: dest, ref: ref)
        } else {
            // Small (≤ one window): reading it whole is memory-safe.
            let whole = (try? Data(contentsOf: sealedURL)) ?? Data()
            try await put(key(ref), whole)
        }
    }

    /// A source that can serve the manifest+chunk keys for one media ref.
    private enum MediaSource {
        case ownRelay                              // our own hosted relay (local store)
        case relay(RelayClient, String)            // dialed relay client + node hex
        case s3(S3Client)                          // shared/owner bucket
        case http(String, String)                  // relay plain-HTTP interface (base url, token)
    }
    /// Fetch one key's bytes from a source (nil = miss).
    private static func fetch(_ src: MediaSource, _ key: String) async -> Data? {
        switch src {
        case .ownRelay: return RelayHost.shared.localGet(key)
        case .relay(let c, _): return await c.get(key: key)
        case .s3(let s3): return try? await s3.getObject(key: key)
        case .http(let base, let token): return (try? await httpGet(base, token, key).get()) ?? nil
        }
    }

    // MARK: - Relay plain-HTTP media interface (client side)
    //
    // GET/PUT against a relay's HTTP interface (core httprelay.rs): `<base>/k/<key>`. This is the
    // DEFAULT cross-NAT media transport; a URL that doesn't answer is backed off for 2 minutes so a
    // dead LAN address doesn't cost a connect-timeout per chunk.
    //
    // AUTHORIZATION: each request is SIGNED by this device's transport key, not gated on a shared
    // bearer token. The relay verifies the signature to learn WHO is asking and then runs the same
    // circle-membership check the iroh path runs (core httprelay.rs). The token from the sealed
    // frame-19 announce is still required — but it is now mixed into the signed transcript instead
    // of being sent, so it never crosses the wire.
    //
    // The seed MUST be the same one `HavenNode.start` binds the transport to (DeviceKeyStore's
    // per-device seed), or the relay sees a node id that is in no roster and answers 403.

    private static var httpUrlBadUntil: [String: Date] = [:]
    static func httpUrlBad(_ base: String) -> Bool { (httpUrlBadUntil[base] ?? .distantPast) > Date() }
    /// Skip a base URL briefly after transport failure. Free trycloudflare DNS flaps hard on some
    /// networks (system NXDOMAIN while DoH works) — a 120s skip made the iPhone UI thrash
    /// unreachable→reachable every couple of minutes and blocked mailbox poll for linked devices.
    private static func markHttpUrlBad(_ base: String) {
        let cool: TimeInterval = base.contains("trycloudflare.com") ? 25 : 60
        httpUrlBadUntil[base] = Date().addingTimeInterval(cool)
    }
    /// Clear a URL's skip so a recovered free tunnel is tried again immediately (e.g. after host reannounce).
    static func clearHttpUrlBad(_ base: String) { httpUrlBadUntil.removeValue(forKey: base) }
    static func clearAllHttpUrlBad() { httpUrlBadUntil.removeAll() }

    /// Relays that have refused us since our roster last reached them. A refusal is not a dead
    /// endpoint — it means the relay has never been told this DEVICE id belongs to our account, so
    /// `blob_forbidden` denies us before it ever considers the key. Publishing the account-signed
    /// roster is precisely the remedy, so record the refusal and let `healForbiddenRelays` fix the
    /// cause rather than backing off from a relay that is working perfectly.
    private static var rosterNeeded: Set<String> = []
    private static var lastHeal = Date.distantPast

    static func noteRefused(_ node: String, _ what: String) {
        rosterNeeded.insert(node)
        HavenLog.relay("relay \(node.prefix(8)) REFUSED \(what) — not an outage; our device id isn't authorized there yet")
    }

    /// Re-publish our device roster to every relay that refused us, so the next attempt is allowed.
    /// Returns true if anything was published (i.e. a retry is worth making). Rate-limited: a relay
    /// that refuses us for some OTHER reason must not turn every media miss into a publish storm.
    @discardableResult
    static func healForbiddenRelays(social: HavenSocial) async -> Bool {
        guard !rosterNeeded.isEmpty, Date().timeIntervalSince(lastHeal) > 30 else { return false }
        let nodes = rosterNeeded.map { $0.prefix(8) }.joined(separator: ",")
        HavenLog.relay("re-publishing device roster after refusal from [\(nodes)]")
        lastHeal = Date()
        rosterNeeded.removeAll()
        // force: a refusal means the relay does NOT have a usable roster from us, so the
        // "already holds these bytes" skip must not suppress the very publish that fixes it.
        await publishDeviceRoster(social: social, force: true)
        return true
    }

    private static func httpKeyURL(_ base: String, _ key: String) -> URL? {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let enc = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        return URL(string: "\(trimmed)/k/\(enc)")
    }

    /// LIST: `GET /l/<prefix>` — signed over the raw store prefix (not the `/l/` route).
    private static func httpListURL(_ base: String, _ prefix: String) -> URL? {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let enc = prefix.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? prefix
        return URL(string: "\(trimmed)/l/\(enc)")
    }

    /// LIST keys under a prefix via the relay's plain-HTTP interface. Three-way like `httpGet`.
    private static func httpList(_ base: String, _ token: String, _ prefix: String) async -> Result<[String], Error> {
        switch await httpListDelta(base, token, prefix, digest: nil) {
        case .success(let r): return .success(r.keys ?? [])
        case .failure(let e): return .failure(e)
        }
    }

    /// Delta-LIST (the radio saver): echo the last-seen `X-Haven-List-Digest` for this prefix and
    /// an UNCHANGED key set comes back as a bodiless 204 (`keys == nil`) instead of the same list
    /// again. A 200 carries the fresh keys plus the digest to echo next time. A relay that doesn't
    /// speak the header simply never answers 204 and never hands us a digest — today's behavior.
    private static func httpListDelta(_ base: String, _ token: String, _ prefix: String,
                                      digest: String?) async -> Result<(keys: [String]?, digest: String?), Error> {
        guard let url = httpListURL(base, prefix) else { return .failure(URLError(.badURL)) }
        guard let auth = httpAuth(token, "GET", prefix, Data()) else { return .failure(URLError(.userAuthenticationRequired)) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        if let digest, !digest.isEmpty { req.setValue(digest, forHTTPHeaderField: "X-Haven-List-Digest") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let respDigest = http?.value(forHTTPHeaderField: "X-Haven-List-Digest")
            switch http?.statusCode ?? 0 {
            case 204:
                return .success((keys: nil, digest: respDigest))   // nothing new — skip the GETs
            case 200...299:
                let text = String(data: data, encoding: .utf8) ?? ""
                let keys = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                return .success((keys: keys, digest: respDigest))
            case 401, 403: return .failure(RelayForbidden())
            default: return .failure(URLError(.badServerResponse))
            }
        } catch { return .failure(error) }
    }

    /// Last-seen LIST digest per (relay, circle prefix). Only committed once a listing's GET batch
    /// finished WITHOUT deferrals/failures — otherwise a 204 on the next poll would skip keys we
    /// listed but never fetched (the seen-set semantics stay exactly as they were).
    private static var mailboxListDigests: [String: String] = [:]

    /// Sign ONE request. Never cache the result: it carries a timestamp, a one-shot nonce and a
    /// digest of THIS body, so a reused header is a replay and the relay refuses it.
    /// `key` is the raw (un-percent-encoded) store key — the relay decodes the path before verifying.
    private static func httpAuth(_ token: String, _ method: String, _ key: String, _ body: Data) -> String? {
        try? httpAuthHeader(seed: DeviceKeyStore.deviceAccount().secretSeed(),
                            token: token, method: method, key: key, body: body)
    }

    /// GET one key. `.success(nil)` = relay reached but doesn't hold it (a real MISS — the iroh
    /// path serves the same store, so don't dial it for the same key); `.failure` = unreachable.
    /// The relay REFUSED us — it is reachable and healthy, we are simply not (yet) a member it
    /// recognises. Distinct from a transport failure because the remedies are opposite: a broken
    /// endpoint should be backed off, whereas a refusal should trigger a device-roster publish and a
    /// retry. Folding the two together is what made a permissions problem present as missing media:
    /// the 403 became `.failure` → `markHttpUrlBad` → the relay was skipped → "NOT FOUND on any
    /// relay/S3", for a blob sitting on that relay's disk the whole time.
    struct RelayForbidden: Error {}

    private static func httpGet(_ base: String, _ token: String, _ key: String) async -> Result<Data?, Error> {
        guard let url = httpKeyURL(base, key) else { return .failure(URLError(.badURL)) }
        guard let auth = httpAuth(token, "GET", key, Data()) else { return .failure(URLError(.userAuthenticationRequired)) }
        // 20s not 60s: a dead NAS / expired trycloudflare was burning a full minute *before*
        // the live Mac Cloudflare front door was tried, so media looked permanently stuck.
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200...299: return .success(data)
            case 404: return .success(nil)
            case 401, 403: return .failure(RelayForbidden())
            default: return .failure(URLError(.badServerResponse))
            }
        } catch { return .failure(error) }
    }

    /// PUT one key. `.success` = stored; `.failure(RelayForbidden)` = the relay is up and would take
    /// this write the moment it knows our device; any other `.failure` = unreachable. The same
    /// three-way split `httpGet` needs, for the mirror-image reason: a device that has never been
    /// authorized cannot upload at all, and a 403 read as an outage backs off the very relay the write
    /// needs — so the blob never lands, and the damage surfaces much later as a fetch that genuinely
    /// 404s. A real absence, manufactured by a permissions problem.
    private static func httpPut(_ base: String, _ token: String, _ key: String, _ body: Data) async -> Result<Void, Error> {
        guard let url = httpKeyURL(base, key) else { return .failure(URLError(.badURL)) }
        // Digest over the EXACT bytes that go on the wire — `upload(for:from:)` sends `body` verbatim.
        guard let auth = httpAuth(token, "PUT", key, body) else { return .failure(URLError(.userAuthenticationRequired)) }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "PUT"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200...299: return .success(())
            case 401, 403: return .failure(RelayForbidden())
            default: return .failure(URLError(.badServerResponse))
            }
        } catch { return .failure(error) }
    }

    // MARK: - Self-sync slot transport (the relay-HTTP rung of SelfSyncCoordinator's ladder)
    //
    // Self-sync used to be iroh-only, which made it a dead lane for exactly the relays that carry
    // everything else (in-app stub / free-CF / cold DERP: HTTP answers while the dial can't) — the
    // "linked devices each receive different things" complaint. These wrappers give the coordinator
    // the same own-relay → signed-HTTP → iroh ladder as uploadEvent, without leaking base URLs or
    // tokens out of this file. Keys are the canonical `haven/self/…` slots; the relay serves them
    // to the account's own fleet only (owner-or-roster-device gate, core blobstore).

    /// Outcome of one self-sync HTTP fetch. `hit`/`miss` both mean the relay was REACHED — it
    /// serves the same store as its iroh path, so the caller must NOT redial for the same key.
    enum RelayHttpFetch { case hit(Data); case miss; case unavailable }

    /// LIST a self-sync prefix over a relay's HTTP interface. nil = no usable interface or every
    /// URL failed/refused → the caller falls through to iroh. A refusal is roster lag, not an
    /// outage: note it so `healForbiddenRelays` republishes the devroster that authorizes us.
    static func selfSyncHttpList(_ node: String, prefix: String) async -> [String]? {
        guard let http = RelayMailboxStore.shared.httpInterface(node) else { return nil }
        for base in http.urls where !httpUrlBad(base) {
            switch await httpList(base, http.token, prefix) {
            case .success(let keys):
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
                return keys
            case .failure(is RelayForbidden):
                noteRefused(node, "selfsync list")
                RelayHealth.shared.recordSuccess(node)   // reachable enough to refuse
                return nil
            case .failure:
                markHttpUrlBad(base)
            }
        }
        return nil
    }

    /// GET one self-sync slot over a relay's HTTP interface (three-way, see `RelayHttpFetch`).
    static func selfSyncHttpGet(_ node: String, key: String) async -> RelayHttpFetch {
        guard let http = RelayMailboxStore.shared.httpInterface(node) else { return .unavailable }
        for base in http.urls where !httpUrlBad(base) {
            switch await httpGet(base, http.token, key) {
            case .success(let data):
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
                if let data, !data.isEmpty { return .hit(data) }
                return .miss
            case .failure(is RelayForbidden):
                noteRefused(node, "selfsync get")
                RelayHealth.shared.recordSuccess(node)
                return .unavailable
            case .failure:
                markHttpUrlBad(base)
            }
        }
        return .unavailable
    }

    /// PUT one self-sync slot over a relay's HTTP interface. false = didn't land here (no
    /// interface, unreachable, or refused pending roster) → the caller may still try iroh.
    static func selfSyncHttpPut(_ node: String, key: String, data: Data) async -> Bool {
        guard let http = RelayMailboxStore.shared.httpInterface(node) else { return false }
        for base in http.urls where !httpUrlBad(base) {
            switch await httpPut(base, http.token, key, data) {
            case .success:
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
                return true
            case .failure(is RelayForbidden):
                noteRefused(node, "selfsync put")
                RelayHealth.shared.recordSuccess(node)
                return false
            case .failure:
                markHttpUrlBad(base)
            }
        }
        return false
    }

    /// Fetch a media blob from the circle's mailbox and open it for whichever circle it belongs to.
    /// If the mailbox holds a chunked manifest (large media), reassemble the sealed bytes by streaming
    /// each 8 MB chunk to a temp file on disk — the full sealed blob is NEVER held in RAM during transfer.
    static func restore(ref: String, circleIds: [String], social: HavenSocial) async -> Data? {
        var chosen: MediaSource?
        var head: Data?
        var src = "none"
        // We fetch the manifest key "haven/media/<ref>" first; whichever source serves it also serves
        // the chunks. Source order: (1) our OWN hosted relay's local store (instant, no dial),
        // (2) each relay's plain-HTTP interface — the DEFAULT cross-NAT media transport,
        // (3) the S3 bucket (only present when the user configured one — rare),
        // (4) dialed iroh relays — the opportunistic fast-path (the blob ALPN stalls ~30s and dies
        // when the dial must cross a NAT over pure relay, so it's tried LAST, not first).
        if RelayHost.shared.serving,
           circleIds.contains(where: { relayNodes($0).contains(RelayHost.shared.nodeId) }),
           let s = RelayHost.shared.localGet(key(ref)) {
            head = s; chosen = .ownRelay; src = "own:\(RelayHost.shared.nodeId.prefix(8))"
        }
        // Relays whose HTTP interface answered 404: the iroh path serves the same store — skip dialing.
        var httpMissed = Set<String>()
        if head == nil {
            httpOuter: for cid in circleIds {
                for node in mediaDests(cid) {
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId { continue }
                    guard let http = RelayMailboxStore.shared.httpInterface(node) else { continue }
                    var anyBase = false
                    var nodeFailedAll = true
                    for base in http.urls where !httpUrlBad(base) {
                        anyBase = true
                        switch await httpGet(base, http.token, key(ref)) {
                        case .success(let s):
                            nodeFailedAll = false
                            // Reachable over HTTP = proof-of-life (green in Storage).
                            RelayHealth.shared.recordSuccess(node)
                            if let s {
                                RelayMailboxStore.shared.markSeen(node)
                                head = s; chosen = .http(base, http.token); src = "http:\(node.prefix(8))"
                                break httpOuter
                            }
                            httpMissed.insert(node)   // reachable, doesn't hold it
                        case .failure(is RelayForbidden):
                            nodeFailedAll = false
                            // NOT a miss: never add to `httpMissed`, or the iroh fallback below is
                            // skipped too and a refusal is laundered into "nobody has it".
                            noteRefused(node, "media fetch \(ref.prefix(10))")
                            continue
                        case .failure:
                            markHttpUrlBad(base)
                            continue
                        }
                        break   // reached the relay (miss) → don't try its other URLs
                    }
                    // Dead front door (stale trycloudflare / offline NAS): backoff so we stop
                    // burning 60s timeouts before the live Mac tunnel on every restore.
                    if anyBase && nodeFailedAll {
                        RelayHealth.shared.recordFailure(node)
                    }
                }
            }
        }
        if head == nil, let s3 = circleIds.compactMap({ mediaS3(for: $0) }).first {
            if let s = try? await s3.getObject(key: key(ref)) { head = s; chosen = .s3(s3); src = "s3" }
        }
        if head == nil {
            outer: for cid in circleIds {
                for node in mediaDests(cid) {
                    // Our own hosted relay was already consulted above; never dial ourselves.
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId { continue }
                    if httpMissed.contains(node) { continue }   // same store already said MISS over HTTP
                    guard let c = await RelayClients.client(node) else { continue }
                    if let s = await c.get(key: key(ref)) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); head = s; chosen = .relay(c, node); src = "dial:\(node.prefix(8))"; break outer }
                }
            }
        }
        guard let head, let source = chosen else {
            // Say which it was. "NOT FOUND" for what was actually a refusal is what made a
            // membership problem look like data loss for days — the blob was on the relay the
            // whole time, and the device simply wasn't allowed to ask for it.
            if rosterNeeded.isEmpty {
                HavenLog.relay("media restore \(ref.prefix(12)): NOT FOUND on any relay/S3")
                // Honest placeholder state: the relays answered and none holds it — we are now
                // waiting on the SENDER to put it (back) up, which is a different thing from
                // "downloading" or "gone forever".
                FeedStore.shared.noteMediaMissingOnRelays(ref)
                // A full miss is ALSO the signature of a relay whose HTTP front door we can't use
                // (rotated tunnel / never learned): the blob may sit on a relay we only failed to
                // ASK properly. Try to fetch each dest relay's self-published interface over iroh —
                // if one lands, the retry path finds the blob and the URL gets re-announced.
                for cid in circleIds {
                    for node in mediaDests(cid) where !(RelayHost.shared.serving && node == RelayHost.shared.nodeId) {
                        FeedStore.shared.refreshRelayInterfaceIfNeeded(node)
                    }
                }
            } else {
                HavenLog.relay("media restore \(ref.prefix(12)): REFUSED by \(rosterNeeded.count) relay(s) — not missing; re-publishing our roster so the retry is allowed")
            }
            return nil
        }

        // Reassemble the SEALED bytes. If `head` is a manifest, stream each chunk to a PERSISTENT
        // .part file on disk (bounded RAM: one 8 MB chunk at a time); otherwise `head` IS the
        // sealed blob (legacy/small). RESUMABLE: chunks append in order and the sidecar records how
        // many landed, so a retry after a mid-download failure fetches only the missing chunks
        // (mirror of the frame-33 peer resume) instead of restarting a multi-hundred-MB pull.
        let sealed: Data?
        if let chunkCount = parseManifest(head) {
            sweepRestorePartsOnce()
            let temp = restorePartURL(ref)
            var have = loadRestorePart(ref, chunks: chunkCount)
            if have == 0 {
                // No (valid) partial — start fresh.
                try? FileManager.default.removeItem(at: temp)
                FileManager.default.createFile(atPath: temp.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: temp) else {
                clearRestorePart(ref)
                HavenLog.relay("media restore \(ref.prefix(12)): temp-open FAIL"); return nil
            }
            var ok = true
            do { try handle.seekToEnd() } catch { ok = false }
            if have > 0 {
                HavenLog.relay("media restore \(ref.prefix(12)): resuming at chunk \(have)/\(chunkCount)")
            }
            if ok {
                for i in have..<chunkCount {
                    guard let part = await fetch(source, chunkKey(ref, i)) else { ok = false; break }
                    do { try handle.write(contentsOf: part) } catch { ok = false; break }
                    have = i + 1
                    saveRestorePart(ref, chunks: chunkCount, got: have)
                    // Honest progress for the placeholder: i/n while a chunked blob reassembles.
                    FeedStore.shared.noteRestoreProgress(ref, done: have, total: chunkCount)
                }
            }
            try? handle.close()
            FeedStore.shared.clearRestoreProgress(ref)
            guard ok else {
                // KEEP the partial + sidecar — the next attempt resumes from `have`.
                HavenLog.relay("media restore \(ref.prefix(12)): chunked reassemble STALLED at \(have)/\(chunkCount) via \(src) — partial kept for resume")
                return nil
            }
            sealed = try? Data(contentsOf: temp)   // read the reassembled sealed blob to open it
            clearRestorePart(ref)
        } else {
            sealed = head
        }
        guard let blob = sealed else {
            HavenLog.relay("media restore \(ref.prefix(12)): reassembled read FAIL via \(src)"); return nil
        }
        for cid in circleIds {
            if let data = social.openCircleMedia(circleId: cid, sealed: blob) {
                HavenLog.relay("media restore \(ref.prefix(12)): OK via \(src), \(data.count)B")
                return data
            }
        }
        HavenLog.relay("media restore \(ref.prefix(12)): found via \(src) (\(blob.count)B) but OPEN FAILED for all \(circleIds.count) circles")
        // Present-but-undecryptable: remember it for this session so the missing-media sweeps stop
        // re-downloading the same bad blob every cycle (Android/desktop parity — unopenableMedia).
        FeedStore.shared.noteUnopenableMedia(ref)
        // The bytes are THERE and cannot be decrypted — the stored copy is bad, not missing. Until now
        // that was a permanent dead end: every cycle re-fetched the same unopenable blob, failed
        // identically, and nothing ever replaced it.
        //
        // The most likely way a blob gets into this state is a resumed chunked upload that stitched
        // windows from two DIFFERENT seals: sealing is not byte-stable (per-recipient key material
        // plus a fresh nonce), so the result reassembles to exactly the right length and decrypts to
        // nothing. That is fixed at the source now — a seal is reused across retries — but blobs
        // written during the window are still out there, and one is already in the field.
        //
        // If we hold the plaintext we can repair it: a FORCED backup re-seals and overwrites the
        // stored copy. If we don't, there is nothing to do here but say so — the author's device is
        // the only one that can fix it.
        if MediaStore.shared.hasLocalFile(ref), let cid = circleIds.first {
            HavenLog.relay("media restore \(ref.prefix(12)): we hold the plaintext — re-sealing and overwriting the bad copy")
            Task { @MainActor in _ = await SharedStore.backup(ref: ref, circleId: cid, social: social, force: true) }
        }
        return nil
    }

    // MARK: - Shared mailbox (store-and-forward for ALL events)
    //
    // A sealed event envelope is already encrypted to the whole circle, so we store the
    // envelope itself in the bucket under mailbox/<circle>/<hash>. The sender uploads
    // when they're online; any member polls + downloads when *they're* online — the two
    // never need to overlap. The bucket only ever holds opaque, circle-sealed blobs.

    // Mailbox keys already ingested or confirmed uploaded — PERSISTED. This was in-memory only,
    // so every cold start treated the whole mailbox as new and re-downloaded + re-verified every
    // envelope (observed: ~6700 keys for an 88-event circle → the 30-second cold start on the
    // circle feed, all burned on crypto for duplicates the engine then dropped). Guarded by a lock
    // (poll/upload run on detached tasks); writes are debounced to one file save per burst.
    nonisolated private static let seenLock = NSLock()
    nonisolated(unsafe) private static var seenLoaded = false
    nonisolated(unsafe) private static var seenMailbox = Set<String>()
    nonisolated(unsafe) private static var seenSavePending = false
    nonisolated private static var seenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-mailbox-seen.txt")
    }
    nonisolated private static func withSeen<T>(_ body: (inout Set<String>) -> T) -> T {
        seenLock.lock(); defer { seenLock.unlock() }
        if !seenLoaded {
            seenLoaded = true
            if let text = try? String(contentsOf: seenURL, encoding: .utf8) {
                seenMailbox = Set(text.split(separator: "\n").map(String.init))
            }
        }
        return body(&seenMailbox)
    }
    nonisolated private static func seenContains(_ key: String) -> Bool { withSeen { $0.contains(key) } }
    /// Record a key as seen and schedule a debounced save (one write per burst, off the caller).
    /// Public so FeedStore can mark HELLO/event keys after successful ingest only.
    nonisolated static func markSeenPublic(_ key: String) { markSeen(key) }

    /// Drop seen-cursor entries under a mailbox circle prefix so a later poll re-GETs them.
    /// Used when a newly-opened key commit must re-drain epoch events that were marked seen while
    /// unopenable (linked-host recovery: Mac had the blobs on disk but never the peer epoch key).
    nonisolated static func forgetSeenPrefix(_ prefix: String) {
        let removed: Int = withSeen { set in
            let before = set.count
            set = set.filter { !$0.hasPrefix(prefix) || $0.contains("/__live__/") }
            return before - set.count
        }
        if removed > 0 {
            HavenLog.relay("mailbox seen: forgot \(removed) keys under \(prefix.prefix(48))")
            scheduleSeenSave()
        }
    }

    /// One-shot recovery for linked Mac hosts: DM mailbox keys that were marked seen while the
    /// device still lacked peer epoch keys (or under older mark-at-fetch races) stay forever
    /// skipped — iPhone (primary / push path) shows mom's activity; Mac store holds the blobs
    /// but the feed never re-opens them. Forget DM content seen-cursors once so control plane
    /// (key commits) and events re-drain under the durable pending buffer. Idempotent via defaults.
    @MainActor static func repairLinkedHostMailboxSeenOnce() {
        let flag = "haven.repair.linkedHostMailbox.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let removed: Int = withSeen { set in
            let before = set.count
            set = set.filter { key in
                // Keep non-DM and live-call frames; drop DM content + hellos so commits re-apply.
                if !key.contains("/dm:") && !key.contains("/dm%3A") { return true }
                if key.contains("/__live__/") { return true }
                return false
            }
            return before - set.count
        }
        if removed > 0 {
            HavenLog.relay("mailbox seen: linked-host repair forgot \(removed) DM keys")
            scheduleSeenSave()
            mailboxListDigests.removeAll()   // re-list in full so the re-queued keys re-GET
        }
    }

    /// One-shot recovery for the hello lane. Earlier builds marked EVERY `__hello__` key seen —
    /// including slots addressed to OTHER ids (other members, sibling devices, stale device ids)
    /// — which (a) consumed circle invites that a correct claim filter would have delivered, and
    /// (b) the sender-side global mark suppressed putHello re-offers to later-adopted relays.
    /// Forget all hello seen-cursors once: the claim filter (pollMailbox/pullMailbox) and the
    /// per-(relay,key) putHello marks now do the right thing, and re-ingesting an already-applied
    /// hello is idempotent (handleHello upserts + reply cooldown). Idempotent via defaults.
    ///
    /// v2: builds through 1.1.4 also marked hellos seen at CLAIM time even when handleHello HELD
    /// them (connection-approval gate, verification hold) — the circle grant riding the hello was
    /// consumed without ever applying (hosting-Mac / E2E-stub "invite never lands" symptom). Now
    /// that pullMailbox marks only CONSUMED hellos, sweep the polluted marks once more so grants
    /// still sitting in a mailbox (own store or a friend's relay) get re-offered and re-judged.
    @MainActor static func repairHelloSeenOnce() {
        let flag = "haven.repair.helloSeen.v2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let removed: Int = withSeen { set in
            let before = set.count
            set = set.filter { !$0.contains("/__hello__/") }
            return before - set.count
        }
        if removed > 0 {
            HavenLog.relay("mailbox seen: hello repair forgot \(removed) keys")
            scheduleSeenSave()
            mailboxListDigests.removeAll()   // re-list in full so re-claimable hellos re-GET
        }
    }

    nonisolated private static func scheduleSeenSave() {
        let schedule: Bool = withSeen { _ in
            guard !seenSavePending else { return false }
            seenSavePending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            let snapshot: String = withSeen { set in
                seenSavePending = false
                return set.joined(separator: "\n")
            }
            try? snapshot.write(to: seenURL, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func markSeen(_ key: String) {
        let inserted: Bool = withSeen { set in set.insert(key).inserted }
        if inserted { scheduleSeenSave() }
    }

    // Per-circle drain state from the latest mailbox poll. The re-open-after-key-commit seen-wipe
    // consults this: wiping a circle's seen-set while thousands of keys are STILL draining resets
    // the drain to zero — at 200 keys per poll an 8.5k mailbox needs ~30 minutes, so any wipe
    // cadence shorter than the drain keeps the backlog permanently full (the "deferred never
    // shrinks" treadmill). The gate is a POSITIVE fully-drained proof (a real listing with nothing
    // new and nothing deferred) rather than "no backlog recorded": a transient empty LIST (relay
    // store handle flip logs "0 keys, 0 new") records zero and would otherwise unlock the wipe
    // mid-drain — exactly the min9 relapse in the 352 direct-run.
    nonisolated(unsafe) private static var drainByCircle: [String: (keys: Int, fresh: Int, deferred: Int)] = [:]
    private static let backlogLock = NSLock()
    nonisolated private static func noteBacklog(_ cid: String, keys: Int, fresh: Int, deferred: Int) {
        backlogLock.lock()
        drainByCircle[cid] = (keys, fresh, deferred)
        backlogLock.unlock()
    }
    /// True only when the latest poll proves the circle's mailbox is fully drained.
    nonisolated static func readyForReopen(_ cid: String) -> Bool {
        backlogLock.lock()
        defer { backlogLock.unlock() }
        guard let d = drainByCircle[cid] else { return false }
        return d.keys > 0 && d.fresh == 0 && d.deferred == 0
    }

    /// Any circle still owing deferred keys? While true, the poll scheduler holds its tight base
    /// cadence instead of the idle stretch — an idle Mac otherwise drains 200 keys every ~5–9 min
    /// and an 8k backlog takes hours.
    nonisolated static func anyOutstandingBacklog() -> Bool {
        backlogLock.lock()
        defer { backlogLock.unlock() }
        return drainByCircle.contains { $0.value.deferred > 0 }
    }

    /// Wipe the persisted seen-set — identity reset/adoption must not inherit the old identity's
    /// ingestion cursor (its keys are meaningless to the new engine state).
    static func resetSeenMailbox() {
        withSeen { $0.removeAll() }
        try? FileManager.default.removeItem(at: seenURL)
        mailboxListDigests.removeAll()   // a fresh cursor must re-list everything
    }

    /// Force the seen-set to disk NOW (called on background/terminate). The normal save is debounced
    /// 2s and one-shot per burst — an app killed during the initial sync burst (common on iOS) never
    /// wrote it, so the next launch treated the WHOLE mailbox as new and re-downloaded + re-verified
    /// every envelope (the "redownloads old posts on every launch" heat report). A synchronous flush
    /// on the way to the background closes that window.
    static func flushSeenMailbox() {
        let snapshot: String? = withSeen { set in
            guard seenLoaded, !set.isEmpty else { return nil }
            seenSavePending = false
            return set.joined(separator: "\n")
        }
        if let snapshot { try? snapshot.write(to: seenURL, atomically: true, encoding: .utf8) }
    }

    private static func mailboxKey(_ circleId: String, _ env: Data) -> String {
        let h = SHA256.hash(data: env).map { String(format: "%02x", $0) }.joined()
        return "haven/mailbox/\(circleId)/\(h)"
    }

    /// The deterministic mailbox key an envelope will be uploaded under — PUBLIC so the author can
    /// seal it into the push banner (`mk`): the recipient's NSE then GETs exactly this key the
    /// moment the banner lands (push-before-content), no LIST, no sweep.
    static func mailboxKeyHint(circleId: String, env: Data) -> String {
        mailboxKey(circleId, env)
    }

    /// Content-addressed live-call frame key under an existing circle mailbox
    /// (`blob_forbidden` already allows mailbox/* for known members — no new allow-list).
    private static func liveCallKey(circleId: String, destHex: String, frame: Data) -> String {
        let h = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
        return "haven/mailbox/\(circleId)/__live__/\(destHex.lowercased())/\(h)"
    }

    /// PUT sealed call wire frames (`[type][payload]`) for each destination under circle mailboxes.
    /// HTTP-mailbox-only topology fallback when iroh dial is unreachable (matrix stub / free CF).
    static func uploadLiveCallFrames(circleIds: [String], dests: [String], frame: Data) async {
        let clean = dests.map { $0.lowercased() }.filter { $0.count == 64 }
        guard !clean.isEmpty, !frame.isEmpty else { return }
        let cids = circleIds.isEmpty ? ["default"] : circleIds
        for circleId in cids {
            for dest in clean {
                let key = liveCallKey(circleId: circleId, destHex: dest, frame: frame)
                // Do NOT markSeen on put — the destination must still list+ingest this key.
                var landed = false
                for node in relayNodes(circleId) {
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                        _ = RelayHost.shared.localPut(key, frame)
                        landed = true
                        continue
                    }
                    guard let http = RelayMailboxStore.shared.httpInterface(node) else { continue }
                    for base in http.urls where !httpUrlBad(base) {
                        switch await httpPut(base, http.token, key, frame) {
                        case .success:
                            RelayMailboxStore.shared.markSeen(node)
                            HavenLog.relay("live-call http-put OK to=\(dest.prefix(8)) relay=\(node.prefix(8))")
                            landed = true
                        case .failure(is RelayForbidden):
                            noteRefused(node, "live-call put")
                        case .failure:
                            markHttpUrlBad(base)
                        }
                        if landed { break }
                    }
                    if landed { break }
                }
            }
        }
    }

    /// LIST+GET live-call frames addressed to any of `myHexes` (device + account).
    /// Claims each key (markSeen) before return so concurrent 2s polls cannot double-dispatch.
    static func pollLiveCallFrames(circleIds: [String], myHexes: [String]) async -> [(key: String, frame: Data)] {
        let mine = myHexes.map { $0.lowercased() }.filter { $0.count == 64 }
        guard !mine.isEmpty else { return [] }
        let cids = circleIds.isEmpty ? ["default"] : circleIds
        var out: [(String, Data)] = []
        for circleId in cids {
            for node in relayNodes(circleId) {
                guard let http = RelayMailboxStore.shared.httpInterface(node) else {
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                        for who in mine {
                            let prefix = "haven/mailbox/\(circleId)/__live__/\(who)/"
                            for key in RelayHost.shared.localList(prefix) where !seenContains(key) {
                                markSeen(key)
                                if let d = RelayHost.shared.localGet(key), !d.isEmpty {
                                    out.append((key, d))
                                }
                            }
                        }
                    }
                    continue
                }
                for who in mine {
                    let prefix = "haven/mailbox/\(circleId)/__live__/\(who)/"
                    for base in http.urls where !httpUrlBad(base) {
                        switch await httpList(base, http.token, prefix) {
                        case .success(let keys):
                            RelayMailboxStore.shared.markSeen(node)
                            for key in keys where !seenContains(key) {
                                markSeen(key)   // claim before GET so concurrent pollers skip
                                switch await httpGet(base, http.token, key) {
                                case .success(let data?):
                                    if !data.isEmpty { out.append((key, data)) }
                                case .success(nil), .failure:
                                    break
                                }
                            }
                        case .failure(is RelayForbidden):
                            noteRefused(node, "live-call list")
                        case .failure:
                            markHttpUrlBad(base)
                        }
                        break
                    }
                }
            }
        }
        return out
    }

    /// Publish a sealed frame-19 relay announce into the circle mailbox so friends who miss live
    /// iroh still learn the relay over HTTP LIST/GET. Content-addressed (payload hash) so a rotated
    /// free-CF URL is a new key rather than stuck behind a seen cursor.
    static func putRelayAnnounce(circleId: String, nodeHex: String, payload: Data) async {
        guard !circleId.isEmpty, nodeHex.count == 64, !payload.isEmpty else { return }
        let h = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let key = "haven/mailbox/\(circleId)/__relay__/\(nodeHex.lowercased())/\(h)"
        if seenContains(key) { return }   // this exact announce already landed
        var landed = false
        for node in relayNodes(circleId) {
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                _ = RelayHost.shared.localPut(key, payload)
                landed = true
                continue
            }
            if let http = RelayMailboxStore.shared.httpInterface(node) {
                for base in http.urls where !httpUrlBad(base) {
                    switch await httpPut(base, http.token, key, payload) {
                    case .success:
                        RelayHealth.shared.recordSuccess(node)
                        RelayMailboxStore.shared.markSeen(node)
                        landed = true
                    case .failure(is RelayForbidden):
                        noteRefused(node, "relay announce put")
                        RelayHealth.shared.recordSuccess(node)
                    case .failure:
                        markHttpUrlBad(base)
                    }
                    if landed { break }
                }
            }
            if landed { break }
            guard let c = await RelayClients.client(node) else { continue }
            do {
                try await c.put(key: key, data: payload)
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
                landed = true
            } catch {
                RelayHealth.shared.recordFailure(node)
            }
            if landed { break }
        }
        if landed {
            markSeen(key)
            HavenLog.relay("relay announce mailbox put circle=\(circleId.prefix(12)) node=\(nodeHex.prefix(8))")
        }
    }

    /// Drop a sealed event envelope into the circle's mailbox (idempotent). Returns whether it
    /// is now safely in the mailbox (already present or just uploaded) — the background uploader
    /// uses this to know when to stop retrying. We only mark a key "seen" on success, so a
    /// failed upload is retried rather than silently dropped.
    @discardableResult
    static func uploadEvent(circleId: String, env: Data) async -> Bool {
        let key = mailboxKey(circleId, env)
        if seenContains(key) { return true }
        // Relay (common path) → owner's own bucket → member's pre-signed pool → legacy creds.
        let nodes = relayNodes(circleId)
        if nodes.isEmpty {
            HavenLog.net("uploadEvent: no relays for circle=\(circleId.prefix(20)) — mailbox skip")
        }
        if !nodes.isEmpty {
            // Mirror to EVERY configured relay (redundancy). Content-addressed key → idempotent;
            // a relay in backoff is skipped. Success on ANY relay means it's safely in a mailbox.
            var landed = false
            for node in nodes {
                // Our OWN hosted relay: store directly into the local mailbox (no iroh self-connection,
                // which blows up iroh's path machinery) so offline members can still pull our posts.
                if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                    _ = RelayHost.shared.localPut(key, env)
                    landed = true; continue
                }
                // Plain-HTTP first (same cross-NAT path as media/devroster). Event envelopes used to
                // be iroh-only, so a relay whose node id had no addressing (in-app stub / CF / cold
                // DERP) could hold media and rosters over HTTP while every post never left the phone.
                if let http = RelayMailboxStore.shared.httpInterface(node) {
                    var done = false
                    for base in http.urls where !httpUrlBad(base) {
                        switch await httpPut(base, http.token, key, env) {
                        case .success:
                            RelayHealth.shared.recordSuccess(node)
                            RelayMailboxStore.shared.markSeen(node)
                            HavenLog.relay("mailbox http-put OK relay=\(node.prefix(8))")
                            landed = true; done = true
                        case .failure(is RelayForbidden):
                            noteRefused(node, "mailbox put")
                            RelayHealth.shared.recordSuccess(node)
                        case .failure:
                            markHttpUrlBad(base)
                        }
                        if done { break }
                    }
                    if done { continue }
                }
                guard let c = await RelayClients.client(node) else { continue }
                if await c.has(key: key) { RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); landed = true; continue }
                do { try await c.put(key: key, data: env); RelayHealth.shared.recordSuccess(node); RelayMailboxStore.shared.markSeen(node); landed = true }
                catch { RelayHealth.shared.recordFailure(node) }   // backoff applies; the CLIENT is kept (RelayClients.forget)
            }
            if landed { markSeen(key); FeedStore.shared.markRelay(true); return true }
            FeedStore.shared.markRelay(false); return false
        }
        if PresignStore.shared.hasPool(circleId) && !isOwner(circleId) {
            // Member: write to one of our pre-signed PUT slots (no credentials).
            guard let put = await PresignStore.shared.nextPutURL(circleId: circleId, myHex: FeedStore.shared.myNodeHex) else {
                FeedStore.shared.markRelay(false); return false
            }
            if await S3Client.putURL(put, data: env) { markSeen(key); FeedStore.shared.markRelay(true); return true }
            FeedStore.shared.markRelay(false); return false
        }
        guard let s3 = isOwner(circleId) ? ownerS3() : mailboxClient() else { return false }
        if await s3.headObject(key: key) { markSeen(key); FeedStore.shared.markRelay(true); return true }
        do {
            try await s3.putObject(key: key, data: env)
            markSeen(key); FeedStore.shared.markRelay(true); return true
        } catch {
            FeedStore.shared.markRelay(false); return false
        }
    }

    /// Refresh the liveness of every envelope in `envelopes` on every relay serving `circleId`
    /// (relay-side mailbox GC deletes entries no member refreshes for 30 days — legacy duplicate
    /// and stale-epoch envelopes age out; these stay). ONE batched TOUCH per relay, not a
    /// round-trip per key; the relay replies with the keys it lacks and we re-PUT those, so the
    /// daily refresh doubles as repair (it also self-heals a relay that GC'd our history while
    /// we were away). Deliberately ignores the seen-set — "seen" means uploaded ONCE, and the
    /// whole point here is re-asserting entries that already exist.
    static func refreshMailbox(circleId: String, envelopes: [Data]) async {
        guard !envelopes.isEmpty else { return }
        var byKey: [String: Data] = [:]
        for env in envelopes { byKey[mailboxKey(circleId, env)] = env }
        let keys = Array(byKey.keys)
        let prefix = "haven/mailbox/\(circleId)/"
        for node in relayNodes(circleId) where !node.hasPrefix("s3:") {
            // Our OWN hosted relay: touch the local store directly (no iroh self-connection).
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                for k in RelayHost.shared.localTouch(keys) {
                    if let env = byKey[k] { _ = RelayHost.shared.localPut(k, env) }
                }
                continue
            }
            guard let c = await RelayClients.client(node) else { continue }
            do {
                let misses = try await c.touch(prefix: prefix, keys: keys)
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
                for k in misses {
                    if let env = byKey[k] { try? await c.put(key: k, data: env) }
                }
            } catch {
                // Unreachable, or a pre-GC relay that doesn't speak TOUCH — either way it
                // isn't sweeping anything, so skipping the refresh is safe.
                HavenLog.relay("touch \(node.prefix(10)) \(circleId): \(error)")
            }
        }
    }

    /// Every mailbox key we've already ingested for a circle (from the persisted seen-set). Used to
    /// keep-alive posts we RECEIVED but didn't author — we can't re-derive a peer's key (only the
    /// author can re-seal), but we hold the keys we fetched, so we can TOUCH them.
    static func seenKeys(circleId: String) -> [String] {
        let prefix = "haven/mailbox/\(circleId)/"
        return withSeen { $0.filter { $0.hasPrefix(prefix) } }
    }

    /// TOUCH keys we HOLD but did not author, to keep them alive against the relay's 30-day GC.
    /// Unlike `refreshMailbox` this never re-PUTs misses (a reader can't reconstruct a peer's sealed
    /// envelope) — a key the relay already swept simply stays gone until its author refreshes it.
    /// This is what makes "any active member keeps a post alive", not just its author.
    static func touchHeldKeys(circleId: String) async {
        let keys = seenKeys(circleId: circleId)
        guard !keys.isEmpty else { return }
        let prefix = "haven/mailbox/\(circleId)/"
        for node in relayNodes(circleId) where !node.hasPrefix("s3:") {
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                _ = RelayHost.shared.localTouch(keys)   // own store: bump liveness, ignore misses
                continue
            }
            guard let c = await RelayClients.client(node) else { continue }
            if let _ = try? await c.touch(prefix: prefix, keys: keys) {
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
            }
        }
    }

    /// HTTP HELLO key under a circle mailbox (membership-gated like events).
    /// `haven/mailbox/<circle>/__hello__/<toAcct>/<fromAcct>/<sha256>`
    static func helloMailboxKey(circleId: String, toHex: String, fromHex: String, body: Data) -> String {
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "haven/mailbox/\(circleId)/__hello__/\(toHex.lowercased())/\(fromHex.lowercased())/\(digest)"
    }

    /// Store-and-forward a HELLO when iroh cannot dial the peer (matrix / cross-NAT).
    /// The key is content-addressed over the hello body, and the dedupe is per (RELAY, key):
    /// "landed SOMEWHERE once" used to mark the bare key seen and short-circuit every later call,
    /// so a relay adopted (or wired via its HTTP interface) AFTER the hello first landed never
    /// received it — and the circle invite riding that hello never reached the member that relay
    /// hosts. The per-relay suffix keeps each relay's copy independently retried until it lands;
    /// sibling relays that mesh-replicate converge anyway, so a redundant PUT is just idempotent.
    static func putHello(circleId: String, toHex: String, fromHex: String, hello: Data, force: Bool = false) async {
        // Route under a mailbox prefix the RECIPIENT actually polls. A freshly-created
        // circle has no relay association yet (relayNodes(circleId) is empty → the PUT
        // silently dropped, losing the invite), and the recipient can't poll a circle
        // it hasn't learned about — so fall back to the shared "default" prefix. The
        // hello PAYLOAD carries the real circle grant; handleHello reads the circle
        // from the payload, never from the key path.
        let route = "default"
        let key = helloMailboxKey(circleId: route, toHex: toHex, fromHex: fromHex, body: hello)
        // Mark shape puts the node FIRST so the mark never shares the `haven/mailbox/…` prefix —
        // seenKeys()/touchHeldKeys sweep that prefix into relay TOUCH bodies, and a mark is not a
        // mailbox key. (repairHelloSeenOnce still matches it via the embedded `/__hello__/`.)
        func relayMark(_ node: String) -> String { "hello@\(node.lowercased())|\(key)" }
        let due = relayNodes(route).filter { !$0.hasPrefix("s3:") && !seenContains(relayMark($0)) }
        if due.isEmpty {
            HavenLog.net("putHello drop: no due relays (route=\(route) all=\(relayNodes(route).count)) to=\(toHex.prefix(8))")
            return
        }
        // Warm device: the ROUTINE hello fan-out is deferrable radio — iroh + nearby still
        // carry the live path. But a FORCED hello (invite grant, handshake reply, connection
        // request) is a user action whose loss is user-visible — it ships through heat.
        if !force, ThermalPolicy.skipHelloFanOut {
            HavenLog.net("putHello drop: thermal skip to=\(toHex.prefix(8))")
            return
        }
        for node in due {
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                if RelayHost.shared.localPut(key, hello) {
                    HavenLog.relay("hello local-put OK to=\(toHex.prefix(8))")
                    markSeen(relayMark(node))
                }
                continue
            }
            guard let http = RelayMailboxStore.shared.httpInterface(node) else { continue }
            var done = false   // one PUT per node — its URLs serve the same store
            for base in http.urls where !httpUrlBad(base) {
                switch await httpPut(base, http.token, key, hello) {
                case .success:
                    RelayMailboxStore.shared.markSeen(node)
                    HavenLog.relay("hello http-put OK to=\(toHex.prefix(8)) relay=\(node.prefix(8))")
                    // Only a SUCCESSFUL PUT marks this relay's copy seen, so a failed upload
                    // retries next tick rather than being silently dropped.
                    markSeen(relayMark(node))
                    done = true
                case .failure(is RelayForbidden):
                    noteRefused(node, "hello put")
                case .failure:
                    markHttpUrlBad(base)
                }
                if done { break }
            }
        }
    }

    /// Per-poll GET batch cap (mirrors the own-relay cap): a cold device drains a fat mailbox
    /// over a few polls instead of one unbounded burst. Control-plane keys rank first — they
    /// unlock everything else. (Mailbox keys are content hashes, so "newest first" is not
    /// derivable from the key; control-first is the useful half.)
    static let mailboxFetchCap = 200
    private static func controlKeyRank(_ key: String) -> Int {
        if key.contains("/__hello__/") { return 0 }
        if key.contains("/__relay__/") { return 1 }
        return 2
    }

    /// Drop cached LIST digests for a circle so the next poll re-lists in full — required after a
    /// key-commit re-queue (`forgetSeenPrefix`), where previously-seen keys must be re-GET even
    /// though the relay's key SET (and so its digest) hasn't changed.
    static func invalidateMailboxListDigests(circleId: String) {
        let suffix = "|\(circleId)"
        for k in mailboxListDigests.keys where k.hasSuffix(suffix) {
            mailboxListDigests.removeValue(forKey: k)
        }
    }

    /// Targeted single-key GET — NO LIST. The push-hints fast path: a push names the exact mailbox
    /// key it announced, so the app fetches just that envelope instead of sweeping every circle
    /// first. Returns nil when already ingested (seen) or when no relay serves it; the caller
    /// routes the bytes through the same ingest/mark-seen path as a polled envelope.
    static func fetchMailboxKey(circleId: String, key: String) async -> Data? {
        guard key.hasPrefix("haven/mailbox/\(circleId)/") else { return nil }   // hint sanity
        if seenContains(key) { return nil }
        for node in relayNodes(circleId) where !node.hasPrefix("s3:") {
            if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                if let d = RelayHost.shared.localGet(key), !d.isEmpty { return d }
                continue
            }
            if let http = RelayMailboxStore.shared.httpInterface(node) {
                var reached = false
                for base in http.urls where !httpUrlBad(base) {
                    switch await httpGet(base, http.token, key) {
                    case .success(let d):
                        RelayHealth.shared.recordSuccess(node)
                        RelayMailboxStore.shared.markSeen(node)
                        if let d, !d.isEmpty { return d }
                        reached = true   // reachable, doesn't hold it → next node
                    case .failure(is RelayForbidden):
                        noteRefused(node, "hinted mailbox get")
                        reached = true
                    case .failure:
                        markHttpUrlBad(base)
                    }
                    if reached { break }
                }
                if reached { continue }
            }
            guard let c = await RelayClients.client(node) else { continue }
            if let d = await c.get(key: key), !d.isEmpty {
                RelayHealth.shared.recordSuccess(node)
                RelayMailboxStore.shared.markSeen(node)
                return d
            }
        }
        return nil
    }

    /// The ids a mailbox HELLO addressed to THIS device may be claimed under: our account hex
    /// (the canonical slot every sender now targets) plus our CURRENT transport device id
    /// (transition-build senders addressed hellos per dial target). STALE/former device ids are
    /// deliberately absent — those slots are dead and stay unclaimed for the relay's TTL.
    static func myHelloClaimIds() -> Set<String> {
        var ids = Set<String>()
        let acct = FeedStore.shared.myNodeHex.lowercased()
        if !acct.isEmpty { ids.insert(acct) }
        let dev = FeedStore.shared.transportNodeHex.lowercased()
        if !dev.isEmpty { ids.insert(dev) }
        return ids
    }

    /// Non-hello keys always pass. A `__hello__` key names its recipient in the path
    /// (`…/__hello__/<to>/…`): fetch only slots addressed to one of `myIds`. Slots addressed to
    /// OTHER ids are left entirely alone — never fetched, never marked seen — so their real owner
    /// (or the relay TTL) gets them. Claiming them is how circle invites died: whichever member
    /// or sibling device polled first mark-seen'd every hello slot in the circle, and the invite
    /// riding a hello addressed to someone else evaporated.
    nonisolated static func helloKeyClaimable(_ key: String, myIds: Set<String>) -> Bool {
        guard let r = key.range(of: "/__hello__/") else { return true }
        let to = key[r.upperBound...].prefix(while: { $0 != "/" }).lowercased()
        return myIds.contains(String(to))
    }

    /// Poll the mailbox for envelopes we haven't seen. Returns (circleId, key, envelope) triples.
    /// Keys are needed so HELLO blobs (`/__hello__/`) can be routed to handleHello, not receive().
    static func pollMailbox(circleIds: [String]) async -> [(String, String, Data)] {
        var out: [(String, String, Data)] = []
        let myHelloIds = myHelloClaimIds()   // hello slots addressed to anyone else stay untouched
        for cid in circleIds {
            let prefix = "haven/mailbox/\(cid)/"
            let nodes = relayNodes(cid)
            if !nodes.isEmpty {
                // Read from ALL relays; seenMailbox is keyed by the content-addressed key, so the
                // same envelope mirrored on several relays is ingested exactly once (dedup).
                for node in nodes {
                    // OUR OWN hosted relay: read the local store directly — we can't dial ourselves
                    // (self-dial guard), so this is how the host ingests what a sibling device or a
                    // friend uploaded to it (the previously-missing read-own-relay path).
                    if RelayHost.shared.serving, node == RelayHost.shared.nodeId {
                        let host = RelayHost.shared
                        // LIST and FILTER off-main too, not just the reads. `localList` enumerates the
                        // whole circle prefix — one real store here holds 7,557 keys in a single
                        // circle — and the seen-set filter walks every one of them. Leaving those two
                        // on the main actor meant that even with nothing new to fetch, every poll
                        // still cost ~10k directory entries plus 10k set lookups on the thread drawing
                        // the UI, per circle. Fast enough to hide on an M4; not on an M1 with a real
                        // store behind it. The seen-set is NSLock-guarded and always was — it just
                        // wasn't declared callable from off the main actor.
                        //
                        // LINKED-HOST RECOVERY: also re-offer a bounded set of already-seen *control*
                        // envelopes (key commits 0x03, device rosters 0x04). A Mac hosting the relay
                        // can mark those seen before it can open them (roster lag / dual-open race /
                        // older mark-at-fetch), leave peer_epoch_keys empty, and then never retry —
                        // while the iPhone (linked, push-capable) decrypts the same traffic fine.
                        // Cap keeps the retry cheap; once keys land, receive returns false for
                        // duplicates and we stop thrashing.
                        let scan: (all: Int, want: [String]) = await Task.detached(priority: .utility) {
                            let all = host.localList(prefix).filter { !$0.contains("/__live__/") }
                            var want = all.filter { !seenContains($0) && helloKeyClaimable($0, myIds: myHelloIds) }
                            // Re-probe seen control-plane keys (bounded). Prefer unread first.
                            // Cap both hits and files inspected so a fat circle (thousands of
                            // already-seen event blobs) does not re-read the whole store every poll.
                            var controlBudget = 48
                            var seenScanned = 0
                            for key in all where seenContains(key) && controlBudget > 0 && seenScanned < 300 {
                                seenScanned += 1
                                guard let data = host.localGet(key), let tag = data.first else { continue }
                                // 0x03 = key commit, 0x04 = device roster — must land before events.
                                if tag == 0x03 || tag == 0x04 {
                                    want.append(key)
                                    controlBudget -= 1
                                }
                            }
                            return (all.count, want)
                        }.value
                        var fresh = scan.want
                        let localKeys = scan.all
                        // BOUND the pass. On a freshly-enabled relay nothing is in the seen-set, so
                        // "fresh" is the WHOLE store — thousands of envelopes — and this loop used to
                        // read every one of them synchronously ON THE MAIN THREAD (SharedStore is
                        // @MainActor and RelayHost was too). That is why enabling the relay made the
                        // app unresponsive within seconds rather than gradually: one poll could block
                        // main for thousands of file reads back to back. The remainder is picked up by
                        // the next poll — ingestion is idempotent and the seen-set carries across.
                        let cap = 200
                        let deferred = max(0, fresh.count - cap)
                        if deferred > 0 { fresh = Array(fresh.prefix(cap)) }
                        noteBacklog(cid, keys: localKeys, fresh: fresh.count, deferred: deferred)
                        HavenLog.relay("poll OWN relay \(cid): \(localKeys) keys, \(fresh.count) new\(deferred > 0 ? " (+\(deferred) next poll)" : "")")
                        // Read OFF the main actor — RelayHost's accessors are nonisolated precisely so
                        // this file I/O doesn't have to happen on the thread drawing the UI.
                        let read: [(String, Data)] = await Task.detached(priority: .utility) {
                            var acc: [(String, Data)] = []
                            for key in fresh {
                                if let data = host.localGet(key) { acc.append((key, data)) }
                            }
                            return acc
                        }.value
                        // Mark seen only once the bytes are in hand, so a failed read is retried on the
                        // next poll instead of being skipped forever.
                        for (key, data) in read { out.append((cid, key, data)) }
                        continue
                    }
                    // Plain-HTTP LIST+GET first — same reason as uploadEvent: iroh dial may be
                    // unreachable while the relay's media port answers. Delta-LIST: echo the last
                    // digest for this (relay, circle) so an unchanged mailbox is one bodiless 204
                    // instead of a full key dump + N seen-set walks (the idle radio saver).
                    if let http = RelayMailboxStore.shared.httpInterface(node) {
                        var listedViaHttp = false
                        let digestKey = "\(node)|\(cid)"
                        for base in http.urls where !httpUrlBad(base) {
                            switch await httpListDelta(base, http.token, prefix, digest: mailboxListDigests[digestKey]) {
                            case .success(let r):
                                listedViaHttp = true
                                // HTTP LIST is a real reachability proof — without this the UI only
                                // greened on iroh dial success, so free-CF (HTTP-only) relays flapped
                                // orange whenever a dial timed out while HTTP was fine.
                                RelayHealth.shared.recordSuccess(node)
                                RelayMailboxStore.shared.markSeen(node)
                                guard let keys = r.keys else { break }   // 204: nothing new — skip the GETs
                                // Unclaimed live-call frames are NOT content: they're claimed by the
                                // in-call 2s poll, and GETting them here just re-fetched frames that
                                // then failed receive() forever. Same for hello slots addressed to
                                // other ids (theirs to claim). Control-plane first, capped batch.
                                var fresh = keys.filter {
                                    !seenContains($0) && !$0.contains("/__live__/")
                                        && helloKeyClaimable($0, myIds: myHelloIds)
                                }
                                fresh.sort { controlKeyRank($0) < controlKeyRank($1) }
                                let deferred = max(0, fresh.count - mailboxFetchCap)
                                if deferred > 0 { fresh = Array(fresh.prefix(mailboxFetchCap)) }
                                noteBacklog(cid, keys: keys.count, fresh: fresh.count, deferred: deferred)
                                var allFetched = true
                                for key in fresh {
                                    if case .success(let data?) = await httpGet(base, http.token, key) {
                                        out.append((cid, key, data))
                                    } else {
                                        allFetched = false
                                    }
                                }
                                // Commit the digest ONLY when this listing is fully drained — a 204
                                // next poll must never hide keys we still owe a GET.
                                if allFetched, deferred == 0, let d = r.digest, !d.isEmpty {
                                    mailboxListDigests[digestKey] = d
                                    if mailboxListDigests.count > 500 { mailboxListDigests.removeAll() }
                                }
                            case .failure(is RelayForbidden):
                                noteRefused(node, "mailbox list")
                                // Reachable enough to refuse — not a dead endpoint.
                                RelayHealth.shared.recordSuccess(node)
                            case .failure:
                                markHttpUrlBad(base)
                            }
                            if listedViaHttp { break }
                        }
                        if listedViaHttp { continue }
                    }
                    guard let c = await RelayClients.client(node) else { continue }
                    // list() now throws so a dead iroh dial isn't read as an empty mailbox;
                    // a failure means this relay gave us nothing — try the next one.
                    guard let keys = try? await c.list(prefix: prefix) else { continue }
                    RelayHealth.shared.recordSuccess(node)
                    RelayMailboxStore.shared.markSeen(node)
                    // We reached this relay over iroh but hold no usable HTTP interface for it —
                    // exactly the state a restarted CLI relay (rotated free-tunnel URL) leaves every
                    // client in, where mailbox flows and MEDIA silently dies (the blob dial drops
                    // cross-NAT). Fetch its self-published interface and adopt + re-announce.
                    FeedStore.shared.refreshRelayInterfaceIfNeeded(node)
                    // Same shape as the HTTP path: skip unclaimed live-call frames + other ids'
                    // hello slots, control first, cap.
                    var fresh = keys.filter {
                        !seenContains($0) && !$0.contains("/__live__/")
                            && helloKeyClaimable($0, myIds: myHelloIds)
                    }
                    fresh.sort { controlKeyRank($0) < controlKeyRank($1) }
                    noteBacklog(cid, keys: keys.count, fresh: min(fresh.count, mailboxFetchCap),
                                deferred: max(0, fresh.count - mailboxFetchCap))
                    for key in fresh.prefix(mailboxFetchCap) {
                        if let data = await c.get(key: key) { out.append((cid, key, data)) }
                    }
                }
            } else if PresignStore.shared.hasPool(cid) && !isOwner(cid) {
                // Member: LIST + GET via the pre-signed pool URLs (no credentials).
                if let listURL = await PresignStore.shared.listURL(cid), let xml = await S3Client.getURL(listURL) {
                    for key in S3Client.parseListKeys(xml) where !seenContains(key) {
                        if let g = await PresignStore.shared.getURL(circleId: cid, key: key), let data = await S3Client.getURL(g) {
                            out.append((cid, key, data))
                        }
                    }
                }
            } else if let s3 = isOwner(cid) ? ownerS3() : mailboxClient(), let s3keys = try? await s3.listKeys(prefix: prefix) {
                for key in s3keys where !seenContains(key) {
                    if let data = try? await s3.getObject(key: key) { out.append((cid, key, data)) }
                }
            }
        }
        return out
    }
}

// MARK: - Push hints (app-group hand-off from the NSE/push worker)

/// One hint the push pipeline wrote for the app: which circle (`c`), the exact mailbox key the
/// push announced (`mk`), media refs to prefetch (`mr`), and the post to deep-link (`p`).
struct SharedPushHint: Decodable {
    let c: String
    let mk: String?
    let mr: [String]?
    let p: String?
}

/// Reader for the app-group push-hint drop (`haven.push.hints.v1`): the NSE appends hints as it
/// processes pushes; the app drains them on foreground/push and turns each into a targeted mailbox
/// GET + media prefetch — closing the "banner arrived before the content was fetchable" gap.
/// Tolerant of the key not existing yet (older NSE builds simply never write it).
enum SharedPushHints {
    static let key = "haven.push.hints.v1"

    @MainActor static func drain() -> [SharedPushHint] {
        guard let d = UserDefaults(suiteName: SharedNotificationPrivacy.appGroup) else { return [] }
        let raw: Data?
        if let data = d.data(forKey: key) { raw = data }
        else if let s = d.string(forKey: key) { raw = Data(s.utf8) }
        else { raw = nil }
        guard let raw, !raw.isEmpty else { return [] }
        d.removeObject(forKey: key)
        guard let hints = try? JSONDecoder().decode([SharedPushHint].self, from: raw) else { return [] }
        return hints.filter { !$0.c.isEmpty }
    }
}
