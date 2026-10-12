import XCTest

/// The text half of the song suggester: caption themes, search-term construction and the
/// language/script filter. Every logged "no themes" report traced back to this layer, and a wrong
/// theme or term pulls the whole Apple Music search somewhere random.
final class SongThemesTests: XCTestCase {
    private typealias S = SongSuggester

    // MARK: plainWords (the deterministic fallback)

    func testPlainWordsRanksNamesAboveOrdinaryWords() {
        // "Marcus" and "Paris" are capitalised mid-sentence, so they outrank the sentence opener.
        XCTAssertEqual(S.plainWords("Trip with Marcus to Paris", limit: 5), ["marcus", "paris", "trip"])
    }

    func testPlainWordsSentenceStartCapitalIsAmbiguousNotDemoted() {
        // "Luma" opens the sentence: it may be a name, so it ranks above longer lower-case words.
        XCTAssertEqual(S.plainWords("Luma got cleaned up at the groomers", limit: 3), ["luma", "groomers", "cleaned"])
    }

    func testPlainWordsDropsStopBlandAndShortWords() {
        let out = S.plainWords("today we have been going to the house with that dog", limit: 10)
        XCTAssertFalse(out.contains("today"), "bland")
        XCTAssertFalse(out.contains("house"), "bland")
        XCTAssertFalse(out.contains("have"), "stop word")
        XCTAssertFalse(out.contains("been"), "stop word")
        XCTAssertFalse(out.contains("going"), "stop word")
        XCTAssertFalse(out.contains("that"), "stop word")
        XCTAssertFalse(out.contains("dog"), "3 letters or fewer never counts")
        XCTAssertEqual(out, [])
    }

    func testPlainWordsDeDuplicatesAcrossTiersAndHonoursLimit() {
        XCTAssertEqual(S.plainWords("Beach beach BEACH sunset", limit: 5), ["beach", "sunset"])
        XCTAssertEqual(S.plainWords("lighthouse waterfall mountain rainbow", limit: 2), ["lighthouse", "waterfall"],
                       "ordinary words rank by length, longest first")
        XCTAssertEqual(S.plainWords("", limit: 3), [])
        XCTAssertEqual(S.plainWords("... !!! ???", limit: 3), [])
    }

    // MARK: captionThemes

    func testCaptionThemesEmptyAndWhitespace() {
        XCTAssertEqual(S.captionThemes(""), [])
        XCTAssertEqual(S.captionThemes("   \n  "), [])
        XCTAssertEqual(S.captionThemes("#"), [])
    }

    func testCaptionThemesFindsTheSubjectAndNeverReturnsBlandWords() {
        let themes = S.captionThemes("Merry Christmas Eve Everyone!", limit: 3)
        XCTAssertTrue(themes.contains("christmas"), "got \(themes)")
        XCTAssertFalse(themes.contains("everyone"))
        let more = S.captionThemes("Great photo of the best sunset today", limit: 3)
        XCTAssertTrue(more.contains("sunset"), "got \(more)")
        for bland in ["today", "photo", "best", "great"] { XCTAssertFalse(more.contains(bland), "\(bland) in \(more)") }
    }

    func testCaptionThemesStripsHashtagMarkAndRespectsLimit() {
        let tags = S.captionThemes("#sunset #mountains #lighthouse #waterfall", limit: 2)
        XCTAssertLessThanOrEqual(tags.count, 2)
        XCTAssertFalse(tags.isEmpty, "hashtag words are themes once the # is removed")
        XCTAssertFalse(tags.contains { $0.contains("#") })
    }

    // MARK: terms

    func testTermsWithGenreAndMonth() {
        XCTAssertEqual(S.terms(themes: ["beach", "sunset"], genre: "Pop Music, Dance", year: 2023, month: 7),
                       ["beach", "beach Pop", "sunset", "sunset Pop", "Pop", "summer", "2023 hits"])
    }

    func testTermsWithoutGenreOrMonth() {
        XCTAssertEqual(S.terms(themes: ["dog"], genre: nil, year: 2020), ["dog", "2020 hits"])
        XCTAssertEqual(S.terms(themes: [], genre: nil, year: 2020, month: 13), ["2020 hits"], "an out-of-range month adds no mood")
        XCTAssertEqual(S.terms(themes: [], genre: "", year: 2020), ["2020 hits"])
        XCTAssertEqual(S.terms(themes: [], genre: "  Rock  ", year: 2001), ["Rock", "2001 hits"])
    }

    func testTermsNeverLeadWithABareDate() {
        // "December 2023" is a lexical search that matches songs literally titled that.
        for m in 1...12 {
            let t = S.terms(themes: [], genre: nil, year: 2023, month: m)
            XCTAssertEqual(t.count, 2)
            XCTAssertFalse(t[0].contains("2023"), "month \(m) -> \(t)")
        }
        let moods = Set((1...12).map { S.terms(themes: [], genre: nil, year: 2023, month: $0)[0] })
        XCTAssertEqual(moods.count, 12, "each month rotates a different mood so same-year posts don't share a query")
    }

    // MARK: Script / language

    func testScriptClassification() {
        XCTAssertEqual(S.script(of: "a"), "latin")
        XCTAssertEqual(S.script(of: "é"), "latin")
        XCTAssertEqual(S.script(of: "ж"), "cyrillic")
        XCTAssertEqual(S.script(of: "α"), "greek")
        XCTAssertEqual(S.script(of: "א"), "hebrew")
        XCTAssertEqual(S.script(of: "ع"), "arabic")
        XCTAssertEqual(S.script(of: "क"), "devanagari")
        XCTAssertEqual(S.script(of: "ก"), "thai")
        XCTAssertEqual(S.script(of: "あ"), "cjk")
        XCTAssertEqual(S.script(of: "漢"), "cjk")
        XCTAssertEqual(S.script(of: "한"), "hangul")
        XCTAssertNil(S.script(of: "7"))
        XCTAssertNil(S.script(of: "!"))
    }

    func testScriptsForLanguages() {
        XCTAssertEqual(S.scripts(for: []), ["latin"])
        XCTAssertEqual(S.scripts(for: ["en"]), ["latin"])
        XCTAssertEqual(S.scripts(for: ["ja"]), ["latin", "cjk"])
        XCTAssertEqual(S.scripts(for: ["ko"]), ["latin", "hangul", "cjk"])
        XCTAssertEqual(S.scripts(for: ["ru", "el"]), ["latin", "cyrillic", "greek"])
        XCTAssertEqual(S.scripts(for: ["he"]), ["latin", "hebrew"])
        XCTAssertEqual(S.scripts(for: ["fa"]), ["latin", "arabic"])
        XCTAssertEqual(S.scripts(for: ["hi"]), ["latin", "devanagari"])
        XCTAssertEqual(S.scripts(for: ["th"]), ["latin", "thai"])
    }

    func testForeignScriptShareThreshold() {
        let latin: Set<String> = ["latin"]
        XCTAssertTrue(S.usesForeignScript("Привет мир", userScripts: latin))
        XCTAssertFalse(S.usesForeignScript("Привет мир", userScripts: ["latin", "cyrillic"]))
        XCTAssertFalse(S.usesForeignScript("Café Münchën Señor", userScripts: latin), "accented Latin is still Latin")
        XCTAssertFalse(S.usesForeignScript("Ab", userScripts: latin), "fewer than three letters is never judged")
        XCTAssertFalse(S.usesForeignScript("1234 !!!", userScripts: latin), "digits and punctuation are ignored")
        // 6 foreign of 15 letters = 40% > 34%; 2 of 12 = 17% is one borrowed word, not a foreign title.
        XCTAssertTrue(S.usesForeignScript("Beautiful Привет", userScripts: latin))
        XCTAssertFalse(S.usesForeignScript("Beautiful night да", userScripts: latin))
    }

    func testLanguageFilterByScript() {
        XCTAssertFalse(S.isLikelyInUsersLanguage("夜に駆ける", userLanguages: ["en"]))
        XCTAssertTrue(S.isLikelyInUsersLanguage("夜に駆ける", userLanguages: ["ja"]))
        XCTAssertTrue(S.isLikelyInUsersLanguage("Halo", userLanguages: ["en"]), "short titles detect at random, so they are kept")
        XCTAssertTrue(S.isLikelyInUsersLanguage("SZA", userLanguages: ["fr"]))
    }

    func testLanguageFilterByRecognizedLanguage() {
        let english = "The quick brown fox jumps over the lazy dog tonight"
        XCTAssertTrue(S.isLikelyInUsersLanguage(english, userLanguages: ["en"]))
        XCTAssertFalse(S.isLikelyInUsersLanguage(english, userLanguages: ["fr"]),
                       "a confidently-English title is not for a French-only device")
        XCTAssertTrue(S.isLikelyInUsersLanguage(english, userLanguages: ["fr", "en"]))
    }

    func testDeviceLocaleOverloadsAgreeWithThemselves() {
        // The no-argument forms read this machine's locale; their result must at least be stable
        // and consistent with the explicit-argument form for plain Latin text.
        XCTAssertFalse(S.usesForeignScript("Hello world"))
        XCTAssertTrue(S.isLikelyInUsersLanguage("Hi"))
    }
}
