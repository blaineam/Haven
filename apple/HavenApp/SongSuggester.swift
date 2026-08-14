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
            if w.count > 3 && !words.contains(w) && !Self.blandWords.contains(w) { words.append(w) }
            return words.count < limit * 3
        }
        return Array(words.prefix(limit))
    }

    /// Nouns and adjectives that carry no subject — the words a caption uses to be a sentence.
    ///
    /// These reliably come FIRST ("Tonight is fun…", "This morning I got to…", "My second book…"),
    /// so without this the generic word wins and the one that actually says what the post is about
    /// — halloween, condors, eclipse, the dog's name — never gets used.
    private static let blandWords: Set<String> = [
        "today", "tonight", "yesterday", "tomorrow", "morning", "afternoon", "evening", "night",
        "time", "year", "week", "month", "day", "days", "weeks", "years", "hours", "minutes",
        "thing", "things", "stuff", "some", "more", "most", "much", "many", "lot", "lots",
        "best", "better", "good", "great", "nice", "cool", "fun", "last", "first", "next",
        "second", "third", "little", "long", "short", "here", "there", "everyone", "everything",
        "people", "someone", "something", "anything", "photo", "photos", "picture", "pictures",
        "video", "videos", "post", "instagram", "sure", "able", "back", "really", "very",
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
            guard let songs = try? await catalog(term) else { continue }
            for song in rankedByEra(songs, year: year) {
                let id = "\(song.id.rawValue)~"
                guard seen.insert(id).inserted else { continue }
                guard isSuitable(song) else { continue }
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
        return pool.randomElement()
    }

    /// Search terms, most specific first.
    ///
    /// KEEP THESE THEMATIC AND SHORT. Apple Music search is lexical — it matches song titles and
    /// artist names, not meaning — so "beautiful" finds songs with "beautiful" in the title, which
    /// is exactly the association wanted. Padding that into "beautiful songs 2023" hands the
    /// matcher two generic tokens to chew on, and every post's query converges on the same popular
    /// results however distinct its theme was. Caption themes were varied all along (61 distinct
    /// across 40 real captions); the query around them was throwing that variety away.
    ///
    /// Era is deliberately NOT in the query. `rankedByEra` re-orders results by release date after
    /// the fact, which gets the same effect without polluting the search.
    static func terms(themes: [String], genre: String?, year: Int, month: Int = 0) -> [String] {
        let genreHead = genre?.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " Music", with: "")
        var out: [String] = []
        for theme in themes {
            out.append(theme)                                             // purely thematic
            if let g = genreHead, !g.isEmpty { out.append("\(theme) \(g)") }
        }
        if let g = genreHead, !g.isEmpty { out.append(g) }
        // Last resorts, for a post with no caption and no recognisable subject. The month is here
        // so that even those don't all issue one identical query across a whole archive.
        if (1...12).contains(month) { out.append("\(Self.monthNames[month - 1]) \(year)") }
        out.append("\(year) hits")
        return out
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]

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

    /// Reject songs that look like they are in a language the user does not read.
    ///
    /// Apple Music does not expose a song's language, so this infers from the title and artist. Two
    /// signals, because one is not enough:
    ///
    ///   SCRIPT is decisive. "夜に駆ける" is unmistakably not English no matter what a statistical
    ///   language model says about it — and NLLanguageRecognizer called that one *Hungarian* at 0.28,
    ///   which is exactly how a Japanese song slipped through a language-only check.
    ///
    ///   LANGUAGE is a tiebreak for same-script cases ("Bailando", "La Vie En Rose"), where script
    ///   tells us nothing. Song titles are short, so detection rarely gets very confident; the
    ///   threshold is set where real English titles from a real library still pass ("Beautiful
    ///   Things" scores 0.70) but confident foreign ones do not.
    ///
    /// Ambiguous stays KEPT. A false reject costs a suggestion nobody misses; a false accept puts a
    /// song the user cannot read onto their own post.
    static func isLikelyInUsersLanguage(_ text: String) -> Bool {
        if usesForeignScript(text) { return false }
        // Very short strings ("Halo", "SZA") detect essentially at random.
        guard text.count >= 12 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.65 else { return true }
        return userLanguages.contains(language.rawValue)
    }

    /// Does the text lean on a script none of the user's languages are written in?
    ///
    /// Judged on the share of LETTERS rather than any single character, so one stray accented or
    /// borrowed glyph in an otherwise readable title doesn't disqualify it.
    static func usesForeignScript(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3 else { return false }
        let foreign = letters.filter { scalar in
            guard let script = script(of: scalar) else { return false }
            return !userScripts.contains(script)
        }
        return Double(foreign.count) / Double(letters.count) > 0.34
    }

    private static func script(of s: Unicode.Scalar) -> String? {
        switch s.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF: return "latin"   // incl. accented Latin
        case 0x0370...0x03FF:                  return "greek"
        case 0x0400...0x04FF:                  return "cyrillic"
        case 0x0590...0x05FF:                  return "hebrew"
        case 0x0600...0x06FF:                  return "arabic"
        case 0x0900...0x097F:                  return "devanagari"
        case 0x0E00...0x0E7F:                  return "thai"
        case 0x3040...0x30FF, 0x4E00...0x9FFF: return "cjk"      // kana + han
        case 0xAC00...0xD7AF, 0x1100...0x11FF: return "hangul"
        default:                               return nil        // digits, marks, unknown — ignored
        }
    }

    /// Scripts the user's own languages are written in. Latin is always included: a device set to
    /// any language still shows Latin-titled songs throughout Apple Music.
    private static let userScripts: Set<String> = {
        var out: Set<String> = ["latin"]
        for code in userLanguages {
            switch code {
            case "ja", "zh":             out.insert("cjk")
            case "ko":                   out.formUnion(["hangul", "cjk"])
            case "ru", "uk", "bg", "sr": out.insert("cyrillic")
            case "el":                   out.insert("greek")
            case "he", "yi":             out.insert("hebrew")
            case "ar", "fa", "ur":       out.insert("arabic")
            case "hi", "mr", "ne":       out.insert("devanagari")
            case "th":                   out.insert("thai")
            default:                     break
            }
        }
        return out
    }()

    /// The user's preferred language codes, reduced to their base ("en-US" → "en"), plus the region
    /// locale's own language so a device set to one language in another country still matches.
    private static let userLanguages: Set<String> = {
        var codes = Locale.preferredLanguages.map { String($0.prefix(2)) }
        if let mine = Locale.current.language.languageCode?.identifier { codes.append(mine) }
        return Set(codes)
    }()

    private static func catalog(_ term: String) async throws -> [MusicKit.Song] {
        var req = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        // A wider net, because the pool is shared across an entire archive: 25 was barely more
        // than the exclude set could burn through in a single year's worth of posts.
        req.limit = 50
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
