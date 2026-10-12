import XCTest

/// Offline friend-invite bookkeeping: when a ticket is live, what pruning drops, which ticket an
/// approval belongs to, and the UserDefaults round trip. A mistake here either leaves a stale link
/// shared forever or drops a ticket whose acceptor is mid-handshake.
final class FriendInviteLedgerTests: XCTestCase {
    private typealias R = FriendInviteRules
    private let day: UInt64 = 24 * 3600
    private let now: UInt64 = 1_800_000_000

    private func issued(_ t: String, at: UInt64, consumed: UInt64? = nil, acceptor: String? = nil) -> FriendInviteIssued {
        FriendInviteIssued(ticket: t, issuedAt: at, consumedAt: consumed, acceptorHex: acceptor)
    }

    // MARK: Liveness

    func testIsLiveBoundaryIsInclusive() {
        let ttl = 30 * day
        XCTAssertTrue(R.isLive(now - ttl, expirySecs: ttl, now: now))
        XCTAssertFalse(R.isLive(now - ttl - 1, expirySecs: ttl, now: now))
        XCTAssertTrue(R.isLive(now, expirySecs: ttl, now: now))
    }

    func testClockMovedBackwardsCountsAsJustMinted() {
        XCTAssertTrue(R.isLive(now + 10 * day, expirySecs: day, now: now))
    }

    func testNeverExpiryIsAlwaysLive() {
        XCTAssertTrue(R.isLive(0, expirySecs: R.neverExpirySecs, now: now))
        XCTAssertEqual(R.neverExpirySecs, 100 * 365 * 24 * 3600, "~a century, still a real u64 timestamp")
    }

    func testNewestLiveSkipsConsumedAndLapsed() {
        let list = [issued("old", at: now - 40 * day),
                    issued("consumed", at: now - 1 * day, consumed: now),
                    issued("live1", at: now - 2 * day),
                    issued("live2", at: now - 1 * day)]
        XCTAssertEqual(R.newestLive(list, expirySecs: 30 * day, now: now)?.ticket, "live2")
        XCTAssertNil(R.newestLive([issued("old", at: now - 40 * day)], expirySecs: 30 * day, now: now))
        XCTAssertNil(R.newestLive([], expirySecs: 30 * day, now: now))
    }

    func testLinkExpiry() {
        let list = [issued("a", at: now - 10 * day)]
        let d = R.linkExpiry(list, expirySecs: 30 * day, now: now)
        XCTAssertEqual(d, Date(timeIntervalSince1970: TimeInterval(now - 10 * day + 30 * day)))
        XCTAssertNil(R.linkExpiry(list, expirySecs: R.neverExpirySecs, now: now), "Never has no expiry date")
        XCTAssertNil(R.linkExpiry([], expirySecs: 30 * day, now: now))
    }

    // MARK: Prune

    func testPruneDropsLapsedUnconsumedOnly() {
        var iss = [issued("lapsed", at: now - 40 * day),
                   issued("lapsedButConsumed", at: now - 40 * day, consumed: now - 39 * day),
                   issued("fresh", at: now - day)]
        var acc: [FriendInviteAccepted] = []
        let changed = R.prune(issued: &iss, accepted: &acc, expirySecs: 30 * day, now: now)
        XCTAssertTrue(changed)
        XCTAssertEqual(iss.map(\.ticket), ["lapsedButConsumed", "fresh"],
                       "a consumed ticket is history the QA dump and approvals still read")
    }

    func testPruneCapsLiveTicketsOldestFirst() {
        var iss = (0..<20).map { issued("t\($0)", at: now - UInt64(20 - $0)) }
        iss.insert(issued("consumed", at: now - 100, consumed: now - 50), at: 3)
        var acc: [FriendInviteAccepted] = []
        XCTAssertTrue(R.prune(issued: &iss, accepted: &acc, expirySecs: 30 * day, now: now))
        XCTAssertEqual(iss.filter { $0.consumedAt == nil }.count, R.maxLive)
        XCTAssertEqual(iss.filter { $0.consumedAt == nil }.first?.ticket, "t4", "oldest four unconsumed were dropped")
        XCTAssertTrue(iss.contains { $0.ticket == "consumed" })
    }

    func testPruneUnchangedReturnsFalse() {
        var iss = [issued("fresh", at: now - 5)]
        var acc: [FriendInviteAccepted] = []
        XCTAssertFalse(R.prune(issued: &iss, accepted: &acc, expirySecs: 30 * day, now: now))
    }

    func testPruneAgesAcceptances() {
        var iss: [FriendInviteIssued] = []
        var acc = [
            FriendInviteAccepted(ticket: "pending", acceptedAt: now - 2 * day, dropLanded: true, granted: false),
            FriendInviteAccepted(ticket: "grantedRecent", acceptedAt: now - 3600, dropLanded: true, granted: true),
            FriendInviteAccepted(ticket: "grantedOld", acceptedAt: now - 2 * day, dropLanded: true, granted: true),
            FriendInviteAccepted(ticket: "lapsed", acceptedAt: now - 40 * day, dropLanded: false, granted: false),
        ]
        let changed = R.prune(issued: &iss, accepted: &acc, expirySecs: 30 * day, now: now)
        XCTAssertFalse(changed, "only the issued list reports a change (it is what the store persists on)")
        XCTAssertEqual(acc.map(\.ticket), ["pending", "grantedRecent"],
                       "a granted acceptance lingers a day so a re-scan de-dups; a lapsed one goes")
    }

    // MARK: Roll / accept / approve

    func testRetireAllOnlyTouchesLiveTickets() {
        var iss = [issued("a", at: 1), issued("b", at: 2, consumed: 99)]
        R.retireAll(&iss, now: 500)
        XCTAssertEqual(iss[0].consumedAt, 500)
        XCTAssertEqual(iss[1].consumedAt, 99, "an already-consumed ticket keeps its original stamp")
    }

    func testRecordAcceptedDeDuplicates() {
        var acc: [FriendInviteAccepted] = []
        XCTAssertTrue(R.recordAccepted(&acc, ticket: "T", now: 5))
        XCTAssertFalse(R.recordAccepted(&acc, ticket: "T", now: 6), "a re-scan must not park a second drop")
        XCTAssertEqual(acc, [FriendInviteAccepted(ticket: "T", acceptedAt: 5, dropLanded: false, granted: false)])
    }

    func testPendingAcceptancesMatchByLowercasedHexAndSkipConsumed() {
        let iss = [issued("a", at: 1, acceptor: "abcd"),
                   issued("b", at: 2, consumed: 9, acceptor: "abcd"),
                   issued("c", at: 3, acceptor: "ffff"),
                   issued("d", at: 4, acceptor: "abcd")]
        let m = R.pendingAcceptances(iss, accountHex: "ABCD")
        XCTAssertEqual(m.map { $0.offset }, [0, 3])
        XCTAssertEqual(m.map { $0.element.ticket }, ["a", "d"])
        XCTAssertTrue(R.pendingAcceptances(iss, accountHex: "0000").isEmpty)
    }

    // MARK: Link value + hex

    func testLinkValue() {
        XCTAssertEqual(R.linkValue("haven-friend:abc123"), "abc123")
        XCTAssertEqual(R.linkValue("haven-friend:"), "")
        XCTAssertNil(R.linkValue("abc123"))
        XCTAssertNil(R.linkValue("Haven-Friend:abc"), "the prefix is case-sensitive")
    }

    func testHexRoundTrip() {
        let d = Data([0x00, 0x0f, 0xa5, 0xff])
        XCTAssertEqual(R.hexString(d), "000fa5ff")
        XCTAssertEqual(R.hexData("000FA5FF"), d)
        XCTAssertEqual(R.hexData(R.hexString(d)), d)
        XCTAssertEqual(R.hexData(""), Data())
    }

    func testHexDataRejectsOddAndNonHex() {
        XCTAssertNil(R.hexData("abc"))
        XCTAssertNil(R.hexData("zz"))
        XCTAssertNil(R.hexData("0g"))
    }

    // MARK: Persistence

    private func freshDefaults() -> UserDefaults {
        let name = "haven.test.friendInvites.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testLoadDefaultsWhenEmpty() {
        let snap = R.load(from: freshDefaults(), defaultExpirySecs: 7 * day)
        XCTAssertEqual(snap, R.Snapshot(issued: [], accepted: [], expirySecs: 7 * day))
    }

    func testSaveLoadRoundTrip() {
        let d = freshDefaults()
        let iss = [issued("a", at: 5, consumed: 9, acceptor: "ab")]
        let acc = [FriendInviteAccepted(ticket: "x", acceptedAt: 3, dropLanded: true, granted: false)]
        R.save(issued: iss, accepted: acc, to: d)
        R.saveExpiry(90 * day, to: d)
        let snap = R.load(from: d, defaultExpirySecs: day)
        XCTAssertEqual(snap.issued, iss)
        XCTAssertEqual(snap.accepted, acc)
        XCTAssertEqual(snap.expirySecs, 90 * day)
    }

    func testLoadIgnoresCorruptBlobs() {
        let d = freshDefaults()
        d.set(Data("not json".utf8), forKey: R.issuedKey)
        d.set("not a number", forKey: R.expiryKey)
        let snap = R.load(from: d, defaultExpirySecs: 3)
        XCTAssertTrue(snap.issued.isEmpty)
        XCTAssertEqual(snap.expirySecs, 3)
    }
}
