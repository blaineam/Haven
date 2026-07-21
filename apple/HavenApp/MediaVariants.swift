import Foundation

/// Wire-format helpers for video **poster** frames, optional **original** companions, and
/// display filtering. A post's `media: [String]` is a signed flat list — these synthetic refs
/// ride alongside real `img_`/`vid_`/`file_` content addresses so any client can reconstruct
/// the pairing without a schema change.
///
/// Synthetic schemes (multi-char URI, so `MediaStore.isSynthetic` already filters them from
/// fetch/upload loops):
///
///   `poster:<videoRef>:<imageRef>`   — poster JPEG for a video
///   `orig:<optimizedRef>:<originalRef>` — uncompressed original sitting beside the optimized
///
/// Display rules:
/// - Posters are images; they may render as the video's still, or as their own slide.
/// - Originals are NOT shown in the feed carousel — only via "Show original" when present.
/// - Markers themselves never render.
enum MediaVariants {

    // MARK: - Markers

    static func posterMarker(video: String, poster: String) -> String {
        "poster:\(video):\(poster)"
    }

    static func originalMarker(optimized: String, original: String) -> String {
        "orig:\(optimized):\(original)"
    }

    /// `poster:<video>:<image>` → (video, poster image).
    static func parsePoster(_ ref: String) -> (video: String, poster: String)? {
        guard ref.hasPrefix("poster:") else { return nil }
        let rest = String(ref.dropFirst("poster:".count))
        // video and poster refs themselves may contain nothing with ':', but be defensive:
        // split on the LAST colon so a future scheme-bearing ref still works.
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let video = String(rest[..<colon])
        let poster = String(rest[rest.index(after: colon)...])
        guard !video.isEmpty, !poster.isEmpty else { return nil }
        return (video, poster)
    }

    /// `orig:<optimized>:<original>` → (optimized, original).
    static func parseOriginal(_ ref: String) -> (optimized: String, original: String)? {
        guard ref.hasPrefix("orig:") else { return nil }
        let rest = String(ref.dropFirst("orig:".count))
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let optimized = String(rest[..<colon])
        let original = String(rest[rest.index(after: colon)...])
        guard !optimized.isEmpty, !original.isEmpty else { return nil }
        return (optimized, original)
    }

    // MARK: - Lookups

    /// Poster image ref for a given video, if the post/DM declared one.
    static func poster(for video: String, in media: [String]) -> String? {
        for r in media {
            if let p = parsePoster(r), p.video == video { return p.poster }
        }
        return nil
    }

    /// Original (uncompressed) companion for an optimized video/image, if declared.
    static func original(for optimized: String, in media: [String]) -> String? {
        for r in media {
            if let o = parseOriginal(r), o.optimized == optimized { return o.original }
        }
        return nil
    }

    /// True when the media list declares an original companion for this ref.
    static func hasOriginal(_ ref: String, in media: [String]) -> Bool {
        original(for: ref, in: media) != nil
    }

    /// Every original ref declared in the list (for backup/fetch bookkeeping).
    static func allOriginals(in media: [String]) -> [String] {
        media.compactMap { parseOriginal($0)?.original }
    }

    /// Every poster image ref declared in the list.
    static func allPosters(in media: [String]) -> [String] {
        media.compactMap { parsePoster($0)?.poster }
    }

    // MARK: - Display filtering

    /// Refs the feed/DM bubble should actually render as slides.
    ///
    /// Drops synthetic markers and original companions (those only appear via "Show original").
    /// Keeps posters as images so super-data-saver can show them without the video bytes.
    /// When a video has a declared poster, the poster is kept *and* the video — the player
    /// uses the poster as its still; data-saver mode can hide the video until play.
    static func displayRefs(_ media: [String]) -> [String] {
        let originals = Set(allOriginals(in: media))
        return media.filter { ref in
            if parsePoster(ref) != nil { return false }
            if parseOriginal(ref) != nil { return false }
            if originals.contains(ref) { return false }
            return true
        }
    }

    /// Refs that must be fetched for the message to be usable under super data saver:
    /// images, audio, files, posters — never full videos or originals.
    static func dataSaverPrefetchRefs(_ media: [String]) -> [String] {
        let display = displayRefs(media)
        let posters = Set(allPosters(in: media))
        var out: [String] = []
        for r in display {
            if posters.contains(r) { out.append(r); continue }
            // Kind by prefix — no MediaStore dependency so this file stays unit-testable.
            if r.hasPrefix("img_") || r.hasPrefix("i:") || r.hasPrefix("aud_") || r.hasPrefix("a:")
                || r.hasPrefix("file_") {
                out.append(r)
            } else if let poster = poster(for: r, in: media) {
                out.append(poster)
            }
            // videos (vid_/v:) deliberately skipped — download on play
        }
        // Always include declared posters even if their video is the only display ref.
        for p in allPosters(in: media) where !out.contains(p) { out.append(p) }
        return out
    }

    /// Build the media array slice for a prepared video: poster (if any) + optimized + markers +
    /// optional original. Order is stable so older clients that just render every non-synthetic
    /// ref still see poster then video.
    static func composeVideoMedia(poster: String?, optimized: String, original: String?) -> [String] {
        var out: [String] = []
        if let poster, !poster.isEmpty {
            out.append(poster)
            out.append(posterMarker(video: optimized, poster: poster))
        }
        out.append(optimized)
        if let original, !original.isEmpty, original != optimized {
            out.append(original)
            out.append(originalMarker(optimized: optimized, original: original))
        }
        return out
    }
}
