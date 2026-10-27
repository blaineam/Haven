import XCTest

/// Spoken-name matching for Siri/CarPlay. The motivating field report: with a contact titled "Tracy M",
/// saying "Tracy" or "Tracy Miller" answered "no matches".
final class ContactMatchingTests: XCTestCase {
    private typealias M = ContactMatching
    private func c(_ id: String, _ names: String...) -> M.Candidate { .init(id: id, names: names) }

    private func resolve(_ q: String, _ cands: [M.Candidate]) -> M.Resolution { M.resolve(queries: [q], candidates: cands) }

    // MARK: the screenshot case

    func testTracyAndTracyMillerBothFindTracyM() {
        let cands = [c("dm:tracy", "Tracy M"), c("dm:theo", "Theo Park"), c("dm:maya", "Maya")]
        for spoken in ["Tracy", "tracy", "Tracy Miller", "TRACY MILLER", "Tracy M", "tracy m."] {
            guard case .confident(let m) = resolve(spoken, cands) else { return XCTFail("\(spoken) -> \(resolve(spoken, cands))") }
            XCTAssertEqual(m.id, "dm:tracy", spoken)
        }
    }

    func testVoiceAssistantSpellingVariantIsTentativeNotNoMatch() {
        guard case .tentative(let m) = resolve("Tracey", [c("dm:tracy", "Tracy M")]) else { return XCTFail("\(resolve("Tracey", [c("dm:tracy", "Tracy M")]))") }
        XCTAssertEqual(m.id, "dm:tracy", "a near-miss spelling asks for confirmation")
    }

    // MARK: folding

    func testFoldsCaseDiacriticsWidthEmojiAndPunctuation() {
        XCTAssertEqual(M.normalize("  José\u{2011}Luís 🌿 "), "jose luis")
        XCTAssertEqual(M.normalize("Ｔｒａｃｙ"), "tracy", "fullwidth Latin")
        XCTAssertEqual(M.normalize("Tracy 🌿"), "tracy")
        XCTAssertEqual(M.normalize("O'Brien, Pat"), "o brien pat")
        XCTAssertEqual(M.normalize("ﾀﾅｶ"), M.normalize("タナカ"), "half-width katakana")
        XCTAssertEqual(M.normalize("たなか"), M.normalize("タナカ"), "hiragana == katakana")
    }

    func testCJKContainmentAndKanaInsensitivity() {
        let cands = [c("dm:tanaka", "田中太郎"), c("dm:sato", "佐藤花子")]
        XCTAssertEqual(resolve("田中", cands), .confident(.init(id: "dm:tanaka", score: 0.8)))
        XCTAssertEqual(resolve("田中太郎", cands), .confident(.init(id: "dm:tanaka", score: 1)))
        XCTAssertEqual(resolve("さとう", [c("dm:s", "サトウ")]), .confident(.init(id: "dm:s", score: 1)))
        XCTAssertEqual(resolve("鈴木", cands), .none)
    }

    func testEmojiAndNicknameDecorationIgnored() {
        XCTAssertEqual(resolve("Tracy", [c("dm:t", "Tracy 🌿")]), .confident(.init(id: "dm:t", score: 1)))
        XCTAssertEqual(resolve("Mom", [c("dm:m", "❤️ Mom ❤️")]), .confident(.init(id: "dm:m", score: 1)))
    }

    // MARK: tokens, initials, prefixes

    func testInitialLetterTokens() {
        XCTAssertGreaterThanOrEqual(M.score(query: "Tracy Miller", name: "Tracy M"), M.strongThreshold)
        XCTAssertGreaterThanOrEqual(M.score(query: "Tracy M", name: "Tracy Miller"), M.strongThreshold)
        XCTAssertEqual(M.tokenScore("miller", "m"), 0.8)
        XCTAssertEqual(M.tokenScore("m", "miller"), 0.8)
        XCTAssertEqual(M.tokenScore("miller", "x"), 0)
        XCTAssertEqual(M.score(query: "Tracy Smith", name: "Tracy M"), 0, "a different surname initial is not a match")
    }

    func testPrefixMatches() {
        XCTAssertGreaterThanOrEqual(M.score(query: "Trac", name: "Tracy Miller"), M.weakThreshold)
        XCTAssertGreaterThanOrEqual(M.score(query: "Alex", name: "Alexander"), M.strongThreshold)
    }

    func testEveryTokenMustMatchAndNameTokensAreUsedOnce() {
        XCTAssertEqual(M.score(query: "Tracy Tracy", name: "Tracy M"), 0, "one name token cannot satisfy two spoken ones")
        XCTAssertEqual(M.score(query: "Tracy Zed", name: "Tracy Miller"), 0)
        XCTAssertEqual(M.score(query: "", name: "Tracy"), 0)
        XCTAssertEqual(M.score(query: "Tracy", name: "🌿"), 0)
    }

    func testNameOrderDoesNotMatter() {
        XCTAssertGreaterThanOrEqual(M.score(query: "Miller Tracy", name: "Tracy Miller"), M.strongThreshold)
    }

    func testEditDistance() {
        XCTAssertTrue(M.editDistanceAtMostOne("tracy", "tracey"))
        XCTAssertTrue(M.editDistanceAtMostOne("tracy", "tracy"))
        XCTAssertTrue(M.editDistanceAtMostOne("tracy", "tracz"))
        XCTAssertFalse(M.editDistanceAtMostOne("tracy", "trace2"))
        XCTAssertFalse(M.editDistanceAtMostOne("tracy", "tr"))
    }

    // MARK: ranking and resolution

    func testExactBeatsPartial() {
        let cands = [c("dm:long", "Maya Chen"), c("dm:short", "Maya")]
        XCTAssertEqual(resolve("Maya", cands), .confident(.init(id: "dm:short", score: 1)))
    }

    func testAmbiguousWhenSeveralAreClose_neverPicksSilently() {
        let cands = [c("dm:a", "Tracy M"), c("dm:b", "Tracy Miller"), c("dm:c", "Maya")]
        guard case .ambiguous(let ms) = resolve("Tracy", cands) else { return XCTFail("\(resolve("Tracy", cands))") }
        XCTAssertEqual(Set(ms.map(\.id)), ["dm:a", "dm:b"])
        let two = [c("dm:1", "Alex Park"), c("dm:2", "Alex Chen")]
        guard case .ambiguous(let ms2) = resolve("Alex", two) else { return XCTFail() }
        XCTAssertEqual(ms2.count, 2)
    }

    func testDuplicateExactNamesAreAmbiguous() {
        guard case .ambiguous(let ms) = resolve("Sam", [c("dm:1", "Sam"), c("dm:2", "Sam")]) else { return XCTFail() }
        XCTAssertEqual(ms.map(\.id), ["dm:1", "dm:2"])
    }

    func testAClearLeaderOutranksAFarWeakerNeighbour() {
        // "Tracy M" is the only strong match for "Tracy Miller"; "Tracy Zhang" shares only the first name.
        let cands = [c("dm:m", "Tracy M"), c("dm:z", "Tracy Zhang")]
        XCTAssertEqual(resolve("Tracy Miller", cands), .confident(.init(id: "dm:m", score: M.score(query: "Tracy Miller", name: "Tracy M"))))
    }

    func testSingleWeakCandidateIsTentativeNotNoMatch() {
        guard case .tentative(let m) = resolve("Tracey", [c("dm:t", "Tracy Miller"), c("dm:o", "Omar")]) else {
            return XCTFail("\(resolve("Tracey", [c("dm:t", "Tracy Miller"), c("dm:o", "Omar")]))")
        }
        XCTAssertEqual(m.id, "dm:t")
    }

    func testSeveralWeakCandidatesAreAmbiguous() {
        guard case .ambiguous(let ms) = resolve("Tracey", [c("dm:1", "Tracy Miller"), c("dm:2", "Tracy Park")]) else { return XCTFail() }
        XCTAssertEqual(ms.count, 2)
    }

    func testNoPlausibleCandidateIsNone() {
        XCTAssertEqual(resolve("Zebediah", [c("dm:t", "Tracy M")]), .none)
        XCTAssertEqual(resolve("anyone", []), .none)
    }

    func testAliasesAndMultipleQueriesCountBest() {
        // The conversation is titled with the user's nickname; Siri says the contact's legal name.
        let cands = [c("dm:mum", "Mum", "Margaret Ellison")]
        XCTAssertEqual(M.resolve(queries: ["Margaret"], candidates: cands), .confident(.init(id: "dm:mum", score: M.score(query: "Margaret", name: "Margaret Ellison"))))
        // displayName "Tracy" and structured name "Tracy Miller": the better one wins.
        XCTAssertEqual(M.resolve(queries: ["xyz", "Tracy Miller"], candidates: [c("dm:t", "Tracy M")]).matchedID, "dm:t")
    }

    func testAtMostFiveChoices() {
        let cands = (0..<9).map { c("dm:\($0)", "Alex \(["Aa", "Bb", "Cc", "Dd", "Ee", "Ff", "Gg", "Hh", "Ii"][$0])") }
        guard case .ambiguous(let ms) = resolve("Alex", cands) else { return XCTFail() }
        XCTAssertEqual(ms.count, M.maxChoices)
    }

    func testRankingIsDeterministic() {
        let cands = [c("dm:b", "Pat"), c("dm:a", "Pat")]
        guard case .ambiguous(let ms) = resolve("Pat", cands) else { return XCTFail() }
        XCTAssertEqual(ms.map(\.id), ["dm:a", "dm:b"])
    }
}

private extension ContactMatching.Resolution {
    var matchedID: String? {
        switch self {
        case .confident(let m), .tentative(let m): return m.id
        default: return nil
        }
    }
}
