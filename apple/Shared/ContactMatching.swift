import Foundation

/// Fuzzy matching of a SPOKEN name against Haven's conversation names, for Siri/CarPlay.
///
/// Siri hands the extension whatever it heard or resolved from the user's Contacts: "Tracy",
/// "Tracy Miller", "tracey", "Miller", a fullwidth or kana spelling. Haven's conversation title is how
/// the user named that person ("Tracy M", "Tracy \u{1F33F}", a nickname). An exact string compare answered
/// "no matches" for all of those, so matching is token-wise and scored:
///
///   * both sides are folded: case, diacritics, WIDTH (fullwidth <-> halfwidth), hiragana -> katakana,
///     emoji and punctuation removed, whitespace collapsed;
///   * each spoken token is matched once against the name's tokens: equal 1.0, name token is a prefix of
///     the spoken one or vice versa 0.85, a one-letter initial 0.8, a near-miss spelling (edit distance 1,
///     tokens of 4+ letters) 0.6, CJK containment 0.8;
///   * the score averages the spoken tokens, and unmatched name tokens cost a little (so "Tracy" prefers
///     the contact called "Tracy" over "Tracy Miller", but still finds "Tracy M").
///
/// `resolve` turns the ranking into what Siri needs: confident (one clear winner), ambiguous (several
/// close - NEVER silently pick one), tentative (one weak candidate - ask the user to confirm, never
/// "no matches"), or none.
enum ContactMatching {
    struct Candidate: Equatable {
        var id: String
        /// The conversation title first, then any other names the person is known by.
        var names: [String]
    }

    struct Match: Equatable {
        var id: String
        var score: Double
    }

    enum Resolution: Equatable {
        case none
        /// A single clear winner (exact name, or the only strong candidate).
        case confident(Match)
        /// Several equally plausible candidates, best first (max `maxChoices`).
        case ambiguous([Match])
        /// One plausible-but-weak candidate: ask "did you mean ...?".
        case tentative(Match)
    }

    static let strongThreshold = 0.8
    static let weakThreshold = 0.5
    /// Candidates within this of the best strong score are "close" (and so ambiguous).
    static let closeMargin = 0.1
    static let maxChoices = 5

    // MARK: Folding

    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.applyingTransform(.hiraganaToKatakana, reverse: false) ?? t
        var out = ""
        for ch in t {
            if isEmojiOrSymbol(ch) { out.append(" ") }
            else if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .spacingMark }) { out.append(ch) }
            else { out.append(" ") }   // punctuation, whitespace, '&', '.', '-', etc. separate tokens
        }
        return out.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    private static func isEmojiOrSymbol(_ c: Character) -> Bool {
        guard let first = c.unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        if first.properties.isEmoji && first.value > 0x238C { return true }
        switch first.properties.generalCategory {
        case .otherSymbol, .mathSymbol, .currencySymbol, .modifierSymbol: return true
        default: return false
        }
    }

    static func tokens(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    // MARK: Scoring

    /// 0...1. 0 = the spoken name cannot be this person.
    static func score(query: String, name: String) -> Double {
        let q = normalize(query), n = normalize(name)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if q == n { return 1 }
        let qt = q.split(separator: " ").map(String.init)
        let nt = n.split(separator: " ").map(String.init)

        // Unspaced scripts (CJK) have one token each way: containment is the best signal available.
        if qt.count == 1, nt.count == 1, isUnspaced(q) || isUnspaced(n) {
            return (n.contains(q) || q.contains(n)) ? 0.8 : 0
        }

        var used = Set<Int>()
        var total = 0.0
        for qtok in qt {
            var best = 0.0, bestIdx = -1
            for (i, ntok) in nt.enumerated() where !used.contains(i) {
                let s = tokenScore(qtok, ntok)
                if s > best { best = s; bestIdx = i }
            }
            if best == 0 { return 0 }          // every spoken token must find a home
            used.insert(bestIdx)
            total += best
        }
        let avg = total / Double(qt.count)
        let coverage = Double(used.count) / Double(nt.count)
        return min(0.99, avg * (0.85 + 0.15 * coverage))   // only an exact name reaches 1.0
    }

    private static func isUnspaced(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    static func tokenScore(_ q: String, _ n: String) -> Double {
        if q == n { return 1 }
        if n.count == 1 { return q.hasPrefix(n) ? 0.8 : 0 }          // "Miller" vs the initial "M"
        if q.count == 1 { return n.hasPrefix(q) ? 0.8 : 0 }          // "M" vs "Miller"
        if n.hasPrefix(q) || q.hasPrefix(n) { return 0.85 }          // "Trac" / "Tracy", "Tracy" / "Tracy"+s
        if q.count >= 4, n.count >= 4, editDistanceAtMostOne(q, n) { return 0.6 }   // "Tracey" / "Tracy"
        return 0
    }

    static func editDistanceAtMostOne(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count > y.count { i += 1 } else if y.count > x.count { j += 1 } else { i += 1; j += 1 }
        }
        edits += (x.count - i) + (y.count - j)
        return edits <= 1
    }

    // MARK: Ranking + resolution

    /// Best score of any query against any of the candidate's names; candidates scoring 0 are dropped.
    static func rank(queries: [String], candidates: [Candidate]) -> [Match] {
        var out: [Match] = []
        for c in candidates {
            var best = 0.0
            for q in queries { for n in c.names { best = max(best, score(query: q, name: n)) } }
            if best >= weakThreshold { out.append(Match(id: c.id, score: best)) }
        }
        return out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }

    static func resolve(queries: [String], candidates: [Candidate]) -> Resolution {
        let ranked = rank(queries: queries, candidates: candidates)
        guard let top = ranked.first else { return .none }

        let exact = ranked.filter { $0.score >= 1 }
        if exact.count == 1 { return .confident(exact[0]) }
        if exact.count > 1 { return .ambiguous(Array(exact.prefix(maxChoices))) }

        let strong = ranked.filter { $0.score >= strongThreshold }
        if !strong.isEmpty {
            let close = strong.filter { top.score - $0.score <= closeMargin }
            return close.count == 1 ? .confident(close[0]) : .ambiguous(Array(close.prefix(maxChoices)))
        }
        // Only weak candidates: never "no matches" while something plausible exists.
        return ranked.count == 1 ? .tentative(top) : .ambiguous(Array(ranked.prefix(maxChoices)))
    }
}
