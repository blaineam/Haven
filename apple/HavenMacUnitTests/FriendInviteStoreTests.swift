import XCTest
@testable import HavenUITestHost

/// Offline friend invites, store side: minting and reusing the share link, rolling it, its expiry,
/// and what accepting a friend's ticket sets in motion (relay adoption, pending-enrollment tracking).
@MainActor
final class FriendInviteStoreTests: XCTestCase {
    private let myRelay = String(repeating: "d1", count: 32)
    private var cleanup: [String] = []

    override func setUp() async throws {
        _ = await Harness.feed()
        RelayMailboxStore.shared.add(circleId: "default", nodeHex: myRelay)
    }
    override func tearDown() async throws {
        let r = RelayMailboxStore.shared
        for hex in cleanup + [myRelay] { r.eraseNow(hex); r.dropErased(hex); r.unforget(hex) }
        cleanup = []
        FriendInviteStore.shared.expirySecs = friendInviteDefaultTtlSecs()
    }

    func testTheLinkIsMintedOnceReusedAndRolledOnDemand() async throws {
        let inv = FriendInviteStore.shared
        _ = inv.rollInviteLink()   // a clean slate: retire whatever earlier tests left live
        let first = try XCTUnwrap(inv.currentTicketLinkValue())
        XCTAssertEqual(inv.currentTicketLinkValue(), first, "re-opening the invite screen doesn't grow the pending set")
        let viaAsync = await inv.currentTicketLinkValueAsync()
        XCTAssertEqual(viaAsync, first, "the off-main path reuses the live ticket too")
        let t = try XCTUnwrap(FriendInviteStore.ticket(fromLinkValue: first))
        XCTAssertTrue(t.relays.contains(myRelay), "the ticket carries my relays")
        XCTAssertNil(FriendInviteStore.ticket(fromLinkValue: "not-a-ticket"))

        let rolled = try XCTUnwrap(inv.rollInviteLink())
        XCTAssertNotEqual(rolled, first, "rolling retires the old link")
        let rolledAsyncMaybe = await inv.rollInviteLinkAsync()
        let rolledAsync = try XCTUnwrap(rolledAsyncMaybe)
        XCTAssertNotEqual(rolledAsync, rolled)
        XCTAssertEqual(inv.currentTicketLinkValue(), rolledAsync)
        XCTAssertFalse(inv.issued.filter { $0.consumedAt == nil }.isEmpty)
    }

    func testTheOfflineLinkNeedsARelayToLandIn() async throws {
        let inv = FriendInviteStore.shared
        let r = RelayMailboxStore.shared
        r.eraseNow(myRelay)
        defer { r.unforget(myRelay); r.add(circleId: "default", nodeHex: myRelay) }
        if r.allRelays().isEmpty {
            XCTAssertNil(inv.rollInviteLink(), "no relay, no mailbox for an offline acceptance: the plain live link still works")
            let none = await inv.rollInviteLinkAsync()
            XCTAssertNil(none)
        }
    }

    func testTheLinkExpiryFollowsTheConfiguredLifetime() async throws {
        let inv = FriendInviteStore.shared
        inv.expirySecs = 7 * 86_400
        _ = inv.rollInviteLink()
        let expiry = try XCTUnwrap(inv.currentLinkExpiry())
        XCTAssertEqual(expiry.timeIntervalSinceNow, 7 * 86_400, accuracy: 120)
        inv.expirySecs = 90 * 86_400
        XCTAssertEqual(try XCTUnwrap(inv.currentLinkExpiry()).timeIntervalSinceNow, 90 * 86_400, accuracy: 120,
                       "changing the lifetime retroactively moves the current link's expiry")
        inv.expirySecs = FriendInviteStore.neverExpirySecs
        XCTAssertNil(inv.currentLinkExpiry(), "Never means no expiry to show")
        XCTAssertNotNil(UserDefaults.standard.object(forKey: FriendInviteRules.expiryKey), "the chosen lifetime is persisted")
    }

    func testAcceptingAFriendsTicketAdoptsTheirRelaysAndExpectsToBeRefusedAtFirst() async throws {
        let inv = FriendInviteStore.shared
        let inviter = Peer(byte: 0x31, name: "Inviter")
        let theirRelay = String(repeating: "d7", count: 32)
        cleanup.append(theirRelay)
        let ticket = try friendInviteIssue(accountBundle: inviter.bundle, issuedAt: UInt64(Date().timeIntervalSince1970),
                                           relays: [theirRelay], deviceHints: [Data(repeating: 0x42, count: 32)])
        let text = try friendTicketEncode(ticket: ticket)
        let link = String(text.dropFirst("haven-friend:".count))
        let before = inv.accepted.count

        inv.acceptTicket(linkValue: link)
        XCTAssertEqual(inv.accepted.count, before + 1)
        XCTAssertFalse(inv.accepted.last!.dropLanded, "the drop is parked later, by the poll pass")
        XCTAssertTrue(RelayMailboxStore.shared.relays(forCircle: "default").contains(theirRelay),
                      "their relays are polled from the start so their first posts arrive in seconds")
        XCTAssertTrue(RelayEnrollment.isTracked(theirRelay), "…and their 403s ride the short flat retry until they enroll us")

        inv.acceptTicket(linkValue: link)
        XCTAssertEqual(inv.accepted.count, before + 1, "accepting the same ticket twice records it once")
        inv.acceptTicket(linkValue: "garbage")
        XCTAssertEqual(inv.accepted.count, before + 1)

        // Approving someone who never used one of my tickets writes no grant.
        let issuedBefore = inv.issued.map(\.consumedAt)
        inv.noteApproved(accountHex: inviter.hex)
        XCTAssertEqual(inv.issued.map(\.consumedAt), issuedBefore)
        await inv.tick()   // a pass with nothing deliverable offline is harmless
    }
}
