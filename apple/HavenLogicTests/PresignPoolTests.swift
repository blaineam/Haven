import XCTest

/// The S3 mailbox's pre-signed URL pool. The owner mints scoped, expiring, single-object URLs so
/// members never see the access key; a member consumes its own PUT slots one at a time.
final class PresignPoolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func s3() -> S3Client {
        S3Client(config: S3Config(endpoint: "https://s3.example.test", region: "us-east-1", bucket: "bkt",
                                  accessKey: "AKID", secret: "SECRET"))
    }

    private func pool(slots: Int = 3) -> PresignPool {
        PresignPool.mint(circleId: "circ", members: ["aa", "bb"], s3: s3(), now: now, slots: slots)
    }

    func testKeysAndPrefixes() {
        XCTAssertEqual(PresignPool.mailboxKey(circleId: "c", memberHex: "m", slot: 7), "haven/mailbox/c/m/7")
        XCTAssertEqual(PresignPool.mailboxPrefix(circleId: "c"), "haven/mailbox/c/")
        XCTAssertEqual(PresignPool.poolKey(circleId: "c"), "haven/presign/c/pool")
        XCTAssertEqual(PresignPool.slotsPerMember, 60)
        XCTAssertEqual(PresignPool.ttl, 7 * 24 * 3600)
    }

    func testMintBuildsSlotsPerMemberAndMatchingGets() {
        let p = pool(slots: 3)
        XCTAssertEqual(p.circleId, "circ")
        XCTAssertEqual(Set(p.puts.keys), ["aa", "bb"])
        XCTAssertEqual(p.puts["aa"]?.count, 3)
        XCTAssertEqual(p.gets.count, 6, "one GET per slot per member")
        XCTAssertNotNil(p.gets["haven/mailbox/circ/aa/0"])
        XCTAssertNotNil(p.gets["haven/mailbox/circ/bb/2"])
        XCTAssertNil(p.gets["haven/mailbox/circ/aa/3"])
    }

    func testEverySlotUrlIsDistinctAndSignedForItsOwnKeyAndMethod() throws {
        let p = pool(slots: 3)
        let puts = try XCTUnwrap(p.puts["aa"])
        XCTAssertEqual(Set(puts).count, 3, "a reused URL would overwrite another message")
        XCTAssertTrue(puts[0].contains("/bkt/haven/mailbox/circ/aa/0?"), puts[0])
        XCTAssertTrue(puts[2].contains("/bkt/haven/mailbox/circ/aa/2?"), puts[2])
        XCTAssertNotEqual(puts[0], p.gets["haven/mailbox/circ/aa/0"], "PUT and GET are signed separately")
        XCTAssertEqual(Set(p.puts.values.flatMap { $0 }).count, 6, "no URL is shared across members")
    }

    func testMintIsDeterministicForAFixedClock() {
        XCTAssertEqual(pool(), pool())
        let later = PresignPool.mint(circleId: "circ", members: ["aa", "bb"], s3: s3(), now: now.addingTimeInterval(60), slots: 3)
        XCTAssertNotEqual(pool(), later)
    }

    func testListURLCoversTheCircleMailboxPrefix() throws {
        let p = pool()
        let comps = try XCTUnwrap(URLComponents(string: p.listURL))
        XCTAssertEqual(comps.path, "/bkt")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "prefix" }?.value, "haven/mailbox/circ/")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "list-type" }?.value, "2")
    }

    func testExpiryIsTheSigV4MaximumFromNow() {
        XCTAssertEqual(pool().expires, now.timeIntervalSince1970 + 604_800)
        XCTAssertEqual(pool().reminderAt, now.timeIntervalSince1970 + 604_800 - 86_400,
                       "the local fallback reminder fires a day before the TTL ends")
    }

    func testFreshnessLeavesAMarginBeforeExpiry() {
        let p = pool()
        XCTAssertTrue(p.isFresh(now: now))
        XCTAssertTrue(p.isFresh(now: Date(timeIntervalSince1970: p.expires - 61)))
        XCTAssertFalse(p.isFresh(now: Date(timeIntervalSince1970: p.expires - 60)), "refetch before it can race the expiry")
        XCTAssertFalse(p.isFresh(now: Date(timeIntervalSince1970: p.expires + 1)))
    }

    func testPutSlotsAreConsumedInOrderThenExhausted() throws {
        let p = pool(slots: 2)
        let first = try XCTUnwrap(p.putURL(forMember: "aa", used: 0))
        let second = try XCTUnwrap(p.putURL(forMember: "aa", used: 1))
        XCTAssertEqual([first.absoluteString, second.absoluteString], p.puts["aa"])
        XCTAssertNil(p.putURL(forMember: "aa", used: 2), "exhausted until the owner re-mints")
        XCTAssertNil(p.putURL(forMember: "aa", used: -1))
        XCTAssertNil(p.putURL(forMember: "stranger", used: 0), "a non-member has no slots")
    }

    func testPoolCodableRoundTripKeepsEverything() throws {
        let p = pool()
        let back = try JSONDecoder().decode(PresignPool.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    func testNoMembersStillMintsAListURL() {
        let p = PresignPool.mint(circleId: "c", members: [], s3: s3(), now: now, slots: 3)
        XCTAssertTrue(p.puts.isEmpty)
        XCTAssertTrue(p.gets.isEmpty)
        XCTAssertFalse(p.listURL.isEmpty)
    }
}
