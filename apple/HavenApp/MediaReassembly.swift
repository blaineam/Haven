import Foundation

/// Durable record of a half-finished chunked media transfer, so a 99%-complete download survives
/// the app being backgrounded, killed, or relaunched instead of restarting from chunk 0.
///
/// A serve is slow by construction (32 KB chunks, a seal each, 12 ms apart — a 200 MB video takes
/// over a minute), so interruptions are the norm, not the exception. Before this, every one of them
/// threw the whole transfer away: `incoming` lived only in memory and the launch scratch sweep
/// deleted the partial file. That is why large media "never loaded" — it wasn't failing once, it was
/// restarting forever.
///
/// The receive path was already most of the way here: chunk N's plaintext is written POSITIONALLY at
/// offset N × chunkSize, so the partial is a valid sparse file with holes in exactly the right
/// places. All that was missing was remembering, across launches, WHICH holes.
struct ReassemblyRecord: Codable {
    let ref: String
    /// The part file's NAME, not its path: the iOS container path changes between launches, so an
    /// absolute URL persisted today doesn't resolve tomorrow. Rejoined with `MediaStore.storageDir`.
    let part: String
    let total: Int
    /// Bit i set = chunk i is on disk. 1,600 chunks is 200 bytes — cheap to keep and cheap to send.
    var got: Data
    /// Epoch seconds of the last chunk written. Drives the 24h abandonment expiry.
    var updated: Double
}

/// The persisted set of in-progress reassemblies, keyed by ref.
///
/// Mutated only from the main actor (the receive bookkeeping in `finishChunk` is already there).
/// `liveParts()` is deliberately `nonisolated` so the launch scratch sweep — which runs detached and
/// off-main — can ask which partials to spare without hopping actors.
final class ReassemblyStore {
    static let shared = ReassemblyStore()
    private static let key = "haven.mediaReassembly"
    /// Abandoned partials expire rather than accumulating: a transfer nobody has fed in a day is
    /// one whose sender is gone, and its bytes are just unaccountable disk.
    static let expiry: TimeInterval = 24 * 3600

    private var records: [String: ReassemblyRecord]
    /// The bitmap is rewritten as chunks land — at ~83 chunks/second, saving on every one would be
    /// pure write churn. Debounced instead. Persisted progress may therefore LAG the file by up to
    /// `saveInterval`, which is safe in exactly one direction: understating what we have costs a few
    /// re-sent chunks (a positional rewrite of identical bytes), while overstating it would leave a
    /// permanent hole. Never record a chunk before its bytes are on disk.
    private var lastSaveAt: Date = .distantPast
    private static let saveInterval: TimeInterval = 2

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([String: ReassemblyRecord].self, from: d) {
            records = list
        } else {
            records = [:]
        }
    }

    // MARK: - Bitmap

    static func bitmap(_ got: Set<Int>, total: Int) -> Data {
        var bits = [UInt8](repeating: 0, count: (max(0, total) + 7) / 8)
        for i in got where i >= 0 && i < total { bits[i / 8] |= UInt8(1 << (i % 8)) }
        return Data(bits)
    }

    static func indices(_ bitmap: Data, total: Int) -> Set<Int> {
        var out = Set<Int>()
        let bytes = [UInt8](bitmap)
        for i in 0..<max(0, total) where i / 8 < bytes.count {
            if bytes[i / 8] & UInt8(1 << (i % 8)) != 0 { out.insert(i) }
        }
        return out
    }

    // MARK: - Frame 33 wire format

    /// `[requesterHex 64][u16 refLen][ref][u32 total][bitmap]`, all little-endian to match `chunkFrame`.
    ///
    /// Frame 3 stays exactly as it was for a first request — its ref is the unlengthed remainder, so
    /// there is nowhere to put a bitmap without breaking every parser in the field, and a first request
    /// has none to send. This is the RE-request that carries one. Codec lives here, next to the bitmap
    /// it wraps, so both ends of the wire are one testable pair rather than two hand-matched halves.
    static func encodeResume(myHex: String, ref: String, total: Int, got: Set<Int>) -> Data {
        var p = Data(myHex.utf8)
        let refData = Data(ref.utf8)
        let rl = UInt16(refData.count)
        p.append(UInt8(rl & 0xff)); p.append(UInt8(rl >> 8))
        p.append(refData)
        let t = UInt32(total)
        p.append(UInt8(t & 0xff)); p.append(UInt8((t >> 8) & 0xff))
        p.append(UInt8((t >> 16) & 0xff)); p.append(UInt8((t >> 24) & 0xff))
        p.append(bitmap(got, total: total))
        return p
    }

    /// Returns nil for anything malformed. Every bound here is a bound on what a PEER can make us
    /// allocate: the declared total must be plausible (4M chunks ≈ 128 GB, far past any real media)
    /// and the bitmap must be exactly the size that total implies.
    static func decodeResume(_ payload: Data) -> (requesterHex: String, ref: String, total: Int, got: Set<Int>)? {
        guard payload.count >= 64 + 2 else { return nil }
        let requesterHex = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        var off = 64
        let lb = [UInt8](payload.subdata(in: off..<(off + 2))); off += 2
        let refLen = Int(UInt16(lb[0]) | UInt16(lb[1]) << 8)
        guard payload.count >= off + refLen + 4 else { return nil }
        let ref = String(data: payload.subdata(in: off..<(off + refLen)), encoding: .utf8) ?? ""
        off += refLen
        let s = payload.startIndex + off
        let total = Int(UInt32(payload[s]) | UInt32(payload[s + 1]) << 8
                        | UInt32(payload[s + 2]) << 16 | UInt32(payload[s + 3]) << 24)
        off += 4
        let bits = payload.subdata(in: off..<payload.count)
        guard requesterHex.count == 64, !ref.isEmpty,
              total > 0, total <= 4_000_000, bits.count == (total + 7) / 8 else { return nil }
        return (requesterHex, ref, total, indices(bits, total: total))
    }

    // MARK: - Records

    @MainActor func record(_ ref: String) -> ReassemblyRecord? { records[ref] }

    /// Register a transfer that just started, or refresh one that's making progress.
    @MainActor func note(ref: String, part: String, total: Int, got: Set<Int>, force: Bool = false) {
        records[ref] = ReassemblyRecord(ref: ref, part: part, total: total,
                                        got: Self.bitmap(got, total: total),
                                        updated: Date().timeIntervalSince1970)
        // Bound the index itself — a peer that starts thousands of transfers we never finish must not
        // grow this without limit. Oldest progress goes first.
        if records.count > 512 {
            let doomed = records.values.sorted { $0.updated < $1.updated }.prefix(records.count - 512)
            for r in doomed { records[r.ref] = nil }
        }
        if force || Date().timeIntervalSince(lastSaveAt) > Self.saveInterval { save() }
    }

    /// Forget a transfer — completed, or its partial rejected — and flush immediately, so a relaunch
    /// never resurrects a reassembly whose bytes are already adopted (or already thrown away).
    @MainActor func clear(_ ref: String) {
        guard records[ref] != nil else { return }
        records[ref] = nil
        save()
    }

    /// Reload the persisted transfers that still have their part file on disk and haven't been
    /// abandoned. Anything whose part vanished is dropped — the bitmap without the bytes is a lie.
    @MainActor func restore() -> [ReassemblyRecord] {
        let cutoff = Date().timeIntervalSince1970 - Self.expiry
        var alive: [ReassemblyRecord] = []
        var changed = false
        for (ref, r) in records {
            let url = MediaStore.storageDir.appendingPathComponent(r.part)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists || r.updated < cutoff {
                if exists { try? FileManager.default.removeItem(at: url) }
                records[ref] = nil
                changed = true
                continue
            }
            alive.append(r)
        }
        if changed { save() }
        return alive
    }

    /// Part-file names the scratch sweep must NOT reclaim, with when each last made progress.
    ///
    /// `nonisolated` on purpose: the sweep runs detached at launch and only reads. A stale read is
    /// harmless because the sweep's own mtime grace already spares anything being actively written —
    /// this only ever decides the fate of a partial that is STALLED, which by definition has no
    /// in-flight write to race with.
    nonisolated static func liveParts() -> [String: Double] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([String: ReassemblyRecord].self, from: d) else { return [:] }
        var out: [String: Double] = [:]
        for r in list.values { out[r.part] = r.updated }
        return out
    }

    private func save() {
        lastSaveAt = Date()
        if let d = try? JSONEncoder().encode(records) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
