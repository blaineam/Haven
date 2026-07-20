import XCTest
@testable import HavenLogicTests

/// The resume decision for a chunked media upload, tested on its own — no app, no FFI, no network.
///
/// The tests that matter here are the ones that would have PASSED a window through under the old
/// behaviour, where "the destination says it holds window i" was the whole decision. Splicing windows
/// from two different seals yields a blob of exactly the right length that decrypts to nothing, and
/// the key is content-addressed and write-once, so it is permanent. Read `MediaUploadPlan`'s header
/// before changing any expectation below.
final class MediaUploadPlanTests: XCTestCase {

    /// Every window probes present — which is exactly what a destination looks like after ANOTHER
    /// DEVICE OF THE SAME ACCOUNT uploaded this ref from its own seal. Under the old probe-only rule
    /// this skipped all 75 windows and wrote a manifest over someone else's envelope. We have no
    /// record of writing those bytes, so nothing may be skipped.
    func testAnotherDevicesUploadIsNeverResumedAcross() async {
        var probes = 0
        let skip = await MediaUploadPlan.resumeSkip(
            force: false, recorded: nil, currentFp: MediaUploadPlan.sealFingerprint(Data("ours".utf8)),
            total: 75, probe: { _ in probes += 1; return true })
        XCTAssertEqual(skip, 0, "a ref we never uploaded here must be re-sent whole, however present it probes")
        XCTAssertEqual(probes, 0, "with nothing to trust the probe must not even be consulted")
    }

    /// The same-length re-seal: identical plaintext, identical recipients, a fresh nonce. The bytes
    /// differ, the length does not — so nothing downstream can catch it, and the probe says yes to
    /// every window the previous seal left behind.
    func testASameLengthResealIsNeverResumedAcross() async {
        var first = Data(repeating: 7, count: 1024)
        var resealed = first
        resealed[0] = 9
        XCTAssertEqual(first.count, resealed.count)
        let a = MediaUploadPlan.sealFingerprint(first)
        let b = MediaUploadPlan.sealFingerprint(resealed)
        XCTAssertNotEqual(a, b, "a same-length re-seal must not fingerprint the same")
        first[0] = 7   // silence the unused-mutation warning; the point is the two buffers differ

        let skip = await MediaUploadPlan.resumeSkip(
            force: false, recorded: (fp: a, windows: 40), currentFp: b, total: 75, probe: { _ in true })
        XCTAssertEqual(skip, 0, "40 windows of the OLD seal are on the relay; none of them are ours now")
    }

    /// The seal replaced part-way through: we recorded 40 windows under fingerprint `a`, then the
    /// upload restarted from bytes `b`. The destination holds a mix and every window probes present.
    func testAMidUploadResealDoesNotSpliceTheTail() async {
        let a = MediaUploadPlan.sealFingerprint(Data("seal-one".utf8))
        let b = MediaUploadPlan.sealFingerprint(Data("seal-two".utf8))
        XCTAssertEqual(MediaUploadPlan.trustedPrefix(force: false, recordedFp: a, currentFp: b,
                                                     recordedWindows: 40, total: 75), 0)
    }

    /// The point of the whole exercise: windows we wrote from these exact bytes, and that are still
    /// there, ARE skipped — otherwise a large upload never converges.
    func testOurOwnWindowsFromTheseBytesAreSkipped() async {
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        let skip = await MediaUploadPlan.resumeSkip(
            force: false, recorded: (fp: fp, windows: 20), currentFp: fp, total: 75, probe: { _ in true })
        XCTAssertEqual(skip, 20)
    }

    /// The probe is the second half: a relay may have swept the chunks since we wrote them, so a
    /// recorded high-water mark alone never authorises a skip.
    func testASweptChunkStopsTheSkipAtTheGap() async {
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        let skip = await MediaUploadPlan.resumeSkip(
            force: false, recorded: (fp: fp, windows: 20), currentFp: fp, total: 75,
            probe: { i in i < 5 })
        XCTAssertEqual(skip, 5, "the run stops at the first window the destination no longer holds")
    }

    /// A probe stops at the first miss, so with a 20-window trust it costs at most 6 calls to find a
    /// 5-window prefix — never a probe per window. That is what keeps this affordable where the only
    /// existence check is a full GET.
    func testTheProbeStopsAtTheFirstMiss() async {
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        var probes = 0
        _ = await MediaUploadPlan.resumeSkip(
            force: false, recorded: (fp: fp, windows: 20), currentFp: fp, total: 75,
            probe: { i in probes += 1; return i < 5 })
        XCTAssertEqual(probes, 6)
    }

    /// `force` is the repair path (`backup(force: true)` when we hold the plaintext for a blob that
    /// is present-but-unopenable). Its whole purpose is to OVERWRITE what the destination holds, so
    /// resuming against the bad copy's windows would leave exactly the bytes we came to replace —
    /// repairing nothing while reporting success.
    func testTheRepairOverwriteNeverResumes() async {
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        let skip = await MediaUploadPlan.resumeSkip(
            force: true, recorded: (fp: fp, windows: 40), currentFp: fp, total: 75, probe: { _ in true })
        XCTAssertEqual(skip, 0, "a forced repair must re-send every window, including ones it 'already has'")
    }

    /// A record left over from a LARGER earlier blob must not authorise skipping past the end.
    func testTrustNeverExceedsTheWindowsThatExist() {
        let fp = MediaUploadPlan.sealFingerprint(Data("x".utf8))
        XCTAssertEqual(MediaUploadPlan.trustedPrefix(force: false, recordedFp: fp, currentFp: fp,
                                                     recordedWindows: 900, total: 3), 3)
    }

    /// No fingerprint (we could not hash the seal) means no provenance, so no skipping.
    func testAnUnknownFingerprintTrustsNothing() {
        XCTAssertEqual(MediaUploadPlan.trustedPrefix(force: false, recordedFp: "", currentFp: "",
                                                     recordedWindows: 40, total: 75), 0)
    }

    /// Progress is a prefix by construction. A hole means that did not hold, so re-send from the hole
    /// — skipping past it would leave a window nothing ever writes.
    func testAGapStopsTheSkipRatherThanJumpingIt() {
        XCTAssertEqual(MediaUploadPlan.skipCount(probed: [true, true, false, true, true]), 2)
        XCTAssertEqual(MediaUploadPlan.skipCount(probed: []), 0)
        XCTAssertEqual(MediaUploadPlan.skipCount(probed: [false]), 0)
    }

    // ---- Window geometry (must match Android/desktop byte for byte) -----------------------------

    func testWindowsCoverTheBlobExactlyWithAShortTail() {
        let c = MediaUploadPlan.chunkBytes
        let size = c * 3 + 12_345
        let w = MediaUploadPlan.windows(size: size)
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w[0].0, 0)
        XCTAssertEqual(w[3].1, size)
        XCTAssertEqual(w[3].1 - w[3].0, 12_345)
        for i in 1..<w.count { XCTAssertEqual(w[i - 1].1, w[i].0, "a gap or overlap here is a corrupt blob") }
    }

    func testAnExactMultipleProducesNoEmptyTrailingWindow() {
        XCTAssertEqual(MediaUploadPlan.windows(size: MediaUploadPlan.chunkBytes * 2).count, 2)
        XCTAssertEqual(MediaUploadPlan.windows(size: 0).count, 0)
    }

    func testTheChunkSizeMatchesTheOtherPlatforms() {
        // MediaUploadPlan.kt CHUNK_BYTES and mediaresume.rs UPLOAD_CHUNK_BYTES. A divergence here
        // means the three platforms slice the same sealed blob into different chunk keys.
        XCTAssertEqual(MediaUploadPlan.chunkBytes, 8 * 1024 * 1024)
    }

    // ---- The persisted high-water record ---------------------------------------------------------

    /// The interruption this exists for is the app being killed, so the record has to survive one.
    func testTheHighWaterMarkSurvivesARelaunch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-resume-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        MediaUploadResume.resetForTesting(storeURL: url)
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        MediaUploadResume.record(dest: "relay-a", ref: "v:img_1", fp: fp, windows: 20)
        MediaUploadResume.record(dest: "relay-b", ref: "v:img_1", fp: fp, windows: 3)

        // Simulated relaunch: drop everything in memory and read it back off the file.
        MediaUploadResume.resetForTesting(storeURL: url)
        let a = MediaUploadResume.progress(dest: "relay-a", ref: "v:img_1")
        XCTAssertEqual(a?.fp, fp)
        XCTAssertEqual(a?.windows, 20)
        // Progress is PER DESTINATION — one relay being 20 windows in says nothing about another.
        XCTAssertEqual(MediaUploadResume.progress(dest: "relay-b", ref: "v:img_1")?.windows, 3)
        XCTAssertNil(MediaUploadResume.progress(dest: "relay-c", ref: "v:img_1"))
    }

    /// A ref may contain ':' (`v:`/`dm:`), which is why the line format is tab-separated. A record
    /// that came back mangled would be a high-water mark for the wrong bytes.
    func testAColonBearingRefRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-resume-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        MediaUploadResume.resetForTesting(storeURL: url)
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        MediaUploadResume.record(dest: "relay-a", ref: "dm:aaa-bbb:img_9", fp: fp, windows: 7)
        MediaUploadResume.resetForTesting(storeURL: url)
        XCTAssertEqual(MediaUploadResume.progress(dest: "relay-a", ref: "dm:aaa-bbb:img_9")?.windows, 7)
    }

    /// The manifest write is the moment the upload is done; nothing is left to resume.
    func testAFinishedUploadDropsItsRecord() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-resume-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        MediaUploadResume.resetForTesting(storeURL: url)
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        MediaUploadResume.record(dest: "relay-a", ref: "img_1", fp: fp, windows: 9)
        MediaUploadResume.clear(dest: "relay-a", ref: "img_1")
        MediaUploadResume.resetForTesting(storeURL: url)
        XCTAssertNil(MediaUploadResume.progress(dest: "relay-a", ref: "img_1"))
    }

    /// A corrupt or hand-edited line is dropped, not guessed at — a half-parsed high-water mark is
    /// exactly the kind of "yes" this whole module exists to refuse.
    func testACorruptLineIsDroppedNotGuessedAt() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-resume-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        try? [
            "relay-a\timg_bad\t\(fp)\tnot-a-number",
            "relay-a\timg_bad2\t\(fp)",
            "\timg_bad3\t\(fp)\t4",
            "relay-a\timg_good\t\(fp)\t4",
        ].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        MediaUploadResume.resetForTesting(storeURL: url)
        XCTAssertNil(MediaUploadResume.progress(dest: "relay-a", ref: "img_bad"))
        XCTAssertNil(MediaUploadResume.progress(dest: "relay-a", ref: "img_bad2"))
        XCTAssertNil(MediaUploadResume.progress(dest: "relay-a", ref: "img_bad3"))
        XCTAssertEqual(MediaUploadResume.progress(dest: "relay-a", ref: "img_good")?.windows, 4)
    }

    /// Bounded, like every other durable record here — a device that starts thousands of uploads it
    /// never finishes must not grow this without limit. Eviction costs a re-upload, never correctness.
    func testTheRecordIsBounded() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-resume-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        MediaUploadResume.resetForTesting(storeURL: url)
        let fp = MediaUploadPlan.sealFingerprint(Data("sealed".utf8))
        for i in 0..<(MediaUploadResume.maxRecords + 50) {
            MediaUploadResume.record(dest: "relay-a", ref: "img_\(i)", fp: fp, windows: 1)
        }
        MediaUploadResume.resetForTesting(storeURL: url)
        // The most recent write always survives; the cap is what matters, not which victim went.
        XCTAssertEqual(MediaUploadResume.progress(
            dest: "relay-a", ref: "img_\(MediaUploadResume.maxRecords + 49)")?.windows, 1)
        var kept = 0
        for i in 0..<(MediaUploadResume.maxRecords + 50) where
            MediaUploadResume.progress(dest: "relay-a", ref: "img_\(i)") != nil { kept += 1 }
        XCTAssertLessThanOrEqual(kept, MediaUploadResume.maxRecords)
    }

    /// The fingerprint of a file on disk must equal the fingerprint of the same bytes in memory —
    /// the upload hashes the sealed FILE (a 600 MB envelope never lands on the managed heap), while
    /// everything reasoning about it uses the in-memory form.
    func testTheStreamedFileFingerprintMatchesTheInMemoryOne() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-seal-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // Larger than the 4 MB read block, so the streaming loop actually iterates.
        var blob = Data(repeating: 0xAB, count: 9 * 1024 * 1024)
        blob[blob.count - 1] = 0x01
        try? blob.write(to: url)
        XCTAssertEqual(MediaUploadPlan.sealFingerprint(fileURL: url), MediaUploadPlan.sealFingerprint(blob))
    }
}
