import XCTest
import AppKit
@testable import HavenUITestHost

/// The held-media sweep: of the files this device holds for posts in its circles, which are the
/// plaintext their address names, which are a seal left at rest, which are damaged — and what the
/// store does about each.
@MainActor
final class FeedStoreHeldMediaTests: XCTestCase {
    private func jpeg(_ tag: String) -> (ref: String, data: Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 30, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        var d = rep.representation(using: .jpeg, properties: [:])!
        d.append(contentsOf: (tag + UUID().uuidString).utf8)
        return (MediaStore.contentRef(.image, d), d)
    }
    /// Put `bytes` where the store looks for `ref` WITHOUT the store's own address check — the way a
    /// damaged or half-migrated file ends up on disk.
    private func plant(_ ref: String, _ bytes: Data) throws {
        let url = try XCTUnwrap(MediaStore.shared.storagePath(for: ref))
        try bytes.write(to: url)
        HeldMediaIndex.shared.insert(url.lastPathComponent)
    }

    func testTheSweepKeepsGoodFilesRepairsSealedOnesAndDropsDamagedOnes() async throws {
        let store = await Harness.feed()
        store.setActiveCircle("default")
        let ann = Peer(byte: 0x3E, name: "Ann")
        await ann.befriend(store)

        let good = jpeg("good"), sealedAtRest = jpeg("sealed"), damaged = jpeg("damaged"), locked = jpeg("locked")
        try plant(good.ref, good.data)
        try plant(sealedAtRest.ref, try ann.engine.sealCircleMedia(circleId: "default", data: sealedAtRest.data))
        try plant(damaged.ref, Data("not the bytes this address names".utf8))
        // Sealed to a circle I am not in: an envelope, but one I can never open — the author must re-seal.
        ann.engine.createCircle(id: "ann-private", name: "private")
        try plant(locked.ref, try ann.engine.sealCircleMedia(circleId: "ann-private", data: locked.data))
        defer { for r in [good.ref, sealedAtRest.ref, damaged.ref, locked.ref] { MediaStore.shared.delete(r) } }

        let body = "held media \(UUID().uuidString.prefix(6))"
        await ann.post(body, into: store, media: [good.ref, sealedAtRest.ref, damaged.ref, locked.ref])
        await Harness.until(store, "ann's post is in the feed") { store.items.contains { !$0.isMe && $0.body == body } }

        store.verifyHeldMedia(limit: 10)
        await Harness.until(store, timeout: 60, "the damaged copy is dropped to be re-fetched") { !MediaStore.shared.has(damaged.ref) }
        await Harness.until(store, timeout: 60, "the sealed-at-rest copy is replaced by its plaintext") {
            MediaStore.shared.rawBytes(sealedAtRest.ref) == sealedAtRest.data
        }
        XCTAssertEqual(MediaStore.shared.rawBytes(good.ref), good.data, "a file that is what its address says is left alone")
        XCTAssertTrue(MediaStore.shared.has(locked.ref), "an unopenable seal is kept: the author is asked to re-seal, nothing is thrown away")

        // Once per ref per launch: a second pass finds nothing new to probe.
        let heldBefore = MediaStore.shared.rawBytes(good.ref)
        store.verifyHeldMedia(limit: 10)
        XCTAssertEqual(MediaStore.shared.rawBytes(good.ref), heldBefore)
    }
}
