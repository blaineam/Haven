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
                case .audio:
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
    case image, video, audio
    var ext: String {
        switch self {
        case .image: return "jpg"
        case .video: return "mp4"
        case .audio: return "m4a"
        }
    }
    /// The kind is encoded in the ref prefix so a recipient knows how to render it. Matches
    /// `haven-p2p::mediaref::MediaKind::prefix` and Android's `LocalMedia` byte-for-byte.
    var prefix: String {
        switch self {
        case .image: return "img_"
        case .video: return "vid_"
        case .audio: return "aud_"
        }
    }
    /// The kind is encoded in the ref prefix so a recipient knows how to render it.
    init?(ref: String) {
        if ref.hasPrefix("img_") { self = .image }
        else if ref.hasPrefix("vid_") { self = .video }
        else if ref.hasPrefix("aud_") { self = .audio }
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
    static func gpsCoordinate(fromImageData data: Data) -> CLLocationCoordinate2D? {
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
        for p in ["img_", "vid_", "aud_", "v:", "i:", "a:"] where ref.hasPrefix(p) {
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
    func diskUsage() -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
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
            var survivors = cands.filter { !deleted.contains($0.url) }.sorted { $0.mtime < $1.mtime }  // oldest first
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
            for ext in ["jpg", "mp4", "m4a"] {
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
            options: [.skipsHiddenFiles]) else { return (0, 0) }
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
        var bytes: Int64 = 0
        var files = 0
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix("mint_") || name.hasPrefix("incoming_") else { continue }
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let m = vals?.contentModificationDate, m > cutoff { continue }   // still being written
            bytes += Int64(vals?.fileSize ?? 0)
            files += 1
            try? fm.removeItem(at: url)
        }
        return (bytes, files)
    }

    @discardableResult
    func addImage(_ image: PlatformImage) -> String {
        // Optimize: downscale very large photos + compress, so they're light to send —
        // but keep it high-res (longest edge up to 2560, well above 1080p).
        let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        // Bake EXIF orientation into the pixels: Android's BitmapFactory ignores the orientation tag,
        // so a portrait iPhone photo arrives sideways unless we normalize it to .up here.
        // Auto-optimize → 2048px JPEG @ 70% (small + universally compatible). Off → original quality.
        let img = Self.normalizedUp(optimize ? Self.downscale(image, maxDimension: 2048) : image)
        let quality: CGFloat = optimize ? 0.70 : 0.95
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
        return ref
    }

    /// Async because optimizing transcodes the video (AVAssetExportSession). Without
    /// this, full-size originals (often 50–200MB) are too big to seal + send P2P.
    @discardableResult
    func addVideo(url src: URL) async -> String {
        // Transcode into scratch first: the ref is the digest of the FINAL bytes, so it can only be
        // known once the export has produced them.
        let scratch = scratchURL("mp4")
        try? FileManager.default.removeItem(at: scratch)
        var ok = false
        if CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId) {
            // Auto-optimize (default): re-encode to 1080p H.264 with a faststart moov atom — small and
            // universally playable, including on Androids that can't decode the iPhone's native HEVC.
            ok = await Self.optimizeVideo(src, to: scratch)
        }
        // Auto-optimize OFF: share in the ORIGINAL format + quality (no transcode). Still do a lossless
        // passthrough remux to strip GPS/device metadata AND move the moov atom to the front (faststart),
        // so playback starts fast — neither changes the codec or quality. Falls back to a raw copy.
        // (Note: with optimize off, an HEVC source stays HEVC, so it may not play on HEVC-less devices —
        //  that's the explicit trade for "original quality as-is".)
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
            return "vid_\(UUID().uuidString)"   // export produced nothing addressable
        }
        cachePut(ref, MediaItem(id: ref, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        return ref
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
        case .audio:
            return ref
        }
    }

    /// Encode a filtered image under its own content address. Same optimize/quality rules as
    /// `addImage`, minus the orientation normalize (the source ref was already normalized).
    private func storeFiltered(_ image: PlatformImage) -> String? {
        let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        let img = optimize ? Self.downscale(image, maxDimension: 2048) : image
        let quality: CGFloat = optimize ? 0.70 : 0.95
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

    static func optimizeVideo(_ src: URL, to dst: URL) async -> Bool {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
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
            let fit = dw > 0 && dh > 0 ? min(1, min(1920 / max(dw, dh), 1080 / min(dw, dh))) : 1
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
    func addAudio(url src: URL) -> String {
        let scratch = scratchURL("m4a")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.copyItem(at: src, to: scratch)
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
        }
        return true
    }

    /// Final on-disk path for a ref (sender reads chunks from here).
    func storagePath(for ref: String) -> URL? { fileURL(ref) }

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

    /// Decode a downsampled thumbnail OFF the main thread and cache it, WITHOUT nudging any global feed
    /// refresh. `FeedImage` awaits this and swaps the result into JUST itself — so a fast scroll never
    /// decodes on the main thread AND a finished decode never re-renders (or flashes) the rest of the feed.
    func thumbnailAsync(_ ref: String, maxDimension: CGFloat) async -> PlatformImage? {
        if let cached = cachedThumbnail(ref, maxDimension: maxDimension) { return cached }
        guard let url = fileURL(ref), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let isVideo = (MediaKind(ref: ref) == .video)
        let img: PlatformImage? = await Task.detached(priority: .userInitiated) {
            if isVideo {
                guard let poster = Self.poster(for: url) else { return nil }
                return max(poster.size.width, poster.size.height) <= maxDimension ? poster
                                                                                   : Self.downscale(poster, maxDimension: maxDimension)
            }
            return Self.downsampled(at: url, maxPixel: maxDimension)
        }.value
        if let img {
            let mi = MediaItem(id: ref, kind: isVideo ? .video : .image, image: img, videoURL: isVideo ? url : nil)
            thumbCache.setObject(Boxed(mi), forKey: "\(ref)@\(Int(maxDimension.rounded()))" as NSString, cost: Self.decodedCost(mi))
        }
        return img
    }

    /// Pixel dimensions of a media ref WITHOUT decoding the full bitmap — ImageIO reads just the header for
    /// images; videos use the (cached, off-main) poster if present, else a sane default. Used for feed
    /// aspect ratios during scroll, where decoding the full image only to read `.size` was a main-thread hitch.
    private var sizeCache: [String: CGSize] = [:]
    func pixelSize(_ ref: String) -> CGSize? {
        if let s = sizeCache[ref] { return s }
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref) else { return nil }
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
            sizeCache[ref] = s; return s
        }
        if kind == .video, let poster = cacheGet(ref)?.image, poster.size.width > 0 {
            sizeCache[ref] = poster.size; return poster.size
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
}

// MARK: - Device pin (#2) — local retention exemption

/// DEVICE-LOCAL "keep on this device" set: media the user asked to retain here, exempt from EVERY
/// cleanup path (orphan sweep, the age/size limit sweep, and the cleanup screen marks it ineligible).
/// It is NOT synced to other devices and NOT hoisted anywhere in the feed — purely a local retention
/// exemption. Refs are stored verbatim; callers union each ref's on-disk stems into the sweep keep-set.
@MainActor
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

/// A graceful placeholder for a referenced blob whose bytes aren't on disk. Three states:
///  • deliberately evicted (cleanup / limit sweep) → a "Download N MB" affordance (re-fetches on tap);
///  • actively downloading → a spinner;
///  • relay/peers no longer have it → "No longer available" (with Retry).
/// Media that's simply still syncing (never evicted) keeps the plain "still loading" spinner.
struct MissingMediaPlaceholder: View {
    let ref: String
    var isVideo: Bool = false
    @ObservedObject private var feed = FeedStore.shared
    @ObservedObject private var evicted = EvictedMediaStore.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemFill))
            content
        }
    }

    @ViewBuilder private var content: some View {
        if feed.downloadingMedia.contains(ref) {
            VStack(spacing: 8) {
                ProgressView()
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        } else if feed.unavailableMedia.contains(ref) {
            VStack(spacing: 8) {
                Image(systemName: "wifi.slash").font(.title2).foregroundStyle(.secondary)
                Text("No longer available").font(.caption).foregroundStyle(.secondary)
                Button("Retry") { feed.downloadEvicted(ref) }
                    .font(.caption.weight(.semibold)).buttonStyle(.borderless).tint(HavenTheme.pink)
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
                ProgressView()
                Text(isVideo ? "Video still loading…" : "Media still loading…")
                    .font(.caption).foregroundStyle(.secondary)
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
                        Text("Sorted by size. Removing an item frees only the copy on this device — the post stays and can be re-downloaded from your relay. “Keep on this device” exempts an item from every cleanup.")
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
        Group {
            if let img, loadedRef == ref {
                // Fade via opacity ONLY — an `.animation(value:)`/`.transition` on a view being inserted
                // into a scrolling LazyVStack bleeds into the cell's LAYOUT and jitters the scroll position.
                // A plain opacity state animated in `onAppear` fades the image without touching layout.
                Image(platformImage: img).resizable().aspectRatio(contentMode: contentMode)
                    .opacity(shown ? 1 : 0)
                    .onAppear { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
            } else {
                placeholder()
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
