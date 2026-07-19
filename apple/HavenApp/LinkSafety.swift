import Foundation

/**
 The guard rail between a link somebody ELSE chose and this device's network stack.

 Parity with Android `LinkSafety` (`android/app/src/main/java/com/blaineam/haven/ui/LinkSafety.kt`),
 and the reasoning is the same: a link preview is the one place where a peer's message body decides
 what our socket connects to, so a circle member could name `http://192.168.1.1/…` or
 `http://169.254.169.254/…` and have the recipient's device probe its own LAN.

 WHAT THIS DOES AND DOES NOT COVER ON APPLE. The actual fetching here is `LPMetadataProvider`, which
 is a black box — it resolves, connects and follows redirects internally, and there is no hook to
 vet a hop. So this checks the destination we are ABOUT to hand it, which stops the direct case, but
 a public host that answers 302 to a private address would still be followed. That residual is
 acceptable only because the fetch is now behind an explicit tap (see `LinkPreviewCard`): once the
 person has asked to expand a specific link, the exposure is no worse than them tapping the link
 into the in-app browser, which would follow the same redirect. What is NOT acceptable, and is what
 changed, is that happening automatically on render for a link a stranger picked.

 Android does not share that limitation — it owns its fetcher, so it re-vets every redirect hop.
 */
enum LinkSafety {

    /// True if this IPv4 address is a destination on the public internet.
    ///
    /// Written as a list of REJECTIONS because the failure mode of missing a range is that we
    /// happily probe it.
    static func isPubliclyRoutable(v4 addr: in_addr) -> Bool {
        let n = UInt32(bigEndian: addr.s_addr)
        let a0 = UInt8((n >> 24) & 0xFF)
        let a1 = UInt8((n >> 16) & 0xFF)
        let a2 = UInt8((n >> 8) & 0xFF)

        if a0 == 0 { return false }                                   // 0/8 "this network"
        if a0 == 10 { return false }                                  // 10/8 private
        if a0 == 127 { return false }                                 // 127/8 loopback
        if a0 == 169 && a1 == 254 { return false }                    // 169.254/16 link-local + metadata
        if a0 == 172 && (16...31).contains(a1) { return false }       // 172.16/12 private
        if a0 == 192 && a1 == 168 { return false }                    // 192.168/16 private
        if a0 == 192 && a1 == 0 && a2 == 0 { return false }           // 192.0.0.0/24 IETF
        if a0 == 100 && (64...127).contains(a1) { return false }      // 100.64/10 CGNAT
        if a0 == 198 && (a1 == 18 || a1 == 19) { return false }       // 198.18/15 benchmarking
        if a0 >= 224 { return false }                                 // 224/4 multicast + 240/4 reserved
        return true
    }

    /// True if this IPv6 address is a destination on the public internet.
    static func isPubliclyRoutable(v6 addr: in6_addr) -> Bool {
        var a = addr
        let bytes: [UInt8] = withUnsafeBytes(of: &a) { Array($0) }
        guard bytes.count == 16 else { return false }

        if bytes.allSatisfy({ $0 == 0 }) { return false }                          // ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false } // ::1 loopback
        if bytes[0] == 0xFF { return false }                                       // ff00::/8 multicast
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return false }          // fe80::/10 link-local
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0 { return false }          // fec0::/10 site-local
        if (bytes[0] & 0xFE) == 0xFC { return false }                              // fc00::/7 unique-local

        // ::ffff:a.b.c.d — an IPv4 address wearing a v6 costume. Unwrap it, or every check above
        // is skipped for exactly the addresses we most want to reject.
        let v4MappedPrefix: [UInt8] = [0,0,0,0, 0,0,0,0, 0,0, 0xFF,0xFF]
        if Array(bytes[0..<12]) == v4MappedPrefix {
            var inner = in_addr()
            inner.s_addr = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16
                         | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            inner.s_addr = inner.s_addr.bigEndian
            return isPubliclyRoutable(v4: inner)
        }
        // ::a.b.c.d deprecated v4-compatible form.
        if Array(bytes[0..<12]).allSatisfy({ $0 == 0 }) { return false }
        return true
    }

    /// Accept only http(s) URLs that carry a host. The cheap syntactic gate.
    static func vetSyntax(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Resolve `url`'s host and require EVERY address it answers with to be publicly routable.
    ///
    /// Every, not any: a host returning one public and one private record would otherwise pass and
    /// then be free to connect to the private one.
    ///
    /// BLOCKING — `getaddrinfo` hits the network. Call it off the main thread.
    static func resolvesPublicly(_ url: URL) -> Bool {
        guard vetSyntax(url), let host = url.host else { return false }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return false }
        defer { freeaddrinfo(head) }

        var sawAny = false
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            guard let sa = current.pointee.ai_addr else { node = current.pointee.ai_next; continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                sawAny = true
                if !isPubliclyRoutable(v4: a) { return false }
            case AF_INET6:
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                sawAny = true
                if !isPubliclyRoutable(v6: a) { return false }
            default:
                break
            }
            node = current.pointee.ai_next
        }
        return sawAny
    }
}
