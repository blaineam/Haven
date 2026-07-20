import Foundation
import CryptoKit

/// Which 8 MB windows of a chunked media upload still have to cross the wire — and, just as
/// important, when skipping a window is SAFE.
///
/// The Apple half of a rule all three platforms now share; the Android original is
/// `core/MediaUploadPlan.kt` and the desktop one is `desktop/src-tauri/src/mediaresume.rs`
/// (the upload half, below the download index). The names match on purpose: `trustedPrefix`,
/// `skipCount`, `sealFingerprint`. If you change the rule here, change it in all three.
///
/// ---- Why resume at all ------------------------------------------------------------------------
///
/// A large sealed video rides as 8 MB windows written IN ORDER to `haven/media/<ref>.p/<i>`, followed
/// by an `HVCHUNK1` manifest at `haven/media/<ref>`. The uploader used to re-send every window from 0
/// on each attempt, and on a phone leaving the app IS an interruption: a 600 MB video (≈75 windows)
/// would push maybe 20, get suspended, and start again at window 0 next time. It never converges — the
/// blob is simply larger than one uninterrupted session can push, and no amount of retrying fixes that
/// when every retry throws the progress away.
///
/// ---- Why the probe is a PREFIX scan -----------------------------------------------------------
///
/// Windows are written strictly in order and the loop stops at the first failure, so a destination's
/// progress is always a PREFIX — never a hole in the middle. Probing sequentially and stopping at the
/// first miss costs exactly (skipped + 1) probes, i.e. ONE when there is no prior progress. That is
/// what keeps it affordable on destinations (S3, a relay's HTTP interface) whose only existence check
/// is a full GET — the previous code probed EVERY window, so a 75-window video cost 75 full-blob GETs.
///
/// ---- Why a probe is NOT enough: the silent-corruption trap -------------------------------------
///
/// This is the correctness half, and it is not optional. Sealing is NOT byte-stable: the envelope
/// carries per-recipient key material (so its length moves as device rosters arrive) AND a fresh nonce
/// — so for an IDENTICAL recipient set the bytes differ while the length matches EXACTLY.
///
/// Splice windows from one seal onto windows from another and the blob reassembles to precisely the
/// right length and decrypts to nothing. The equal-length case is the COMMON one, so it corrupts
/// SILENTLY, presents as "this one photo never loads", and — the key being content-addressed and
/// write-once — is then frozen in place. One such blob is already in the field.
///
/// Keeping `.seal-<ref>.tmp` across retries (so OUR retries reuse identical bytes) is necessary but
/// NOT sufficient. Asking a destination "do you hold window i?" cannot distinguish "present" from
/// "present AND sliced from these bytes", and there are two ordinary ways to get a YES that must not
/// be trusted:
///
///  * the seal was replaced PART-WAY through an upload. The destination now holds a mix: the leading
///    windows this attempt rewrote, and a tail left over from the old seal. Every one probes present.
///  * ANOTHER DEVICE OF THE SAME ACCOUNT uploaded the same ref. Same plaintext → same ref → an
///    entirely different seal. Own-device media sync makes this routine, not a corner case.
///
/// So a window is skipped only when WE wrote it, from THESE bytes: ``trustedPrefix`` caps the skip at
/// the high-water mark recorded for that destination under this exact fingerprint, and the probe then
/// confirms the bytes are still there (a relay may have swept them). Both must agree. The asymmetry is
/// the whole point — a cap that is too LOW costs a re-upload of bytes that were fine, while one that is
/// too HIGH is permanent corruption. When in doubt, re-send.
enum MediaUploadPlan {

    /// 8 MB — well under the relay's 256 MB MAX_BLOB, and identical on Android/desktop so the three
    /// platforms slice the same sealed blob into the same chunk keys.
    static let chunkBytes = 8 * 1024 * 1024

    /// Byte ranges of each window over a blob of `size` bytes: `(from, toExclusive)`, in wire order.
    static func windows(size: Int, chunkBytes: Int = MediaUploadPlan.chunkBytes) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var off = 0
        while off < size {
            let end = min(off + chunkBytes, size)
            out.append((off, end))
            off = end
        }
        return out
    }

    /// Identity of the exact sealed bytes an upload is made of, streamed so a 600 MB envelope never
    /// lands on the managed heap (holding one whole is what traps the allocator — see `putMediaFile`).
    /// Hashing a few hundred MB costs about a second: trivial next to the tens of windows of network
    /// this decision gates, and it runs only when a reachable destination actually needs the blob.
    static func sealFingerprint(fileURL: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            guard let block = (try? fh.read(upToCount: 4 * 1024 * 1024)) ?? nil, !block.isEmpty else { break }
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint of bytes already in memory — the small-blob and test path.
    static func sealFingerprint(_ blob: Data) -> String {
        SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    /// How many leading windows this destination may be ASKED about — the count we ourselves wrote to
    /// it from these exact sealed bytes, and nothing beyond. Windows past this point may well be
    /// present; they are simply not provably ours (see the two YES-you-must-not-trust cases above).
    ///
    /// `force` is the recovery path, whose whole purpose is to OVERWRITE what is stored, so it trusts
    /// nothing — skipping windows the destination already has would leave in place exactly the bytes
    /// we came to replace, repairing nothing. A destination with no record for this ref (first attempt,
    /// another device's upload, or an eviction from the bounded record) also trusts nothing and
    /// re-sends everything: the safe direction, and the only one that is safe.
    static func trustedPrefix(force: Bool, recordedFp: String?, currentFp: String,
                              recordedWindows: Int, total: Int) -> Int {
        if force || currentFp.isEmpty { return 0 }
        guard let recordedFp, recordedFp == currentFp else { return 0 }
        return max(0, min(recordedWindows, total))
    }

    /// Index of the first window that still has to be sent, given the probe answers gathered so far.
    /// Anything after the first miss is ignored even if it is `true`: a gap means the "progress is a
    /// prefix" invariant did not hold, and re-sending is the safe reading of that.
    static func skipCount(probed: [Bool]) -> Int {
        var n = 0
        while n < probed.count && probed[n] { n += 1 }
        return n
    }

    /// How many leading windows to SKIP for one destination: the ones we ourselves wrote there from
    /// these exact sealed bytes (``trustedPrefix``) AND that it still holds (the probe, which may find
    /// a relay has swept them). Both must agree.
    ///
    /// A probe that THROWS or times out counts as a MISS — an unreachable destination must re-send,
    /// never skip. The probe is never even consulted when the trusted prefix is 0, which is what makes
    /// the common path cost nothing and the two untrustworthy-YES cases impossible to act on.
    static func resumeSkip(force: Bool, recorded: (fp: String, windows: Int)?, currentFp: String,
                           total: Int, probe: (Int) async -> Bool) async -> Int {
        let trusted = trustedPrefix(force: force, recordedFp: recorded?.fp, currentFp: currentFp,
                                    recordedWindows: recorded?.windows ?? 0, total: total)
        if trusted == 0 { return 0 }
        var probed: [Bool] = []
        for i in 0..<trusted {
            let held = await probe(i)
            probed.append(held)
            if !held { break }
        }
        return skipCount(probed: probed)
    }
}

/// How far a chunked upload of a ref got on ONE destination, and from WHICH sealed bytes.
///
/// Per DESTINATION, not per ref, because progress is per destination — and the fingerprint travels
/// with it because windows written from a different seal must never be counted (see
/// ``MediaUploadPlan``). PERSISTED, because the interruption this exists for is the app being
/// suspended or killed; an in-memory record would be empty exactly when the decision gets made.
///
/// Written after each window, which is nothing beside the 8 MB PUT it follows. Losing the last write
/// or two to a kill is harmless in the only direction that matters: it UNDERSTATES progress, costing a
/// re-sent window, and can never overstate it.
enum MediaUploadResume {

    /// Bounded like every other durable record here. Eviction only costs a full re-upload of a
    /// long-idle ref (the safe direction — see ``MediaUploadPlan``), never correctness.
    static let maxRecords = 2_000

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var records: [String: String] = [:]   // "<dest>|<ref>" -> "<fp>:<windows>"
    /// Overridable so tests get their own file instead of the app's.
    nonisolated(unsafe) static var storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-media-upload-resume.txt")
    }()

    private static func recordKey(_ dest: String, _ ref: String) -> String { "\(dest)|\(ref)" }

    private static func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let text = try? String(contentsOf: storeURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            // `<dest>\t<ref>\t<fp>\t<windows>` — tab-separated because a ref may contain ':' but
            // never a tab or a newline. A line that doesn't parse is dropped, not guessed at.
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 4, let n = Int(f[3]), n >= 0, !f[0].isEmpty, !f[1].isEmpty, !f[2].isEmpty
            else { continue }
            records[recordKey(String(f[0]), String(f[1]))] = "\(f[2]):\(n)"
        }
    }

    private static func saveLocked() {
        let body = records.compactMap { (k, v) -> String? in
            guard let bar = k.lastIndex(of: "|"), let colon = v.lastIndex(of: ":") else { return nil }
            return "\(k[k.startIndex..<bar])\t\(k[k.index(after: bar)...])\t\(v[v.startIndex..<colon])\t\(v[v.index(after: colon)...])"
        }.joined(separator: "\n")
        try? body.write(to: storeURL, atomically: true, encoding: .utf8)
    }

    /// The `(fingerprint, windows)` this destination was last given for `ref`, or nil if we have no
    /// record — in which case nothing may be skipped.
    static func progress(dest: String, ref: String) -> (fp: String, windows: Int)? {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        guard let v = records[recordKey(dest, ref)], let colon = v.lastIndex(of: ":"),
              let n = Int(v[v.index(after: colon)...]) else { return nil }
        return (String(v[v.startIndex..<colon]), n)
    }

    /// Record that `windows` leading windows of `ref`, sealed to `fp`, are on `dest`.
    static func record(dest: String, ref: String, fp: String, windows: Int) {
        guard !fp.isEmpty, !dest.isEmpty, !ref.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        let k = recordKey(dest, ref)
        let v = "\(fp):\(windows)"
        if records[k] == v { return }
        records[k] = v
        while records.count > maxRecords, let victim = records.keys.first(where: { $0 != k }) {
            records.removeValue(forKey: victim)
        }
        saveLocked()
    }

    /// A finished upload needs no resume record; drop it rather than let it age out of the cap.
    static func clear(dest: String, ref: String) {
        lock.lock(); defer { lock.unlock() }
        loadLocked()
        guard records.removeValue(forKey: recordKey(dest, ref)) != nil else { return }
        saveLocked()
    }

    /// Test seam: forget everything in memory so the next read comes off `storeURL`.
    static func resetForTesting(storeURL url: URL) {
        lock.lock(); defer { lock.unlock() }
        storeURL = url
        records = [:]
        loaded = false
    }
}
