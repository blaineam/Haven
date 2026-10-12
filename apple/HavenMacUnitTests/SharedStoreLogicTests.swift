import XCTest
import Combine
@testable import HavenUITestHost

@MainActor
final class SharedStoreLogicTests: XCTestCase {
    private func uniq(_ p: String) -> String { "\(p)-\(UUID().uuidString.prefix(8))" }

    // MARK: MediaBackupLedger

    func testLedgerMarksIndexesAndForgets() {
        let ref = uniq("img"), relayA = uniq("relayA"), relayB = uniq("relayB")
        XCTAssertFalse(MediaBackupLedger.hasAny(ref))
        MediaBackupLedger.mark(relayA, ref)
        MediaBackupLedger.mark(relayA, ref)          // idempotent
        MediaBackupLedger.mark(relayB, ref)
        XCTAssertTrue(MediaBackupLedger.has(relayA, ref))
        XCTAssertTrue(MediaBackupLedger.hasAny(ref))
        XCTAssertEqual(Set(MediaBackupLedger.destinations(for: ref)), [relayA, relayB])
        // "Backed up" for a friend excludes my own relay.
        XCTAssertTrue(MediaBackupLedger.hasAnyRemote(ref, ownRelayHex: relayA))
        MediaBackupLedger.forgetDest(relayB)
        XCTAssertFalse(MediaBackupLedger.hasAnyRemote(ref, ownRelayHex: relayA), "only my own relay is left")
        XCTAssertTrue(MediaBackupLedger.hasAny(ref))
        MediaBackupLedger.forget(ref)
        XCTAssertFalse(MediaBackupLedger.hasAny(ref))
        XCTAssertEqual(MediaBackupLedger.destinations(for: ref), [])
        MediaBackupLedger.forget(ref)                // forgetting nothing is a no-op
    }

    func testLedgerPersistsToDefaults() {
        let ref = uniq("persist"), dest = uniq("dest")
        MediaBackupLedger.mark(dest, ref)
        let stored = UserDefaults.standard.stringArray(forKey: "haven.media.backedUp") ?? []
        XCTAssertTrue(stored.contains("\(dest)|\(ref)"))
        MediaBackupLedger.forget(ref)
        XCTAssertFalse((UserDefaults.standard.stringArray(forKey: "haven.media.backedUp") ?? []).contains("\(dest)|\(ref)"))
    }

    func testLedgerChangesBatchesTouchedRefs() async {
        let changes = MediaLedgerChanges.shared
        let ref = uniq("touched")
        let gen = changes.generation
        changes.note(ref)
        let exp = expectation(description: "burst flushed")
        let sub = changes.$generation.dropFirst().sink { g in if g > gen { exp.fulfill() } }
        await fulfillment(of: [exp], timeout: 10)
        sub.cancel()
        XCTAssertTrue(changes.touched([ref]))
        XCTAssertFalse(changes.touched([uniq("other")]))
        changes.noteAll()
        let exp2 = expectation(description: "second burst")
        let g2 = changes.generation
        let sub2 = changes.$generation.dropFirst().sink { g in if g > g2 { exp2.fulfill() } }
        await fulfillment(of: [exp2], timeout: 10)
        sub2.cancel()
        XCTAssertTrue(changes.touched([uniq("anything")]), "a whole-destination drop touches every ref")
    }

    // MARK: MediaBackupBackoff

    func testBackoffEscalatesThenClears() {
        let ref = uniq("stall")
        XCTAssertFalse(MediaBackupBackoff.shouldSkip(ref))
        XCTAssertNil(MediaBackupBackoff.earliestDue([ref]), "an unknown ref is due now")
        MediaBackupBackoff.recordStalled(ref)
        XCTAssertTrue(MediaBackupBackoff.shouldSkip(ref))
        let first = MediaBackupBackoff.earliestDue([ref])
        XCTAssertNotNil(first)
        MediaBackupBackoff.recordStalled(ref)
        MediaBackupBackoff.recordStalled(ref)    // past the two quick gaps: minutes now
        let third = MediaBackupBackoff.earliestDue([ref])
        XCTAssertGreaterThan(third ?? 0, first ?? UInt64.max, "the gap grows with consecutive stalls")
        // One due ref among several means something can run NOW.
        XCTAssertNil(MediaBackupBackoff.earliestDue([ref, uniq("fresh")]))
        MediaBackupBackoff.recordLanded(ref)
        XCTAssertFalse(MediaBackupBackoff.shouldSkip(ref))
    }

    func testPendingEnrollmentRefusalTakesAFlatGapAndReleases() {
        let ref = uniq("pend")
        MediaBackupBackoff.notePendingEnrollment(ref)
        MediaBackupBackoff.recordStalled(ref)
        XCTAssertTrue(MediaBackupBackoff.shouldSkip(ref))
        XCTAssertGreaterThanOrEqual(MediaBackupBackoff.releasePendingEnrollment(), 1)
        XCTAssertFalse(MediaBackupBackoff.shouldSkip(ref), "enrollment landing makes the deferred ref due now")
        XCTAssertEqual(MediaBackupBackoff.releasePendingEnrollment(), 0)
    }

    func testEnrollmentTrackingOnlyAppliesToAdoptedRelays() {
        let relay = String(repeating: "ab", count: 32)
        XCTAssertFalse(RelayEnrollment.isTracked(relay))
        RelayEnrollment.noteAdopted(["short", relay])
        XCTAssertTrue(RelayEnrollment.isTracked(relay))
        XCTAssertFalse(RelayEnrollment.isTracked("short"))
        XCTAssertTrue(RelayEnrollment.mayAttempt(relay))
        XCTAssertTrue(RelayEnrollment.anyPending())
        XCTAssertTrue(RelayEnrollment.pendingRelays().contains(relay))
        XCTAssertTrue(RelayEnrollment.mayAttempt(String(repeating: "cd", count: 32)), "an untracked relay is never held")
        // A 403 from a relay still pending enrollment is the expected kind: no long backoff.
        let ref = uniq("pendingRef")
        XCTAssertTrue(SharedStore.noteRefused(relay, "PUT", ref: ref))
        XCTAssertFalse(RelayEnrollment.mayAttempt(relay), "held for the flat gap after the refusal")
        // A refusal from a relay nobody is enrolling on is a real one.
        XCTAssertFalse(SharedStore.noteRefused(String(repeating: "ef", count: 32), "GET"))
        RelayEnrollment.confirm(relay)
        XCTAssertTrue(RelayEnrollment.mayAttempt(relay))
    }

    func testForbiddenErrorsAreRecognised() {
        struct Boom: Error {}
        XCTAssertTrue(RelayEnrollment.isForbidden(SharedStore.RelayForbidden()))
        XCTAssertFalse(RelayEnrollment.isForbidden(Boom()))
        XCTAssertTrue(RelayEnrollment.isForbidden(NSError(domain: "relay", code: 403, userInfo: [NSLocalizedDescriptionKey: "Forbidden"])))
    }

    // MARK: Media backup queue

    func testBackupQueueDedupesPromotesAndAnswersPending() throws {
        let engine = Engine(try HavenSocial(accountSeed: Data(repeating: 7, count: 32)))
        let q = MediaBackupQueue.shared
        let a = uniq("qa"), b = uniq("qb")
        XCTAssertFalse(q.hasPending(a))
        q.enqueue(a, circleId: "default", engine: engine, mine: nil)
        q.enqueue(a, circleId: "default", engine: engine, mine: true)   // dedupes, learns authorship
        q.enqueue(b, circleId: "other", engine: engine, priority: true)
        XCTAssertTrue(q.hasPending(a))
        XCTAssertTrue(q.hasPending(b))
        XCTAssertEqual(q.circleId(forPending: a), "default")
        XCTAssertEqual(q.circleId(forPending: b), "other")
        XCTAssertNil(q.circleId(forPending: uniq("never")))
        XCTAssertTrue(q.hasAnyPending)
        q.promote(a)
        q.promote(uniq("not queued"))   // no-op
        XCTAssertTrue(q.hasPending(a))
        // Synthetic refs (map pins) carry no bytes and never queue.
        let pin = "geo:1.0,2.0"
        q.enqueue(pin, circleId: "default", engine: engine)
        XCTAssertFalse(q.hasPending(pin))
        q.drainPersisted(engine: engine)   // offline: refuses, keeps everything persisted
        XCTAssertTrue(q.hasPending(a))
    }

    // MARK: Mailbox keys and seen cursor

    func testHelloAndEnvelopeMailboxKeys() {
        let body = Data("hello".utf8)
        let k1 = SharedStore.helloMailboxKey(circleId: "c1", toHex: "AABB", fromHex: "CCDD", body: body)
        XCTAssertTrue(k1.hasPrefix("haven/mailbox/c1/__hello__/aabb/ccdd/"))
        XCTAssertEqual(k1, SharedStore.helloMailboxKey(circleId: "c1", toHex: "aabb", fromHex: "ccdd", body: body))
        XCTAssertNotEqual(k1, SharedStore.helloMailboxKey(circleId: "c1", toHex: "aabb", fromHex: "ccdd", body: Data("other".utf8)))
        let env = Data([1, 2, 3, 4])
        let hint = SharedStore.mailboxKeyHint(circleId: "c9", env: env)
        XCTAssertTrue(hint.hasPrefix("haven/mailbox/c9/"))
        XCTAssertEqual(hint.split(separator: "/").last?.count, 64)
        XCTAssertEqual(hint, SharedStore.mailboxKeyHint(circleId: "c9", env: env))
    }

    func testHelloKeysAreClaimedOnlyByTheirRecipient() {
        let mine: Set<String> = ["aa11", "bb22"]
        XCTAssertTrue(SharedStore.helloKeyClaimable("haven/mailbox/c/abc", myIds: mine), "event keys always pass")
        XCTAssertTrue(SharedStore.helloKeyClaimable("haven/mailbox/c/__hello__/AA11/zz/dd", myIds: mine))
        XCTAssertTrue(SharedStore.helloKeyClaimable("haven/mailbox/c/__hello__/bb22/zz/dd", myIds: mine))
        XCTAssertFalse(SharedStore.helloKeyClaimable("haven/mailbox/c/__hello__/cc33/zz/dd", myIds: mine))
    }

    func testSeenCursorMarkForgetAndAwaitingPersist() {
        let prefix = "haven/mailbox/\(uniq("seen"))/"
        let k1 = prefix + "one", k2 = prefix + "two", live = prefix + "__live__/x/y"
        SharedStore.markSeenPublic(k1); SharedStore.markSeenPublic(k2); SharedStore.markSeenPublic(live)
        XCTAssertTrue(SharedStore.isDurablySeen(k1))
        SharedStore.flushSeenMailbox()
        SharedStore.forgetSeenPrefix(prefix)
        XCTAssertFalse(SharedStore.isDurablySeen(k1))
        XCTAssertFalse(SharedStore.isDurablySeen(k2))
        XCTAssertTrue(SharedStore.isDurablySeen(live), "live-call frames keep their marks")
        // Held-awaiting-persist keys are counted: released only by as many releases as holds.
        SharedStore.holdAwaitingPersist([k1]); SharedStore.holdAwaitingPersist([k1])
        SharedStore.releaseAwaitingPersist([k1])
        SharedStore.releaseAwaitingPersist([k1])
        SharedStore.holdAwaitingPersist([]); SharedStore.releaseAwaitingPersist([])
        XCTAssertFalse(SharedStore.isDurablySeen(k1))
    }

    func testBadHttpUrlsCoolDownAndClear() {
        let base = "http://\(uniq("relay")).example"
        XCTAssertFalse(SharedStore.httpUrlBad(base))
        SharedStore.clearHttpUrlBad(base)
        SharedStore.clearAllHttpUrlBad()
        XCTAssertFalse(SharedStore.httpUrlBad(base))
    }

    func testRosterPullBackoffGatesPerAccount() {
        let acct = uniq("acct")
        XCTAssertTrue(SharedStore.rosterPullDue(acct))
        SharedStore.noteRosterPullAttempt(acct)
        XCTAssertFalse(SharedStore.rosterPullDue(acct))
        SharedStore.clearRosterPullBackoff(acct)
        XCTAssertTrue(SharedStore.rosterPullDue(acct))
        SharedStore.noteRosterPullAttempt(acct)
        SharedStore.clearRosterPullBackoff()
        XCTAssertTrue(SharedStore.rosterPullDue(acct))
    }

    func testFanOutKeepsInputOrder() async {
        let out = await SharedStore.fanOut([3, 1, 2, 5, 4], limit: 2) { n in n * 10 }
        XCTAssertEqual(out, [30, 10, 20, 50, 40])
        let none = await SharedStore.fanOut([Int](), limit: 3) { $0 }
        XCTAssertEqual(none, [])
    }

    func testPassClaimsAreSharedAcrossRelays() {
        let c = MailboxPassClaims()
        XCTAssertFalse(c.has("c", "k"))
        c.add("c", "k")
        XCTAssertTrue(c.has("c", "k"))
    }

    // MARK: Shared mailbox config + owner S3

    func testSharedMailboxKeepsSecretOutOfDefaults() {
        let store = SharedMailboxStore.shared
        let cfg = S3Config(endpoint: "https://s3.example", region: "eu-1", bucket: "b", accessKey: "AK", secret: "SECRETVALUE")
        store.set(cfg)
        XCTAssertEqual(store.config, cfg)
        XCTAssertTrue(SharedStore.isVolunteering)
        XCTAssertNotNil(SharedStore.mailboxClient())
        let raw = UserDefaults.standard.data(forKey: "haven.sharedMailbox") ?? Data()
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("SECRETVALUE"), "the secret lives in the keychain, not prefs")
        XCTAssertEqual(Keychain.get("sharedMailboxSecret"), "SECRETVALUE")
        store.clear()
        XCTAssertNil(store.config)
        XCTAssertNil(Keychain.get("sharedMailboxSecret"))
    }
}
