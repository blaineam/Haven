import Foundation

/// The pure half of "which relay holds which media blob" — the decisions behind `MediaBackupLedger`
/// (SharedStore.swift), split out Foundation-only so HavenLogicTests covers them host-less.
///
/// Field report (2.0.0-rc.3, iPhone 17 Pro Max): after Settings ▸ Devices ▸ "Load history from your
/// relays" pulled hundreds of posts and their media, the phone got hot and stayed hot. Three things
/// stacked up:
///
///   1. The ledger was written ONLY on the upload/probe paths. A blob this device had just
///      downloaded — complete, decrypted — from relay X was not recorded as held by X.
///   2. So the 2-minute backfill enqueued every one of those refs, and the backup probe asked each
///      relay "do you hold it?" with a FULL GET of the blob: the phone re-downloaded every recovered
///      photo from the relay it had just downloaded it from, then re-sealed and uploaded it to any
///      other relay that lacked it.
///   3. That mirroring of media this device did not author was gated only at `.serious` thermal, so
///      a warm (`.fair`) phone kept going.
///
/// And because the badge on your own posts reads the ledger, those recovered posts showed the orange
/// "not backed up" cloud while the relay in fact held everything.
enum MediaHolding {

    // MARK: - Download → ledger

    /// The ledger destination for a source that just served a blob: the relay's node hex, or "s3".
    /// `nil` for a source with no stable identity (nothing to record).
    enum Source: Equatable {
        case relay(String)     // node hex — a relay's HTTP interface, an iroh dial, or our own hosted relay
        case s3
        var ledgerDest: String? {
            switch self {
            case .relay(let n): return n.isEmpty ? nil : n
            case .s3: return "s3"
            }
        }
    }

    /// The ledger destination to record as HOLDING a ref after a download from `source` — ONLY when
    /// the blob was complete (every window of a chunked blob came from that one source, including the
    /// last) AND it opened. A partial reassembly or an undecryptable copy proves nothing about what the
    /// source holds, and a ledger entry is permanent (the backfill and the probe never revisit it), so
    /// recording one of those would hide a broken relay copy forever. nil = record nothing.
    static func holderToRecord(from source: Source?, complete: Bool, opened: Bool) -> String? {
        guard complete, opened else { return nil }
        return source?.ledgerDest
    }

    // MARK: - The "does this relay hold it?" probe

    /// One `HEAD /k/<key>` answer from a relay's HTTP interface.
    enum Head: Equatable {
        case present, absent
        /// The relay (or a proxy in front of it) does not speak HEAD — 400/405/501. Fall back to GET.
        case unsupported
        case refused        // 401/403: reachable, but not (yet) letting us in
        case unreachable
    }

    /// One GET answer (the fallback probe, and the tiny manifest read).
    enum Fetch: Equatable {
        case data(Data), miss, refused, unreachable
    }

    enum Verdict: Equatable {
        case complete        // holds every window → ledger it, never ask again
        case incomplete      // manifest present, tail window missing → re-upload
        case absent          // reachable, holds nothing → upload
        case refused
        case unreachable
    }

    /// Ask one relay whether it holds a COMPLETE copy of a ref, as cheaply as possible.
    ///
    /// The old probe was `GET haven/media/<ref>` — the whole blob for any unchunked media, i.e. every
    /// photo — just to learn "yes". HEAD answers the same question with no body (haven-relay has
    /// served `HEAD /k/<key>` since its HTTP interface shipped; the in-app relays run the same code):
    ///
    ///   * HEAD manifest key — absent → `.absent`.
    ///   * HEAD chunk 0 — absent → the blob is unchunked, and presence IS completeness.
    ///   * Chunked: GET the manifest (~100 bytes, it is a manifest now) for the window count, then
    ///     HEAD the LAST window — the same tail check `holdsCompleteBlob` has always made.
    ///
    /// A relay that answers HEAD with `.unsupported` gets exactly the old behaviour (full GET of the
    /// manifest key, then a GET of the last window), so an old relay or an odd proxy never loses
    /// media — it just stays as expensive as it was. `fullGets` counts body-carrying GETs of a key
    /// that may be a whole blob (the e2e/QA "probe bytes" signal); the tiny manifest GET is not one.
    static func probe(manifestKey: String, chunkKey: (Int) -> String,
                      head: (String) async -> Head,
                      get: (String) async -> Fetch,
                      chunkCount: (Data) -> Int?) async -> (verdict: Verdict, fullGets: Int) {
        switch await head(manifestKey) {
        case .refused: return (.refused, 0)
        case .unreachable: return (.unreachable, 0)
        case .absent: return (.absent, 0)
        case .unsupported:
            return await legacyProbe(manifestKey: manifestKey, chunkKey: chunkKey, get: get, chunkCount: chunkCount)
        case .present:
            switch await head(chunkKey(0)) {
            case .absent: return (.complete, 0)   // not chunked → presence is completeness
            case .refused: return (.refused, 0)
            case .unreachable: return (.unreachable, 0)
            case .unsupported:
                return await legacyProbe(manifestKey: manifestKey, chunkKey: chunkKey, get: get, chunkCount: chunkCount)
            case .present:
                // Chunked: the manifest key holds a tiny manifest, so this GET is cheap.
                switch await get(manifestKey) {
                case .refused: return (.refused, 0)
                case .unreachable: return (.unreachable, 0)
                case .miss: return (.absent, 0)   // vanished between the two asks
                case .data(let m):
                    guard let n = chunkCount(m), n > 0 else { return (.complete, 0) }
                    switch await head(chunkKey(n - 1)) {
                    case .present: return (.complete, 0)
                    case .absent: return (.incomplete, 0)
                    case .refused: return (.refused, 0)
                    case .unreachable, .unsupported: return (.unreachable, 0)
                    }
                }
            }
        }
    }

    /// The pre-HEAD probe, kept verbatim as the fallback.
    private static func legacyProbe(manifestKey: String, chunkKey: (Int) -> String,
                                    get: (String) async -> Fetch,
                                    chunkCount: (Data) -> Int?) async -> (verdict: Verdict, fullGets: Int) {
        switch await get(manifestKey) {
        case .refused: return (.refused, 1)
        case .unreachable: return (.unreachable, 1)
        case .miss: return (.absent, 1)
        case .data(let m):
            guard let n = chunkCount(m), n > 0 else { return (.complete, 1) }
            if case .data(let d) = await get(chunkKey(n - 1)), !d.isEmpty { return (.complete, 2) }
            return (.incomplete, 2)
        }
    }

    // MARK: - Backfill

    /// The circle's wanted relay ids as LEDGER destinations: an `s3:` pseudo-relay is recorded as
    /// "s3", so comparing the raw ids meant a circle with an S3 entry could never be satisfied and
    /// its media was re-enqueued on every 2-minute sweep forever.
    static func ledgerDests(forWanted wanted: [String]) -> Set<String> {
        Set(wanted.map { $0.hasPrefix("s3:") ? "s3" : $0 })
    }

    /// Whether the backfill should enqueue `ref` at all.
    ///
    /// - `wanted`: the circle's relays (raw ids, `s3:` pseudo-relays included).
    /// - `held`: the ledger's destinations for `ref`.
    /// - `heldRemotely`: the ledger has it on some destination other than our own hosted relay.
    static func needsBackfill(wanted: [String], held: Set<String>, heldRemotely: Bool) -> Bool {
        if wanted.isEmpty { return !heldRemotely }   // no explicit relay set → the old remote test
        return !ledgerDests(forWanted: wanted).isSubset(of: held)
    }

    /// Backfill of media this device is NOT the only safe holder of — someone else's post, or your
    /// own post whose blob already sits on a relay another device can read (the history-recovery
    /// case) — is MIRRORING: redundancy across relays, valuable but never urgent. It runs at
    /// background priority (`HeavyWorkPolicy.UploadBudget.mirror`). Only your own media with no
    /// remote copy anywhere keeps the authored-upload budget, because there it is the only copy.
    ///
    /// `mine == nil` is a job persisted by an older build, which recorded no authorship: treated as
    /// mirroring (the cooler choice; the next sweep re-tags your own refs).
    static func isBackgroundMirror(mine: Bool?, heldRemotely: Bool) -> Bool {
        !(mine ?? false) || heldRemotely
    }

    /// Refs the 2-minute sweep may enqueue per circle per pass. Your own unbacked media keeps the
    /// generous cap (it is the only copy); mirroring stays small on a phone so a big recovered
    /// history trickles instead of saturating the radio. A hosted-relay Mac keeps its old cap.
    static func perCircleCap(hostingRelay: Bool, phone: Bool, mirror: Bool) -> Int {
        if hostingRelay { return 40 }
        if mirror && phone { return 12 }
        return 200
    }

    // MARK: - The badge on your own posts

    enum Badge: Equatable {
        case backedUp          // pink checkmark.icloud.fill
        case noRelay           // orange: no relay known for the circle
        case ownRelayOnly      // orange drive: only our own hosted relay has it
        /// A determinate ring; `stuck` = it has restarted repeatedly (drawn orange).
        case uploading(Double, stuck: Bool)
        /// Queued, nothing written yet (`stuck`: orange exclamationmark.icloud — not reaching a relay).
        case waiting(stuck: Bool)
    }

    /// The badge is a pure function of the ledger + queue — which is why it must re-render when the
    /// ledger changes for one of its refs (`MediaLedgerChanges`), not on an hourly timer.
    static func badge(blobs: [String], heldRemotely: (String) -> Bool, heldAnywhere: (String) -> Bool,
                      pending: (String) -> Bool, progress: Double?, looksStuck: Bool,
                      hasRelay: Bool) -> Badge {
        let backed = !blobs.isEmpty && blobs.allSatisfy(heldRemotely)
        if backed { return .backedUp }
        if !hasRelay { return .noRelay }
        let localOnly = !blobs.isEmpty && blobs.allSatisfy(heldAnywhere)
        if localOnly { return .ownRelayOnly }
        let isPending = blobs.contains(where: pending)
        let stuck = looksStuck || (!isPending && !blobs.isEmpty)
        if let progress { return .uploading(progress, stuck: stuck) }
        return .waiting(stuck: stuck)
    }
}
