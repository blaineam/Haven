import Foundation
import NaturalLanguage

/// The text-only half of `SongSuggester`: what a post is about (caption themes), the search terms those
/// produce, and the "would a reader of this device's languages recognise this title" filter. Split from
/// SongSuggester.swift (MusicKit, Vision, AVFoundation) so it runs in the host-less logic tests.
enum SongSuggester {
    // MARK: - What the post is about

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
        // NLTagger IS NOT AVAILABLE EVERYWHERE. `.lexicalClass` needs language assets that are
        // present on macOS but frequently absent on iOS — where it does not fail, it simply returns
        // no tags at all. Every suggestion in a real import run came through with no themes for
        // exactly this reason, while the same captions tagged perfectly in a macOS test binary.
        //
        // So the tagger is an optimisation, not the mechanism. When it gives nothing, fall back to
        // plain word splitting: it cannot tell a noun from a verb, but "Merry Christmas Eve
        // Everyone!" still yields "christmas", which is the whole job.
        if words.isEmpty { words = plainWords(cleaned, limit: limit) }
        return Array(words.prefix(limit))
    }

    /// Content words with the grammar removed. No model, no assets, works anywhere.
    ///
    /// CAPITALISED WORDS FIRST. Length was the first heuristic and it was a poor one — it surfaced
    /// "themselves", "encouragement" and "appreciation", which are long, abstract, and say nothing
    /// about the post. In a caption the capitalised word is the subject: Christmas, Luma, Condors,
    /// Jerusalem. Sentence-initial words are excluded from that preference, since being first is
    /// not the same as being a name.
    static func plainWords(_ text: String, limit: Int) -> [String] {
        let raw = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
        // THREE tiers, not two. A capital mid-sentence is almost certainly a name and ranks first.
        // A capital that OPENS the sentence is ambiguous — it may be a name ("Luma got cleaned up")
        // or just the first word ("Merry Christmas") — so it ranks second rather than being demoted
        // to ordinary, which is what made "Luma" lose to "groomers" and "cleaned".
        var midSentence: [String] = []
        var sentenceStart: [String] = []
        var ordinary: [String] = []
        var atStart = true
        for word in raw {
            guard !word.isEmpty else { continue }
            let lower = word.lowercased()
            let startsSentence = atStart
            atStart = false
            guard lower.count > 3, !blandWords.contains(lower), !stopWords.contains(lower) else { continue }
            let capitalised = word.first?.isUppercase == true
            if capitalised && !startsSentence { midSentence.append(lower) }
            else if capitalised { sentenceStart.append(lower) }
            else { ordinary.append(lower) }
        }
        var seen = Set<String>()
        return (midSentence + sentenceStart + ordinary.sorted { $0.count > $1.count })
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Grammar the tagger would have discarded for us.
    static let stopWords: Set<String> = [
        "that", "this", "with", "from", "they", "them", "then", "than", "have", "has", "had",
        "been", "being", "were", "was", "will", "would", "could", "should", "just", "only",
        "about", "into", "over", "under", "after", "before", "when", "what", "where", "which",
        "while", "your", "yours", "mine", "ours", "their", "there", "here", "also", "because",
        "trying", "going", "getting", "doing", "make", "made", "take", "took", "come", "came",
        "want", "need", "like", "love", "know", "think", "look", "looks", "looking", "glad",
        "happy", "everyone", "everybody", "always", "never", "still", "even", "some", "such",
    ]

    /// Nouns and adjectives that carry no subject — the words a caption uses to be a sentence.
    ///
    /// These reliably come FIRST ("Tonight is fun…", "This morning I got to…", "My second book…"),
    /// so without this the generic word wins and the one that actually says what the post is about
    /// — halloween, condors, eclipse, the dog's name — never gets used.
    static let blandWords: Set<String> = [
        "today", "tonight", "yesterday", "tomorrow", "morning", "afternoon", "evening", "night",
        "time", "year", "week", "month", "day", "days", "weeks", "years", "hours", "minutes",
        "thing", "things", "stuff", "some", "more", "most", "much", "many", "lot", "lots",
        "best", "better", "good", "great", "nice", "cool", "fun", "last", "first", "next",
        "second", "third", "little", "long", "short", "here", "there", "everyone", "everything",
        "people", "someone", "something", "anything", "photo", "photos", "picture", "pictures",
        "video", "videos", "post", "instagram", "sure", "able", "back", "really", "very",
        "season", "seasons", "family", "friends", "everybody", "moment", "moments",
        "weekend", "week", "today", "life", "world", "place", "home", "house",
    ]

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
        // Last resort only. NOTE what NOT to put here: a bare date like "December 2023" is a
        // lexical search, so it matches songs literally TITLED that — the observed results were
        // "December 2023 — Hiimian" and "december 2023 - steady", which is noise dressed as a
        // suggestion. A mood word gives the catalog something musical to match instead, and
        // rotating it by month keeps same-year posts from all issuing one identical query.
        if (1...12).contains(month) { out.append(Self.moodByMonth[month - 1]) }
        out.append("\(year) hits")
        return out
    }

    /// Seasonal moods, used only when a post gives us nothing else to go on. These are words the
    /// catalog can actually match against song titles, unlike a date.
    private static let moodByMonth = ["new beginnings", "love songs", "spring", "sunshine",
                                      "bloom", "summer nights", "summer", "golden hour",
                                      "autumn", "cozy", "grateful", "winter"]

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
        isLikelyInUsersLanguage(text, userLanguages: Self.userLanguages)
    }

    static func isLikelyInUsersLanguage(_ text: String, userLanguages: Set<String>) -> Bool {
        if usesForeignScript(text, userScripts: scripts(for: userLanguages)) { return false }
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
        usesForeignScript(text, userScripts: Self.userScripts)
    }

    static func usesForeignScript(_ text: String, userScripts: Set<String>) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3 else { return false }
        let foreign = letters.filter { scalar in
            guard let script = script(of: scalar) else { return false }
            return !userScripts.contains(script)
        }
        return Double(foreign.count) / Double(letters.count) > 0.34
    }

    static func script(of s: Unicode.Scalar) -> String? {
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
    private static let userScripts: Set<String> = scripts(for: userLanguages)

    /// The writing systems a reader of `languages` is assumed to read (Latin always).
    static func scripts(for languages: Set<String>) -> Set<String> {
        var out: Set<String> = ["latin"]
        for code in languages {
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
    }

    /// The user's preferred language codes, reduced to their base ("en-US" → "en"), plus the region
    /// locale's own language so a device set to one language in another country still matches.
    private static let userLanguages: Set<String> = {
        var codes = Locale.preferredLanguages.map { String($0.prefix(2)) }
        if let mine = Locale.current.language.languageCode?.identifier { codes.append(mine) }
        return Set(codes)
    }()

}
