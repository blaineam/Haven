import XCTest
@testable import HavenLogicTests

/// The address rules that decide who can fetch your photos.
///
/// The case that motivated these is `theTailscaleAddressThatAteEveryPost`: a Mac relay announced its
/// `100.122.x.x` Tailscale address, became the account default, and every post went somewhere no
/// member outside the tailnet could reach — silently, because it worked perfectly for the owner.
final class RelayAddressTests: XCTestCase {

    private let tailnet = ["100.122.152.113", "192.168.4.60"]
    private let plainLAN = ["192.168.4.60"]

    // MARK: - The regression

    func testTheTailscaleAddressThatAteEveryPost() {
        let url = "http://100.122.152.113:8674"

        // From my own machine, on the tailnet, it is genuinely the right thing to try.
        XCTAssertTrue(RelayAddress.plausiblyReachable(url, ourIPv4s: tailnet),
                      "my own tailnet relay must stay usable from my own device")

        // From a member who is not on my tailnet, it is unreachable — and must not be tried.
        XCTAssertFalse(RelayAddress.plausiblyReachable(url, ourIPv4s: plainLAN),
                       "a peer with no tailnet address must not burn a connect attempt on CGNAT")

        // And it is never a sane address to publish to a circle, even from my own device.
        XCTAssertFalse(RelayAddress.reachableByOthers(url),
                       "being in someone's circle does not put you on their tailnet")
    }

    /// The /24 rule is wrong for CGNAT: Tailscale hands out /32s from one flat /10, so same-tailnet
    /// peers almost never share a /24. Using the LAN test here would reject addresses that work.
    func testTwoTailnetPeersInDifferentSlashTwentyFoursStillReachEachOther() {
        XCTAssertTrue(RelayAddress.plausiblyReachable("http://100.97.202.118:8674",
                                                      ourIPv4s: ["100.122.152.113"]),
                      "100.97.x and 100.122.x are one tailnet despite different /24s")
    }

    // MARK: - The pre-existing LAN rule still holds

    func testAPrivateLanAddressIsOnlyTriedFromThatLan() {
        let url = "http://192.168.4.126:8674"
        XCTAssertTrue(RelayAddress.plausiblyReachable(url, ourIPv4s: ["192.168.4.60"]))
        XCTAssertFalse(RelayAddress.plausiblyReachable(url, ourIPv4s: ["10.0.0.5"]),
                       "a 192.168.4.x URL cannot be reached from a 10.0.0.x network, ever")
        XCTAssertFalse(RelayAddress.reachableByOthers(url))
    }

    func testEveryPrivateRangeIsRefusedForOthers() {
        for url in ["http://10.0.0.20:8674",
                    "http://172.16.5.9:8674",
                    "http://172.31.255.1:8674",
                    "http://192.168.1.1:8674",
                    "http://127.0.0.1:8674",
                    "http://169.254.10.10:8674",
                    "http://100.64.0.1:8674",
                    "http://100.127.255.254:8674"] {
            XCTAssertFalse(RelayAddress.reachableByOthers(url), "\(url) must not be offered to a circle")
        }
    }

    /// 172.15 and 172.32 are OUTSIDE 172.16/12 — an off-by-one here would silently drop public relays.
    func testTheEdgesOfTheOneSevenTwoRangeArePublic() {
        XCTAssertTrue(RelayAddress.reachableByOthers("http://172.15.0.1:8674"))
        XCTAssertTrue(RelayAddress.reachableByOthers("http://172.32.0.1:8674"))
        XCTAssertFalse(RelayAddress.reachableByOthers("http://172.16.0.1:8674"))
        XCTAssertFalse(RelayAddress.reachableByOthers("http://172.31.0.1:8674"))
    }

    /// 100.x outside 64...127 is ordinary public space (e.g. 100.42.x), not CGNAT.
    func testOneHundredDotIsOnlyCGNATInsideTheSlashTen() {
        XCTAssertTrue(RelayAddress.reachableByOthers("http://100.42.1.1:8674"))
        XCTAssertTrue(RelayAddress.reachableByOthers("http://100.128.1.1:8674"))
        XCTAssertFalse(RelayAddress.reachableByOthers("http://100.64.1.1:8674"))
    }

    func testPublicAddressesAndHostnamesArePublishable() {
        for url in ["https://relay.haven.is", "http://203.0.113.7:8674", "https://example.com:8674"] {
            XCTAssertTrue(RelayAddress.reachableByOthers(url))
            XCTAssertTrue(RelayAddress.plausiblyReachable(url, ourIPv4s: plainLAN))
        }
    }

    // MARK: - Cool-down forgiveness on a relay announce

    func testAReAnnounceOfADeadRelayKeepsItsCoolDown() {
        let held = (urls: ["http://127.0.0.1:8684", "http://10.0.0.4:18684"], token: "t1")
        XCTAssertEqual(RelayAddress.urlsToForgive(held: held, announced: held.urls, token: "t1"), [],
                       "members keep re-announcing a relay for 5 min after it dies — that is not news")
    }

    func testANewDoorOrARotatedTokenIsForgiven() {
        let held = (urls: ["http://127.0.0.1:8684"], token: "t1")
        XCTAssertEqual(RelayAddress.urlsToForgive(held: held, announced: ["http://127.0.0.1:8686"], token: "t1"),
                       ["http://127.0.0.1:8686"], "the relay moved: its new door is tried at once")
        XCTAssertEqual(RelayAddress.urlsToForgive(held: held, announced: held.urls, token: "t2"), held.urls,
                       "a rotated token means a restarted relay — every door is worth a try")
        XCTAssertEqual(RelayAddress.urlsToForgive(held: nil, announced: ["https://x.example"], token: "t"),
                       ["https://x.example"], "a relay we never held")
    }

    private let acct = String(repeating: "f", count: 64)
    private let device = String(repeating: "d", count: 64)

    func testADeadAccountIdEntryIsSupersededByALearnedDeviceRelay() {
        XCTAssertEqual(RelayAddress.supersededAccountRelays(entries: [acct], learned: device, accountIds: [acct]) { _ in false },
                       [acct])
    }

    func testALiveAccountIdRelayIsNeverSuperseded() {
        // The flip-flop: a Mac hosts relay `acct`; learning `device` must not evict it, or its next
        // announce re-adds it (backfill + media re-upload) and the two evict each other forever.
        XCTAssertEqual(RelayAddress.supersededAccountRelays(entries: [acct, device], learned: device, accountIds: [acct]) { $0 == self.acct },
                       [])
    }

    func testTheLearnedRelayAndNonAccountEntriesStay() {
        let other = String(repeating: "e", count: 64)
        XCTAssertEqual(RelayAddress.supersededAccountRelays(entries: [acct, other], learned: acct, accountIds: [acct]) { _ in false }, [])
        XCTAssertEqual(RelayAddress.supersededAccountRelays(entries: [other], learned: device, accountIds: [acct]) { _ in false }, [])
    }
}
