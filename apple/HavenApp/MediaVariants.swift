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
///   `thumb:<contentRef>:<thumbRef>`  — tiny (~256px, ≤32KB) preview companion for a photo
///
/// Display rules:
/// - Posters are images; they may render as the video's still, or as their own slide.
/// - Originals are NOT shown in the feed carousel — only via "Show original" when present.
/// - Thumbs never render as slides — they back the loading placeholder (blurred) until the
///   full-size bytes arrive, and are prefetched everywhere (tiny, so exempt from data saver).
/// - Markers themselves never render.
enum MediaVariants {

    // MARK: - Markers

    static func posterMarker(video: String, poster: String) -> String {
        "poster:\(video):\(poster)"
    }

    static func originalMarker(optimized: String, original: String) -> String {
        "orig:\(optimized):\(original)"
    }

    static func thumbMarker(content: String, thumb: String) -> String {
        "thumb:\(content):\(thumb)"
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

    /// `thumb:<content>:<thumb>` → (content, thumb image).
    static func parseThumb(_ ref: String) -> (content: String, thumb: String)? {
        guard ref.hasPrefix("thumb:") else { return nil }
        let rest = String(ref.dropFirst("thumb:".count))
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        let content = String(rest[..<colon])
        let thumb = String(rest[rest.index(after: colon)...])
        guard !content.isEmpty, !thumb.isEmpty else { return nil }
        return (content, thumb)
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

    /// Thumb companion for a content ref, if the post/DM declared one.
    static func thumb(for content: String, in media: [String]) -> String? {
        for r in media {
            if let t = parseThumb(r), t.content == content { return t.thumb }
        }
        return nil
    }

    /// Every thumb image ref declared in the list (prefetched everywhere — tiny by contract).
    static func allThumbs(in media: [String]) -> [String] {
        media.compactMap { parseThumb($0)?.thumb }
    }

    // MARK: - Display filtering

    /// Refs the feed/DM bubble should actually render as slides.
    ///
    /// Drops synthetic markers, original companions (those only appear via "Show original"),
    /// and **poster stills that belong to a video**. The poster rides with the video page as its
    /// still (super data saver shows that still + play until the user taps to download/play) —
    /// keeping it as its own carousel slide made the first page a dead image: tapping zoomed the
    /// still and never pulled the video.
    static func displayRefs(_ media: [String]) -> [String] {
        let originals = Set(allOriginals(in: media))
        let posterImages = Set(allPosters(in: media))
        let thumbImages = Set(allThumbs(in: media))
        return media.filter { ref in
            if parsePoster(ref) != nil { return false }
            if parseOriginal(ref) != nil { return false }
            if parseThumb(ref) != nil { return false }
            if originals.contains(ref) { return false }
            if posterImages.contains(ref) { return false }
            if thumbImages.contains(ref) { return false }
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
        // Thumbs are ≤32KB by contract — always worth fetching, data saver included.
        for t in allThumbs(in: media) where !out.contains(t) { out.append(t) }
        return out
    }

    /// The relay-upload order for a media list's fetchable refs: thumbs first (tiny, unblock the
    /// placeholder), then posters, then everything else in list order. Synthetic markers dropped.
    static func uploadOrder(_ media: [String]) -> [String] {
        let thumbs = Set(allThumbs(in: media))
        let posters = Set(allPosters(in: media))
        func rank(_ r: String) -> Int {
            if thumbs.contains(r) { return 0 }
            if posters.contains(r) { return 1 }
            return 2
        }
        // Keep list order within a rank (stable sort) and skip markers — a ':' at index > 1 is a
        // synthetic scheme (mirror of MediaStore.isSynthetic, inlined so this file stays test-only).
        let real = media.filter { r in
            guard let i = r.firstIndex(of: ":") else { return true }
            return r.distance(from: r.startIndex, to: i) <= 1
        }
        return real.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
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

    // MARK: - Re-optimize rewrite

    /// Rewrite a post's media array after re-optimize.
    ///
    /// - `swap`: old content ref → new content ref (stills/videos that were re-encoded).
    /// - `posters`: **old** video ref → poster image ref to attach (or replace). Poster-only
    ///   work uses this with an empty `swap`; a re-encoded video uses both (new clip + new still).
    ///
    /// Why this is not a plain `map { swap[$0] ?? $0 }`:
    /// 1. Re-encoding changes the video's content address — any existing `poster:old:img` marker
    ///    must be rewritten or the still is orphaned from the playable clip.
    /// 2. Already-compressed clips never enter the shrink path, but old posts may still lack a
    ///    published poster. Poster-only work **inserts** `img_` + `poster:` without touching the
    ///    video bytes (length of the array grows — desktop's equal-length check does not apply on
    ///    Apple/Android, which re-sign the full media list).
    /// 3. Replacing a poster must drop the previous poster image ref and marker so they do not
    ///    linger as a second still in the carousel.
    static func rewriteMedia(_ media: [String], swap: [String: String], posters: [String: String]) -> [String] {
        // Old poster stills we are replacing — drop their bare `img_` entries when we hit them.
        var dropPosterImages = Set<String>()
        for (oldVideo, _) in posters {
            if let oldP = poster(for: oldVideo, in: media) {
                dropPosterImages.insert(oldP)
            }
        }
        var out: [String] = []
        var emittedPosterFor = Set<String>() // old video refs already paired

        for ref in media {
            if let (v, p) = parsePoster(ref) {
                if posters[v] != nil {
                    // Replacing this video's poster — marker re-inserted next to the video.
                    continue
                }
                let nv = swap[v] ?? v
                let np = swap[p] ?? p
                out.append(posterMarker(video: nv, poster: np))
                continue
            }
            if let (opt, orig) = parseOriginal(ref) {
                out.append(originalMarker(optimized: swap[opt] ?? opt, original: swap[orig] ?? orig))
                continue
            }
            if dropPosterImages.contains(ref) {
                // Old still that only existed as this video's published poster.
                continue
            }

            let oldRef = ref
            let newRef = swap[ref] ?? ref
            if let posterImg = posters[oldRef], !emittedPosterFor.contains(oldRef) {
                if !out.contains(posterImg) { out.append(posterImg) }
                out.append(posterMarker(video: newRef, poster: posterImg))
                out.append(newRef)
                emittedPosterFor.insert(oldRef)
                continue
            }
            out.append(newRef)
        }

        // Videos that needed a poster but were missing from the list entirely (shouldn't happen)
        // — no-op. Videos present only via swap without appearing as bare refs are covered above.
        return out
    }
}
