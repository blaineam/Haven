import Foundation

/// Which relay addresses are worth trying, and which are safe to hand to a circle.
///
/// Dependency-free on purpose (no SwiftUI, no FFI, no RelayHost) so it compiles into the
/// `HavenLogicTests` target and runs on the host Mac in milliseconds. The rule it encodes has
/// already failed silently in production twice, so it needs a test people actually run.
///
/// THE FAILURE THIS EXISTS TO PREVENT. A relay hosted inside the Mac app announces every address the
/// box has. One of those was a Tailscale address (`100.122.x.x`), that relay became the account's
/// DEFAULT, and from then on every post, story and photo was published to an address that only
/// devices on the same tailnet could resolve. Nothing reported an error: the owner could reach it
/// perfectly, so it looked healthy, while everyone they shared with silently got nothing. The
/// existing filter caught `192.168.x` and waved this through, because CGNAT is not RFC1918.
enum RelayAddress {

    /// Is this URL worth trying FROM HERE?
    ///
    /// Public hosts always. An address that only works inside some private network only when we are
    /// demonstrably inside that same network — with a different test per kind:
    ///
    ///  - **RFC1918** (`10/8`, `172.16/12`, `192.168/16`): ordinary LANs are subnetted, so "do we
    ///    hold an address on the same /24" is a good proxy for "can we reach it".
    ///  - **CGNAT `100.64.0.0/10`** (Tailscale, carrier NAT): the /24 test is WRONG — Tailscale hands
    ///    every device a /32 from one flat /10, so two peers on the same tailnet almost never share a
    ///    /24 and the check would reject addresses that work fine. Membership of the /10 is the
    ///    honest signal available locally.
    static func plausiblyReachable(_ url: String, ourIPv4s: [String]) -> Bool {
        guard let parts = octets(url) else { return true }   // hostname/domain — assume routable

        if isCGNAT(parts) {
            return ourIPv4s.contains { octets(host: $0).map(isCGNAT) ?? false }
        }
        guard isRFC1918(parts) else { return true }
        let ours = Set(ourIPv4s.map { $0.split(separator: ".").prefix(3).joined(separator: ".") })
        return ours.contains(parts.prefix(3).map(String.init).joined(separator: "."))
    }

    /// Can a member on some OTHER network use this URL as a direct shortcut?
    ///
    /// NOT "can they reach the relay" — they can, over iroh, from anywhere; that path is the point
    /// of the network and it is why the Docker relay, which advertises no HTTP address at all, is
    /// the best-behaved one. This answers only whether the HTTP fast path is usable off-network, so
    /// the UI can explain a slower first connect. Anything built on this must not imply the relay is
    /// unreachable — an earlier version of that copy said exactly that, and it was wrong.
    static func reachableByOthers(_ url: String) -> Bool {
        guard let p = octets(url) else { return true }       // hostname/domain — assume public DNS
        if p[0] == 127 { return false }                      // loopback
        if p[0] == 169, p[1] == 254 { return false }         // link-local
        if isCGNAT(p) { return false }                       // Tailscale / carrier NAT
        return !isRFC1918(p)
    }

    // MARK: - Ranges

    private static func isCGNAT(_ p: [Int]) -> Bool { p[0] == 100 && (64...127).contains(p[1]) }

    private static func isRFC1918(_ p: [Int]) -> Bool {
        p[0] == 10
            || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 192 && p[1] == 168)
    }

    /// Four octets from a URL, or nil when the host is a name rather than a dotted quad.
    private static func octets(_ url: String) -> [Int]? {
        guard let host = URL(string: url)?.host else { return nil }
        return octets(host: host)
    }

    private static func octets(host: String) -> [Int]? {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return parts
    }
}
