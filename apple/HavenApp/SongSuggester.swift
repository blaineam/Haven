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
extension SongSuggester {

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
            // 0.6 was far too strict — VNClassifyImageRequest's confidences run low and it was
            // yielding nothing at all, which is half of why suggestions had no themes to work with.
            .filter { $0.confidence > 0.25 && !Self.uselessLabels.contains($0.identifier) }
            .prefix(limit)
        // Vision identifiers are lowercase, sometimes hyphenated compounds ("hot_air_balloon").
        return hits.map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    /// Labels that describe every photograph ever taken and therefore distinguish nothing.
    static let uselessLabels: Set<String> = [
        "people", "person", "adult", "man", "woman", "indoor", "outdoor", "sky", "material",
        "structure", "plant", "object", "light", "color", "texture", "day", "night",
    ]





    // MARK: - Suggesting

    /// Songs for a post, most relevant first, excluding anything already used.
    ///
    /// `exclude` is what stops an import scoring three hundred posts with the same track: the
    /// importer accumulates every catalog id it has attached and passes them back in, so each post
    /// takes the best song not yet spoken for. It is a preference, not a hard rule — if a search
    /// only returns songs already used, reusing one still beats leaving the post silent.
    static func suggestions(themes: [String], genre: String?, year: Int, month: Int = 0,
                            exclude: Set<String> = [], limit: Int = 5) async -> [TrackRefFfi] {
        var seen = Set<String>()
        var fresh: [TrackRefFfi] = []
        var reused: [TrackRefFfi] = []

        for term in terms(themes: themes, genre: genre, year: year, month: month) {
            let songs: [MusicKit.Song]
            do {
                songs = try await catalog(term)
            } catch {
                // Loud on purpose. This used to be `try?`, so when the request started failing —
                // an over-limit parameter — every post silently got no suggestion and the feature
                // looked switched off rather than broken.
                HavenLog.sync("song search failed for '\(term)': \(error.localizedDescription)")
                continue
            }
            HavenLog.sync("song-suggest   term '\(term)' -> \(songs.count) results")
            for song in rankedByEra(songs, year: year) {
                let id = "\(song.id.rawValue)~"
                guard seen.insert(id).inserted else { continue }
                guard isSuitable(song) else { continue }
                let ref = TrackRefFfi(catalogId: id, title: song.title, artist: song.artistName,
                                      artworkUrl: song.artwork?.url(width: 120, height: 120)?.absoluteString ?? "",
                                      durationMs: UInt64((song.duration ?? 0) * 1000))
                if exclude.contains(id) { reused.append(ref) } else { fresh.append(ref) }
            }
            // Keep going past the first satisfying term. Stopping early meant the pool came from
            // ONE search, so the "random" pick chose between 8 near-identical results; drawing from
            // a couple of terms is what makes two posts actually sound different.
            if fresh.count >= limit * 2 { break }
        }
        // Unused songs first, then already-used ones as a fallback so a post is never left bare
        // purely because the catalog was small.
        return Array((fresh + reused).prefix(limit))
    }

    /// One song for a post — the importer's entry point.
    ///
    /// Asks for a HANDFUL and picks among them at random rather than taking the single best. The
    /// ranking below is a soft preference (era, then catalog popularity), and treating it as an
    /// order rather than a winner is most of what stops an archive sounding like one playlist on
    /// repeat: with no caption and no strong visual subject, two posts from the same year search
    /// identically, so if the top result always won they would always match.
    static func song(themes: [String], genre: String?, year: Int, month: Int = 0,
                     exclude: Set<String>) async -> TrackRefFfi? {
        let pool = await suggestions(themes: themes, genre: genre, year: year, month: month,
                                     exclude: exclude, limit: 8)
        let pick = pool.randomElement()
        // The whole point of theming is that the choice should be explicable. Without this the
        // only way to judge "is it matching on content?" is to stare at chips in the feed and
        // guess — so log what it had to work with and what it did with it.
        HavenLog.sync("song-suggest themes=\(themes.isEmpty ? "[none]" : themes.joined(separator: "+")) "
            + "genre=\(genre?.split(separator: ",").first.map(String.init) ?? "-") "
            + "pool=\(pool.count) -> \(pick.map { "\($0.title) — \($0.artist)" } ?? "NOTHING")")
        return pick
    }



    /// Is this song fit to be attached to someone's post WITHOUT them hearing it first?
    ///
    /// A suggestion is different from a search result. The user picked a search result on purpose;
    /// a suggestion is something Haven put on their family's feed on their behalf, so the bar is
    /// "safe to attach unheard", not "plausibly relevant".
    static func isSuitable(_ song: MusicKit.Song) -> Bool {
        // Never suggest explicit content. Haven circles are family and close friends, and an import
        // attaches hundreds of these at once — nobody is auditioning them one by one.
        if song.contentRating == .explicit { return false }
        return isLikelyInUsersLanguage("\(song.title) \(song.artistName)")
    }






    private static func catalog(_ term: String) async throws -> [MusicKit.Song] {
        var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        // 25 is the MAXIMUM MusicCatalogSearchRequest accepts. Asking for 50 to widen the pool made
        // every request throw, and because this is called as `try?` the failure was silent: the
        // suggester simply returned nothing for every post, so only Shazam-identified posts ended
        // up with a chip. Widen the pool with MORE TERMS (below), never with a bigger limit.
        req.limit = 25
        return Array(try await req.response().songs)
    }

    /// Prefer releases near the post's year — but only as a PREFERENCE.
    ///
    /// Songs the same distance from the target year are interchangeable for this purpose, so their
    /// order is shuffled rather than fixed by catalog rank. Sorting them deterministically meant one
    /// song was permanently "the best 2023 indie track" and won every single time that search ran.
    /// Era still dominates; which of the equally-close songs surfaces does not.
    private static func rankedByEra(_ songs: [MusicKit.Song], year: Int) -> [MusicKit.Song] {
        func distance(_ s: MusicKit.Song) -> Int {
            guard let d = s.releaseDate else { return 999 }
            return abs(Calendar.current.component(.year, from: d) - year)
        }
        return Dictionary(grouping: songs, by: distance)
            .sorted { $0.key < $1.key }
            .flatMap { $0.value.shuffled() }
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
