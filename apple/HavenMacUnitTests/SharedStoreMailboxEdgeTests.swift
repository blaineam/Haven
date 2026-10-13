import XCTest
@testable import HavenUITestHost

/// The relay mailbox's single-key operations over the in-process wire: parking a relay announce,
/// fetching the exact key a push named, and listing / reading a circle's history — each with a relay
/// that answers, one that doesn't hold the key, one that refuses us, and one that is down.
@MainActor
final class SharedStoreMailboxEdgeTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayA = String(repeating: "e5", count: 32)
    private let relayB = String(repeating: "e6", count: 32)

    override func setUp() async throws {
        _ = await Harness.feed()
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        let r = RelayMailboxStore.shared
        for (hex, base) in [(relayA, FakeWire.relayBase), (relayB, FakeWire.relay2Base)] {
            r.add(circleId: "default", nodeHex: hex)
            r.setHttpInterface(hex, urls: [base], token: "tok")
            RelayEnrollment.confirm(hex)
        }
    }
    override func tearDown() async throws {
        let r = RelayMailboxStore.shared
        for hex in [relayA, relayB] { r.eraseNow(hex); r.dropErased(hex); r.unforget(hex) }
        wire.uninstall()
    }

    private func uniqKey(_ tail: String = "") -> String { "haven/mailbox/default/\(UUID().uuidString.lowercased())\(tail)" }

    func testARelayAnnounceIsParkedOnceAndIgnoredWhenMalformed() async {
        let node = String(repeating: "ab", count: 32)
        let plain = Data("announce \(UUID().uuidString)".utf8)
        let payload = Data([9, 8, 7])
        let key = RelayAnnounceKey.key(circleId: "default", nodeHex: node, plain: plain)

        await SharedStore.putRelayAnnounce(circleId: "", nodeHex: node, plain: plain, payload: payload)
        await SharedStore.putRelayAnnounce(circleId: "default", nodeHex: "short", plain: plain, payload: payload)
        await SharedStore.putRelayAnnounce(circleId: "default", nodeHex: node, plain: plain, payload: Data())
        XCTAssertTrue(wire.requests(method: "PUT").isEmpty, "malformed announces never reach the wire")

        await SharedStore.putRelayAnnounce(circleId: "default", nodeHex: node, plain: plain, payload: payload)
        let landedOn = [FakeWire.relayHost, FakeWire.relay2Host].filter { wire.relayData(key, host: $0) == payload }
        XCTAssertEqual(landedOn.count, 1, "the first relay that takes it is enough")
        let puts = wire.requests(method: "PUT").count
        await SharedStore.putRelayAnnounce(circleId: "default", nodeHex: node, plain: plain, payload: payload)
        XCTAssertEqual(wire.requests(method: "PUT").count, puts, "the same announcement is one entry")
    }

    func testAnAnnounceSurvivesOneRefusingRelayAndOneDeadRelay() async {
        let node = String(repeating: "cd", count: 32)
        let plain = Data("announce-2 \(UUID().uuidString)".utf8)
        let key = RelayAnnounceKey.key(circleId: "default", nodeHex: node, plain: plain)
        wire.refuse = true; wire.unreachable2 = true
        await SharedStore.putRelayAnnounce(circleId: "default", nodeHex: node, plain: plain, payload: Data([1]))
        XCTAssertNil(wire.relayData(key)); XCTAssertNil(wire.relayData(key, host: FakeWire.relay2Host))
        XCTAssertFalse(SharedStore.httpUrlBad(FakeWire.relayBase), "a refusal is not an outage")
        XCTAssertTrue(SharedStore.httpUrlBad(FakeWire.relay2Base), "a dead relay is skipped for a while")

        wire.refuse = false; wire.unreachable2 = false
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        await SharedStore.putRelayAnnounce(circleId: "default", nodeHex: node, plain: plain, payload: Data([1]))
        XCTAssertTrue(wire.relayData(key) != nil || wire.relayData(key, host: FakeWire.relay2Host) != nil, "…and it lands once a relay answers")
    }

    func testTheKeyAPushNamedIsFetchedFromWhicheverRelayHoldsIt() async {
        let key = uniqKey(), env = Data((0..<40).map { UInt8($0) })
        wire.putRelay(key, env, host: FakeWire.relay2Host)   // only the second relay has it
        let got = await SharedStore.fetchMailboxKey(circleId: "default", key: key)
        XCTAssertEqual(got, env, "the first relay doesn't hold it: the next is asked")

        let outside = await SharedStore.fetchMailboxKey(circleId: "default", key: "haven/mailbox/other/abc")
        XCTAssertNil(outside, "a hint naming another circle's key is never a free fetch")
        let gets = wire.requests(method: "GET").count
        let missing = await SharedStore.fetchMailboxKey(circleId: "default", key: uniqKey())
        XCTAssertNil(missing)
        XCTAssertGreaterThan(wire.requests(method: "GET").count, gets, "both relays were asked")

        SharedStore.markSeenPublic(key)
        let seen = await SharedStore.fetchMailboxKey(circleId: "default", key: key)
        XCTAssertNil(seen, "a key already ingested is not fetched again")
    }

    func testAHintedFetchTreatsARefusalAsNotAnOutage() async {
        let key = uniqKey(), env = Data([5, 5, 5])
        wire.putRelay(key, env)
        wire.refuse = true
        let refused = await SharedStore.fetchMailboxKey(circleId: "default", key: key)
        XCTAssertNil(refused)
        XCTAssertFalse(SharedStore.httpUrlBad(FakeWire.relayBase))
        wire.refuse = false
        let ok = await SharedStore.fetchMailboxKey(circleId: "default", key: key)
        XCTAssertEqual(ok, env)

        let other = uniqKey()
        wire.putRelay(other, env, host: FakeWire.relay2Host)
        wire.unreachable = true
        let viaSecond = await SharedStore.fetchMailboxKey(circleId: "default", key: other)
        XCTAssertEqual(viaSecond, env, "a dead relay doesn't stop the next one answering")
        XCTAssertTrue(SharedStore.httpUrlBad(FakeWire.relayBase))
    }

    func testHistoryIsListedAndReadKeyByKey() async {
        let a = uniqKey(), b = uniqKey()
        wire.putRelay(a, Data([1])); wire.putRelay(b, Data([2]))
        let listed = await SharedStore.historyList(circleId: "default", node: relayA)
        XCTAssertEqual(Set(listed ?? []).intersection([a, b]), [a, b])
        let one = await SharedStore.historyGet(node: relayA, key: a)
        XCTAssertEqual(one, Data([1]))
        let none = await SharedStore.historyGet(node: relayA, key: uniqKey())
        XCTAssertNil(none, "an absent key reads as nil, not an error")

        wire.refuse = true
        let refusedList = await SharedStore.historyList(circleId: "default", node: relayA)
        XCTAssertNil(refusedList)
        let refusedGet = await SharedStore.historyGet(node: relayA, key: a)
        XCTAssertNil(refusedGet)
        XCTAssertFalse(SharedStore.httpUrlBad(FakeWire.relayBase))
        wire.refuse = false

        wire.unreachable = true
        let downList = await SharedStore.historyList(circleId: "default", node: relayA)
        XCTAssertNil(downList)
        XCTAssertTrue(SharedStore.httpUrlBad(FakeWire.relayBase))
        SharedStore.clearAllHttpUrlBad()
        let downGet = await SharedStore.historyGet(node: relayA, key: a)
        XCTAssertNil(downGet)
        XCTAssertTrue(SharedStore.httpUrlBad(FakeWire.relayBase))
        wire.unreachable = false
        XCTAssertTrue(Set(SharedStore.historyRelayNodes("default")).isSuperset(of: [relayA, relayB]))
    }
}
