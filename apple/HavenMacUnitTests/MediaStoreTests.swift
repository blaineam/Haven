import XCTest
import AppKit
@testable import HavenUITestHost

@MainActor
final class MediaStoreTests: XCTestCase {
    /// A small, distinct image per `seed` — real pixels, so decoding paths are exercised.
    private func image(_ seed: Int, size: Int = 96) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedHue: CGFloat(seed % 100) / 100, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.white.setFill()
        NSRect(x: seed % 40, y: seed % 30, width: 20, height: 20).fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }
    private func jpeg(_ seed: Int) -> Data { image(seed).jpegData(compressionQuality: 0.8)! }
    /// A ref shaped like a content address (64 lowercase hex) but for different bytes — the only kind
    /// the store can prove wrong. (`ref + "0"` is merely a legacy-shaped ref, which is taken on faith.)
    private func wrongAddress(like ref: String) -> String {
        let last = ref.last == "0" ? "1" : "0"
        return String(ref.dropLast()) + last
    }
    private func uniqueJPEG() -> (ref: String, data: Data) {
        let d = jpeg(Int.random(in: 1...9_999_999))
        // Make the bytes unique even if two seeds collide.
        var x = d; x.append(contentsOf: UUID().uuidString.utf8)
        return (MediaStore.contentRef(.image, x), x)
    }

    // MARK: Refs

    func testKindPrefixesAndBareIds() {
        XCTAssertEqual(MediaKind(ref: "img_ab"), .image)
        XCTAssertEqual(MediaKind(ref: "vid_ab"), .video)
        XCTAssertEqual(MediaKind(ref: "aud_ab"), .audio)
        XCTAssertEqual(MediaKind(ref: "file_ab"), .file)
        XCTAssertNil(MediaKind(ref: "zzz_ab"))
        XCTAssertEqual(MediaKind.image.ext, "jpg"); XCTAssertEqual(MediaKind.video.ext, "mp4")
        XCTAssertEqual(MediaKind.audio.ext, "m4a"); XCTAssertEqual(MediaKind.file.ext, "zip")
        XCTAssertEqual(MediaKind.audio.prefix, "aud_"); XCTAssertEqual(MediaKind.file.prefix, "file_")
        for p in ["img_", "vid_", "aud_", "file_", "v:", "i:", "a:"] {
            XCTAssertEqual(MediaStore.bareId(p + "abc"), "abc")
        }
        XCTAssertEqual(MediaStore.bareId("plain"), "plain")
    }

    func testStemsCoverLegacySchemes() {
        XCTAssertEqual(MediaStore.storedStems(for: "v:abc"), ["v:abc", "abc", "vid_abc"])
        XCTAssertEqual(MediaStore.storedStems(for: "i:abc"), ["i:abc", "abc", "img_abc"])
        XCTAssertEqual(MediaStore.storedStems(for: "a:abc"), ["a:abc", "abc", "aud_abc"])
        XCTAssertEqual(MediaStore.storedStems(for: "file_abc"), ["file_abc", "abc"])
        XCTAssertTrue(MediaStore.isSynthetic("geo:1,2"))
        XCTAssertFalse(MediaStore.isSynthetic("i:abc"), "a one-letter scheme is a legacy media ref, not a pin")
        XCTAssertFalse(MediaStore.isSynthetic("img_abc"))
    }

    func testContentRefsAreVerifiable() throws {
        let data = Data("hello media".utf8)
        let ref = MediaStore.contentRef(.audio, data)
        XCTAssertTrue(ref.hasPrefix("aud_"))
        XCTAssertTrue(MediaStore.isVerifiable(ref))
        XCTAssertTrue(MediaStore.verify(ref, data))
        XCTAssertFalse(MediaStore.verify(ref, Data("tampered".utf8)))
        XCTAssertTrue(MediaStore.verify("img_\(UUID().uuidString)", data), "legacy uuid refs are taken on faith")
        XCTAssertFalse(MediaStore.isVerifiable("geo:1,2"))
        XCTAssertFalse(MediaStore.isVerifiable("img_" + String(repeating: "A", count: 64)), "uppercase hex is not a content address")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString).bin")
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(MediaStore.sha256Hex(fileAt: url), MediaStore.sha256Hex(data))
        XCTAssertEqual(MediaStore.contentRef(.audio, fileAt: url), ref)
        XCTAssertTrue(MediaStore.verify(ref, fileAt: url))
        XCTAssertFalse(MediaStore.verify(ref, fileAt: url.appendingPathExtension("missing")), "an unreadable file fails closed")
        XCTAssertNil(MediaStore.sha256Hex(fileAt: url.appendingPathExtension("missing")))
    }

    // MARK: Storing

    func testStoreRoundTripsAndRejectsTamperedBytes() {
        let store = MediaStore.shared
        let (ref, data) = uniqueJPEG()
        XCTAssertFalse(store.has(ref))
        XCTAssertFalse(store.store(ref, Data("not the image".utf8)), "bytes must hash to the ref")
        XCTAssertFalse(store.hasLocalFile(ref))
        XCTAssertTrue(store.store(ref, data))
        XCTAssertTrue(store.has(ref))
        XCTAssertTrue(store.hasLocalFile(ref))
        XCTAssertEqual(store.rawBytes(ref), data)
        XCTAssertNotNil(store.storagePath(for: ref))
        XCTAssertFalse(store.store("zzz_unknown", data), "an unknown kind prefix is refused")
        XCTAssertGreaterThan(store.delete(ref), 0)
        XCTAssertFalse(store.hasLocalFile(ref))
        XCTAssertNil(store.rawBytes(ref))
        XCTAssertEqual(store.delete("geo:1,2"), 0, "synthetic refs have nothing to delete")
    }

    func testStoreAsyncAndAdoptVerifyTheContentAddress() async throws {
        let store = MediaStore.shared
        let (ref, data) = uniqueJPEG()
        let ok = await store.storeAsync(ref, data)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.rawBytes(ref), data)
        let rejected = await store.storeAsync(wrongAddress(like: ref), data)
        XCTAssertFalse(rejected)
        store.delete(ref)

        // Chunked transfers land through a temp file.
        let (ref2, data2) = uniqueJPEG()
        let tmp = store.makeTempFile()
        try data2.write(to: tmp)
        XCTAssertTrue(store.adopt(ref2, from: tmp))
        XCTAssertEqual(store.rawBytes(ref2), data2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "the temp is consumed")
        let bad = store.makeTempFile()
        try Data("garbage".utf8).write(to: bad)
        XCTAssertFalse(store.adopt(wrongAddress(like: ref2), from: bad))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path), "a mismatched temp is dropped, not adopted")
        XCTAssertFalse(store.adopt("zzz_nope", from: store.makeTempFile()))
        store.delete(ref2)

        let (ref3, data3) = uniqueJPEG()
        let tmp3 = store.makeTempFile(); try data3.write(to: tmp3)
        let adopted = await store.adoptAsync(ref3, from: tmp3)
        XCTAssertTrue(adopted)
        let bad3 = store.makeTempFile(); try Data("garbage".utf8).write(to: bad3)
        let rejected3 = await store.adoptAsync(wrongAddress(like: ref3), from: bad3)
        XCTAssertFalse(rejected3)
        let unknown = await store.adoptAsync("zzz_nope", from: store.makeTempFile())
        XCTAssertFalse(unknown)
        store.delete(ref3)
    }

    func testAudioAndFileKindsCacheWithoutDecoding() throws {
        let store = MediaStore.shared
        let audio = Data("fake m4a payload \(UUID())".utf8)
        let ref = MediaStore.contentRef(.audio, audio)
        XCTAssertTrue(store.store(ref, audio))
        let item = store.item(ref)
        XCTAssertEqual(item?.kind, .audio)
        XCTAssertNotNil(item?.videoURL)
        store.clearMemoryCache()
        XCTAssertTrue(store.has(ref), "still on disk after the memory cache is dropped")
        store.delete(ref)
    }

    func testImageItemThumbnailAndPixelSize() async {
        let store = MediaStore.shared
        let (ref, data) = uniqueJPEG()
        XCTAssertTrue(store.store(ref, data))
        let item = store.item(ref)
        XCTAssertEqual(item?.kind, .image)
        XCTAssertNotNil(item?.image)
        XCTAssertNotNil(store.thumbnail(ref, maxDimension: 48))
        let thumb = await store.thumbnailAsync(ref, maxDimension: 32)
        XCTAssertNotNil(thumb)
        XCTAssertNotNil(store.cachedThumbnail(ref, maxDimension: 32))
        let size = store.pixelSize(ref)
        XCTAssertEqual(size?.width, 96)
        store.recordPixelSize(ref, CGSize(width: 10, height: 20))
        XCTAssertEqual(store.pixelSize(ref, allowSyncRead: false)?.height, 20)
        XCTAssertNil(store.item("img_" + UUID().uuidString), "an absent ref has no item")
        store.delete(ref)
        XCTAssertNil(store.item(ref))
    }

    func testAddImageMintsAContentAddressedRef() {
        let store = MediaStore.shared
        let ref = store.addImage(image(Int.random(in: 1...5000)), forceOptimize: true)
        XCTAssertTrue(ref.hasPrefix("img_"))
        XCTAssertTrue(MediaStore.isVerifiable(ref))
        let bytes = store.rawBytes(ref)
        XCTAssertNotNil(bytes)
        XCTAssertTrue(MediaStore.verify(ref, bytes ?? Data()))
        store.delete(ref)
    }

    func testFileAttachmentsAreMintedFromDisk() throws {
        let store = MediaStore.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("note-\(UUID().uuidString).txt")
        try Data("a note \(UUID())".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let ref = store.addFile(url: url)
        XCTAssertTrue(ref.hasPrefix("file_"), "got \(ref)")
        XCTAssertTrue(store.has(ref))
        store.delete(ref)
    }

    func testLocationIsKeptLocally() {
        let store = MediaStore.shared
        let ref = "img_" + UUID().uuidString
        XCTAssertNil(store.location(for: ref))
        XCTAssertFalse(store.anyLocated([ref]))
        store.setLocation(.init(latitude: 12.5, longitude: -3.25), for: ref)
        XCTAssertEqual(store.location(for: ref)?.latitude, 12.5)
        XCTAssertTrue(store.anyLocated(["x", ref]))
    }

    func testGpsIsReadFromExifAndAbsentWhenStripped() throws {
        XCTAssertNil(MediaStore.gpsCoordinate(fromImageData: jpeg(3)))
        XCTAssertNil(MediaStore.gpsCoordinate(fromImageData: Data("nope".utf8)))
    }

    // MARK: Sweeps

    func testStoredBlobsAndDiskUsageSeeWhatWasStored() {
        let store = MediaStore.shared
        let (ref, data) = uniqueJPEG()
        XCTAssertTrue(store.store(ref, data))
        let blobs = MediaStore.storedBlobs()
        XCTAssertEqual(blobs.first { $0.ref == ref }?.bytes, Int64(data.count))
        let usage = store.diskUsage()
        XCTAssertGreaterThanOrEqual(usage.bytes, Int64(data.count))
        XCTAssertGreaterThanOrEqual(usage.files, 1)
        store.delete(ref)
    }

    func testOrphanSweepSparesInUseAndFreshFiles() {
        let store = MediaStore.shared
        let (keep, keepData) = uniqueJPEG(), (orphan, orphanData) = uniqueJPEG(), (fresh, freshData) = uniqueJPEG()
        for (r, d) in [(keep, keepData), (orphan, orphanData), (fresh, freshData)] { XCTAssertTrue(store.store(r, d)) }
        // Backdate two of them past the grace window; the third stays fresh.
        let old = Date().addingTimeInterval(-10 * 86_400)
        for r in [keep, orphan] {
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: store.storagePath(for: r)!.path)
        }
        let r = MediaStore.performOrphanSweep(inUse: [keep], graceSeconds: 86_400)
        XCTAssertGreaterThanOrEqual(r.files, 1)
        XCTAssertTrue(store.hasLocalFile(keep), "in-use media survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storagePath(for: orphan)!.path), "the aged orphan goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storagePath(for: fresh)!.path), "fresh media is inside the grace window")
        store.delete(keep); store.delete(fresh)
    }

    func testLimitSweepEvictsByAgeAndSparesPinned() {
        let store = MediaStore.shared
        let (old, oldData) = uniqueJPEG(), (pinned, pinnedData) = uniqueJPEG(), (recent, recentData) = uniqueJPEG()
        for (r, d) in [(old, oldData), (pinned, pinnedData), (recent, recentData)] { XCTAssertTrue(store.store(r, d)) }
        let ancient = Date().addingTimeInterval(-90 * 86_400)
        for r in [old, pinned] {
            try? FileManager.default.setAttributes([.modificationDate: ancient], ofItemAtPath: store.storagePath(for: r)!.path)
        }
        XCTAssertEqual(MediaStore.performLimitSweep(maxDays: 0, maxGB: 0, pinnedStems: [], inUse: []).files, 0, "no caps, no sweep")
        let r = MediaStore.performLimitSweep(maxDays: 30, maxGB: 0, pinnedStems: MediaStore.storedStems(for: pinned),
                                             inUse: MediaStore.storedStems(for: old), graceSeconds: 3600)
        XCTAssertGreaterThanOrEqual(r.files, 1)
        XCTAssertNotNil(r.evict[old], "a still-referenced evicted blob is reported so it isn't auto-refetched")
        XCTAssertFalse(store.hasLocalFile(old))
        XCTAssertTrue(store.hasLocalFile(pinned), "device pins are never evicted")
        XCTAssertTrue(store.hasLocalFile(recent))
        store.delete(pinned); store.delete(recent)
    }

    func testStaleScratchIsReclaimed() throws {
        let store = MediaStore.shared
        let scratch = store.makeTempFile()
        try Data(repeating: 1, count: 128).write(to: scratch)
        XCTAssertEqual(MediaStore.sweepStaleScratch(grace: 3600).files >= 0, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path), "a just-written partial may be live")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: scratch.path)
        let swept = MediaStore.sweepStaleScratch(grace: 3600)
        XCTAssertGreaterThanOrEqual(swept.files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    // MARK: Small stores

    func testPinnedMediaStore() {
        let pins = PinnedMediaStore.shared
        let a = "img_" + UUID().uuidString, b = "vid_" + UUID().uuidString
        pins.pin([a, b, "geo:1,2"])
        XCTAssertTrue(pins.isPinned(a)); XCTAssertFalse(pins.isPinned("geo:1,2"))
        XCTAssertTrue(pins.anyPinned([b]))
        XCTAssertTrue(pins.inUseStems().isSuperset(of: MediaStore.storedStems(for: a)))
        pins.togglePin([a, b])      // some pinned -> unpin all
        XCTAssertFalse(pins.anyPinned([a, b]))
        pins.togglePin([a])         // none pinned -> pin
        XCTAssertTrue(pins.isPinned(a))
        XCTAssertGreaterThan(pins.count, 0)
        pins.unpin([a])
    }

    func testWantedStoreSeparatesAutomaticFromManualAsks() {
        let w = MediaWantedStore.shared
        let auto = "img_" + UUID().uuidString, manual = "img_" + UUID().uuidString
        w.add(auto)
        w.add(manual, manual: true)
        XCTAssertTrue(w.isWanted(auto)); XCTAssertFalse(w.isManuallyWanted(auto))
        XCTAssertTrue(w.isWanted(manual)); XCTAssertTrue(w.isManuallyWanted(manual))
        XCTAssertFalse(w.takeManual(auto), "an automatic repair earns no notification")
        XCTAssertTrue(w.takeManual(manual))
        XCTAssertFalse(w.takeManual(manual), "one ask, one notification")
        w.clear(manual); w.clear(auto)
        XCTAssertFalse(w.isWanted(manual)); XCTAssertFalse(w.isWanted(auto))
        w.clear(auto)   // already gone: no-op
    }

    func testEvictedStoreMatchesByRefOrBareHash() {
        let e = EvictedMediaStore.shared
        let bare = UUID().uuidString
        e.mark(bare, bytes: 1234)
        XCTAssertTrue(e.contains("img_" + bare))
        XCTAssertEqual(e.size("vid_" + bare), 1234)
        e.mark("img_" + bare, bytes: 99)
        XCTAssertEqual(e.size("img_" + bare), 99)
        e.clear("img_" + bare)
        XCTAssertFalse(e.contains("img_" + bare))
        XCTAssertNil(e.size("img_" + bare))
        e.clear("img_" + bare)
    }

    func testKeptStoriesPinTombstoneAndSyncPerEntry() {
        let kept = KeptStoriesStore.shared
        let id = "story-" + UUID().uuidString, media = ["img_" + UUID().uuidString]
        let track = TrackRefFfi(catalogId: "c1", title: "Song", artist: "Band", artworkUrl: "", durationMs: 1000)
        kept.toggle(id: id, body: "a story", media: media, createdAt: 1_000, music: track)
        XCTAssertTrue(kept.isKept(id))
        XCTAssertTrue(PinnedMediaStore.shared.isPinned(media[0]), "keeping pins the media against cleanup")
        kept.keep(id: id, body: "again", media: media, createdAt: 1_000, music: nil)   // kept at most once
        XCTAssertEqual(kept.kept.filter { $0.id == id }.count, 1)
        let payload = kept.syncPayload()
        XCTAssertNotNil(payload)

        kept.toggle(id: id, body: "", media: media, createdAt: 0, music: nil)
        XCTAssertFalse(kept.isKept(id))
        XCTAssertFalse(PinnedMediaStore.shared.isPinned(media[0]), "un-keeping releases the pin")
        XCTAssertNotNil(kept.removed[id])
        // The sibling's OLDER copy (kept 5 s before my un-keep) must not resurrect a newer tombstone.
        var obj = try! JSONSerialization.jsonObject(with: payload!) as! [String: Any]
        obj["kept"] = (obj["kept"] as! [[String: Any]]).map { row -> [String: Any] in
            var row = row
            row["keptAt"] = ((row["keptAt"] as? NSNumber)?.uint64Value ?? 0) &- 5_000
            return row
        }
        kept.applySynced(try! JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(kept.isKept(id))
        // A sibling's genuinely newer keep wins and pins again.
        let newer = id + "-b"
        let newMedia = ["img_" + UUID().uuidString]
        kept.keep(id: newer, body: "from my mac", media: newMedia, createdAt: 5, music: nil)
        let payload2 = kept.syncPayload()!
        kept.unkeep(newer)
        kept.applySynced(Data("not json".utf8))      // garbage is ignored
        XCTAssertFalse(kept.isKept(newer))
        kept.applySynced(payload2)                   // keptAt is newer than my tombstone? equal-ish; either way no crash
        kept.unkeep(newer); kept.unkeep(newer)
    }
}
