import Foundation

/// Device-id dial hints riding invite links.
///
/// Under the device-seed transport a friend's ACCOUNT id resolves to no node, and their signed
/// device roster (frame 27) can only arrive over a path that itself needs a device id — so a
/// freshly-added internet friend would be unreachable until some other transport worked (the
/// roster-bootstrap deadlock). The invite link therefore carries the inviter's device node id(s)
/// as a `d=` query placed BEFORE the `#` fragment, so an old parser — which reads only the
/// fragment — still accepts the link unchanged. The scanner dials the hints until the real
/// signed roster arrives and supersedes them. Byte-format parity with Android + desktop.
enum InviteHints {
    static let maxHints = 4

    /// Insert `?d=<id1>,<id2>` before the link's `#` fragment. Returns the link unchanged when
    /// there is nothing to embed or it already carries a query.
    static func embed(in link: String, deviceIds: [String]) -> String {
        let ids = deviceIds.filter { $0.count == 64 }.prefix(maxHints)
        guard !ids.isEmpty, let hash = link.firstIndex(of: "#"), !link.contains("?") else { return link }
        return String(link[..<hash]) + "?d=" + ids.joined(separator: ",") + String(link[hash...])
    }

    /// Append one more query pair before the `#` fragment (after any existing query — unlike the
    /// `d=` embed, which stays first for byte-format parity with old parsers). Used for the
    /// offline-invite ticket (`t=`); base64url values need no percent-escaping.
    static func appendQuery(in link: String, name: String, value: String) -> String {
        guard !value.isEmpty else { return link }
        let hash = link.firstIndex(of: "#") ?? link.endIndex
        let sep = link[..<hash].contains("?") ? "&" : "?"
        return String(link[..<hash]) + sep + name + "=" + value + String(link[hash...])
    }

    /// A named query value from a pasted/scanned link (nil when absent).
    static func queryValue(from link: String, name: String) -> String? {
        guard let qStart = link.firstIndex(of: "?") else { return nil }
        let end = link.firstIndex(of: "#") ?? link.endIndex
        guard qStart < end else { return nil }
        for pair in link[link.index(after: qStart)..<end].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    /// The `d=` device ids from a pasted/scanned link (empty when absent). Only 64-hex ids pass.
    static func extract(from link: String) -> [String] {
        guard let qStart = link.firstIndex(of: "?") else { return [] }
        let end = link.firstIndex(of: "#") ?? link.endIndex
        guard qStart < end else { return [] }
        for pair in link[link.index(after: qStart)..<end].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "d" else { continue }
            return kv[1].split(separator: ",")
                .map { $0.lowercased() }
                .filter { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }
                .prefix(maxHints)
                .map { String($0) }
        }
        return []
    }
}
