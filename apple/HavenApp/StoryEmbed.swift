import Foundation

/// A post shared *as a story*: the story carries the source post's media + music, plus a compact,
/// invisible token in its body that (a) deep-links back to the original post and (b) remembers where
/// the music should start. The token is wrapped in U+2063 (INVISIBLE SEPARATOR) so it never shows in
/// the caption and is trivially stripped for display — this keeps the whole feature a body convention,
/// so every platform (iOS/macOS, Android, desktop) round-trips it without any engine/FFI change.
///
/// Wire form inside the body:  `⁣haven-embed:v1|<circleId>|<postId>|<musicStartMs>⁣<visible caption>`
enum StoryEmbed {
    private static let sep = "\u{2063}"          // INVISIBLE SEPARATOR — never rendered
    private static let tag = "haven-embed:v1|"

    struct Ref: Equatable {
        var circleId: String
        var postId: String
        var musicStartMs: UInt64
    }

    /// Build a story body that embeds `ref` ahead of the visible `caption`.
    static func encode(_ ref: Ref, caption: String) -> String {
        // circleId/postId never contain '|' (ids are hex / base32); guard anyway by stripping it.
        let cid = ref.circleId.replacingOccurrences(of: "|", with: "")
        let pid = ref.postId.replacingOccurrences(of: "|", with: "")
        return "\(sep)\(tag)\(cid)|\(pid)|\(ref.musicStartMs)\(sep)\(caption)"
    }

    /// Parse a story body: returns the embedded post ref (if any) and the caption with the token removed.
    static func decode(_ body: String) -> (ref: Ref?, caption: String) {
        guard body.hasPrefix(sep) else { return (nil, body) }
        let afterFirst = body.dropFirst(sep.count)
        guard let close = afterFirst.range(of: sep) else { return (nil, body) }
        let token = String(afterFirst[afterFirst.startIndex..<close.lowerBound])
        let caption = String(afterFirst[close.upperBound...])
        guard token.hasPrefix(tag) else { return (nil, body) }
        let parts = token.dropFirst(tag.count).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return (nil, caption) }
        let ref = Ref(circleId: String(parts[0]),
                      postId: String(parts[1]),
                      musicStartMs: UInt64(parts[2]) ?? 0)
        return (ref, caption)
    }

    /// Whether a story body carries an embed (cheap check for the renderer).
    static func isEmbed(_ body: String) -> Bool { decode(body).ref != nil }
}
