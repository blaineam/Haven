import XCTest
@testable import HavenUITestHost

/// The relay bookkeeping (RelayMailboxStore / RelayHealth / RelayBackoffStep): which relays serve
/// which circle, and how deletes, re-adds and restores converge across my devices.
@MainActor
final class RelayStoreTests: XCTestCase {
    private var created: [String] = []
    private var circles: [String] = []

    private func relay() -> String {
        let h = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        created.append(h)
        return h
    }
    private func circle() -> String { let c = "tc-\(UUID().uuidString.prefix(8))"; circles.append(c); return c }
    private var store: RelayMailboxStore { RelayMailboxStore.shared }

    override func tearDown() async throws {
        for r in created { store.eraseNow(r); store.dropErased(r); store.unforget(r) }
        for c in circles { store.clear(circleId: c) }
        store.setDefault(nil)
        created.removeAll(); circles.removeAll()
    }

    func testAddAssociatesAndNormalises() {
        let c = circle(), r = relay()
        store.add(circleId: c, nodeHex: "  " + r.uppercased() + " ")
        XCTAssertEqual(store.relays(forCircle: c), [r])
        XCTAssertEqual(store.nodeId(forCircle: c), r)
        XCTAssertEqual(store.explicitRelays(forCircle: c), [r])
        XCTAssertTrue(store.allRelays().contains(r))
        XCTAssertTrue(store.circlesWithRelay(excluding: "other").contains(c))
        XCTAssertFalse(store.circlesWithRelay(excluding: c).contains(c))
        store.add(circleId: c, nodeHex: r)           // duplicate is a no-op
        XCTAssertEqual(store.explicitRelays(forCircle: c).count, 1)
        store.add(circleId: c, nodeHex: "tooshort")  // malformed ids are refused
        XCTAssertEqual(store.explicitRelays(forCircle: c).count, 1)
        XCTAssertEqual(store.addedAtMs(r) > 0, true)
        XCTAssertTrue(store.allEntries().contains { $0.hex == r && $0.active })
        store.rename(r, to: "  My NAS  ")
        XCTAssertEqual(store.entries[r]?.name, "My NAS")
        store.rename(r, to: "   ")
        XCTAssertEqual(store.entries[r]?.name, "My NAS", "blank names are ignored")
        store.remove(circleId: c, nodeHex: r)
        XCTAssertEqual(store.explicitRelays(forCircle: c), [])
        XCTAssertEqual(store.activeExplicitRelays(forCircle: c), [])
    }

    func testS3EntriesKeepTheirScheme() {
        let c = circle()
        let s3 = "s3:bucket-\(UUID().uuidString.prefix(8))"
        created.append(s3)
        store.add(circleId: c, nodeHex: s3, name: nil, isS3: true)
        XCTAssertEqual(store.entries[s3]?.isS3, true)
        XCTAssertTrue(RelayMailboxStore.shortName(s3).hasPrefix("S3 · "))
        XCTAssertTrue(RelayMailboxStore.shortName(relay()).hasPrefix("Relay · "))
        store.add(circleId: c, nodeHex: "bucket-without-prefix", isS3: true)   // refused: not an s3: id
        XCTAssertEqual(store.explicitRelays(forCircle: c), [s3])
    }

    func testDefaultRelayServesEveryCircle() {
        let c1 = circle(), c2 = circle(), r = relay()
        store.setDefault(r)
        XCTAssertEqual(store.defaultNodeHex, r)
        XCTAssertTrue(store.relays(forCircle: c1).contains(r))
        XCTAssertTrue(store.relays(forCircle: c2).contains(r))
        XCTAssertEqual(store.explicitRelays(forCircle: c1), [], "the default is not an explicit association")
        XCTAssertTrue(store.allRelays().contains(r))
        store.setDefault(nil)
        XCTAssertFalse(store.relays(forCircle: c1).contains(r))
    }

    func testForgetDeactivatesButKeepsConfigAndRestoreBringsItBack() {
        let c = circle(), r = relay()
        store.add(circleId: c, nodeHex: r)
        store.forget(nodeHex: r)
        XCTAssertFalse(store.isActive(r))
        XCTAssertTrue(store.isForgotten(r))
        XCTAssertGreaterThan(store.forgottenAtMs(r), 0)
        XCTAssertNotNil(store.forgottenRelays[r])
        XCTAssertEqual(store.relays(forCircle: c), [], "inactive relays are not dialed")
        XCTAssertEqual(store.explicitRelays(forCircle: c), [r], "…but the association survives")
        XCTAssertTrue(store.recoverableRelays.contains { $0.hex == r })
        // A passive learn must not resurrect what the user deleted.
        store.addSynced(circleId: circle(), nodeHex: r)
        XCTAssertFalse(store.isActive(r))
        store.adoptBootstrapRelays([r])
        XCTAssertFalse(store.isActive(r))
        store.restore(nodeHex: r)
        XCTAssertTrue(store.isActive(r))
        XCTAssertFalse(store.isForgotten(r))
        XCTAssertEqual(store.relays(forCircle: c), [r])
        XCTAssertTrue(store.clearedRelayForgetRecords[r] != nil, "a restore is published as a CLEAR")
        store.restore(nodeHex: relay())   // erased for good: nothing to recover, no crash
    }

    func testEraseArchivesAndRestoreErasedPutsEverythingBack() {
        let c = circle(), r = relay()
        store.add(circleId: c, nodeHex: r, name: "Basement")
        store.setDefault(r)
        store.eraseNow(r)
        XCTAssertNil(store.entries[r])
        XCTAssertNil(store.defaultNodeHex)
        XCTAssertEqual(store.explicitRelays(forCircle: c), [])
        XCTAssertTrue(store.hasErasedRecord(r))
        let rec = store.erasedRelays.first { $0.entry.hex == r }
        XCTAssertEqual(rec?.entry.name, "Basement")
        XCTAssertEqual(rec?.wasDefault, true)
        store.restoreErased(r)
        XCTAssertEqual(store.entries[r]?.active, true)
        XCTAssertEqual(store.explicitRelays(forCircle: c), [r])
        XCTAssertEqual(store.defaultNodeHex, r)
        XCTAssertFalse(store.hasErasedRecord(r))
        store.eraseNow(r)
        store.dropErased(r)
        XCTAssertFalse(store.hasErasedRecord(r))
        store.dropErased(r)   // already gone
        store.restoreErased(r) // nothing archived: no-op
        XCTAssertNil(store.entries[r])
    }

    func testBareTombstonesStillListAsRestorable() {
        let r = relay()
        store.applyForgottenTombstone(r, atMs: 5_000)       // a sibling deleted it; we never had it
        let listed = store.erasedRelays.first { $0.entry.hex == r }
        XCTAssertNotNil(listed, "a legacy tombstone is enough to bring a relay back")
        XCTAssertFalse(store.hasErasedRecord(r))
        XCTAssertEqual(listed?.circles, [])
    }

    func testPurgeOnlyReapsInactiveAndUnseen() {
        let c = circle(), stale = relay(), active = relay()
        store.add(circleId: c, nodeHex: stale)
        store.add(circleId: c, nodeHex: active)
        store.forget(nodeHex: stale)
        let farFuture = UInt64(Date().timeIntervalSince1970 * 1000) + RelayMailboxStore.staleAfterMs + 1_000
        store.purgeStale(nowMs: farFuture)
        XCTAssertNil(store.entries[stale], "inactive + unseen for a week is erased")
        XCTAssertNotNil(store.entries[active], "an active relay is never purged, however long unreachable")
    }

    // MARK: LWW convergence across devices

    func testSyncedDeletionBeatsOlderAdoptionButLosesToNewerReAdd() {
        let c = circle(), r = relay()
        store.add(circleId: c, nodeHex: r)
        let adopted = store.addedAtMs(r)
        store.applyForgottenTombstone(r, atMs: adopted - 1)    // older than my adoption → ignored
        XCTAssertTrue(store.isActive(r))
        store.applyForgottenTombstone(r, atMs: 0)              // no stamp → ignored
        XCTAssertTrue(store.isActive(r))
        store.applyForgottenTombstone(r, atMs: adopted + 10)   // newer → applies
        XCTAssertFalse(store.isActive(r))
        XCTAssertEqual(store.forgottenAtMs(r), adopted + 10)
        store.applyForgottenTombstone(r, atMs: adopted + 10)   // idempotent
        // A sibling's re-add older than my delete loses; a newer one wins.
        store.applyClearedRelayForget(r, atMs: adopted + 5)
        XCTAssertTrue(store.isForgotten(r))
        store.applyClearedRelayForget(r, atMs: adopted + 20)
        XCTAssertFalse(store.isForgotten(r))
        XCTAssertEqual(store.clearedRelayForgetRecords[r], adopted + 20)
        store.applyClearedRelayForget(r, atMs: 0)
        store.applyClearedRelayForget(r, atMs: adopted + 20)   // already cleared: no-op
    }

    func testSyncLearnedRelayCarriesNoAdoptionStamp() {
        let c = circle(), r = relay()
        store.addSynced(circleId: c, nodeHex: r)
        XCTAssertEqual(store.addedAtMs(r), 0, "a sync-learned relay must not claim a fresh adoption")
        XCTAssertEqual(store.explicitRelays(forCircle: c), [r])
        store.addSynced(circleId: c, nodeHex: "short")
        XCTAssertEqual(store.explicitRelays(forCircle: c), [r])
    }

    func testReactivateAndUnforgetPublishAClear() {
        let c = circle(), r = relay()
        store.add(circleId: c, nodeHex: r)
        store.forget(nodeHex: r)
        store.reactivate(r)
        XCTAssertTrue(store.isActive(r))
        XCTAssertFalse(store.isForgotten(r))
        XCTAssertNotNil(store.clearedRelayForgetRecords[r])
        store.unforget(r)   // nothing left to clear
    }

    // MARK: Interfaces and fabric

    func testHttpDerpAndTurnSettingsStickOnTheEntry() {
        let c = circle(), r = relay()
        store.add(circleId: c, nodeHex: r)
        store.setHttpInterface(r, urls: ["https://relay.example"], token: "tok")
        store.setHttpInterface(r, urls: ["https://relay.example"], token: "tok")   // unchanged: no write
        XCTAssertEqual(store.entries[r]?.httpUrls, ["https://relay.example"])
        XCTAssertEqual(store.entries[r]?.httpToken, "tok")
        XCTAssertNil(store.httpInterface(r), "HAVEN_NO_NET retires the whole HTTP lane")

        store.setDerpUrl(r, url: " https://derp.example/ ")
        XCTAssertEqual(store.entries[r]?.derpUrl, "https://derp.example")
        XCTAssertTrue(store.allDerpUrls().contains("https://derp.example"))
        store.setDerpUrl(r, url: "https://derp.example")      // unchanged
        store.setTurn(r, urls: ["turn:t.example:3478", "ftp://bogus", " turns:t.example:5349 "], user: " u ", pass: " p ")
        XCTAssertEqual(store.entries[r]?.turnUrls, ["turn:t.example:3478", "turns:t.example:5349"])
        let ice = store.allTurnIce()
        XCTAssertTrue(ice.urls.contains("turn:t.example:3478"))
        XCTAssertFalse(ice.user.isEmpty); XCTAssertFalse(ice.pass.isEmpty)
        store.setTurn(r, urls: ["turn:t.example:3478", "turns:t.example:5349"], user: "u", pass: "p")  // unchanged
        store.setDerpUrl(r, url: nil)
        XCTAssertNil(store.entries[r]?.derpUrl)
        store.setTurn(r, urls: [], user: "", pass: "")
        XCTAssertNil(store.entries[r]?.turnUrls)
        store.forget(nodeHex: r)
        XCTAssertFalse(store.allDerpUrls().contains("https://derp.example"), "an inactive relay's fabric is not advertised")
    }

    func testMarkSeenIsCoarse() {
        let c = circle(), r = relay()
        store.add(circleId: c, nodeHex: r)
        let before = store.entries[r]?.lastSeenMs ?? 0
        store.markSeen(r)      // younger than the granularity: untouched
        XCTAssertEqual(store.entries[r]?.lastSeenMs, before)
        store.markSeen("not-a-relay")
    }

    func testBootstrapAndFriendInviteRelays() {
        let a = relay(), b = relay()
        XCTAssertTrue(store.adoptFriendInviteRelays([a, b]))
        XCTAssertTrue(store.relays(forCircle: "default").contains(a))
        XCTAssertTrue(store.allRelays().contains(b))
        XCTAssertFalse(store.adoptFriendInviteRelays([a, b]), "adopting the same relays again changes nothing")
        store.clear(circleId: "__bootstrap__")
        store.remove(circleId: "default", nodeHex: a)
        store.remove(circleId: "default", nodeHex: b)
        store.setDefault(nil)
    }

    func testRelayUrlHelpersDelegateToAddressRules() {
        XCTAssertTrue(RelayMailboxStore.urlPlausiblyReachable("https://relay.example.com"))
        XCTAssertTrue(RelayMailboxStore.urlReachableByOthers("https://relay.example.com"))
        XCTAssertFalse(RelayMailboxStore.urlReachableByOthers("http://192.168.1.5:8080"))
    }

    // MARK: Health

    func testHealthBacksOffExponentiallyAndRecovers() {
        let h = RelayHealth.shared, r = relay()
        XCTAssertTrue(h.available(r))
        XCTAssertFalse(h.provenAlive(r, withinMs: 60_000))
        h.recordSuccess(r)
        XCTAssertTrue(h.provenAlive(r, withinMs: 60_000))
        h.recordFailure(r)
        XCTAssertFalse(h.available(r), "inside the backoff window")
        XCTAssertTrue(h.provenAlive(r, withinMs: 60_000), "one blip keeps proof of life")
        h.recordFailure(r)    // same outage: does not escalate
        XCTAssertEqual(h.qaRow(r)["fails"] as? Int, 1, "one outage is one strike")
        XCTAssertEqual(h.qaRow(r)["reason"] as? String, "failure")
        h.resetBackoffs()
        XCTAssertTrue(h.available(r))
        XCTAssertEqual(h.qaRow(r)["fails"] as? Int, 0)
        XCTAssertFalse(h.qaSnapshot().isEmpty)
        h.qaResetPeak()
        h.recordSuccess(r)
        XCTAssertTrue(h.available(r))
        h.forget(r)
    }

    func testBackoffStepGrowsOnlyAfterTheWindowExpires() {
        let first = RelayBackoffStep.next(fails: 0, nextRetryMs: 0, now: 1_000)
        XCTAssertEqual(first?.backoffMs, RelayBackoffStep.baseMs)
        XCTAssertNil(RelayBackoffStep.next(fails: 1, nextRetryMs: 10_000, now: 2_000), "inside the window: one outage, one strike")
        let second = RelayBackoffStep.next(fails: 1, nextRetryMs: 10_000, now: 20_000)
        XCTAssertEqual(second?.backoffMs, RelayBackoffStep.baseMs * 2)
        let capped = RelayBackoffStep.next(fails: 50, nextRetryMs: 0, now: 1)
        XCTAssertEqual(capped?.backoffMs, RelayBackoffStep.maxMs)
    }
}
