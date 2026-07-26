import SwiftUI
import AVFoundation
import AVKit
import CoreImage
import CoreLocation
import CryptoKit
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Photos

/// Save a post's media (photo or video) into the user's Photos library.
@MainActor
enum MediaSaver {
    static func save(_ ref: String) {
        guard let m = MediaStore.shared.item(ref) else { return }
        let imageURL = MediaStore.shared.storagePath(for: ref)
        let kind = m.kind
        let videoURL = m.videoURL
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                switch kind {
                case .video:
                    if let url = videoURL { PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                case .image:
                    if let url = imageURL { PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url) }
                case .audio, .file:
                    break
                }
            } completionHandler: { _, _ in }
        }
    }
}

#if os(macOS)
/// Native macOS has no `UIVideoEditorController`, so this is a small AVFoundation trimmer:
/// preview the clip, pick a start/end with two sliders, and export the selected range to a new
/// MP4 (handed back via `onTrimmed`). Functional parity with the iOS system trim editor.
struct VideoTrimmer: View {
    let path: String
    var onTrimmed: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 16) {
            VideoPlayer(player: player)
                .frame(minWidth: 420, minHeight: 280)
                .cornerRadius(12)

            if duration > 0 {
                VStack(spacing: 10) {
                    HStack {
                        Text("Start \(timeLabel(start))").font(.caption).monospacedDigit()
                        Slider(value: $start, in: 0...duration) { editing in
                            if !editing { if start > end - 0.5 { start = max(0, end - 0.5) }; seek(start) }
                        }
                    }
                    HStack {
                        Text("End \(timeLabel(end))").font(.caption).monospacedDigit()
                        Slider(value: $end, in: 0...duration) { editing in
                            if !editing { if end < start + 0.5 { end = min(duration, start + 0.5) }; seek(end) }
                        }
                    }
                    Text("Trimmed length: \(timeLabel(max(0, end - start)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassPillButtonStyle())
                Spacer()
                Button(exporting ? "Trimming…" : "Trim") { Task { await export() } }
                    .buttonStyle(BrandButtonStyle())
                    .frame(width: 150)   // the style fills its width; pin the confirm pill's size
                    .keyboardShortcut(.defaultAction)
                    .disabled(exporting || duration == 0)
                    .opacity(exporting || duration == 0 ? 0.5 : 1)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .onAppear { load() }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }   // release decode buffers
    }

    private func load() {
        let url = URL(fileURLWithPath: path)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        Task {
            let secs = (try? await item.asset.load(.duration).seconds) ?? 0
            await MainActor.run { duration = secs.isFinite ? secs : 0; end = duration }
        }
    }

    private func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func timeLabel(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func export() async {
        guard end > start else { dismiss(); return }
        exporting = true
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim_\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            exporting = false; dismiss(); return
        }
        session.outputURL = dst
        session.outputFileType = .mp4
        session.stripIdentifyingMetadata()   // trimmed clips are shared media too
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        if session.status == .completed { onTrimmed(dst) }
        exporting = false
        dismiss()
    }
}
#elseif targetEnvironment(macCatalyst)
/// Mac Catalyst has no UIVideoEditorController; trim isn't offered there (canTrim → false).
struct VideoTrimmer: UIViewControllerRepresentable {
    let path: String
    var onTrimmed: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIViewController {
        DispatchQueue.main.async { dismiss() }
        return UIViewController()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
#else
/// The system video trimmer (UIVideoEditorController) wrapped for SwiftUI.
struct VideoTrimmer: UIViewControllerRepresentable {
    let path: String
    var onTrimmed: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard UIVideoEditorController.canEditVideo(atPath: path) else {
            DispatchQueue.main.async { dismiss() }
            return UIViewController()
        }
        let vc = UIVideoEditorController()
        vc.videoPath = path
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIVideoEditorControllerDelegate {
        let parent: VideoTrimmer
        init(_ parent: VideoTrimmer) { self.parent = parent }
        func videoEditorController(_ editor: UIVideoEditorController, didSaveEditedVideoToPath path: String) {
            parent.onTrimmed(URL(fileURLWithPath: path)); parent.dismiss()
        }
        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) { parent.dismiss() }
        func videoEditorController(_ editor: UIVideoEditorController, didFailWithError error: Error) { parent.dismiss() }
    }
}
#endif

extension AVAssetExportSession {
    /// Drop identifying metadata — GPS above all — from an exported video. EVERY video export that
    /// produces bytes we share must call this.
    ///
    /// `metadata = []` alone is NOT enough, and that was the actual bug: it governs only the movie's
    /// top-level metadata, while AVFoundation independently copies the source's location into the
    /// output's QuickTime **UserData `loci` box**. Verified with exiftool — an export with
    /// `metadata = []` still carried `UserData:LocationInformation` with the exact capture
    /// coordinates. `metadataItemFilter = .forSharing()` is the knob that actually removes it (it's
    /// Apple's own "safe to hand to someone else" filter: strips location/device/capture identifiers,
    /// keeps benign descriptive tags). Both are set here — the filter does the real work, and the
    /// empty array keeps us from ever propagating movie-level metadata a future filter might allow.
    func stripIdentifyingMetadata() {
        metadata = []
        metadataItemFilter = .forSharing()
    }
}

enum MediaKind: String {
    case image, video, audio, file
    var ext: String {
        switch self {
        case .image: return "jpg"
        case .video: return "mp4"
        case .audio: return "m4a"
        case .file:  return "zip"
        }
    }
    /// The kind is encoded in the ref prefix so a recipient knows how to render it. Matches
    /// `haven-p2p::mediaref::MediaKind::prefix` and Android's `LocalMedia` byte-for-byte.
    var prefix: String {
        switch self {
        case .image: return "img_"
        case .video: return "vid_"
        case .audio: return "aud_"
        case .file:  return "file_"
        }
    }
    /// The kind is encoded in the ref prefix so a recipient knows how to render it.
    init?(ref: String) {
        if ref.hasPrefix("img_") { self = .image }
        else if ref.hasPrefix("vid_") { self = .video }
        else if ref.hasPrefix("aud_") { self = .audio }
        else if ref.hasPrefix("file_") { self = .file }
        else { return nil }
    }
}

/// A piece of attached media held locally. Bytes are persisted to disk (so they
/// survive restarts) and are sealed E2E before they ever leave the device.
struct MediaItem: Identifiable {
    let id: String
    let kind: MediaKind
    let image: PlatformImage?   // the photo, or a video's poster frame
    let videoURL: URL?
}

/// Persistent, content-ref'd media store. Refs encode the kind (img_/vid_/aud_) so a
/// recipient who receives the bytes can reconstruct the item. Files live under
/// Application Support/haven-media so they survive app restarts and updates.
@MainActor
final class MediaStore: ObservableObject {
    static let shared = MediaStore()

    /// Decoded media is held in an NSCache, NOT a plain dictionary — a dictionary held every image ever
    /// viewed at full resolution (~26 MB each at 2560px) forever, which walked the app past the
    /// per-process memory limit and got it jetsam-killed (~3.5 GB OOM). NSCache bounds total decoded
    /// bytes, auto-evicts least-recently-used entries, and dumps everything on a memory warning. The
    /// bytes are always on disk under haven-media, so an eviction just means the next `item(_:)`
    /// re-decodes from the file — cheap, and bounded.
    private final class Boxed { let item: MediaItem; init(_ i: MediaItem) { item = i } }
    private let cache: NSCache<NSString, Boxed> = {
        let c = NSCache<NSString, Boxed>()
        c.totalCostLimit = 96 * 1024 * 1024   // ~96 MB of full-res media resident (the feed uses thumbnails;
                                              // full images are only the zoom viewer), then evict LRU
        return c
    }()
    private func cacheGet(_ ref: String) -> MediaItem? { cache.object(forKey: ref as NSString)?.item }
    private func cachePut(_ ref: String, _ item: MediaItem) {
        cache.setObject(Boxed(item), forKey: ref as NSString, cost: Self.decodedCost(item))
        // Persist the shape as soon as we have pixels (a photo, or a video's poster frame). The NSCache
        // evicts under pressure, but the feed still needs this ref's aspect to lay its card out at the
        // right height on the FIRST pass — otherwise the card resizes when the poster reloads and shoves
        // everything below it down the screen.
        if let s = item.image?.size, s.width > 0, s.height > 0 { recordPixelSize(ref, s) }
    }
    private func cacheRemove(_ ref: String) { cache.removeObject(forKey: ref as NSString) }
    /// Approximate decoded RAM footprint (≈4 bytes/pixel) so NSCache's cost accounting keeps total
    /// resident bytes under the limit. Audio/video shells (no decoded image) are near-free.
    private static func decodedCost(_ item: MediaItem) -> Int {
        guard let s = item.image?.size, s.width > 0, s.height > 0 else { return 4096 }
        return max(4096, Int(s.width * s.height) * 4)
    }
    /// Drop all decoded media from memory (factory reset, or to proactively relieve pressure).
    func clearMemoryCache() { cache.removeAllObjects(); thumbCache.removeAllObjects() }

    // MARK: - Captured location (opt-in)

    /// GPS coords extracted from a picked photo/video at import, kept on-device only. The raw
    /// metadata is stripped from the shared bytes; this coordinate is shared ONLY if the author
    /// flips the per-post "Show location" toggle (then it's reverse-geocoded into a `geo:` pin).
    private var locations: [String: CLLocationCoordinate2D] = [:]
    func setLocation(_ c: CLLocationCoordinate2D, for ref: String) { locations[ref] = c }
    func location(for ref: String) -> CLLocationCoordinate2D? { locations[ref] }
    /// Whether any of these refs carries a captured location (drives the compose toggle's visibility).
    func anyLocated(_ refs: [String]) -> Bool { refs.contains { locations[$0] != nil } }

    /// Pull a GPS coordinate out of raw image bytes (EXIF GPS dictionary), or nil if absent.
    /// `nonisolated` so picker decode queues can read EXIF without hopping to the MainActor.
    nonisolated static func gpsCoordinate(fromImageData data: Data) -> CLLocationCoordinate2D? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return CLLocationCoordinate2D(latitude: latRef == "S" ? -lat : lat,
                                      longitude: lonRef == "W" ? -lon : lon)
    }

    /// The on-disk media directory. `nonisolated` so the orphan sweep (which walks the whole dir with
    /// FileManager only) can run off the main actor without hopping through the shared instance.
    nonisolated static var storageDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("haven-media", isDirectory: true)
        // Protect media at rest to match the in-transit E2EE: files created here inherit
        // "until first user authentication" (so the NSE/background can still read), not the weaker
        // process default. Re-applied each access so an already-existing dir gets upgraded too.
        #if os(iOS)
        try? FileManager.default.createDirectory(
            at: d, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: d.path)
        #else
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        #endif
        return d
    }
    private var dir: URL { Self.storageDir }
    private func fileURL(_ ref: String) -> URL? {
        guard let kind = MediaKind(ref: ref) else { return nil }
        return dir.appendingPathComponent("\(ref).\(kind.ext)")
    }

    // MARK: - Content addressing
    //
    // A ref is the sha-256 of the media's PLAINTEXT, so the bytes a relay hands back can be held to
    // account for the ref the signed post named. This store used to mint `img_<UUID()>` — a random
    // name that says nothing about the bytes — and then rendered whatever arrived under it. A relay
    // operator (always an ordinary circle member) could therefore PUT one member's sealed photo at
    // another member's ref and every client would render it: the seal opens, the signature verifies,
    // and nothing ever compared the bytes to the ref. Signing the post but not binding its media
    // meant whoever stored the bytes chose what the post showed.
    //
    // The digest is over the plaintext, not the sealed bytes, because sealing is non-deterministic
    // (fresh key + nonce per seal, recipients vary with the roster) — a ciphertext address would
    // change on every re-seal and differ per device, orphaning the media its own post points at.
    // Plaintext hashing gives one stable address per photo on every platform. This mirrors
    // `haven-p2p::mediaref` exactly, and Android/desktop have minted these same sha-256 refs since
    // they shipped; iOS was the odd one out.

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stream a file's digest in 1 MB windows — a 600 MB video must never land in a `Data` whole
    /// (that single allocation is what traps in `__DataStorage.init`).
    nonisolated static func sha256Hex(fileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            // Pool per iteration: `read` retains its buffers, which is what walked a strip loop
            // through the whole file's worth of RAM.
            autoreleasepool { hasher.update(data: chunk) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The ref to publish for these bytes.
    nonisolated static func contentRef(_ kind: MediaKind, _ data: Data) -> String {
        "\(kind.prefix)\(sha256Hex(data))"
    }
    /// The ref to publish for a file already on disk (streamed).
    nonisolated static func contentRef(_ kind: MediaKind, fileAt url: URL) -> String? {
        sha256Hex(fileAt: url).map { "\(kind.prefix)\($0)" }
    }

    /// The ref's unique part with any kind prefix stripped — the content hash. NOT a storage key:
    /// it's kind-blind, so `img_X` and `vid_X` reduce to the same string (`fileURL` keeps the whole
    /// ref, kind included, which is what stops a photo and a video sharing one file).
    nonisolated static func bareId(_ ref: String) -> String {
        for p in ["img_", "vid_", "aud_", "file_", "v:", "i:", "a:"] where ref.hasPrefix(p) {
            return String(ref.dropFirst(p.count))
        }
        return ref
    }

    /// Can bytes be checked against this ref? True only for content addresses. The UUID refs this
    /// store used to mint carry no digest, so there is nothing to check and they are taken on faith
    /// — see `verify`.
    nonisolated static func isVerifiable(_ ref: String) -> Bool {
        guard !isSynthetic(ref) else { return false }
        let id = bareId(ref)
        return id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Do these bytes account for this ref? This is the check that makes a signed post's media
    /// actually its own.
    ///
    /// Legacy refs pass: real posts out there name `img_<uuid>`, there is no digest in them to hold
    /// bytes to, and the only alternative to accepting them is every existing post's media going
    /// blank. That hole is closed by construction — minting is content-addressed now, so the
    /// unverifiable population is exactly what was already minted, and it only shrinks. It also
    /// can't be used to downgrade: the ref comes from the author-signed post, so nobody can swap a
    /// verifiable ref for a legacy-shaped one without the author's key.
    nonisolated static func verify(_ ref: String, _ data: Data) -> Bool {
        guard isVerifiable(ref) else { return true }
        return sha256Hex(data) == bareId(ref)
    }
    /// `verify` for a plaintext file, streamed. An unreadable file under a verifiable ref fails closed.
    nonisolated static func verify(_ ref: String, fileAt url: URL) -> Bool {
        guard isVerifiable(ref) else { return true }
        return sha256Hex(fileAt: url) == bareId(ref)
    }

    /// A scratch file inside the protected media dir, for producing media before its ref is known.
    /// Content addressing inverts the old order: the bytes have to exist before they can be named.
    private func scratchURL(_ ext: String) -> URL {
        dir.appendingPathComponent("mint_\(UUID().uuidString).\(ext)")
    }

    /// Move a just-produced file to its content address and return the ref. The scratch file is
    /// always consumed. An identical file already in place is left alone — same bytes, same ref,
    /// so the put is idempotent (which is the other thing content addressing buys).
    private func adoptProduced(_ kind: MediaKind, from scratch: URL) -> String? {
        guard let ref = Self.contentRef(kind, fileAt: scratch), let dst = fileURL(ref) else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: scratch)
            return ref
        }
        do { try FileManager.default.moveItem(at: scratch, to: dst) } catch {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        return ref
    }

    /// Total bytes of synced media on disk (the `haven-media` dir), and the file count. Walked lazily
    /// off the caller's thread by the Settings screen so it never blocks. Photos/videos/audio dominate;
    /// the small event log lives elsewhere and isn't counted here.
    nonisolated func diskUsage() -> (bytes: Int64, files: Int) { Self.diskUsageOnDisk() }

    /// Pure directory walk — no MainActor / shared instance required.
    nonisolated static func diskUsageOnDisk() -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        let dir = storageDir
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                       options: [.skipsHiddenFiles]) else { return (0, 0) }
        var total: Int64 = 0
        var count = 0
        for url in items {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size); count += 1
            }
        }
        return (total, count)
    }

    /// One stored blob on disk, keyed by its on-disk STEM (the ref for `img_`/`vid_`/`aud_` files, the
    /// bare hash for legacy/cross-platform files). Used by the cleanup screen and the local-limit sweep.
    /// Sendable so it crosses off the main actor.
    struct StoredBlob: Sendable, Identifiable {
        var id: String { ref }
        let ref: String        // on-disk stem — a real media ref (kind-prefixed) or a bare content hash
        let bytes: Int64
        let mtime: Date
    }

    /// Every stored media blob with its size + mtime, for the size-sorted cleanup screen and the
    /// local-limit sweep. Skips in-flight scratch (`mint_*`, `incoming_*.part`) and hidden files.
    /// `nonisolated static` so the walk runs off the main actor.
    nonisolated static func storedBlobs() -> [StoredBlob] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [StoredBlob] = []
        for url in items {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            if vals?.isDirectory == true { continue }
            let name = url.lastPathComponent
            if name.hasPrefix("mint_") || name.hasPrefix("incoming_") { continue }   // producing / reassembling
            let stem = url.deletingPathExtension().lastPathComponent
            out.append(StoredBlob(ref: stem,
                                  bytes: Int64(vals?.fileSize ?? 0),
                                  mtime: vals?.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// The client sibling of the relay's retention: evict this device's cached blobs by AGE then SIZE
    /// (oldest first) until under the caps. Unlike the orphan sweep, a blob a live event still
    /// references IS eligible here — it just becomes a re-downloadable placeholder (the caller records
    /// such refs in the evicted set so they aren't auto-refetched). `pinnedStems` (device pins) and
    /// composer-staged/in-flight media (fresh mtime, grace window) are never touched. `inUse` is passed
    /// only to decide which evicted refs to record. Returns freed bytes/files + the referenced refs to
    /// mark evicted (keyed by on-disk stem → last-known size). `nonisolated static` — runs off-main.
    nonisolated static func performLimitSweep(maxDays: Int, maxGB: Int,
                                              pinnedStems: Set<String>, inUse: Set<String>,
                                              graceSeconds: TimeInterval = 48 * 3600) -> (bytes: Int64, files: Int, evict: [String: Int64]) {
        guard maxDays > 0 || maxGB > 0 else { return (0, 0, [:]) }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return (0, 0, [:]) }
        struct Cand { let url: URL; let stem: String; let bytes: Int64; let mtime: Date }
        let freshCutoff = Date().addingTimeInterval(-graceSeconds)
        var cands: [Cand] = []
        var pinnedBytes: Int64 = 0
        for url in items {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            if vals?.isDirectory == true { continue }
            let name = url.lastPathComponent
            if name.hasPrefix("mint_") || name.hasPrefix("incoming_") || name.hasPrefix(".") { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let bytes = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? Date()
            if pinnedStems.contains(stem) { pinnedBytes += bytes; continue }   // device-pinned: never evict
            if mtime > freshCutoff { continue }                               // too fresh to judge
            cands.append(Cand(url: url, stem: stem, bytes: bytes, mtime: mtime))
        }
        var freed: Int64 = 0, files = 0
        var evict: [String: Int64] = [:]
        var deleted = Set<URL>()
        func remove(_ c: Cand) {
            guard !deleted.contains(c.url) else { return }
            try? fm.removeItem(at: c.url); deleted.insert(c.url)
            freed += c.bytes; files += 1
            if !storedStems(for: c.stem).isDisjoint(with: inUse) { evict[c.stem] = c.bytes }
        }
        if maxDays > 0 {
            let ageCutoff = Date().addingTimeInterval(-Double(maxDays) * 86_400)
            for c in cands where c.mtime < ageCutoff { remove(c) }
        }
        if maxGB > 0 {
            let cap = Int64(maxGB) * 1_000_000_000
            let survivors = cands.filter { !deleted.contains($0.url) }.sorted { $0.mtime < $1.mtime }  // oldest first
            var total = pinnedBytes + survivors.reduce(0) { $0 + $1.bytes }
            var i = 0
            while total > cap, i < survivors.count { remove(survivors[i]); total -= survivors[i].bytes; i += 1 }
        }
        return (freed, files, evict)
    }

    // MARK: - Deletion & GC
    //
    // Blobs never deleted themselves: `purge_expired` drops the EVENTS, but the bytes under
    // haven-media lived forever (and unsent/expired posts left orphans). Deletion is ref-driven —
    // the engine hands back the purged events' media refs, the caller subtracts anything still
    // referenced by a live event in ANY circle, and what's left is removed here.

    /// Every on-disk basename STEM a ref could be stored under. Files here are `<ref>.<ext>` for
    /// kind-prefixed refs; the legacy single-letter schemes normalize onto the modern prefix and the
    /// bare hash is included defensively (other platforms store under it, and refs may arrive either
    /// way). Used both to DELETE a ref's file(s) and to build the sweep's keep-set — one definition,
    /// so the two can't drift.
    nonisolated static func storedStems(for ref: String) -> Set<String> {
        let id = bareId(ref)
        var out: Set<String> = [ref, id]
        if ref.hasPrefix("v:") { out.insert("vid_\(id)") }
        if ref.hasPrefix("i:") { out.insert("img_\(id)") }
        if ref.hasPrefix("a:") { out.insert("aud_\(id)") }
        if ref.hasPrefix("file_") { out.insert("file_\(id)") }
        return out
    }

    /// Remove a ref's blob from disk (every stem × every media ext, so a legacy-schemed duplicate
    /// goes too) and evict its decoded copies from memory. Only call with refs no live event
    /// references — the caller owns the in-use check. Returns the bytes freed.
    @discardableResult
    func delete(_ ref: String) -> Int64 {
        guard !Self.isSynthetic(ref) else { return 0 }
        let fm = FileManager.default
        var freed: Int64 = 0
        for stem in Self.storedStems(for: ref) {
            for ext in ["jpg", "mp4", "m4a", "zip"] {
                let url = dir.appendingPathComponent("\(stem).\(ext)")
                guard fm.fileExists(atPath: url.path) else { continue }
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    freed += Int64(size)
                }
                try? fm.removeItem(at: url)
            }
        }
        cacheRemove(ref)
        sizeCache.removeValue(forKey: ref)
        // NSCache can't evict by key prefix and the thumb keys are "<ref>@<bucket>" — drop them all;
        // thumbnails re-derive from disk, and deletion is rare (expiry/sweep), not a hot path.
        thumbCache.removeAllObjects()
        return freed
    }

    /// Delete every file whose stem no live event references (the caller passes the in-use stem set
    /// built from every circle's feed + comments + scheduled posts). A GRACE window skips anything
    /// modified recently: media staged in a composer but not yet posted, an in-flight `incoming_*.part`
    /// reassembly, and a `mint_*` scratch mid-produce all have fresh mtimes and no referencing event
    /// yet — age, not referencedness, is what makes those safe to judge. Static + nonisolated so the
    /// walk runs off the main actor; the caller clears the in-memory caches afterwards.
    nonisolated static func performOrphanSweep(inUse: Set<String>, graceSeconds: TimeInterval = 48 * 3600) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            // NOT skipsHiddenFiles: the upload seals are `.seal-<ref>.tmp`, and a leading dot meant
            // no sweep in the app ever saw them. One 642 MB seal sat on a device for two days that
            // way. They matter more now that a FAILED upload deliberately keeps its seal so the retry
            // resumes against identical bytes — without a sweep that is an unbounded pile.
            options: []) else { return (0, 0) }
        let cutoff = Date().addingTimeInterval(-graceSeconds)
        var bytes: Int64 = 0
        var files = 0
        for url in items {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            if vals?.isDirectory == true { continue }
            if let m = vals?.contentModificationDate, m > cutoff { continue }   // too fresh to judge
            let stem = url.deletingPathExtension().lastPathComponent
            if inUse.contains(stem) { continue }
            // Past the grace window with no referencing event anywhere: an orphan. This also retires
            // stale mint_/incoming_ scratch a crash left behind (their stems are never in a feed).
            bytes += Int64(vals?.fileSize ?? 0)
            files += 1
            try? fm.removeItem(at: url)
        }
        return (bytes, files)
    }

    /// Reclaim leaked produce/reassembly scratch promptly. A `mint_*` (media being sealed for upload)
    /// or `incoming_*.part` (chunks being reassembled) is deleted on the normal path, but an
    /// interrupted operation orphans it: the app killed mid-export of a big video, or a download that
    /// keeps failing to reassemble — and each failed reassembly ATTEMPT mints a fresh `incoming_<uuid>`,
    /// so they accumulate. Nothing removes them promptly — the orphan sweep is weekly with a 48h grace,
    /// and the cleanup screen hides scratch entirely — so they surface as gigabytes of unaccountable
    /// used space (`diskUsage` counts them; `storedBlobs`/Manage-media does not). Anything WRITTEN in
    /// the last `grace` may be a live operation and is left alone; scratch stems are UUIDs, never a real
    /// ref, so no feed scan is needed. Cheap — safe to run at every launch.
    @discardableResult
    nonisolated static func sweepStaleScratch(grace: TimeInterval = 3600) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return (0, 0) }
        let cutoff = Date().addingTimeInterval(-grace)
        // Partials belonging to a RESUMABLE transfer are spared: they are 99%-complete downloads
        // waiting for the rest, not leaked scratch. Deleting them was the second half of why large
        // media never arrived — the transfer survived the relaunch in principle, and then this sweep
        // threw the bytes away. Spared until abandoned (no progress in `ReassemblyStore.expiry`),
        // after which they expire here so they can't accumulate either.
        let live = ReassemblyStore.liveParts()
        let abandoned = Date().timeIntervalSince1970 - ReassemblyStore.expiry
        var bytes: Int64 = 0
        var files = 0
        for url in items {
            let name = url.lastPathComponent
            // `.seal-` gets a much longer grace than produce/reassembly scratch: a seal is kept ON
            // PURPOSE between upload attempts (see SharedStore.backup), and `backup` itself remakes
            // one older than 24h. Reclaim past that, so an abandoned upload can't hoard its seal.
            let isSeal = name.hasPrefix(".seal-")
            guard isSeal || name.hasPrefix("mint_") || name.hasPrefix("incoming_") else { continue }
            if isSeal {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if let m = vals?.contentModificationDate, Date().timeIntervalSince(m) < 24 * 3600 { continue }
                bytes += Int64(vals?.fileSize ?? 0)
                files += 1
                try? fm.removeItem(at: url)
                continue
            }
            if let progressed = live[name], progressed > abandoned { continue }   // live reassembly
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let m = vals?.contentModificationDate, m > cutoff { continue }   // still being written
            bytes += Int64(vals?.fileSize ?? 0)
            files += 1
            try? fm.removeItem(at: url)
        }
        return (bytes, files)
    }

    /// `forceOptimize` ignores the circle's auto-optimize setting. Used by the re-optimize run, whose
    /// entire premise is that the setting was OFF (or the old encoder was in place) when these bytes
    /// were first shared — honouring it there would make the button a no-op for exactly the media it
    /// exists to fix.
    @discardableResult
    func addImage(_ image: PlatformImage, forceOptimize: Bool = false) -> String {
        // Optimize: downscale very large photos + compress, so they're light to send —
        // but keep it high-res (longest edge up to 2560, well above 1080p).
        let optimize = forceOptimize || CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        // Bake EXIF orientation into the pixels: Android's BitmapFactory ignores the orientation tag,
        // so a portrait iPhone photo arrives sideways unless we normalize it to .up here.
        // Auto-optimize → 2048px JPEG @ 70% (small + universally compatible). Off → original quality.
        let img = Self.normalizedUp(optimize ? Self.downscale(image, maxDimension: Self.optimizedImageMaxDimension) : image)
        let quality: CGFloat = optimize ? Self.optimizedImageQuality : 0.95
        // The ref is minted from the ENCODED bytes we actually store and send — the same bytes a
        // recipient will hash — so it has to be produced before the ref exists.
        guard let data = img.jpegData(compressionQuality: quality) else {
            // No bytes, no content address. Keep the old shape (a ref is always returned) but make
            // it obviously kind-tagged and unfetchable rather than minting a bogus address.
            return "img_\(UUID().uuidString)"
        }
        let ref = Self.contentRef(.image, data)
        if let url = fileURL(ref) { try? data.write(to: url) }
        cachePut(ref, MediaItem(id: ref, kind: .image, image: img, videoURL: nil))
        // Mint the tiny thumb companion (~256px, ≤32KB) for photos worth one: recipients render it
        // blurred behind the loading placeholder long before the full bytes land. The pairing
        // marker (`thumb:<ref>:<thumbRef>`) joins the SIGNED media list at post time — see
        // FeedStore.withThumbMarkers — so old clients simply ignore it (synthetic scheme).
        if data.count > 64 * 1024 { mintThumbCompanion(for: ref, from: img) }
        return ref
    }

    // MARK: - Thumb companions (compose-time tiny previews — see MediaVariants `thumb:`)

    private static let thumbCompanionKey = "haven.media.thumbCompanions"
    private var thumbCompanions: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: MediaStore.thumbCompanionKey) as? [String: String]) ?? [:]
    }()

    /// The thumb companion ref minted for a photo at compose time, if one exists.
    func thumbCompanion(_ ref: String) -> String? { thumbCompanions[ref] }

    /// Encode + store a ≤32KB, ~256px JPEG companion for `ref` and remember the pairing. Skipped
    /// silently when the encode can't get small enough — a "thumb" that isn't tiny is just waste.
    private func mintThumbCompanion(for ref: String, from image: PlatformImage) {
        guard thumbCompanions[ref] == nil else { return }
        let small = Self.downscale(image, maxDimension: 256)
        var quality: CGFloat = 0.6
        guard var data = small.jpegData(compressionQuality: quality) else { return }
        while data.count > 32 * 1024, quality > 0.25 {
            quality -= 0.15
            guard let d = small.jpegData(compressionQuality: quality) else { break }
            data = d
        }
        guard data.count <= 48 * 1024 else { return }
        let thumbRef = Self.contentRef(.image, data)
        if let url = fileURL(thumbRef) { try? data.write(to: url) }
        thumbCompanions[ref] = thumbRef
        if thumbCompanions.count > 2000 {   // bound: old pairings only matter until the post is sealed
            thumbCompanions = Dictionary(uniqueKeysWithValues: Array(thumbCompanions.suffix(1000)))
        }
        UserDefaults.standard.set(thumbCompanions, forKey: Self.thumbCompanionKey)
    }

    /// Async because optimizing transcodes the video (AVAssetExportSession). Without
    /// this, full-size originals (often 50–200MB) are too big to seal + send P2P.
    ///
    /// `forceOptimize` is the re-optimize run re-driving media it ALREADY shared through this exact
    /// path — same encoder, same fallback ladder, same content-addressing. One implementation, so a
    /// future change to how Haven compresses automatically reaches old media too.
    ///
    /// Always cuts a poster still (uploaded as a separate `img_` so super-data-saver clients can
    /// render the card without the video bytes). When auto-optimize is on (default) the playable
    /// ref is the compressed copy; when the user also wants the camera original (`sendOriginal` or
    /// auto-optimize OFF), that rides alongside as an `orig:` companion — see `MediaVariants`.
    @discardableResult
    func addVideo(url src: URL, forceOptimize: Bool = false) async -> String {
        let bundle = await prepareVideo(url: src, forceOptimize: forceOptimize)
        return bundle.videoRef
    }

    /// Full video attach result: playable ref + optional poster/original + the media-array slice
    /// (including synthetic markers) a post or DM should publish. Prefer this over `addVideo` at
    /// compose time so the poster and original companions actually leave the device.
    struct PreparedVideo: Sendable {
        /// Playable optimized (or passthrough) video ref. Empty when the clip was refused.
        let videoRef: String
        let posterRef: String?
        let originalRef: String?
        /// Ready-to-append media list: poster, video, original, and the synthetic pairing markers.
        let mediaRefs: [String]
        var isEmpty: Bool { videoRef.isEmpty }
    }

    /// Encode + poster + optional original for a freshly attached video. See `addVideo` for the
    /// encoder ladder; this is the compose-time entry point that returns everything the post needs.
    func prepareVideo(url src: URL, forceOptimize: Bool = false,
                      alsoOriginal: Bool? = nil) async -> PreparedVideo {
        let empty = PreparedVideo(videoRef: "", posterRef: nil, originalRef: nil, mediaRefs: [])
        // Transcode into scratch first: the ref is the digest of the FINAL bytes, so it can only be
        // known once the export has produced them.
        let scratch = scratchURL("mp4")
        try? FileManager.default.removeItem(at: scratch)
        var ok = false
        // Tell the UI something is happening. Attaching a video takes tens of seconds; without this
        // the composer sits blank and "working on it" is indistinguishable from "it didn't take".
        MediaProcessing.shared.begin("video")
        defer { MediaProcessing.shared.end() }
        // HARD LIMIT first: no amount of encoding makes a feature film reasonable to hand a circle,
        // and every member pays to store and move whatever this produces.
        //
        // Not applied when re-optimizing: that clip is ALREADY shared and already costing the circle
        // its full size. Refusing to shrink it because it is long leaves everyone paying the larger
        // bill — the limit governs what you may newly hand a circle, not what you may improve.
        if !forceOptimize, let dur = try? await AVURLAsset(url: src).load(.duration),
           dur.seconds > Self.maxVideoSeconds {
            HavenLog.sync("video add: REJECTED — \(Int(dur.seconds))s exceeds the \(Int(Self.maxVideoSeconds))s limit")
            return empty
        }
        let wantOptimize = forceOptimize || CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        // Always try to produce an optimized playable when possible. Auto-optimize OFF used to skip
        // the encoder entirely and ship the camera file as the only ref — recipients on data saver
        // then had no small copy, and "show original" had nothing to distinguish. Now the small copy
        // is the playable ref; the camera file rides as an optional companion.
        // Bitrate-controlled H.264 first — the only path that actually targets a SIZE. The preset
        // exports below cap dimensions and choose their own (much higher) bitrate, so they stay as
        // fallbacks for anything AVAssetWriter can't handle rather than the normal route.
        ok = await VideoEncoder.encode(src, to: scratch)
        if ok {
            HavenLog.sync("video add: encoded 1080p H.264 @ \(VideoEncoder.videoBitrate / 1_000_000)Mbps")
        } else {
            try? FileManager.default.removeItem(at: scratch)
            HavenLog.sync("video add: bitrate encode FAILED — falling back to the preset export")
        }
        if !ok {
            // Auto-optimize (default): re-encode to 1080p H.264 with a faststart moov atom — small and
            // universally playable, including on Androids that can't decode the iPhone's native HEVC.
            ok = await Self.optimizeVideo(src, to: scratch)
            // A failed 1080p export used to fall straight through to the passthrough remux below —
            // which keeps the ORIGINAL resolution and bitrate. So with auto-optimize ON and an export
            // that failed for any ordinary reason (app backgrounded mid-export, low disk, a codec
            // AVFoundation won't take), we silently shipped a 600 MB 4K clip while the user believed
            // it was being shrunk. Try a smaller preset before giving up: 720p is still a perfectly
            // good story/post, and it is enormously better than uploading the original.
            if !ok {
                try? FileManager.default.removeItem(at: scratch)
                ok = await Self.optimizeVideo(src, to: scratch, preset: AVAssetExportPreset960x540)
                HavenLog.sync("video optimize: 1080p export failed, 720p retry \(ok ? "succeeded" : "ALSO FAILED")")
            }
        }
        // Encoder failed entirely: share in the ORIGINAL format + quality (no transcode). Still do a
        // lossless passthrough remux to strip GPS/device metadata AND move the moov atom to the front
        // (faststart), so playback starts fast — neither changes the codec or quality.
        if !ok {
            try? FileManager.default.removeItem(at: scratch)
            ok = await Self.stripVideoMetadata(src, to: scratch)
        }
        // LAST RESORT — raw bytes, metadata and all. Only reachable when BOTH exports above failed,
        // i.e. AVFoundation can't export the asset at all; the alternative is a post whose video is
        // simply missing. This is the one path that can still carry the source's GPS, so it stays a
        // fallback and must never become the ordinary route.
        if !ok {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.copyItem(at: src, to: scratch)
        }
        guard let ref = adoptProduced(.video, from: scratch), let dst = fileURL(ref) else {
            // A ref minted from a UUID rather than the bytes names a file that does not exist. The post
            // that carries it can never upload (nothing to send), never render (no video), and pins its
            // upload indicator forever — a ghost post that looks like a stuck transfer.
            HavenLog.sync("video add: export produced NOTHING addressable — this post will have no playable video")
            return empty
        }
        // What actually shipped. Auto-optimize failing quietly and passing the original through is the
        // difference between a 20 MB upload and a 600 MB one, and until now nothing recorded which
        // happened — the only visible symptom was an upload that never finished.
        let outBytes = (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let inBytes = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        HavenLog.sync("video add: optimize=\(wantOptimize) \(inBytes / 1_048_576)MB → \(outBytes / 1_048_576)MB ref=\(ref.prefix(12))")
        let posterImage = Self.poster(for: dst)
        cachePut(ref, MediaItem(id: ref, kind: .video, image: posterImage, videoURL: dst))

        // Always cut a poster JPEG from the playable file and store it as its own content-addressed
        // image. Super data saver (and Places) can then render the still without downloading the
        // video; the marker ties them together for "which poster goes with this video".
        var posterRef: String? = nil
        if let posterImage {
            posterRef = addImage(posterImage, forceOptimize: true)
        }

        // Keep the camera original when the user asked for it, or when auto-optimize is off (they
        // explicitly want the pristine file available). Strip metadata first so GPS never rides
        // along. Skip when the "optimized" ref is already the same bytes (encode failed → passthrough).
        let wantOriginal = alsoOriginal
            ?? (SettingsStore.shared.sendOriginal || !wantOptimize)
        var originalRef: String? = nil
        if wantOriginal, !forceOptimize {
            let origScratch = scratchURL("mp4")
            try? FileManager.default.removeItem(at: origScratch)
            var origOk = await Self.stripVideoMetadata(src, to: origScratch)
            if !origOk {
                try? FileManager.default.removeItem(at: origScratch)
                try? FileManager.default.copyItem(at: src, to: origScratch)
                origOk = FileManager.default.fileExists(atPath: origScratch.path)
            }
            if origOk, let oRef = adoptProduced(.video, from: origScratch), oRef != ref,
               let oDst = fileURL(oRef) {
                cachePut(oRef, MediaItem(id: oRef, kind: .video, image: Self.poster(for: oDst), videoURL: oDst))
                originalRef = oRef
                HavenLog.sync("video add: original companion ref=\(oRef.prefix(12))")
            } else {
                try? FileManager.default.removeItem(at: origScratch)
            }
        }

        let mediaRefs = MediaVariants.composeVideoMedia(poster: posterRef, optimized: ref, original: originalRef)
        return PreparedVideo(videoRef: ref, posterRef: posterRef, originalRef: originalRef, mediaRefs: mediaRefs)
    }

    /// Zip one or more files/folders into a `file_` media ref for posts and DMs.
    @discardableResult
    func addFileArchive(urls: [URL], name: String = "attachment") -> String {
        guard let zipURL = FileArchive.zip(urls, preferredName: name) else {
            HavenLog.sync("file add: zip failed or empty")
            return ""
        }
        defer { try? FileManager.default.removeItem(at: zipURL) }
        guard let ref = adoptProduced(.file, from: zipURL) else {
            // adoptProduced moves the file; if it failed the defer still cleans the temp.
            HavenLog.sync("file add: adopt failed")
            return ""
        }
        // Re-point: adoptProduced moved zipURL → storage; cache a file shell (no image/video).
        if let dst = fileURL(ref) {
            cachePut(ref, MediaItem(id: ref, kind: .file, image: nil, videoURL: dst))
        }
        HavenLog.sync("file add: ref=\(ref.prefix(12))")
        return ref
    }

    /// Single-file convenience (already a zip, or any blob we store as `file_`).
    @discardableResult
    func addFile(url src: URL) -> String {
        // If it's already a zip, store as-is; otherwise wrap the single file in a zip so the
        // on-disk extension and the MediaKind stay consistent for every recipient.
        if src.pathExtension.lowercased() == "zip" {
            let scratch = scratchURL("zip")
            try? FileManager.default.removeItem(at: scratch)
            do { try FileManager.default.copyItem(at: src, to: scratch) } catch { return "" }
            guard let ref = adoptProduced(.file, from: scratch), let dst = fileURL(ref) else { return "" }
            cachePut(ref, MediaItem(id: ref, kind: .file, image: nil, videoURL: dst))
            return ref
        }
        return addFileArchive(urls: [src], name: src.deletingPathExtension().lastPathComponent)
    }

    /// Remux a video to drop its metadata (location, device, timestamps) without re-encoding.
    static func stripVideoMetadata(_ src: URL, to dst: URL) async -> Bool {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        export.outputURL = dst
        // .mp4 (not .mov/QuickTime): Android's MediaPlayer reliably plays MP4; some builds choke on MOV.
        export.outputFileType = .mp4
        export.stripIdentifyingMetadata()   // no location/maker metadata travels with shared media
        // FASTSTART: move the moov atom to the FRONT of the file. Android's VideoView/MediaPlayer needs the
        // moov early to initialize — a moov-at-the-end file (AVFoundation's default) often won't play or
        // stalls. This is a lossless container rewrite (no re-encode), so it's safe even for "share original".
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        return export.status == .completed
    }

    /// What "auto-optimize" actually targets for a still.
    ///
    /// Was 2048px @ 0.70. A phone screen is ~1200px wide and these are looked at in a feed, so 2048
    /// bought resolution nobody sees and made every photo roughly twice the bytes it needed. Cut to a
    /// size that is still comfortably sharp full-screen on any device.
    ///
    /// The numbers themselves live in `MediaOptimizationTarget` because two things now depend on
    /// them: this producer, and the probe that decides whether ALREADY-SHARED media needs rewriting.
    /// If those two ever held different values the re-optimize run would either re-encode its own
    /// output forever (probe stricter than producer) or never fire at all (looser). One definition,
    /// aliased here so every existing call site reads the same.
    static let optimizedImageMaxDimension = MediaOptimizationTarget.imageMaxDimension
    static let optimizedImageQuality = MediaOptimizationTarget.imageQuality

    static let storySlideMax: Double = 15.0   // max seconds per story slide
    static let storyMaxSlides = 5             // a long video splits into at most this many

    /// Split a long video into up to 5 consecutive ≤15s segments for a story. Photos and
    /// short videos pass through unchanged (returns [ref]).
    func splitStoryVideo(_ ref: String) async -> [String] {
        guard let m = item(ref), m.kind == .video, let src = storagePath(for: ref) else { return [ref] }
        let asset = AVURLAsset(url: src)
        let dur = ((try? await asset.load(.duration))?.seconds) ?? 0
        if dur <= Self.storySlideMax { return [ref] }
        let count = min(Self.storyMaxSlides, Int(ceil(dur / Self.storySlideMax)))
        var refs: [String] = []
        for i in 0..<count {
            let start = Double(i) * Self.storySlideMax
            let len = min(Self.storySlideMax, dur - start)
            if len <= 0.5 { break }
            if let seg = await exportSegment(asset: asset, start: start, duration: len) { refs.append(seg) }
        }
        return refs.isEmpty ? [ref] : refs
    }

    private func exportSegment(asset: AVAsset, start: Double, duration: Double) async -> String? {
        let scratch = scratchURL("mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else { return nil }
        export.outputURL = scratch
        export.outputFileType = .mp4
        export.stripIdentifyingMetadata()   // a story slide is shared media like any other
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        guard let newRef = adoptProduced(.video, from: scratch), let dst = fileURL(newRef) else { return nil }
        cachePut(newRef, MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        return newRef
    }

    /// Produce a muted copy of a video (audio track stripped); returns a new ref.
    func muteVideo(_ ref: String) async -> String? {
        guard let src = storagePath(for: ref) else { return nil }
        let asset = AVURLAsset(url: src)
        let comp = AVMutableComposition()
        guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let dur = (try? await asset.load(.duration)) ?? .zero
        try? compV.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vTrack, at: .zero)
        if let xf = try? await vTrack.load(.preferredTransform) { compV.preferredTransform = xf }
        let scratch = scratchURL("mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        export.outputURL = scratch
        export.outputFileType = .mp4
        export.stripIdentifyingMetadata()   // muting re-exports the movie — location rides along otherwise
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        guard let newRef = adoptProduced(.video, from: scratch), let dst = fileURL(newRef) else { return nil }
        cachePut(newRef, MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        return newRef
    }

    /// Adopt an externally-trimmed video file as a new ref.
    func importTrimmed(_ url: URL) -> String {
        let scratch = scratchURL("mp4")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.copyItem(at: url, to: scratch)
        guard let ref = adoptProduced(.video, from: scratch), let dst = fileURL(ref) else {
            return "vid_\(UUID().uuidString)"
        }
        cachePut(ref, MediaItem(id: ref, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        return ref
    }

    // MARK: - Filters

    /// Apply a `HavenFilter` to an existing media ref and return the ref of the filtered media
    /// to send. `.original` is a no-op (returns the same ref). For images the bytes are
    /// re-written in place under the same ref; for videos a new filtered ref is produced via a
    /// Core Image video composition export (the original ref is left untouched). All color math
    /// lives in `FilterEngine` — this only orchestrates storage. Returns the original ref on any
    /// failure so capture never breaks.
    @discardableResult
    func applyFilter(_ filter: HavenFilter, to ref: String) async -> String {
        guard filter != .original, let item = item(ref) else { return ref }
        switch item.kind {
        case .image:
            guard let img = item.image else { return ref }
            let filtered = FilterEngine.apply(filter, to: img)
            // A filter changes the bytes, so it changes the address: mint a NEW ref rather than
            // rewriting under the old one. Overwriting in place is exactly the thing a content
            // address forbids — the ref would name bytes that no longer exist, and a recipient
            // hashing what arrived would (rightly) reject it. Videos already worked this way.
            return storeFiltered(filtered) ?? ref
        case .video:
            return await filteredVideo(ref, filter: filter) ?? ref
        case .audio, .file:
            return ref
        }
    }

    /// Encode a filtered image under its own content address. Same optimize/quality rules as
    /// `addImage`, minus the orientation normalize (the source ref was already normalized).
    private func storeFiltered(_ image: PlatformImage) -> String? {
        let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        let img = optimize ? Self.downscale(image, maxDimension: Self.optimizedImageMaxDimension) : image
        let quality: CGFloat = optimize ? Self.optimizedImageQuality : 0.95
        guard let data = img.jpegData(compressionQuality: quality) else { return nil }
        let ref = Self.contentRef(.image, data)
        guard let url = fileURL(ref) else { return nil }
        do { try data.write(to: url) } catch { return nil }
        cachePut(ref, MediaItem(id: ref, kind: .image, image: img, videoURL: nil))
        return ref
    }

    /// Export a new video ref with `filter` baked into every frame via
    /// `AVMutableVideoComposition(asset:applyingCIFiltersWithHandler:)`. Returns the new ref, or
    /// nil on failure (caller falls back to the unfiltered ref).
    private func filteredVideo(_ ref: String, filter: HavenFilter) async -> String? {
        guard let src = storagePath(for: ref) else { return nil }
        let spec = filter.spec
        let asset = AVURLAsset(url: src)
        // Per-frame CI pipeline reusing the exact same FilterEngine math as stills.
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent()
            let output = FilterEngine.apply(spec, to: source).cropped(to: request.sourceImage.extent)
            request.finish(with: output, context: nil)
        }
        let scratch = scratchURL("mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            return nil
        }
        try? FileManager.default.removeItem(at: scratch)
        export.outputURL = scratch
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.stripIdentifyingMetadata()   // a filter changes pixels, not metadata — strip it here too
        export.videoComposition = composition
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        guard let newRef = adoptProduced(.video, from: scratch), let dst = fileURL(newRef) else { return nil }
        cachePut(newRef, MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        return newRef
    }

    /// Downscale so the longest side is at most `maxDimension` (keeps aspect ratio).
    /// Cross-platform via `PlatformImage.downscaled` (Platform.swift).
    nonisolated static func downscale(_ image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
        image.downscaled(maxDimension: maxDimension)
    }

    /// Redraw an image so its pixels are upright (`.up` orientation), instead of relying on an EXIF
    /// orientation tag. Cross-platform decoders (Android BitmapFactory) ignore that tag, so without
    /// this a portrait iPhone photo shows up rotated 90° elsewhere.
    #if canImport(UIKit)
    static func normalizedUp(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
    #else
    static func normalizedUp(_ image: PlatformImage) -> PlatformImage { image }
    #endif

    /// Transcode a video to a network-friendly 1080p H.264 MP4 (full HD, just
    /// re-encoded smaller than the camera original).
    /// True if the source video is HEVC/H.265 (which many non-Apple players can't decode).
    static func isHEVC(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descs = try? await track.load(.formatDescriptions), let desc = descs.first else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(desc)
        return codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_HEVCWithAlpha
    }

    /// Longest video Haven will accept. Not a technical limit — a product one: without it a person
    /// can hand their circle a feature film, and every member's device pays to store and move it.
    static let maxVideoSeconds: Double = 15 * 60

    static func optimizeVideo(_ src: URL, to dst: URL,
                              preset: String = AVAssetExportPreset1920x1080) async -> Bool {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            return false
        }
        export.outputURL = dst
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        // The DEFAULT share path — re-encoding does NOT drop the source's location; AVFoundation
        // copies it into the output. Without this, auto-optimize (on by default) shipped the capture
        // GPS to the circle while the non-default "share original" path was the one that tried to strip.
        export.stripIdentifyingMetadata()
        // BAKE the camera rotation into the pixels: a passthrough CI composition renders each frame in
        // its display orientation, so the output is upright with an identity transform. Otherwise the
        // rotation rides as track metadata that Android ignores → portrait iPhone video shows sideways.
        if let vTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await vTrack.load(.naturalSize),
           let xf = try? await vTrack.load(.preferredTransform), !xf.isIdentity {
            // A custom videoComposition's renderSize OVERRIDES the 1920x1080 preset's downscale — so without
            // clamping it here, a portrait 4K clip re-encodes at full 4K (the 600MB "auto-optimize didn't
            // shrink it" bug; landscape clips took the identity-transform path and downscaled fine). Fit the
            // display-oriented size within 1920x1080 (preserve aspect, never upscale) and scale each frame
            // (already display-oriented by the composition) to that renderSize.
            let disp = natural.applying(xf)
            let dw = abs(disp.width), dh = abs(disp.height)
            // Clamp to the PRESET's box, not a hardcoded 1920x1080 — otherwise a 720p retry renders at
            // 1080p and the fallback that exists to shrink a too-big export doesn't actually shrink it.
            let box: (CGFloat, CGFloat)
            switch preset {
            case AVAssetExportPreset960x540:  box = (960, 540)
            case AVAssetExportPreset1280x720: box = (1280, 720)
            default:                          box = (1920, 1080)
            }
            let fit = dw > 0 && dh > 0 ? min(1, min(box.0 / max(dw, dh), box.1 / min(dw, dh))) : 1
            func even(_ v: CGFloat) -> CGFloat { let n = (v * fit).rounded(.down); return max(2, n - n.truncatingRemainder(dividingBy: 2)) }
            let renderW = even(dw), renderH = even(dh)
            let comp = AVMutableVideoComposition(asset: asset) { request in
                let src = request.sourceImage
                let s = min(renderW / src.extent.width, renderH / src.extent.height)
                request.finish(with: src.transformed(by: CGAffineTransform(scaleX: s, y: s)), context: nil)
            }
            comp.renderSize = CGSize(width: renderW, height: renderH)
            export.videoComposition = comp
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        return export.status == .completed
    }

    /// Audio reuses `videoURL` as the file URL.
    @discardableResult
    func addAudio(url src: URL) async -> String {
        MediaProcessing.shared.begin("recording")
        defer { MediaProcessing.shared.end() }
        let scratch = scratchURL("m4a")
        try? FileManager.default.removeItem(at: scratch)
        // Re-encode to AAC rather than shipping whatever arrived. An in-app voice note is already
        // AAC so this is near-neutral, but anything shared IN can be WAV/AIFF/ALAC — uncompressed or
        // lossless, i.e. tens of megabytes of speech. Verified on real recordings before wiring:
        // 0.12 MB → 0.10 MB and 0.07 MB → 0.02 MB, duration exact.
        if !(await VideoEncoder.encodeAudio(src, to: scratch)) {
            // Falls back to the verbatim copy, so an asset AVFoundation can't read is still sendable.
            HavenLog.sync("audio add: AAC encode failed — keeping the original")
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.copyItem(at: src, to: scratch)
        }
        guard let ref = adoptProduced(.audio, from: scratch), let dst = fileURL(ref) else {
            return "aud_\(UUID().uuidString)"
        }
        cachePut(ref, MediaItem(id: ref, kind: .audio, image: nil, videoURL: dst))
        return ref
    }

    /// True if `ref` is a synthetic, non-fetchable attachment (e.g. a `geo:<lat>,<lon>,<label>`
    /// location pin) rather than real media bytes. Location shares ride inside a post's `media`
    /// array, but no peer or relay can EVER serve them — blobstore safe_path (core/haven-net) rejects
    /// ':' in a key component, so such a key was never storable — so the missing-media sweeps would
    /// re-enqueue a doomed S3-404 + ~30s iroh dial for them every cycle and `nbMediaPending` would
    /// never settle to 0. Real media refs are `img_`/`vid_`/`aud_` or a bare content hash; the legacy
    /// single-letter media schemes `v:`/`i:`/`a:` stay fetchable, so we key off a MULTI-char URI
    /// scheme (a ':' at index > 1) rather than a bare "contains ':'".
    nonisolated static func isSynthetic(_ ref: String) -> Bool {
        guard let i = ref.firstIndex(of: ":") else { return false }
        return ref.distance(from: ref.startIndex, to: i) > 1
    }

    /// Do we already hold the bytes for this ref?
    func has(_ ref: String) -> Bool {
        if cacheGet(ref) != nil { return true }
        guard let url = fileURL(ref) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Raw bytes for a ref (to seal + send to a peer who's missing it).
    func rawBytes(_ ref: String) -> Data? {
        guard let url = fileURL(ref) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Store media bytes received from a peer, reconstructing the item for rendering.
    ///
    /// This is the inbound chokepoint — every relay restore, peer chunk transfer and own-device sync
    /// lands here — so this is where bytes are held to account for the ref that named them. Bytes
    /// that don't hash to a content-addressed ref are DROPPED, not stored: they are, by definition,
    /// not the media this post is about.
    @discardableResult
    func store(_ ref: String, _ bytes: Data) -> Bool {
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref) else { return false }
        guard Self.verify(ref, bytes) else {
            HavenLog.relay("media REJECTED \(ref.prefix(12)): \(bytes.count)B do not match its content address")
            return false
        }
        try? bytes.write(to: url)
        switch kind {
        case .image: cachePut(ref, MediaItem(id: ref, kind: .image, image: PlatformImage(data: bytes), videoURL: nil))
        case .video: cachePut(ref, MediaItem(id: ref, kind: .video, image: Self.poster(for: url), videoURL: url))
        case .audio: cachePut(ref, MediaItem(id: ref, kind: .audio, image: nil, videoURL: url))
        case .file:  cachePut(ref, MediaItem(id: ref, kind: .file, image: nil, videoURL: url))
        }
        return true
    }

    /// Final on-disk path for a ref (sender reads chunks from here).
    func storagePath(for ref: String) -> URL? { fileURL(ref) }

    /// Are this ref's bytes on disk? A cheap `stat` — used by the photo grid to decide between the image
    /// tile and the still-downloading tile WITHOUT decoding anything, which is what layout used to do.
    func hasLocalFile(_ ref: String) -> Bool {
        guard let url = fileURL(ref) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A fresh empty temp file for reassembling an incoming chunked transfer.
    func makeTempFile() -> URL {
        let u = dir.appendingPathComponent("incoming_\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: u.path, contents: nil)
        return u
    }

    /// Move a fully-reassembled temp file into place under `ref` and cache the item.
    ///
    /// The other inbound chokepoint (chunked transfers, which never hold the blob in RAM). Verified
    /// by STREAMING the digest off the temp file — so a 600 MB video is checked without ever being
    /// materialized — and the temp is dropped rather than adopted on a mismatch. This is what binds
    /// chunked media: the chunks and their HVCHUNK1 manifest only carry the bytes, and any tamper in
    /// them lands here as a digest that doesn't match.
    @discardableResult
    func adopt(_ ref: String, from temp: URL) -> Bool {
        guard MediaKind(ref: ref) != nil, let dst = fileURL(ref) else { return false }
        guard Self.verify(ref, fileAt: temp) else {
            HavenLog.relay("media REJECTED \(ref.prefix(12)): reassembled bytes do not match its content address")
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: temp, to: dst) } catch { return false }
        // Do NOT eagerly decode the full image here. With own-device media sync, a burst of received blobs
        // each got decoded to a ~20MB bitmap on arrival → memory spike → iOS jetsam (SIGKILL) on launch.
        // Just drop any stale cache entry; item()/thumbnail() decode lazily (and downsampled) when rendered.
        cacheRemove(ref)
        return true
    }

    /// A separate, bounded cache of DOWNSCALED thumbnails for feed tiles / avatars. Rendering a full-res
    /// 2560px photo in a 56–150px slot makes SwiftUI re-sample a huge bitmap on the main thread every
    /// scroll frame — that's the feed/You-tab scroll lag. Downscale once to ~maxDimension, cache, and the
    /// tiles draw a tiny bitmap instead. The full image stays available via item(_:) for the zoom viewer.
    /// Video refs whose poster is currently being generated off-main — so scroll doesn't kick off a second
    /// generation for the same tile on every frame. Touched only on the main thread.
    private var posterInFlight = Set<String>()
    /// Refs whose display size is currently being read off-main. Main thread only.
    private var sizeProbeInFlight = Set<String>()

    /// Read an image's pixel size from its header OFF the main thread and record it. ImageIO only parses
    /// the header (no decode), but it's still file I/O — doing it inline for every tile of a photo grid,
    /// on every layout pass, is what made those posts stutter.
    private func probeImageSize(_ ref: String, _ url: URL) {
        guard !sizeProbeInFlight.contains(ref) else { return }
        sizeProbeInFlight.insert(ref)
        Task.detached(priority: .utility) {
            var found: CGSize?
            if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
               let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
                let o = (props[kCGImagePropertyOrientation] as? Int) ?? 1
                found = (5...8).contains(o) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            }
            let size = found
            await MainActor.run {
                MediaStore.shared.sizeProbeInFlight.remove(ref)
                if let size {
                    MediaStore.shared.recordPixelSize(ref, size)
                    FeedStore.shared.scheduleRefresh()
                }
            }
        }
    }

    /// Read a video's DISPLAY size (natural size through its preferred transform, so a portrait clip reports
    /// tall) off the main thread and record it. Much cheaper than generating a poster, so the feed can commit
    /// to the correct card height early; the result is persisted, so a given video only ever settles once.
    private func probeVideoSize(_ ref: String, _ url: URL) {
        guard !sizeProbeInFlight.contains(ref) else { return }
        sizeProbeInFlight.insert(ref)
        Task.detached(priority: .utility) {
            var found: CGSize?
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let r = natural.applying(transform)
                let s = CGSize(width: abs(r.width), height: abs(r.height))
                if s.width > 0, s.height > 0 { found = s }
            }
            let size = found
            await MainActor.run {
                MediaStore.shared.sizeProbeInFlight.remove(ref)
                if let size {
                    MediaStore.shared.recordPixelSize(ref, size)
                    FeedStore.shared.scheduleRefresh()   // re-render at the now-known aspect
                }
            }
        }
    }
    private let thumbCache: NSCache<NSString, Boxed> = {
        let c = NSCache<NSString, Boxed>()
        c.totalCostLimit = 48 * 1024 * 1024   // ~48 MB of decoded thumbnails, then evict LRU
        return c
    }()
    func thumbnail(_ ref: String, maxDimension: CGFloat) -> PlatformImage? {
        let bucket = Int(maxDimension.rounded())
        let key = "\(ref)@\(bucket)" as NSString
        if let b = thumbCache.object(forKey: key) { return b.item.image }
        let kind = MediaKind(ref: ref)
        let t: PlatformImage?
        if kind == .image, let url = fileURL(ref), FileManager.default.fileExists(atPath: url.path) {
            // Decode a DOWNSAMPLED bitmap straight from the file (ImageIO never materializes the full 2560px
            // image — that spike OOM-jetsammed iOS on launch). SYNCHRONOUS here — this path is for NON-scroll
            // callers (comment chips, share). The feed's scroll hot path uses `FeedImage` (self-loading,
            // off-main), which is what keeps a fast flick from decoding on the main thread WITHOUT the
            // per-decode `scheduleRefresh` that rebuilt the whole feed and flashed already-shown media.
            t = Self.downsampled(at: url, maxPixel: maxDimension)
        } else if kind == .video, let url = fileURL(ref), FileManager.default.fileExists(atPath: url.path) {
            // Video poster generation (AVAssetImageGenerator) is EXPENSIVE and was running on the main thread
            // the first time each video tile scrolled into view — that's the scroll choppiness. If it's
            // already cached use it; otherwise generate OFF the main thread, cache, and nudge a refresh so the
            // tile fills in a moment later. Return nil now (the tile shows its loading placeholder briefly).
            if let poster = cacheGet(ref)?.image {
                t = max(poster.size.width, poster.size.height) <= maxDimension ? poster : Self.downscale(poster, maxDimension: maxDimension)
            } else {
                if !posterInFlight.contains(ref) {
                    posterInFlight.insert(ref)
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        let poster = Self.poster(for: url)
                        DispatchQueue.main.async {
                            self.posterInFlight.remove(ref)
                            if let poster { self.cachePut(ref, MediaItem(id: ref, kind: .video, image: poster, videoURL: url)) }
                            FeedStore.shared.scheduleRefresh()   // re-render so the now-cached poster shows
                        }
                    }
                }
                t = nil
            }
        } else if let full = item(ref)?.image {
            t = max(full.size.width, full.size.height) <= maxDimension ? full : Self.downscale(full, maxDimension: maxDimension)
        } else {
            t = nil
        }
        guard let thumb = t else { return nil }
        let mi = MediaItem(id: ref, kind: .image, image: thumb, videoURL: nil)
        thumbCache.setObject(Boxed(mi), forKey: key, cost: Self.decodedCost(mi))
        return thumb
    }

    /// Cache-only peek — no decode, no side effects. Lets a self-loading image show INSTANTLY when the
    /// thumbnail is already resident (no placeholder flash on media you've already seen).
    func cachedThumbnail(_ ref: String, maxDimension: CGFloat) -> PlatformImage? {
        thumbCache.object(forKey: "\(ref)@\(Int(maxDimension.rounded()))" as NSString)?.item.image
    }

    /// Decodes in flight, keyed ref@size. More than one view now wants the same bitmap — the tile draws it
    /// and the blurred backdrop behind the tile blurs it — and without this they each ran their own decode.
    /// For a video that second decode is an AVAssetImageGenerator poster pass, the expensive thing this
    /// whole path exists to keep off the scroll. Unstructured on purpose: one awaiter walking away (a lazy
    /// cell recycled mid-decode) must not cancel the decode the other awaiter is still waiting on.
    private var thumbTasks: [String: Task<PlatformImage?, Never>] = [:]

    /// Decode a downsampled thumbnail OFF the main thread and cache it, WITHOUT nudging any global feed
    /// refresh. `FeedImage` awaits this and swaps the result into JUST itself — so a fast scroll never
    /// decodes on the main thread AND a finished decode never re-renders (or flashes) the rest of the feed.
    /// Concurrent callers for the same ref+size share one decode (see `thumbTasks`).
    func thumbnailAsync(_ ref: String, maxDimension: CGFloat) async -> PlatformImage? {
        if let cached = cachedThumbnail(ref, maxDimension: maxDimension) { return cached }
        let key = "\(ref)@\(Int(maxDimension.rounded()))"
        if let inFlight = thumbTasks[key] { return await inFlight.value }
        guard let url = fileURL(ref), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let isVideo = (MediaKind(ref: ref) == .video)
        // A video's poster may already be resident from an earlier generation — downscale that (cheap,
        // and on the main actor where every other poster resize already happens) rather than running
        // AVAssetImageGenerator again just to land in a different size bucket.
        if isVideo, let poster = cacheGet(ref)?.image {
            let img = max(poster.size.width, poster.size.height) <= maxDimension
                ? poster : Self.downscale(poster, maxDimension: maxDimension)
            let mi = MediaItem(id: ref, kind: .video, image: img, videoURL: url)
            thumbCache.setObject(Boxed(mi), forKey: key as NSString, cost: Self.decodedCost(mi))
            return img
        }
        let task = Task { @MainActor [weak self] () -> PlatformImage? in
            let img: PlatformImage? = await Task.detached(priority: .userInitiated) {
                if isVideo {
                    guard let poster = Self.poster(for: url) else { return nil }
                    return max(poster.size.width, poster.size.height) <= maxDimension ? poster
                                                                                       : Self.downscale(poster, maxDimension: maxDimension)
                }
                return Self.downsampled(at: url, maxPixel: maxDimension)
            }.value
            guard let self else { return img }
            self.thumbTasks[key] = nil
            if let img {
                let mi = MediaItem(id: ref, kind: isVideo ? .video : .image, image: img, videoURL: isVideo ? url : nil)
                self.thumbCache.setObject(Boxed(mi), forKey: key as NSString, cost: Self.decodedCost(mi))
            }
            return img
        }
        // Registered before the first suspension point below, so a second caller arriving while this
        // decode runs joins it instead of starting its own.
        thumbTasks[key] = task
        return await task.value
    }

    /// Pixel dimensions of a media ref WITHOUT decoding the full bitmap — ImageIO reads just the header for
    /// images; videos use the (cached, off-main) poster if present, else a sane default. Used for feed
    /// aspect ratios during scroll, where decoding the full image only to read `.size` was a main-thread hitch.
    private var sizeCache: [String: CGSize] = [:]
    private var sizeCacheLoaded = false
    private var sizeCacheSavePending = false
    /// Where the ref→pixel-size map is persisted. Knowing a video's shape BEFORE its poster is (re)generated
    /// is what keeps the feed from resizing a card mid-scroll.
    nonisolated static var sizeMapURL: URL { storageDir.appendingPathComponent("media-sizes.json") }

    /// Load the persisted size map once. Without this, a video whose poster had been evicted from the
    /// NSCache (or any video after a relaunch) reported NO size, so the feed laid its card out at the 4:3
    /// fallback and then snapped to the real aspect the moment the poster finished decoding — the cards
    /// below it visibly jumped. The map is tiny (two numbers per ref) and survives eviction + relaunch.
    private func loadSizeCacheIfNeeded() {
        guard !sizeCacheLoaded else { return }
        sizeCacheLoaded = true
        guard let data = try? Data(contentsOf: Self.sizeMapURL),
              let raw = try? JSONDecoder().decode([String: [CGFloat]].self, from: data) else { return }
        for (ref, wh) in raw where wh.count == 2 && wh[0] > 0 && wh[1] > 0 {
            if sizeCache[ref] == nil { sizeCache[ref] = CGSize(width: wh[0], height: wh[1]) }
        }
    }

    /// Remember a ref's pixel size (in-memory + on disk, debounced).
    func recordPixelSize(_ ref: String, _ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        loadSizeCacheIfNeeded()
        guard sizeCache[ref] != size else { return }
        sizeCache[ref] = size
        guard !sizeCacheSavePending else { return }
        sizeCacheSavePending = true
        let snapshot = sizeCache.mapValues { [$0.width, $0.height] }
        let url = Self.sizeMapURL
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
            Task { @MainActor in MediaStore.shared.sizeCacheSavePending = false }
        }
    }

    /// `allowSyncRead: false` = never touch the filesystem on the caller's thread. A cache miss then
    /// returns nil (the caller uses a fallback aspect) and the real size is probed off-main and recorded.
    /// The photo GRID uses this: reading 10+ image headers inline, once per layout pass, was the jitter on
    /// big multi-photo posts. A grid tile's aspect only affects its width inside a horizontal scroller, so
    /// filling it in late costs nothing — unlike a single-media post, whose aspect sets the card's height.
    func pixelSize(_ ref: String, allowSyncRead: Bool = true) -> CGSize? {
        loadSizeCacheIfNeeded()
        if let s = sizeCache[ref] { return s }
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref) else { return nil }
        if !allowSyncRead {
            if kind == .image { probeImageSize(ref, url) } else { probeVideoSize(ref, url) }
            return nil
        }
        if kind == .image,
           let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
           w > 0, h > 0 {
            // Honor EXIF orientation: for a 90°/270° rotation (values 5–8) the DISPLAYED image is
            // width↔height swapped from the raw pixels. Without this, a portrait photo that carries a
            // rotation tag (common for media from another device / a story) reports as landscape here, so
            // the feed sizes it into a short wide box even though it renders tall. (Orientation-baked
            // photos report 1, so this is a no-op for them.)
            let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
            let s = (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            recordPixelSize(ref, s); return s
        }
        if kind == .video {
            if let poster = cacheGet(ref)?.image, poster.size.width > 0 {
                recordPixelSize(ref, poster.size); return poster.size
            }
            // No poster yet (never viewed on this device). Reading the track's natural size is far cheaper
            // than generating a poster, so probe it off-main and record it — the card settles on its true
            // height as early as possible instead of sitting at the 4:3 fallback until poster decode lands.
            probeVideoSize(ref, url)
        }
        return nil
    }

    /// Decode a downsampled image directly from a file via ImageIO — peak memory is the THUMBNAIL size,
    /// not the full bitmap. This is the memory-safe way to make feed thumbnails.
    nonisolated static func downsampled(at url: URL, maxPixel: CGFloat) -> PlatformImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    func item(_ ref: String) -> MediaItem? {
        if let c = cacheGet(ref) { return c }
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        switch kind {
        case .image:
            let item = MediaItem(id: ref, kind: .image, image: PlatformImage(contentsOfFile: url.path), videoURL: nil)
            cachePut(ref, item); return item
        case .video:
            // NEVER generate the video poster (AVAssetImageGenerator) on the calling thread — during scroll
            // that's a main-thread hitch the first time each video appears. Return with videoURL now (the
            // player + grid tiles don't need item().image; tiles get their poster from thumbnail(), which
            // generates off-main). Kick off an off-main poster generation that re-caches when ready.
            if !posterInFlight.contains(ref) {
                posterInFlight.insert(ref)
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let poster = Self.poster(for: url)
                    DispatchQueue.main.async {
                        self.posterInFlight.remove(ref)
                        if let poster { self.cachePut(ref, MediaItem(id: ref, kind: .video, image: poster, videoURL: url)) }
                    }
                }
            }
            return MediaItem(id: ref, kind: .video, image: nil, videoURL: url)   // not cached (would shadow the real poster)
        case .audio:
            let item = MediaItem(id: ref, kind: .audio, image: nil, videoURL: url)
            cachePut(ref, item); return item
        case .file:
            let item = MediaItem(id: ref, kind: .file, image: nil, videoURL: url)
            cachePut(ref, item); return item
        }
    }

    /// Can this video be trimmed? Native macOS has its own AVFoundation `VideoTrimmer`; iOS uses
    /// the system editor. Only Mac Catalyst has neither.
    func canTrim(_ ref: String) -> Bool {
        #if os(macOS)
        return storagePath(for: ref) != nil
        #elseif targetEnvironment(macCatalyst)
        return false
        #else
        guard let url = storagePath(for: ref) else { return false }
        return UIVideoEditorController.canEditVideo(atPath: url.path)
        #endif
    }

    /// Extract a poster frame so videos show something before playback.
    nonisolated static func poster(for url: URL) -> PlatformImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1080, height: 1080)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
        else { return nil }
        return PlatformImage(cgImage: cg)
    }

    /// Content-address a poster still for an **already stored** video without re-encoding the clip.
    /// Used by re-optimize's poster-only path: already-compressed videos that never published a
    /// `poster:` marker still need a still for super data saver / feed cards.
    @MainActor
    func ensurePosterImage(for videoRef: String) -> String? {
        guard MediaKind(ref: videoRef) == .video,
              let url = storagePath(for: videoRef),
              FileManager.default.fileExists(atPath: url.path),
              let img = Self.poster(for: url) else { return nil }
        return addImage(img, forceOptimize: true)
    }
}

// MARK: - Device pin (#2) — local retention exemption

/// DEVICE-LOCAL "keep on this device" set: media the user asked to retain here, exempt from EVERY
/// cleanup path (orphan sweep, the age/size limit sweep, and the cleanup screen marks it ineligible).
/// It is NOT synced to other devices and NOT hoisted anywhere in the feed — purely a local retention
/// exemption. Refs are stored verbatim; callers union each ref's on-disk stems into the sweep keep-set.
@MainActor
/// Stories you chose to KEEP — held on your profile after the 24h story window closes.
///
/// A story is an ordinary post with a 24h retention, so the event itself is purged on schedule
/// everywhere, for everyone. Keeping one therefore can't mean "stop it expiring": it means holding
/// your OWN snapshot of it, which is why this stores the story's content rather than a reference to
/// an event that is about to stop existing.
///
/// Keep deliberately does NOT re-publish. It used to turn the story into a permanent post, which put
/// it in the circle feed as a new thing everyone saw again — a different act from wanting to hold on
/// to it yourself. A kept story stays yours, on your profile, and still leaves the circle's story row
/// when its 24 hours are up.
final class KeptStoriesStore: ObservableObject {
    static let shared = KeptStoriesStore()

    struct Kept: Codable, Identifiable, Equatable {
        let id: String            // the original event id, so a story is kept at most once
        let body: String
        let media: [String]
        let createdAt: UInt64
        /// When I kept it — the LWW clock for syncing this entry against a sibling's tombstone.
        /// Optional so records written before syncing existed still decode.
        var keptAt: UInt64?
        // Flattened rather than holding a TrackRefFfi: that's generated FFI glue, not a storage type,
        // and pinning a persisted format to it would break on the next binding regeneration.
        let musicCatalogId: String?
        let musicTitle: String?
        let musicArtist: String?
        let musicArtworkUrl: String?
        let musicDurationMs: UInt64?
    }

    @Published private(set) var kept: [Kept]
    /// Un-kept story ids and WHEN — so un-keeping propagates to my other devices instead of a
    /// sibling's copy quietly re-adding it. Absence is not removal; this codebase has already paid
    /// for that lesson once with additive-only self-sync.
    private(set) var removed: [String: UInt64]
    private let d = UserDefaults.standard
    private let key = "haven.stories.kept"
    private let removedKey = "haven.stories.kept.removed"

    private init() {
        if let data = d.data(forKey: key), let list = try? JSONDecoder().decode([Kept].self, from: data) {
            kept = list
        } else {
            kept = []
        }
        removed = (d.dictionary(forKey: removedKey) as? [String: NSNumber])?
            .mapValues { $0.uint64Value } ?? [:]
    }

    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    func isKept(_ id: String) -> Bool { kept.contains { $0.id == id } }

    /// Keep a story: snapshot it and PIN its media, so the blobs survive the cleanup sweeps that
    /// would otherwise reclaim them once the event is gone. Without the pin, a kept story would
    /// become a row of "no longer available" placeholders — kept in name only.
    func keep(id: String, body: String, media: [String], createdAt: UInt64, music: TrackRefFfi?) {
        guard !isKept(id) else { return }
        kept.append(Kept(id: id, body: body, media: media, createdAt: createdAt, keptAt: nowMs(),
                         musicCatalogId: music?.catalogId, musicTitle: music?.title,
                         musicArtist: music?.artist, musicArtworkUrl: music?.artworkUrl,
                         musicDurationMs: music?.durationMs))
        removed.removeValue(forKey: id)   // re-keeping clears the tombstone
        PinnedMediaStore.shared.pin(media)
        save()
    }

    /// Stop keeping it — and release the pin, so the blobs are eligible for cleanup again.
    func unkeep(_ id: String) {
        guard let i = kept.firstIndex(where: { $0.id == id }) else { return }
        let media = kept[i].media
        kept.remove(at: i)
        removed[id] = nowMs()   // tombstone, so a sibling doesn't re-add it on the next sync
        unpinIfUnused(media)
        save()
    }

    /// Release pins for blobs no OTHER kept story still needs (a story shared twice can share refs).
    private func unpinIfUnused(_ media: [String]) {
        let stillNeeded = Set(kept.flatMap(\.media))
        PinnedMediaStore.shared.unpin(media.filter { !stillNeeded.contains($0) })
    }

    // MARK: Self-sync (per-entry LWW, tombstoned)

    /// What to publish to my other devices.
    func syncPayload() -> Data? {
        guard !kept.isEmpty || !removed.isEmpty else { return nil }
        let wire = Wire(kept: kept, removed: removed)
        return try? JSONEncoder().encode(wire)
    }

    /// Merge a sibling's state. Per ENTRY, not wholesale: keeping a story on my phone and a different
    /// one on my Mac must end with both kept, which a last-writer-wins collection would not do.
    /// A tombstone beats an entry only if it is NEWER — so re-keeping something later still wins.
    func applySynced(_ data: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return }
        var changed = false
        for (id, ts) in wire.removed where (removed[id] ?? 0) < ts {
            removed[id] = ts; changed = true
        }
        for entry in wire.kept {
            let entryAt = entry.keptAt ?? entry.createdAt
            if (removed[entry.id] ?? 0) > entryAt { continue }   // un-kept more recently than kept
            if let i = kept.firstIndex(where: { $0.id == entry.id }) {
                if (kept[i].keptAt ?? 0) < entryAt { kept[i] = entry; changed = true }
            } else {
                kept.append(entry); PinnedMediaStore.shared.pin(entry.media); changed = true
            }
        }
        // Apply tombstones that are newer than my own copy.
        for (id, ts) in removed {
            if let i = kept.firstIndex(where: { $0.id == id }), (kept[i].keptAt ?? 0) < ts {
                let media = kept[i].media
                kept.remove(at: i); unpinIfUnused(media); changed = true
            }
        }
        if changed { save() }
    }

    private struct Wire: Codable {
        let kept: [Kept]
        let removed: [String: UInt64]
    }

    func toggle(id: String, body: String, media: [String], createdAt: UInt64, music: TrackRefFfi?) {
        if isKept(id) { unkeep(id) } else { keep(id: id, body: body, media: media, createdAt: createdAt, music: music) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(kept) { d.set(data, forKey: key) }
        // Bound the tombstones: they only need to outlive a sibling being offline, not forever.
        if removed.count > 500 {
            removed = Dictionary(uniqueKeysWithValues:
                removed.sorted { $0.value > $1.value }.prefix(250).map { ($0.key, $0.value) })
        }
        d.set(removed.mapValues { NSNumber(value: $0) }, forKey: removedKey)
        objectWillChange.send()
    }
}

final class PinnedMediaStore: ObservableObject {
    static let shared = PinnedMediaStore()
    @Published private(set) var refs: Set<String>
    private let d = UserDefaults.standard
    private let key = "haven.media.pinned"

    private init() { refs = Set(d.stringArray(forKey: key) ?? []) }

    func isPinned(_ ref: String) -> Bool { refs.contains(ref) }
    func anyPinned(_ rs: [String]) -> Bool { rs.contains { refs.contains($0) } }
    var count: Int { refs.count }

    func pin(_ rs: [String]) {
        for r in rs where !MediaStore.isSynthetic(r) { refs.insert(r) }
        save()
    }
    func unpin(_ rs: [String]) {
        for r in rs { refs.remove(r) }
        save()
    }
    func togglePin(_ rs: [String]) { if anyPinned(rs) { unpin(rs) } else { pin(rs) } }

    /// On-disk stems of every pinned ref — unioned into the orphan-sweep and limit-sweep keep-sets so a
    /// pinned blob is never deleted, whatever its age/referencedness.
    func inUseStems() -> Set<String> {
        var s = Set<String>()
        for r in refs { s.formUnion(MediaStore.storedStems(for: r)) }
        return s
    }

    private func save() { d.set(Array(refs), forKey: key) }
}

// MARK: - Evicted set (#3/#4) — deliberately-removed, do-not-auto-refetch

/// Refs whose LOCAL blob was deliberately removed (cleanup screen selection of a still-referenced item,
/// or the age/size limit sweep) while the EVENT still lives. The missing-media sweep must NOT auto-refetch
/// these — that would silently undo the space the user just freed — so they render as an explicit
/// "Download X MB" placeholder and are re-fetched only on tap. Keyed by on-disk stem → last-known bytes
/// (for the placeholder label). DEVICE-LOCAL, persisted as JSON in UserDefaults.
@MainActor
/// Media I've asked to be told about when it comes back.
///
/// A relay sweeps media on the operator's retention, and a post outlives its blob — so "No longer
/// available" is a permanent dead end even though the AUTHOR usually still has the original sitting
/// on their device. This records that I want it, so I can be told when it returns.
///
/// Deliberately just a local set of refs: the REQUEST itself travels as a sealed frame through the
/// circle's mailbox, which is already store-and-forward, so an author who is offline for a week
/// receives it the moment they next sync. Nothing needs to be parked on a relay by hand.
final class MediaWantedStore: ObservableObject {
    static let shared = MediaWantedStore()
    @Published private(set) var wanted: Set<String>
    private let d = UserDefaults.standard
    private let key = "haven.media.wanted"

    private init() { wanted = Set(d.stringArray(forKey: key) ?? []) }

    func isWanted(_ ref: String) -> Bool { wanted.contains(ref) }

    func add(_ ref: String) {
        guard !wanted.contains(ref) else { return }
        wanted.insert(ref)
        // Bounded: a user who taps this on everything shouldn't grow an unbounded list, and the
        // oldest asks are the least likely to still matter.
        if wanted.count > 500 { wanted.removeFirst() }
        d.set(Array(wanted), forKey: key)
    }

    /// It arrived (or the ask is moot) — stop tracking it.
    func clear(_ ref: String) {
        guard wanted.contains(ref) else { return }
        wanted.remove(ref)
        d.set(Array(wanted), forKey: key)
    }
}

final class EvictedMediaStore: ObservableObject {
    static let shared = EvictedMediaStore()
    @Published private(set) var sizes: [String: Int64]
    private let d = UserDefaults.standard
    private let key = "haven.media.evicted"

    private init() {
        if let data = d.data(forKey: key),
           let m = try? JSONDecoder().decode([String: Int64].self, from: data) { sizes = m }
        else { sizes = [:] }
    }

    /// Matches on the ref itself AND its bare hash, so an event ref (`img_<hash>`) resolves an eviction
    /// recorded under a bare-hash on-disk stem (cross-platform files) and vice-versa.
    func contains(_ ref: String) -> Bool { sizes[ref] != nil || sizes[MediaStore.bareId(ref)] != nil }
    func size(_ ref: String) -> Int64? { sizes[ref] ?? sizes[MediaStore.bareId(ref)] }

    func mark(_ ref: String, bytes: Int64) {
        sizes[ref] = bytes
        if sizes.count > 8000 { sizes = Dictionary(sizes.prefix(4000).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a }) }
        save()
    }
    func clear(_ ref: String) {
        var changed = sizes.removeValue(forKey: ref) != nil
        if sizes.removeValue(forKey: MediaStore.bareId(ref)) != nil { changed = true }
        if changed { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sizes) { d.set(data, forKey: key) }
    }
}

// MARK: - Missing-media placeholder (#3)

/// A graceful placeholder for a referenced blob whose bytes aren't on disk. Honest states:
///  • deliberately evicted (cleanup / limit sweep) → a "Download N MB" affordance (re-fetches on tap);
///  • actively downloading → a spinner, with chunk progress (i/n) for large chunked blobs;
///  • relays reachable but empty → "Waiting for sender…" (their device hasn't uploaded it yet);
///  • retries exhausted / relay swept it → "No longer available" (Retry + Ask-for-it-back).
/// Media that's simply still syncing keeps the plain "still loading" spinner — rendered over the
/// post's blurred `thumb:` companion when one is held, so the card has real shape + color instead
/// of a grey box (and the layout doesn't jump when the full bytes land).
struct MissingMediaPlaceholder: View {
    let ref: String
    var isVideo: Bool = false
    /// Which post this blob belongs to, and who wrote it. Needed to ask the AUTHOR to put it back
    /// (and to deep-link the notification when they do). Absent where a placeholder isn't rendered
    /// inside a post — the ask simply isn't offered there rather than guessing at an author.
    var postContext: (circleId: String, postId: String, authorShort: String)?
    /// The post's full media list — how the placeholder finds this ref's `thumb:` companion.
    var mediaList: [String] = []
    @ObservedObject private var feed = FeedStore.shared
    @ObservedObject private var evicted = EvictedMediaStore.shared
    @ObservedObject private var wanted = MediaWantedStore.shared

    /// The held thumb companion image, if the post declared one and its tiny bytes have arrived.
    private var thumbImage: PlatformImage? {
        guard let t = MediaVariants.thumb(for: ref, in: mediaList) else { return nil }
        return MediaStore.shared.thumbnail(t, maxDimension: 512)
    }

    var body: some View {
        ZStack {
            if bytesPresent {
                // The media is HERE. Draw nothing at all — not even the grey fill.
                //
                // `FeedImage` keeps this view mounted underneath the photo to cross-dissolve into it,
                // and in a carousel the blurred letterbox backdrop is `FeedImage`'s own `.background`.
                // An opaque fill here therefore sits BETWEEN the backdrop and the photo and paints the
                // letterbox flat grey — which is exactly what happened to the carousel backdrop. The
                // fill only ever existed to stop an empty tile looking broken, and a tile whose bytes
                // are on disk is not empty.
                Color.clear
            } else if let img = thumbImage {
                // SHARP, and with nothing over it. The thumb IS the picture, just smaller — blurring
                // it and dropping a scrim + a status line on top made a post that was loading fine
                // look broken. It sits here until the full-res bytes cross-fade in over it
                // (`FeedImage`), which is the whole progressive-loading story: small then big, never
                // "obscured then revealed".
                Image(platformImage: img).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemFill))
            }
            content
        }
    }

    /// White reads on a photo; secondary reads on the plain fill.
    private var overlayStyle: Color { thumbImage != nil ? .white : .secondary }

    /// The bytes are actually on disk. Trust the filesystem over the in-flight bookkeeping: if a
    /// `downloadingMedia` entry is ever left behind (a path that returns without clearing it, a
    /// restore that lands via a different route than the one that set the flag), the spinner would
    /// otherwise sit on top of media that finished — reported from the field as "media obviously
    /// downloaded and blurred, with a loading status hanging over it for a while".
    private var bytesPresent: Bool {
        guard let url = MediaStore.shared.storagePath(for: ref) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @ViewBuilder private var content: some View {
        if bytesPresent {
            // Present but the parent still had us on screen — show the preview WITHOUT any chrome;
            // the real view swaps in on the next refresh. No spinner over finished media.
            EmptyView()
        } else if thumbImage != nil,
                  feed.downloadingMedia.contains(ref) || feed.waitingForSenderMedia.contains(ref),
                  !feed.unavailableMedia.contains(ref) {
            // We are holding a picture of it and it is on its way. Show the picture. A spinner and a
            // "Waiting for sender…" caption over a photo that is visibly there reads as an error, and
            // it is not one — nothing here needs the user to do anything. The full-res version
            // cross-fades in when it lands.
            EmptyView()
        } else if feed.downloadingMedia.contains(ref) {
            // No thumb to show, so the tile would be a blank grey box: say something.
            VStack(spacing: 8) {
                ProgressView()
                if let p = feed.mediaRestoreProgress[ref], p.total > 1 {
                    Text("Downloading… \(p.done)/\(p.total)").font(.caption).foregroundStyle(overlayStyle)
                }
            }
        } else if feed.waitingForSenderMedia.contains(ref), !feed.unavailableMedia.contains(ref) {
            // The relays answered and none holds it — the SENDER hasn't uploaded it yet. A different
            // truth from "downloading" (we aren't) and from "gone" (it never arrived anywhere). Only
            // said out loud when there is no thumb, i.e. when the tile is otherwise empty.
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(overlayStyle)
                Text("Waiting for sender…").font(.caption).foregroundStyle(overlayStyle)
            }
        } else if feed.unavailableMedia.contains(ref) {
            VStack(spacing: 8) {
                Image(systemName: "wifi.slash").font(.title2).foregroundStyle(.secondary)
                Text("No longer available").font(.caption).foregroundStyle(.secondary)
                Button("Retry") { feed.downloadEvicted(ref) }
                    .font(.caption.weight(.semibold)).buttonStyle(.borderless).tint(HavenTheme.pink)
                // A relay's retention swept this, but the AUTHOR probably still has the original.
                // Asking them is the difference between "gone" and "gone from the relay".
                if wanted.isWanted(ref) {
                    Label("We'll tell you when it's back", systemImage: "bell.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let ctx = postContext {
                    Button {
                        feed.requestMediaWhenAvailable(ref: ref, circleId: ctx.circleId,
                                                       postId: ctx.postId, authorShort: ctx.authorShort)
                    } label: {
                        Label("Notify me when it's back", systemImage: "bell")
                    }
                    .font(.caption.weight(.semibold)).buttonStyle(.borderless).tint(HavenTheme.pink)
                }
            }
        } else if let bytes = evicted.size(ref) {
            Button { feed.downloadEvicted(ref) } label: {
                VStack(spacing: 8) {
                    Image(systemName: isVideo ? "arrow.down.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(HavenTheme.pink)
                    Text("Download \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    Text("Removed to save space").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 8) {
                ProgressView().tint(thumbImage != nil ? .white : nil)
                Text(isVideo ? "Video still loading…" : "Media still loading…")
                    .font(.caption).foregroundStyle(overlayStyle)
            }
        }
    }
}

// MARK: - Cleanup screen (#1) — size-sorted inventory

/// One row of the "Manage media" screen: a stored blob, its size, and the post/DM it belongs to
/// (best-effort). `isOrphan` = no live event references it (safe to delete freely). `isPinned` = kept
/// on this device, so it's shown as ineligible for cleanup.
struct MediaInventoryRow: Identifiable, Sendable {
    var id: String { ref }
    let ref: String
    let bytes: Int64
    let mtime: Date
    let kind: MediaKind?
    let circleId: String?
    let circleName: String
    let snippet: String?
    let eventMs: UInt64
    let isOrphan: Bool
    let isPinned: Bool
}

/// The size-sorted storage manager: every cached photo/video/audio blob, largest first, each mapped to
/// the post/DM it belongs to (or flagged as unused). Multi-select to free space; per-item "Keep on this
/// device" pins a blob so no cleanup ever removes it. Deleting frees only the LOCAL bytes — the post
/// stays and re-renders as a downloadable placeholder.
struct MediaCleanupView: View {
    @ObservedObject private var pinned = PinnedMediaStore.shared
    @State private var rows: [MediaInventoryRow] = []
    @State private var loading = true
    @State private var selection = Set<String>()
    @State private var working = false
    @State private var lastResult: String?

    private var totalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    private var pinnedBytes: Int64 { rows.filter(\.isPinned).reduce(0) { $0 + $1.bytes } }
    private var selectedBytes: Int64 { rows.filter { selection.contains($0.ref) }.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        ZStack {
            HavenBackground()
            if loading {
                ProgressView("Measuring…")
            } else if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "internaldrive").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No cached media").foregroundStyle(.secondary)
                }
            } else {
                List {
                    Section {
                        ForEach(rows) { row in rowView(row) }
                    } header: {
                        Text("\(rows.count) item\(rows.count == 1 ? "" : "s") · \(fmt(totalBytes))"
                             + (pinnedBytes > 0 ? " · \(fmt(pinnedBytes)) kept" : ""))
                    } footer: {
                        Text("Frees space on this device only — posts re-download on demand. Kept items stay.")
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Manage media")
        .havenInlineNavTitle()
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                Button {
                    Task { await deleteSelected() }
                } label: {
                    HStack {
                        if working { ProgressView().tint(.white) }
                        Text(working ? "Removing…" : "Remove \(selection.count) · frees \(fmt(selectedBytes))")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(working)
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .task { await reload() }
    }

    @ViewBuilder private func rowView(_ row: MediaInventoryRow) -> some View {
        let selected = selection.contains(row.ref)
        HStack(spacing: 12) {
            // Selection toggle (pinned rows are ineligible — no checkbox).
            if row.isPinned {
                Image(systemName: "pin.fill").foregroundStyle(HavenTheme.pink).frame(width: 24)
            } else {
                Button {
                    if selected { selection.remove(row.ref) } else { selection.insert(row.ref) }
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? HavenTheme.pink : .secondary)
                }
                .buttonStyle(.plain).frame(width: 24)
            }
            thumb(row)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.circleName).font(.subheadline.weight(.medium)).lineLimit(1)
                if let s = row.snippet, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if row.isOrphan {
                    Text("Not linked to any post").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(fmt(row.bytes)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text("·").font(.caption2).foregroundStyle(.secondary)
                    Text(row.mtime, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary)
                    if row.isPinned {
                        Text("· Kept").font(.caption2.weight(.semibold)).foregroundStyle(HavenTheme.pink)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !row.isPinned else { return }
            if selected { selection.remove(row.ref) } else { selection.insert(row.ref) }
        }
        .swipeActions(edge: .leading) {
            Button {
                pinned.togglePin([row.ref])
                Task { await reloadPinnedFlags() }
            } label: {
                Label(row.isPinned ? "Unkeep" : "Keep", systemImage: row.isPinned ? "pin.slash" : "pin")
            }.tint(HavenTheme.pink)
        }
    }

    @ViewBuilder private func thumb(_ row: MediaInventoryRow) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
            if row.kind == .audio {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            } else if let img = MediaStore.shared.thumbnail(row.ref, maxDimension: 120) {
                Image(platformImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: row.kind == .video ? "video.fill" : "photo.fill").foregroundStyle(.secondary)
            }
            if row.kind == .video {
                Image(systemName: "play.circle.fill").foregroundStyle(.white.opacity(0.9)).shadow(radius: 2)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private func reload() async {
        loading = true
        rows = await FeedStore.shared.mediaInventory()
        // Prune selections that no longer exist.
        selection = selection.intersection(Set(rows.map(\.ref)))
        loading = false
    }
    /// Re-fetch just the pinned flags without a full re-measure (after a pin toggle).
    private func reloadPinnedFlags() async {
        let pinnedRefs = pinned.refs
        rows = rows.map { r in
            MediaInventoryRow(ref: r.ref, bytes: r.bytes, mtime: r.mtime, kind: r.kind, circleId: r.circleId,
                              circleName: r.circleName, snippet: r.snippet, eventMs: r.eventMs,
                              isOrphan: r.isOrphan, isPinned: pinnedRefs.contains(r.ref))
        }
        // A newly-pinned row can't stay selected.
        selection = selection.subtracting(pinnedRefs)
    }

    private func deleteSelected() async {
        working = true
        let chosen = rows.filter { selection.contains($0.ref) && !$0.isPinned }
        let freed = await FeedStore.shared.deleteSelectedMedia(chosen)
        lastResult = "Freed \(fmt(freed))"
        selection.removeAll()
        working = false
        await reload()
    }
}

/// A self-loading feed thumbnail. Shows the cached bitmap instantly if it's resident, otherwise decodes it
/// OFF the main thread (`thumbnailAsync`) and swaps it into JUST this view — never a global feed refresh.
/// That's what lets a fast scroll neither hitch (no main-thread decode) NOR flash (a finished decode
/// re-renders only this cell, not the whole feed + every blurred backdrop). `.task(id: ref)` reloads it
/// correctly when a lazy cell is reused for a different post.
struct FeedImage<Placeholder: View>: View {
    let ref: String
    var maxDimension: CGFloat = 1200
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var img: PlatformImage?
    @State private var loadedRef: String?
    @State private var shown = false   // drives an OPACITY-only fade (never a layout animation)

    var body: some View {
        // ZStack, not a Group that swaps branches: the placeholder holds the thumbnail, so swapping
        // it OUT the instant the full-res image mounts cut to an empty tile and then faded the photo
        // in from nothing. Keeping it underneath and fading its opacity to 0 makes the same moment a
        // cross-dissolve from the small version to the big one.
        //
        // Fade via opacity ONLY — an `.animation(value:)`/`.transition` on a view being INSERTED into
        // a scrolling LazyVStack bleeds into the cell's LAYOUT and jitters the scroll position. Both
        // layers here are permanently mounted, so nothing about this can move layout.
        ZStack {
            placeholder()
                .opacity(shown ? 0 : 1)
                .allowsHitTesting(!shown)
            if let img, loadedRef == ref {
                Image(platformImage: img).resizable().aspectRatio(contentMode: contentMode)
                    .opacity(shown ? 1 : 0)
                    .onAppear { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
            }
        }
        .task(id: ref) {
            shown = false
            if let cached = MediaStore.shared.cachedThumbnail(ref, maxDimension: maxDimension) {
                img = cached; loadedRef = ref; shown = true; return   // already resident → no fade needed
            }
            img = nil; loadedRef = nil
            let decoded = await MediaStore.shared.thumbnailAsync(ref, maxDimension: maxDimension)
            if !Task.isCancelled { img = decoded; loadedRef = ref }
        }
    }
}
