import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Re-encode media I ALREADY shared, and re-share it, so the whole circle gets the smaller copy.
///
/// The compression rewrite only ever applied to the next thing you post. Everything already out
/// there stayed exactly as big as it was — one real device is holding 53 items / 1.3 GB with single
/// videos at 320 MB, and every member of those circles is holding the same 320 MB. Nothing in the
/// app could ever make that better; the only lever was deleting it. This is that lever.
///
///
/// THE HARD PART: a ref IS the digest of its bytes.
///
/// `MediaStore.contentRef` names a blob by the sha-256 of its plaintext, and that is load-bearing
/// security, not a naming convention: it is what stops a relay operator (always an ordinary circle
/// member) from PUTting their bytes at someone else's ref and having every client render it. So
/// re-encoding is not an in-place operation. New bytes are, by construction, a NEW ADDRESS. There is
/// no way to shrink a blob and leave the ref pointing at it — a recipient hashing what arrived would
/// reject it, correctly.
///
/// Which leaves three options for the posts already naming the old ref:
///
///  1. An alias table: "ref A now means the bytes at ref B". Rejected outright. That is precisely
///     the indirection content addressing exists to forbid — whoever controls the table controls
///     what a signed post displays, and the signature no longer binds the media. It would undo the
///     fix, for a storage win.
///
///  2. Keep both, and let clients prefer whichever is smaller. Rejected: it makes the saving
///     imaginary. Both blobs remain referenced, so neither can ever be swept, and every member now
///     stores the 320 MB original AND the 38 MB copy. That is worse than doing nothing.
///
///  3. EDIT THE POST to point at the new ref. Chosen. An Edit event is already a first-class thing
///     in this protocol — `EditPostSheet` writes one whenever you change a caption or swap an
///     attachment, and it carries a full media array. Re-optimizing is that same operation with the
///     text left alone. It keeps the item's id, author, thread position and original timestamp, so
///     nothing reorders in anyone's feed and no notification fires. Members who are online get the
///     edit immediately; members who are offline get it from the relay alongside the new blob, which
///     is queued through `MediaBackupQueue` exactly like a fresh post's media.
///
/// Two consequences fall straight out of choosing (3), and both are load-bearing:
///
///  - ONLY MY OWN posts and comments are eligible. An Edit is signed by the author; I cannot
///    re-point someone else's post at new bytes and must not be able to. So this shrinks what I put
///    into my circles. Media others sent me is left alone — for that, the local caps and the
///    cleanup sweep are still the answer.
///
///  - THE OLD BLOB IS NOT DELETED HERE. It is tempting: the moment the edit is written, nothing of
///    mine references the old ref and the bytes look like pure waste. But a member who is offline
///    right now still holds the PRE-edit post, still naming the old ref, and if they ask for it
///    while my copy is gone they get a permanently broken post. So the old bytes stay a servable
///    source and are retired the ordinary way — the weekly orphan sweep, which already skips
///    anything referenced by a live event and gives everything a 48-hour grace window. The saving
///    lands slightly later; nothing breaks in the gap.
///
///
/// BOUNDING. This encodes video, which means it is the exact shape of task that has cost this
/// codebase a machine before. So: it never starts on its own (no timer, no launch hook, no
/// background scheduling — the only caller is a button), it runs at most `batchLimit` items per tap
/// and then STOPS and asks again, it is cancellable between items, it refuses to start without disk
/// headroom, and it holds one encode in flight at a time.
@MainActor
final class MediaReoptimizer: ObservableObject {
    static let shared = MediaReoptimizer()

    /// One tap = at most this many items, then it stops and reports. A 300 MB clip takes ~35s, so a
    /// full batch is minutes, not hours, and the user is never more than one batch from an idle app.
    static let batchLimit = 25

    /// What this candidate needs. Re-encode shrinks bytes; poster-only publishes a still for a
    /// video that is already small enough (or that we are not re-encoding) but never shipped a
    /// `poster:` marker — super data saver and feed cards need that still even when the clip
    /// itself will not shrink.
    enum Work: Sendable {
        case reencode
        case posterOnly
    }

    /// One item of mine that re-optimize can improve (smaller bytes and/or a missing video poster).
    struct Candidate: Identifiable, Sendable {
        /// Distinct from `ref` so a video can be both "needs shrink" and "needs poster" without
        /// colliding in the skip set (poster failures use `poster:<ref>`).
        var id: String { work == .posterOnly ? "poster:\(ref)" : ref }
        let ref: String
        let kind: MediaKind
        let work: Work
        /// Shape of the on-disk bytes. For poster-only this is still the video's shape (for
        /// ordering / UI size), not a claim that we will re-encode it.
        let shape: MediaOptimizationTarget.Shape
        /// Timestamp of the oldest post/comment of mine that names it.
        let firstSharedMs: UInt64
        /// Shared before the encoder rewrite landed (as opposed to shared after it with
        /// auto-optimize switched off) — reported, not used as a gate. See `scan`.
        let legacyByAge: Bool
    }

    @Published private(set) var scanning = false
    @Published private(set) var running = false
    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var doneCount = 0
    @Published private(set) var batchCount = 0
    @Published private(set) var currentLabel = ""
    @Published private(set) var lastSummary: String?
    /// Set when a run stopped for a reason the user needs to know (no disk, nothing shrank).
    @Published private(set) var lastWarning: String?
    /// Distinguishes "not measured yet" from "measured, and there is genuinely nothing to do" —
    /// otherwise a scan that finds a clean library looks identical to a button that did nothing.
    @Published private(set) var hasScanned = false

    private var cancelRequested = false
    /// Total bytes of shrink candidates still waiting (poster-only is a small JPEG — not counted as library size).
    var pendingBytes: Int64 {
        candidates.reduce(0) { $0 + ($1.work == .reencode ? $1.shape.bytes : 0) }
    }
    var posterOnlyCount: Int { candidates.filter { $0.work == .posterOnly }.count }

    // MARK: - Don't-retry set
    //
    // A blob that failed to encode, or that came back no smaller, must not be offered again on every
    // scan forever — that would burn minutes of CPU per tap re-deciding the same thing. Persisted so
    // it survives a relaunch, and bounded so it cannot itself become the leak.
    private let skipKey = "haven.reoptimize.skip"
    private lazy var skipped: Set<String> = Set(UserDefaults.standard.stringArray(forKey: skipKey) ?? [])
    private func skip(_ ref: String) {
        skipped.insert(ref)
        if skipped.count > 500 { skipped = Set(skipped.prefix(500)) }
        UserDefaults.standard.set(Array(skipped), forKey: skipKey)
    }

    // MARK: - Scan

    /// Find my shared media that is above target, **and** videos that never published a poster.
    ///
    /// TWO SIGNALS for the shrink path, and it is worth being precise about how they combine, because
    /// the obvious reading ("anything before the cutoff") is not what this does:
    ///
    ///   AGE (`MediaOptimizationTarget.legacyCutoff`, 2026-07-20 08:00 America/Los_Angeles) is a
    ///   fact about provenance: media shared before that instant CANNOT have come from the current
    ///   encoder, whatever it looks like.
    ///
    ///   SHAPE (`MediaOptimizationTarget.probe`) is a fact about the bytes: codec, dimensions,
    ///   bitrate, bytes-per-pixel. HEVC is the strongest single tell — the optimized path hard-codes
    ///   H.264 because Android can't be relied on to decode HEVC — so an `hvc1` track is proof the
    ///   file came from the passthrough remux or the raw-copy fallback.
    ///
    /// SHAPE alone is dispositive for re-encode, and AGE is reported rather than enforced. That is
    /// deliberate: age would exclude media shared AFTER the cutoff with auto-optimize switched OFF,
    /// which is half the population this button exists for, and it would include media that is
    /// already at target and would gain nothing from a rewrite. Asking the file is strictly better
    /// than asking the calendar.
    ///
    /// POSTER-ONLY is a third path: a video may already be at target (so it will never re-encode)
    /// yet still lack a `poster:<video>:<image>` marker on one of my posts. Super data saver and
    /// feed cards need that still. We cut a JPEG from the existing file and edit the post — no
    /// re-transcode of the clip.
    ///
    /// The safety property that makes a shape-only gate sound is idempotence: the encoder's own
    /// output must re-probe as AT target, or this would re-encode the same clip on every run. That
    /// is why the probe's ceilings carry headroom over the encoder's nominal rates, and it was
    /// measured on real files rather than reasoned about — 305.7 MB @ 38.1 Mbps in, 37.7 MB @ 4.7
    /// Mbps out, against a 6.0 Mbps ceiling. Poster-only is idempotent because a post that already
    /// has a marker for that video is not offered again.
    func scan() async {
        guard !scanning, !running else { return }
        scanning = true
        lastWarning = nil
        defer { scanning = false }

        let targets = await FeedStore.shared.reoptimizeTargets()
        // Earliest time each ref was shared by me. A ref used by several posts is ONE encode.
        var firstShared: [String: UInt64] = [:]
        // Videos that appear on at least one of my posts without a poster marker.
        var needsPoster = Set<String>()
        for target in targets {
            for ref in target.media {
                guard !MediaStore.isSynthetic(ref), let kind = MediaKind(ref: ref) else { continue }
                firstShared[ref] = min(firstShared[ref] ?? .max, target.createdAtMs)
                if kind == .video,
                   MediaVariants.poster(for: ref, in: target.media) == nil {
                    needsPoster.insert(ref)
                }
            }
        }
        let skipSnap = skipped
        // Only refs whose bytes are actually here.
        let probeList: [(ref: String, url: URL, kind: MediaKind, since: UInt64, wantPoster: Bool)] =
            firstShared.compactMap { ref, ms in
                guard let kind = MediaKind(ref: ref),
                      let url = MediaStore.shared.storagePath(for: ref),
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (ref, url, kind, ms, needsPoster.contains(ref) && !skipSnap.contains("poster:\(ref)"))
            }

        // Probing reads headers off dozens of files and spins up an AVAsset per video — off the main
        // actor, or the Settings screen locks up for the duration.
        let found: [Candidate] = await Task.detached(priority: .userInitiated) {
            var out: [Candidate] = []
            for p in probeList {
                let shape = await MediaOptimizationTarget.probe(p.url)
                let legacy = MediaOptimizationTarget.isLegacyByAge(createdAtMs: p.since)
                let above = shape?.aboveTarget == true
                if above, !skipSnap.contains(p.ref), let shape {
                    // Re-encode path also regenerates a poster when the clip is a video.
                    out.append(Candidate(ref: p.ref, kind: p.kind, work: .reencode, shape: shape,
                                         firstSharedMs: p.since, legacyByAge: legacy))
                } else if p.kind == .video, p.wantPoster {
                    // Already small enough (or unprobeable) but still missing a published still.
                    // Do NOT also add poster-only when we're re-encoding — that path publishes a poster.
                    let bytes = shape?.bytes
                        ?? Int64((try? p.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    let s = shape ?? MediaOptimizationTarget.Shape(
                        bytes: bytes, maxDimension: 0, codec: "video", bitrate: 0, seconds: 0,
                        aboveTargetReason: nil)
                    out.append(Candidate(ref: p.ref, kind: .video, work: .posterOnly, shape: s,
                                         firstSharedMs: p.since, legacyByAge: legacy))
                }
            }
            return out
        }.value

        // Biggest re-encodes first; poster-only (cheap JPEG cut) after shrink work of similar size.
        candidates = found.sorted {
            if $0.work != $1.work { return $0.work == .reencode && $1.work == .posterOnly }
            return $0.shape.bytes > $1.shape.bytes
        }
        hasScanned = true
    }

    // MARK: - Run

    func cancel() { cancelRequested = true }

    /// Re-encode / poster-fill up to `batchLimit` candidates and re-share every post that named them.
    func run() async {
        guard !running, !candidates.isEmpty else { return }
        running = true
        cancelRequested = false
        lastWarning = nil
        doneCount = 0
        defer { running = false; currentLabel = "" }

        let batch = Array(candidates.prefix(Self.batchLimit))
        batchCount = batch.count
        var before: Int64 = 0, after: Int64 = 0
        // old ref -> new ref (re-encoded stills/videos).
        var swap: [String: String] = [:]
        // old video ref -> poster image ref (poster-only OR regenerated with re-encode).
        var posters: [String: String] = [:]
        var postersAdded = 0

        for candidate in batch {
            if cancelRequested || Task.isCancelled { break }

            switch candidate.work {
            case .posterOnly:
                currentLabel = "poster"
                // Poster is a small JPEG — only need modest headroom, not a full video rewrite budget.
                guard hasDiskHeadroom(for: 8 * 1_048_576) else {
                    lastWarning = "Stopped — not enough free space to re-encode safely."
                    break
                }
                if let pRef = MediaStore.shared.ensurePosterImage(for: candidate.ref), !pRef.isEmpty {
                    posters[candidate.ref] = pRef
                    postersAdded += 1
                } else {
                    skip("poster:\(candidate.ref)")
                }
                doneCount += 1
                await Task.yield()

            case .reencode:
                guard hasDiskHeadroom(for: candidate.shape.bytes) else {
                    lastWarning = "Stopped — not enough free space to re-encode safely."
                    break
                }
                currentLabel = candidate.kind == .video ? "video" : (candidate.kind == .audio ? "audio" : "photo")

                let encoded = await encode(candidate)
                guard let newRef = encoded.ref, !newRef.isEmpty, newRef != candidate.ref,
                      let newURL = MediaStore.shared.storagePath(for: newRef),
                      let newBytes = (try? newURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                else {
                    // Re-encode failed — still try a poster if this video never published one.
                    if candidate.kind == .video,
                       let pRef = MediaStore.shared.ensurePosterImage(for: candidate.ref), !pRef.isEmpty {
                        posters[candidate.ref] = pRef
                        postersAdded += 1
                    }
                    skip(candidate.ref)
                    doneCount += 1
                    continue
                }
                // A rewrite that doesn't clearly win is worse than none: every member pays a re-download
                // for nothing. Drop it and never offer this ref again — but still publish a poster if
                // the post never had one (the clip stays; the still is new value).
                if Double(newBytes) >= Double(candidate.shape.bytes) * MediaOptimizationTarget.requiredShrinkFactor {
                    HavenLog.sync("reoptimize: \(candidate.ref.prefix(12)) came back no smaller (\(newBytes) vs \(candidate.shape.bytes)) — keeping the original")
                    MediaStore.shared.delete(newRef)
                    if candidate.kind == .video,
                       let pRef = MediaStore.shared.ensurePosterImage(for: candidate.ref), !pRef.isEmpty {
                        posters[candidate.ref] = pRef
                        postersAdded += 1
                    }
                    skip(candidate.ref)
                    doneCount += 1
                    continue
                }
                before += candidate.shape.bytes
                after += Int64(newBytes)
                swap[candidate.ref] = newRef
                if let p = encoded.posterRef, !p.isEmpty {
                    posters[candidate.ref] = p
                    postersAdded += 1
                } else if candidate.kind == .video,
                          let pRef = MediaStore.shared.ensurePosterImage(for: newRef), !pRef.isEmpty {
                    // prepareVideo should have cut one; fall back if it didn't.
                    posters[candidate.ref] = pRef
                    postersAdded += 1
                }
                doneCount += 1
                await Task.yield()
            }
        }

        // Apply. Targets are re-read NOW rather than reused from the scan: minutes have passed, and
        // a post edited or retracted in the meantime must be edited against its current state, not a
        // stale copy that would silently revert the user's own change.
        var reshared = 0
        if !swap.isEmpty || !posters.isEmpty {
            for target in await FeedStore.shared.reoptimizeTargets() {
                // Poster map is per-post: only videos this post names, and only when the post
                // still lacks a marker (or the video itself is being swapped — re-pair then).
                var postPosters: [String: String] = [:]
                for (oldV, pImg) in posters {
                    guard target.media.contains(oldV) else { continue }
                    let willSwap = swap[oldV] != nil
                    let missing = MediaVariants.poster(for: oldV, in: target.media) == nil
                    if willSwap || missing { postPosters[oldV] = pImg }
                }
                let needsSwap = target.media.contains { swap[$0] != nil }
                guard needsSwap || !postPosters.isEmpty else { continue }
                let media = MediaVariants.rewriteMedia(target.media, swap: swap, posters: postPosters)
                if media != target.media, await FeedStore.shared.applyReoptimized(target, media: media) {
                    reshared += 1
                }
            }
            FeedStore.shared.refresh()
        }

        let shrinkN = swap.count
        if shrinkN == 0 && postersAdded == 0 {
            lastSummary = "Nothing could be improved"
        } else {
            var parts: [String] = []
            if shrinkN > 0 {
                parts.append("\(shrinkN) item\(shrinkN == 1 ? "" : "s") smaller (\(fmt(before)) → \(fmt(after)), \(pct(before, after))%)")
            }
            if postersAdded > 0 {
                parts.append("\(postersAdded) video poster\(postersAdded == 1 ? "" : "s") added")
            }
            parts.append("\(reshared) post\(reshared == 1 ? "" : "s") re-shared")
            lastSummary = parts.joined(separator: " · ")
        }
        HavenLog.sync("reoptimize: \(lastSummary ?? "")")
        if cancelRequested { lastWarning = "Stopped." }

        // Re-scan so the remaining count is honest.
        let raised = lastWarning
        await scan()
        if let raised, lastWarning == nil { lastWarning = raised }
    }

    /// Re-encode one blob through the SAME entry points a brand-new attachment uses.
    /// Videos use `prepareVideo` so a poster still is produced and returned for the media rewrite.
    private func encode(_ candidate: Candidate) async -> (ref: String?, posterRef: String?) {
        guard let src = MediaStore.shared.storagePath(for: candidate.ref) else { return (nil, nil) }
        switch candidate.kind {
        case .video:
            let prepared = await MediaStore.shared.prepareVideo(url: src, forceOptimize: true)
            if prepared.isEmpty { return (nil, nil) }
            return (prepared.videoRef, prepared.posterRef)
        case .audio:
            return (await MediaStore.shared.addAudio(url: src), nil)
        case .image:
            let ref = await MediaProcessing.tracking("photo") { () -> String? in
                guard let img = MediaStore.shared.item(candidate.ref)?.image else { return nil }
                return MediaStore.shared.addImage(img, forceOptimize: true)
            }
            return (ref, nil)
        case .file:
            return (nil, nil)
        }
    }

    /// Refuse to start an encode without room for the source AND its output plus a margin. Filling
    /// the disk in a loop is the other way a job like this ruins someone's day.
    private func hasDiskHeadroom(for bytes: Int64) -> Bool {
        let dir = MediaStore.storageDir
        guard let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage else { return true }   // unknown → don't block
        return free > bytes + 512 * 1_048_576
    }

    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    private func pct(_ before: Int64, _ after: Int64) -> Int {
        before > 0 ? max(0, 100 - Int(Double(after) * 100 / Double(before))) : 0
    }
}

/// One post or comment of mine that carries media, as handed to `MediaReoptimizer` by `FeedStore`.
/// Everything an Edit needs to be written back unchanged except for the media array.
struct ReoptimizeTarget: Sendable {
    let circleId: String
    let eventId: String
    let body: String
    let media: [String]
    let music: TrackRefFfi?
    let muteVideo: Bool
    let createdAtMs: UInt64
}

// MARK: - The Settings row

/// Settings ▸ Storage's action button. Two taps by design: the first measures and TELLS you what it
/// found, the second commits. A button that silently re-encoded a gigabyte and re-published a year of
/// posts on one tap would be the wrong shape of thing entirely.
struct ReoptimizeMediaRow: View {
    @ObservedObject private var reopt = MediaReoptimizer.shared
    var onFinished: () async -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    if reopt.candidates.isEmpty { await reopt.scan() } else { await reopt.run(); await onFinished() }
                }
            } label: {
                HStack {
                    Label(title, systemImage: icon)
                    Spacer()
                    if reopt.scanning || reopt.running { ProgressView() }
                }
            }
            .disabled(reopt.scanning || reopt.running)

            if reopt.running {
                Button(role: .destructive) { reopt.cancel() } label: {
                    Label("Stop after this one", systemImage: "stop.circle")
                }
                .font(.caption)
            }
            // The composer's in-flight card, reused verbatim — it is already the app's answer to
            // "something is encoding right now".
            MediaProcessingCard()

            if let w = reopt.lastWarning {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let s = reopt.lastSummary, !reopt.running {
                Label(s, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if !reopt.candidates.isEmpty && !reopt.running {
                Text(foundText).font(.caption).foregroundStyle(.secondary)
            } else if reopt.hasScanned && !reopt.scanning && !reopt.running && reopt.lastSummary == nil {
                Label("Everything you've shared is already optimized — including video posters.",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        if reopt.scanning { return "Checking your shared media…" }
        if reopt.running {
            return "Re-optimizing \(min(reopt.doneCount + 1, reopt.batchCount)) of \(reopt.batchCount)… (\(reopt.currentLabel))"
        }
        if reopt.candidates.isEmpty { return "Re-optimize media I already shared" }
        let n = min(reopt.candidates.count, MediaReoptimizer.batchLimit)
        let posters = reopt.candidates.filter { $0.work == .posterOnly }.count
        let shrinks = reopt.candidates.count - posters
        if shrinks == 0 {
            return "Add posters to \(min(posters, n)) video\(min(posters, n) == 1 ? "" : "s")"
        }
        if posters == 0 {
            return "Shrink & re-share \(n) item\(n == 1 ? "" : "s")"
        }
        return "Improve \(n) item\(n == 1 ? "" : "s") (shrink + posters)"
    }
    private var icon: String {
        reopt.candidates.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill"
    }
    private var foundText: String {
        let total = reopt.candidates.count
        let size = ByteCountFormatter.string(fromByteCount: reopt.pendingBytes, countStyle: .file)
        let batch = min(total, MediaReoptimizer.batchLimit)
        let legacy = reopt.candidates.filter(\.legacyByAge).count
        let posters = reopt.posterOnlyCount
        let shrinks = total - posters
        var s = ""
        if shrinks > 0 {
            s = "\(shrinks) item\(shrinks == 1 ? "" : "s") · \(size) currently on every member's device"
        }
        if posters > 0 {
            let p = "\(posters) video\(posters == 1 ? "" : "s") missing a feed poster"
            s = s.isEmpty ? p : s + " · " + p
        }
        if legacy > 0 { s += " · \(legacy) shared before Haven learned to compress" }
        if batch < total { s += ". This run does \(batch); tap again for the rest." }
        return s
    }
}
