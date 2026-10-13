import XCTest
import AppKit
import Security
@testable import HavenUITestHost

/// A circle served by TWO relays over the in-process wire: media reaches both, a relay that lost a
/// blob gets a ciphertext copy from the one that holds it, and one relay's refusal or outage never
/// takes the other down with it.
@MainActor
final class SharedStoreRelayTests: XCTestCase {
    private let wire = FakeWire.shared
    private let relayA = String(repeating: "e1", count: 32)
    private let relayB = String(repeating: "e2", count: 32)

    override func setUp() async throws {
        _ = await Harness.feed()
        wire.install()
        SharedStore.clearAllHttpUrlBad()
        RelayHealth.shared.resetBackoffs()
        let r = RelayMailboxStore.shared
        for (hex, base) in [(relayA, FakeWire.relayBase), (relayB, FakeWire.relay2Base)] {
            r.add(circleId: "default", nodeHex: hex)
            r.setHttpInterface(hex, urls: [base], token: "tok-\(hex.prefix(2))")
            RelayEnrollment.confirm(hex)
        }
    }
    override func tearDown() async throws {
        let r = RelayMailboxStore.shared
        for hex in [relayA, relayB] { r.eraseNow(hex); r.dropErased(hex); r.unforget(hex) }
        r.setDefault(nil)
        wire.uninstall()
    }

    private func jpeg(_ tag: String) -> (ref: String, data: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var d = rep.representation(using: .jpeg, properties: [:])!
        d.append(contentsOf: (tag + UUID().uuidString).utf8)
        return (MediaStore.contentRef(.image, d), d)
    }
    private func until(_ what: String, timeout: TimeInterval = 60, _ cond: @escaping @MainActor () -> Bool) async {
        await Harness.until(FeedStore.shared, timeout: timeout, what, cond)
    }
    private func anyEngine() throws -> Engine {
        Engine(try HavenSocial(accountSeed: try XCTUnwrap(AccountStore.storedSeed())))
    }
    private func hold(_ ref: String, host: String) -> Bool { wire.relayData("haven/media/\(ref)", host: host) != nil }

    /// Post a blob so BOTH relays hold it, then drop the plaintext and relay B's copy.
    private func strand(_ ref: String, _ data: Data) async {
        let store = FeedStore.shared
        store.setActiveCircle("default")
        XCTAssertTrue(MediaStore.shared.store(ref, data))
        _ = await store.postNow("two relays \(ref.prefix(6))", media: [ref])
        await until("both relays hold the blob") { self.hold(ref, host: FakeWire.relayHost) && self.hold(ref, host: FakeWire.relay2Host) }
        await until("the upload queue drains") { !MediaBackupQueue.shared.hasPending(ref) }
        wire.removeRelay(prefix: "haven/media/\(ref)", host: FakeWire.relay2Host)
        MediaBackupLedger.forget(ref)
        MediaBackupBackoff.recordLanded(ref)
        MediaStore.shared.delete(ref)
    }

    func testARelayThatLostABlobGetsACiphertextCopyFromTheOneThatHasIt() async throws {
        let (ref, data) = jpeg("mirror")
        await strand(ref, data)
        XCTAssertFalse(MediaStore.shared.hasLocalFile(ref), "the plaintext is gone: nothing can be re-sealed")
        XCTAssertFalse(hold(ref, host: FakeWire.relay2Host))

        let ok = await SharedStore.backup(ref: ref, circleId: "default", engine: try anyEngine())
        XCTAssertTrue(ok)
        XCTAssertEqual(wire.relayData("haven/media/\(ref)", host: FakeWire.relay2Host), wire.relayData("haven/media/\(ref)"),
                       "the very same sealed bytes were copied across")
        XCTAssertTrue(MediaBackupLedger.has(relayB, ref))
        XCTAssertNotEqual(wire.relayData("haven/media/\(ref)", host: FakeWire.relay2Host), data, "relays only ever hold ciphertext")

        // Everyone holds it now: a second pass is a no-op that asks nobody.
        let before = wire.requests().count
        let again = await SharedStore.backup(ref: ref, circleId: "default", engine: try anyEngine())
        XCTAssertTrue(again)
        XCTAssertEqual(wire.requests().count, before, "a fully-confirmed blob costs no traffic")
    }

    func testNothingToCopyFromIsAStallNotASuccess() async throws {
        let (ref, data) = jpeg("stall")
        await strand(ref, data)
        wire.removeRelay(prefix: "haven/media/\(ref)", host: FakeWire.relayHost)   // now NOBODY holds it
        MediaBackupLedger.forget(ref)
        let ok = await SharedStore.backup(ref: ref, circleId: "default", engine: try anyEngine())
        XCTAssertFalse(ok, "no relay holds it and it can't be re-sealed")
        XCTAssertTrue(MediaBackupBackoff.shouldSkip(ref), "…so the sweep backs off instead of re-probing every pass")
        MediaBackupBackoff.recordLanded(ref)
    }

    func testAnUnreachableOrRefusingSecondRelayDoesNotBlockTheFirst() async throws {
        let (ref, data) = jpeg("down")
        await strand(ref, data)
        // B is down: A already holds it, so the pass succeeds and B is marked bad for a while.
        wire.unreachable2 = true
        let ok = await SharedStore.backup(ref: ref, circleId: "default", engine: try anyEngine())
        XCTAssertTrue(ok)
        XCTAssertTrue(SharedStore.httpUrlBad(FakeWire.relay2Base), "a dead relay is skipped for a while")
        XCTAssertFalse(SharedStore.httpUrlBad(FakeWire.relayBase))
        XCTAssertFalse(hold(ref, host: FakeWire.relay2Host))

        // B answers but refuses us: reachable, not an outage.
        wire.unreachable2 = false
        SharedStore.clearAllHttpUrlBad()
        wire.refuse2 = true
        let refused = await SharedStore.backup(ref: ref, circleId: "default", engine: try anyEngine())
        XCTAssertTrue(refused, "the blob is safe on A either way")
        XCTAssertFalse(SharedStore.httpUrlBad(FakeWire.relay2Base), "a refusal is not an outage")
        XCTAssertFalse(hold(ref, host: FakeWire.relay2Host))

        // And once B takes us again the copy lands.
        wire.refuse2 = false
        RelayHealth.shared.resetBackoffs()
        SharedStore.clearAllHttpUrlBad()
        MediaBackupLedger.forget(ref)
        let healed = await SharedStore.backup(ref: ref, circleId: "default", engine: try anyEngine())
        XCTAssertTrue(healed)
        await until("relay B receives the mirror") { self.hold(ref, host: FakeWire.relay2Host) }
        MediaBackupBackoff.recordLanded(ref)
    }

    func testAChunkedBlobIsMirroredWindowByWindowManifestLast() async throws {
        // 17 MB seals into three 8 MB windows plus a manifest.
        var big = Data(count: 17 * 1024 * 1024)
        big.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let ref = MediaStore.contentRef(.file, big)
        await strand(ref, big)
        XCTAssertFalse(wire.relayKeys(prefix: "haven/media/\(ref).p/").isEmpty, "the original upload was chunked")
        XCTAssertTrue(wire.relayKeys(prefix: "haven/media/\(ref)", host: FakeWire.relay2Host).isEmpty)

        let ok = await SharedStore.backup(ref: ref, circleId: "default", engine: try anyEngine())
        XCTAssertTrue(ok)
        let windows = wire.relayKeys(prefix: "haven/media/\(ref).p/")
        XCTAssertEqual(wire.relayKeys(prefix: "haven/media/\(ref).p/", host: FakeWire.relay2Host), windows, "every window was copied")
        XCTAssertEqual(wire.relayData("haven/media/\(ref)", host: FakeWire.relay2Host), wire.relayData("haven/media/\(ref)"), "…and the manifest")
        for k in windows { XCTAssertEqual(wire.relayData(k, host: FakeWire.relay2Host), wire.relayData(k)) }
        XCTAssertTrue(MediaBackupLedger.has(relayB, ref))
    }

    func testAChunkedBlobIsReassembledFromTheRelayBitForBit() async throws {
        var big = Data(count: 17 * 1024 * 1024)
        big.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let ref = MediaStore.contentRef(.file, big)
        await strand(ref, big)
        defer { MediaStore.shared.delete(ref) }
        XCTAssertFalse(MediaStore.shared.hasLocalFile(ref))
        FeedStore.shared.requestMedia(ref, circleId: "default")
        await until("the chunked blob is restored", timeout: 180) { MediaStore.shared.hasLocalFile(ref) }
        XCTAssertEqual(MediaStore.shared.rawBytes(ref), big, "…every window, in order")
        let windowGets = wire.requests(method: "GET", host: FakeWire.relayHost).filter { $0.path.contains(".p/") }.count
        XCTAssertGreaterThanOrEqual(windowGets, 3, "three 8 MB windows were fetched one at a time")
    }
}
