import SwiftUI
import AVFoundation
import AVKit
import CoreImage
import CoreLocation
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
                Spacer()
                Button(exporting ? "Trimming…" : "Trim") { Task { await export() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(exporting || duration == 0)
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

enum MediaKind: String {
    case image, video, audio
    var ext: String {
        switch self {
        case .image: return "jpg"
        case .video: return "mp4"
        case .audio: return "m4a"
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

    private var dir: URL {
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
    private func fileURL(_ ref: String) -> URL? {
        guard let kind = MediaKind(ref: ref) else { return nil }
        return dir.appendingPathComponent("\(ref).\(kind.ext)")
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

    @discardableResult
    func addImage(_ image: PlatformImage) -> String {
        let ref = "img_\(UUID().uuidString)"
        // Optimize: downscale very large photos + compress, so they're light to send —
        // but keep it high-res (longest edge up to 2560, well above 1080p).
        let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        // Bake EXIF orientation into the pixels: Android's BitmapFactory ignores the orientation tag,
        // so a portrait iPhone photo arrives sideways unless we normalize it to .up here.
        // Auto-optimize → 2048px JPEG @ 70% (small + universally compatible). Off → original quality.
        let img = Self.normalizedUp(optimize ? Self.downscale(image, maxDimension: 2048) : image)
        let quality: CGFloat = optimize ? 0.70 : 0.95
        if let data = img.jpegData(compressionQuality: quality), let url = fileURL(ref) {
            try? data.write(to: url)
        }
        cachePut(ref, MediaItem(id: ref, kind: .image, image: img, videoURL: nil))
        return ref
    }

    /// Async because optimizing transcodes the video (AVAssetExportSession). Without
    /// this, full-size originals (often 50–200MB) are too big to seal + send P2P.
    @discardableResult
    func addVideo(url src: URL) async -> String {
        let ref = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(ref) else { return ref }
        try? FileManager.default.removeItem(at: dst)
        var ok = false
        if CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId) {
            // Auto-optimize (default): re-encode to 1080p H.264 with a faststart moov atom — small and
            // universally playable, including on Androids that can't decode the iPhone's native HEVC.
            ok = await Self.optimizeVideo(src, to: dst)
        }
        // Auto-optimize OFF: share in the ORIGINAL format + quality (no transcode). Still do a lossless
        // passthrough remux to strip GPS/device metadata AND move the moov atom to the front (faststart),
        // so playback starts fast — neither changes the codec or quality. Falls back to a raw copy.
        // (Note: with optimize off, an HEVC source stays HEVC, so it may not play on HEVC-less devices —
        //  that's the explicit trade for "original quality as-is".)
        if !ok {
            ok = await Self.stripVideoMetadata(src, to: dst)
        }
        if !ok {
            try? FileManager.default.copyItem(at: src, to: dst)
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
        export.metadata = []   // no location/maker metadata travels with shared media
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
        let newRef = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(newRef),
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else { return nil }
        export.outputURL = dst
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: duration, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else { return nil }
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
        let newRef = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(newRef),
              let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)
        else { return nil }
        export.outputURL = dst
        export.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else { return nil }
        cachePut(newRef, MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        return newRef
    }

    /// Adopt an externally-trimmed video file as a new ref.
    func importTrimmed(_ url: URL) -> String {
        let ref = "vid_\(UUID().uuidString)"
        if let dst = fileURL(ref) {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: url, to: dst)
            cachePut(ref, MediaItem(id: ref, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        }
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
            return replaceImage(ref: ref, with: filtered) ? ref : ref
        case .video:
            return await filteredVideo(ref, filter: filter) ?? ref
        case .audio:
            return ref
        }
    }

    /// Overwrite an image ref's bytes + cache with a new image (same ref). Returns whether it
    /// stuck.
    @discardableResult
    private func replaceImage(ref: String, with image: PlatformImage) -> Bool {
        guard MediaKind(ref: ref) == .image, let url = fileURL(ref) else { return false }
        let optimize = CircleSettingsStore.shared.autoOptimize(FeedStore.shared.activeCircleId)
        let img = optimize ? Self.downscale(image, maxDimension: 2048) : image
        let quality: CGFloat = optimize ? 0.70 : 0.95
        guard let data = img.jpegData(compressionQuality: quality) else { return false }
        do { try data.write(to: url) } catch { return false }
        cachePut(ref, MediaItem(id: ref, kind: .image, image: img, videoURL: nil))
        return true
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
        let newRef = "vid_\(UUID().uuidString)"
        guard let dst = fileURL(newRef),
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            return nil
        }
        try? FileManager.default.removeItem(at: dst)
        export.outputURL = dst
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = composition
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: dst)
            return nil
        }
        cachePut(newRef, MediaItem(id: newRef, kind: .video, image: Self.poster(for: dst), videoURL: dst))
        return newRef
    }

    /// Downscale so the longest side is at most `maxDimension` (keeps aspect ratio).
    /// Cross-platform via `PlatformImage.downscaled` (Platform.swift).
    static func downscale(_ image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
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
        let ref = "aud_\(UUID().uuidString)"
        if let dst = fileURL(ref) {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            cachePut(ref, MediaItem(id: ref, kind: .audio, image: nil, videoURL: dst))
        }
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
    func store(_ ref: String, _ bytes: Data) {
        guard let kind = MediaKind(ref: ref), let url = fileURL(ref) else { return }
        try? bytes.write(to: url)
        switch kind {
        case .image: cachePut(ref, MediaItem(id: ref, kind: .image, image: PlatformImage(data: bytes), videoURL: nil))
        case .video: cachePut(ref, MediaItem(id: ref, kind: .video, image: Self.poster(for: url), videoURL: url))
        case .audio: cachePut(ref, MediaItem(id: ref, kind: .audio, image: nil, videoURL: url))
        }
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
    func adopt(_ ref: String, from temp: URL) {
        guard MediaKind(ref: ref) != nil, let dst = fileURL(ref) else { return }
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: temp, to: dst) } catch { return }
        // Do NOT eagerly decode the full image here. With own-device media sync, a burst of received blobs
        // each got decoded to a ~20MB bitmap on arrival → memory spike → iOS jetsam (SIGKILL) on launch.
        // Just drop any stale cache entry; item()/thumbnail() decode lazily (and downsampled) when rendered.
        cacheRemove(ref)
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
            // Decode a DOWNSAMPLED bitmap straight from the file via ImageIO — never materialize the full
            // 2560px image in memory (that spike OOM-jetsammed iOS on launch).
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
    static func downsampled(at url: URL, maxPixel: CGFloat) -> PlatformImage? {
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
