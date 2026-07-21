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

    /// One item of mine whose stored bytes are above target.
    struct Candidate: Identifiable, Sendable {
        var id: String { ref }
        let ref: String
        let kind: MediaKind
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
    /// Total bytes of everything still waiting.
    var pendingBytes: Int64 { candidates.reduce(0) { $0 + $1.shape.bytes } }

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

    /// Find my shared media that is above target.
    ///
    /// TWO SIGNALS, and it is worth being precise about how they combine, because the obvious
    /// reading ("anything before the cutoff") is not what this does:
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
    /// SHAPE alone is dispositive, and AGE is reported rather than enforced. That is deliberate:
    /// age would exclude media shared AFTER the cutoff with auto-optimize switched OFF, which is
    /// half the population this button exists for, and it would include media that is already at
    /// target and would gain nothing from a rewrite. Asking the file is strictly better than asking
    /// the calendar. The cutoff is kept because it explains a row to the user ("shared before Haven
    /// learned to compress") and because it is the honest answer to "why is this here at all".
    ///
    /// The safety property that makes a shape-only gate sound is idempotence: the encoder's own
    /// output must re-probe as AT target, or this would re-encode the same clip on every run. That
    /// is why the probe's ceilings carry headroom over the encoder's nominal rates, and it was
    /// measured on real files rather than reasoned about — 305.7 MB @ 38.1 Mbps in, 37.7 MB @ 4.7
    /// Mbps out, against a 6.0 Mbps ceiling.
    func scan() async {
        guard !scanning, !running else { return }
        scanning = true
        lastWarning = nil
        defer { scanning = false }

        // Earliest time each ref was shared by me. A ref used by several posts is ONE encode.
        var firstShared: [String: UInt64] = [:]
        for target in FeedStore.shared.reoptimizeTargets() {
            for ref in target.media {
                guard !MediaStore.isSynthetic(ref), MediaKind(ref: ref) != nil, !skipped.contains(ref) else { continue }
                firstShared[ref] = min(firstShared[ref] ?? .max, target.createdAtMs)
            }
        }
        // Only refs whose bytes are actually here. One that has been evicted or never arrived can't
        // be re-encoded from nothing, and re-downloading a 320 MB blob in order to shrink it is a
        // decision for the user, not for a settings button.
        let probeList: [(ref: String, url: URL, kind: MediaKind, since: UInt64)] = firstShared.compactMap { ref, ms in
            guard let kind = MediaKind(ref: ref),
                  let url = MediaStore.shared.storagePath(for: ref),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (ref, url, kind, ms)
        }

        // Probing reads headers off dozens of files and spins up an AVAsset per video — off the main
        // actor, or the Settings screen locks up for the duration.
        let found: [Candidate] = await Task.detached(priority: .userInitiated) {
            var out: [Candidate] = []
            for p in probeList {
                guard let shape = await MediaOptimizationTarget.probe(p.url), shape.aboveTarget else { continue }
                out.append(Candidate(ref: p.ref, kind: p.kind, shape: shape, firstSharedMs: p.since,
                                     legacyByAge: MediaOptimizationTarget.isLegacyByAge(createdAtMs: p.since)))
            }
            return out
        }.value

        // Biggest first: the win is dominated by a handful of videos, and a user who runs one batch
        // and stops should still have captured most of the saving.
        candidates = found.sorted { $0.shape.bytes > $1.shape.bytes }
        hasScanned = true
    }

    // MARK: - Run

    func cancel() { cancelRequested = true }

    /// Re-encode up to `batchLimit` candidates and re-share every post that named them.
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
        // old ref -> new ref. Built across the whole batch, then applied in ONE pass, so a post with
        // three rewritten photos gets a single edit rather than three.
        var swap: [String: String] = [:]

        for candidate in batch {
            if cancelRequested || Task.isCancelled { break }
            guard hasDiskHeadroom(for: candidate.shape.bytes) else {
                lastWarning = "Stopped — not enough free space to re-encode safely."
                break
            }
            currentLabel = candidate.kind == .video ? "video" : (candidate.kind == .audio ? "audio" : "photo")

            guard let newRef = await encode(candidate), !newRef.isEmpty, newRef != candidate.ref,
                  let newURL = MediaStore.shared.storagePath(for: newRef),
                  let newBytes = (try? newURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            else {
                skip(candidate.ref)
                doneCount += 1
                continue
            }
            // A rewrite that doesn't clearly win is worse than none: every member pays a re-download
            // for nothing. Drop it and never offer this ref again.
            guard Double(newBytes) < Double(candidate.shape.bytes) * MediaOptimizationTarget.requiredShrinkFactor else {
                HavenLog.sync("reoptimize: \(candidate.ref.prefix(12)) came back no smaller (\(newBytes) vs \(candidate.shape.bytes)) — keeping the original")
                MediaStore.shared.delete(newRef)
                skip(candidate.ref)
                doneCount += 1
                continue
            }
            before += candidate.shape.bytes
            after += Int64(newBytes)
            swap[candidate.ref] = newRef
            doneCount += 1
            // Let the UI (and anything else on the main actor) breathe between items — the encode
            // itself is off-main, but content-addressing the result streams a sha-256 here.
            await Task.yield()
        }

        // Apply. Targets are re-read NOW rather than reused from the scan: minutes have passed, and
        // a post edited or retracted in the meantime must be edited against its current state, not a
        // stale copy that would silently revert the user's own change.
        var reshared = 0
        if !swap.isEmpty {
            for target in FeedStore.shared.reoptimizeTargets() where target.media.contains(where: { swap[$0] != nil }) {
                // `map` preserves order and passes everything else through untouched — including
                // synthetic `geo:` location pins, which ride in the same array and carry no bytes.
                let media = target.media.map { swap[$0] ?? $0 }
                if FeedStore.shared.applyReoptimized(target, media: media) { reshared += 1 }
            }
            FeedStore.shared.refresh()
        }

        lastSummary = swap.isEmpty
            ? "Nothing could be made smaller"
            : "\(swap.count) item\(swap.count == 1 ? "" : "s") re-shared across \(reshared) post\(reshared == 1 ? "" : "s") · "
              + "\(fmt(before)) → \(fmt(after)) (\(pct(before, after))% smaller)"
        HavenLog.sync("reoptimize: \(lastSummary ?? "")")
        if cancelRequested { lastWarning = "Stopped." }

        // Re-scan so the remaining count is honest, and so anything just rewritten drops off the
        // list (nothing references the old ref any more, so it is no longer one of my shared items).
        //
        // But HOLD THE WARNING ACROSS IT. `scan()` clears `lastWarning` (a fresh measurement
        // shouldn't inherit a stale complaint), which means this trailing re-scan would otherwise
        // wipe the two messages this run most needs to deliver — "Stopped." and "not enough free
        // space" — before `ReoptimizeMediaRow` ever renders them. A warning that is only displayed
        // for the duration of a re-scan is a warning that was never shown. A warning raised BY the
        // re-scan wins, since that one describes the state the user is looking at now.
        let raised = lastWarning
        await scan()
        if let raised, lastWarning == nil { lastWarning = raised }
    }

    /// Re-encode one blob through the SAME entry points a brand-new attachment uses — the whole
    /// point of `forceOptimize` on those two. Not a parallel encoder: when the compression targets
    /// change again, old media follows automatically.
    private func encode(_ candidate: Candidate) async -> String? {
        guard let src = MediaStore.shared.storagePath(for: candidate.ref) else { return nil }
        switch candidate.kind {
        case .video:
            // addVideo already drives MediaProcessing itself, so the shared card is live here.
            return await MediaStore.shared.addVideo(url: src, forceOptimize: true)
        case .audio:
            return await MediaStore.shared.addAudio(url: src)
        case .image:
            // addImage is synchronous and has no indicator of its own — wrap it in the SAME counted
            // store the composer uses rather than inventing a second progress mechanism.
            return await MediaProcessing.tracking("photo") {
                guard let img = MediaStore.shared.item(candidate.ref)?.image else { return nil }
                return MediaStore.shared.addImage(img, forceOptimize: true)
            }
        case .file:
            // Zip attachments are already the user's chosen archive — re-encoding them is
            // meaningless. Skip so re-optimize never invents a second copy of a file blob.
            return nil
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
                Label("Everything you've shared is already as small as it can be.",
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
        return "Shrink & re-share \(n) item\(n == 1 ? "" : "s")"
    }
    private var icon: String {
        reopt.candidates.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill"
    }
    private var foundText: String {
        let total = reopt.candidates.count
        let size = ByteCountFormatter.string(fromByteCount: reopt.pendingBytes, countStyle: .file)
        let batch = min(total, MediaReoptimizer.batchLimit)
        let legacy = reopt.candidates.filter(\.legacyByAge).count
        var s = "\(total) item\(total == 1 ? "" : "s") · \(size) currently on every member's device"
        if legacy > 0 { s += " · \(legacy) shared before Haven learned to compress" }
        if batch < total { s += ". This run does the \(batch) largest; tap again for the rest." }
        return s
    }
}
