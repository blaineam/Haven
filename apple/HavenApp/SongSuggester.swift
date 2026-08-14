import Foundation
import AVFoundation
import MusicKit
import Vision
import NaturalLanguage
#if canImport(UIKit)
import UIKit
#endif

/// Suggests songs for a post from what the post is actually ABOUT — what's in the picture, what the
/// caption says, and when it was taken.
///
/// Used in two places, deliberately the same engine:
///   * the Instagram importer, filling silent posts with something era-appropriate, and
///   * the composer's song picker, as the starting list for someone with no song in mind.
///
/// The importer's first version searched one term per year ("2024 hits"), took the top hit, and so
/// gave EVERY silent post from that year the identical song. Variety is not a nicety here — a
/// hundred imported posts scored with one track is worse than scoring none of them.
enum SongSuggester {

    // MARK: - What the post is about

    /// Scene/subject labels for an image, via Vision. "beach", "sunset", "dog" — the words that make
    /// one post's suggestion different from the next one's.
    ///
    /// Confidence is deliberately strict: a weak guess pulls the search somewhere random, and a
    /// wrong theme is worse than no theme, because no theme still leaves genre and era to work with.
    static func visualThemes(_ image: Data, limit: Int = 2) -> [String] {
        #if canImport(UIKit)
        guard let ui = UIImage(data: image), let cg = ui.cgImage else { return [] }
        #else
        guard let src = CGImageSourceCreateWithData(image as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
        #endif
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let hits = (request.results ?? [])
            .filter { $0.confidence > 0.6 && !Self.uselessLabels.contains($0.identifier) }
            .prefix(limit)
        // Vision identifiers are lowercase, sometimes hyphenated compounds ("hot_air_balloon").
        return hits.map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    /// Labels that describe every photograph ever taken and therefore distinguish nothing.
    private static let uselessLabels: Set<String> = [
        "people", "person", "adult", "man", "woman", "indoor", "outdoor", "sky", "material",
        "structure", "plant", "object", "light", "color", "texture", "day", "night",
    ]

    /// Content words from a caption — the nouns and adjectives that carry the subject.
    ///
    /// Hashtags are stripped of their '#' and kept: on an Instagram caption they are frequently the
    /// most descriptive word in the whole post.
    static func captionThemes(_ caption: String, limit: Int = 2) -> [String] {
        let cleaned = caption.replacingOccurrences(of: "#", with: " ")
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = cleaned
        var words: [String] = []
        tagger.enumerateTags(in: cleaned.startIndex..<cleaned.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard let tag, tag == .noun || tag == .adjective else { return true }
            let w = String(cleaned[range]).lowercased()
            if w.count > 3 && !words.contains(w) { words.append(w) }
            return words.count < limit * 3
        }
        return Array(words.prefix(limit))
    }

    // MARK: - Suggesting

    /// Songs for a post, most relevant first, excluding anything already used.
    ///
    /// `exclude` is what stops an import scoring three hundred posts with the same track: the
    /// importer accumulates every catalog id it has attached and passes them back in, so each post
    /// takes the best song not yet spoken for. It is a preference, not a hard rule — if a search
    /// only returns songs already used, reusing one still beats leaving the post silent.
    static func suggestions(themes: [String], genre: String?, year: Int,
                            exclude: Set<String> = [], limit: Int = 5) async -> [TrackRefFfi] {
        var seen = Set<String>()
        var fresh: [TrackRefFfi] = []
        var reused: [TrackRefFfi] = []

        for term in terms(themes: themes, genre: genre, year: year) {
            guard let songs = try? await catalog(term) else { continue }
            for song in rankedByEra(songs, year: year) {
                let id = "\(song.id.rawValue)~"
                guard seen.insert(id).inserted else { continue }
                let ref = TrackRefFfi(catalogId: id, title: song.title, artist: song.artistName,
                                      artworkUrl: song.artwork?.url(width: 120, height: 120)?.absoluteString ?? "",
                                      durationMs: UInt64((song.duration ?? 0) * 1000))
                if exclude.contains(id) { reused.append(ref) } else { fresh.append(ref) }
            }
            if fresh.count >= limit { break }
        }
        // Unused songs first, then already-used ones as a fallback so a post is never left bare
        // purely because the catalog was small.
        return Array((fresh + reused).prefix(limit))
    }

    /// One song for a post — the importer's entry point.
    static func song(themes: [String], genre: String?, year: Int,
                     exclude: Set<String>) async -> TrackRefFfi? {
        await suggestions(themes: themes, genre: genre, year: year, exclude: exclude, limit: 1).first
    }

    /// Search terms, most specific first, so the most post-specific result wins when one exists.
    ///
    /// Several terms rather than one is the other half of the variety fix: two posts from the same
    /// year now differ by subject and caption, and only fall back to the generic year search when
    /// there is nothing else to go on.
    static func terms(themes: [String], genre: String?, year: Int) -> [String] {
        let genreHead = genre?.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " Music", with: "")
        var out: [String] = []
        for theme in themes {
            if let g = genreHead, !g.isEmpty { out.append("\(theme) \(g)") }
            out.append("\(theme) songs \(year)")
        }
        if let g = genreHead, !g.isEmpty { out.append("\(g) \(year)") }
        out.append("\(year) hits")
        return out
    }

    private static func catalog(_ term: String) async throws -> [MusicKit.Song] {
        var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        req.limit = 25
        return Array(try await req.response().songs)
    }

    /// Prefer releases near the post's year; ties keep catalog order, which reflects popularity.
    private static func rankedByEra(_ songs: [MusicKit.Song], year: Int) -> [MusicKit.Song] {
        func distance(_ s: MusicKit.Song) -> Int {
            guard let d = s.releaseDate else { return 999 }
            return abs(Calendar.current.component(.year, from: d) - year)
        }
        return songs.enumerated()
            .sorted { (distance($0.element), $0.offset) < (distance($1.element), $1.offset) }
            .map(\.element)
    }

    // MARK: - Audio presence (used to decide suggest-vs-identify)

    /// Does this media have an audible track already? Photos never do; a video usually does.
    ///
    /// Asked of the staged file rather than guessed from the extension, because "is a video" and
    /// "makes sound" are different questions — a screen recording, a time-lapse or a clip muted
    /// before posting are silent videos that deserve a song as much as a photo does.
    static func hasAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            return false
        }
        for t in tracks {
            let enabled = (try? await t.load(.isEnabled)) ?? true
            let duration = (try? await t.load(.timeRange).duration.seconds) ?? 0
            if enabled && duration > 0.1 { return true }
        }
        return false
    }

    /// Ask once, up front — not once per post.
    static func authorize() async -> Bool {
        await MusicAuthorization.request() == .authorized
    }
}
