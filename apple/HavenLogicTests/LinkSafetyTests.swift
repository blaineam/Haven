import XCTest

/// The link-preview SSRF guard on Apple — parity with Android `LinkSafetyTest`. A peer's message
/// body decides what our socket connects to here, so every private/reserved range must be refused.
/// Address predicates are fed literals (inet_pton), so nothing in this file resolves DNS.
final class LinkSafetyTests: XCTestCase {

    private func v4(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        var a = in_addr()
        XCTAssertEqual(inet_pton(AF_INET, s, &a), 1, "bad literal \(s)", file: file, line: line)
        return LinkSafety.isPubliclyRoutable(v4: a)
    }

    private func v6(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        var a = in6_addr()
        XCTAssertEqual(inet_pton(AF_INET6, s, &a), 1, "bad literal \(s)", file: file, line: line)
        return LinkSafety.isPubliclyRoutable(v6: a)
    }

    func testRejectsLoopback() {
        XCTAssertFalse(v4("127.0.0.1"))
        XCTAssertFalse(v4("127.5.5.5"))
        XCTAssertFalse(v6("::1"))
    }

    func testRejectsRFC1918() {
        XCTAssertFalse(v4("10.0.0.1"))
        XCTAssertFalse(v4("172.16.0.1"))
        XCTAssertFalse(v4("172.31.255.254"))
        XCTAssertFalse(v4("192.168.1.1"))
        // Just outside 172.16/12 is public.
        XCTAssertTrue(v4("172.15.255.255"))
        XCTAssertTrue(v4("172.32.0.1"))
    }

    func testRejectsLinkLocalIncludingCloudMetadata() {
        XCTAssertFalse(v4("169.254.169.254"))
        XCTAssertFalse(v4("169.254.0.1"))
        XCTAssertFalse(v6("fe80::1"))
        XCTAssertFalse(v6("febf::1"))
    }

    func testRejectsCGNATButNotItsNeighbours() {
        XCTAssertFalse(v4("100.64.0.1"))
        XCTAssertFalse(v4("100.127.255.255"))
        XCTAssertTrue(v4("100.63.255.255"))
        XCTAssertTrue(v4("100.128.0.1"))
    }

    func testRejectsReservedV4() {
        for s in ["0.0.0.0", "0.1.2.3", "192.0.0.1", "198.18.0.1", "198.19.255.255",
                  "224.0.0.1", "240.0.0.1", "255.255.255.255"] {
            XCTAssertFalse(v4(s), s)
        }
    }

    func testRejectsV6UniqueLocalSiteLocalMulticastAndUnspecified() {
        for s in ["fc00::1", "fd12:3456::1", "fec0::1", "ff02::1", "::"] {
            XCTAssertFalse(v6(s), s)
        }
    }

    /// The v4-mapped form is exactly how a private target would slip past a v6-only check.
    func testV4MappedV6IsUnwrappedAndJudgedAsV4() {
        XCTAssertFalse(v6("::ffff:127.0.0.1"))
        XCTAssertFalse(v6("::ffff:169.254.169.254"))
        XCTAssertFalse(v6("::ffff:192.168.0.1"))
        XCTAssertTrue(v6("::ffff:8.8.8.8"))
        // Deprecated v4-compatible form is refused outright.
        XCTAssertFalse(v6("::8.8.8.8"))
    }

    func testAllowsOrdinaryPublicAddresses() {
        XCTAssertTrue(v4("1.1.1.1"))
        XCTAssertTrue(v4("8.8.8.8"))
        XCTAssertTrue(v4("93.184.216.34"))
        XCTAssertTrue(v6("2606:4700:4700::1111"))
    }

    func testSyntaxGateTakesOnlyHttpAndHttpsWithAHost() {
        XCTAssertFalse(LinkSafety.vetSyntax(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(LinkSafety.vetSyntax(URL(string: "ftp://example.com/x")!))
        XCTAssertFalse(LinkSafety.vetSyntax(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(LinkSafety.vetSyntax(URL(string: "haven://u/abc")!))
        XCTAssertFalse(LinkSafety.vetSyntax(URL(string: "https:///nohost")!))
        XCTAssertTrue(LinkSafety.vetSyntax(URL(string: "https://example.com/x")!))
        XCTAssertTrue(LinkSafety.vetSyntax(URL(string: "HTTP://example.com")!))
    }

    /// Literal-IP URLs resolve locally (no DNS), so the end-to-end gate can be exercised offline.
    func testResolvesPubliclyRefusesLiteralPrivateTargets() {
        XCTAssertFalse(LinkSafety.resolvesPublicly(URL(string: "http://127.0.0.1/")!))
        XCTAssertFalse(LinkSafety.resolvesPublicly(URL(string: "http://169.254.169.254/latest/meta-data")!))
        XCTAssertFalse(LinkSafety.resolvesPublicly(URL(string: "http://[::1]:8080/")!))
        XCTAssertFalse(LinkSafety.resolvesPublicly(URL(string: "http://10.1.2.3/")!))
        XCTAssertFalse(LinkSafety.resolvesPublicly(URL(string: "file:///etc/hosts")!))
        XCTAssertTrue(LinkSafety.resolvesPublicly(URL(string: "http://1.1.1.1/")!))
    }
}
