import Foundation

/// The history handoff's wire format — relay keys, request/manifest records, and the page codec
/// (`HistoryHandoff.swift` drives it). Foundation only, so `HavenLogicTests` covers it host-less.
enum HistoryHandoffWire {
    // MARK: keys
    //
    //   history-req/<target>                        the ask (Request)
    //   history-m/<target>/<source>                 one manifest PER SOURCE — two devices holding the
    //                                               history must not overwrite each other's progress
    //   history/<target>/<source>/<run>/<n>         the pages

    static func lane(_ acct: String) -> String { "haven/self/\(acct.lowercased())/" }
    static func requestPrefix(_ acct: String) -> String { lane(acct) + "history-req/" }
    static func requestKey(_ acct: String, _ target: String) -> String { requestPrefix(acct) + target.lowercased() }
    static func manifestPrefix(_ acct: String, _ target: String) -> String {
        lane(acct) + "history-m/\(target.lowercased())/"
    }
    static func manifestKey(_ acct: String, _ target: String, _ source: String) -> String {
        manifestPrefix(acct, target) + source.lowercased()
    }
    static func pageKey(_ acct: String, _ target: String, _ source: String, _ run: String, _ n: Int) -> String {
        lane(acct) + "history/\(target.lowercased())/\(source.lowercased())/\(run)/\(n)"
    }

    /// A source whose manifest hasn't moved for this long is presumed gone (uninstalled, wiped): a
    /// second source may take the request over, and the target may switch to it.
    static let staleSourceMs: UInt64 = 45 * 60 * 1000

    struct Request: Codable {
        var v = 1
        var device: String
        var at: UInt64
        var done: Bool?
        /// The requesting device's account-signed roster wire (base64). The source ingests it before
        /// exporting: a circle whose members are all current seals its key to known DEVICE ids only,
        /// so a source that has never seen the new device would export pages it can't open.
        var roster: String?
    }
    struct Manifest: Codable {
        var v = 1
        var run: String
        var source: String
        /// The request (`Request.at`) this run answers — a manifest from an older ask is stale.
        var forRequest: UInt64
        var pages: Int
        var complete: Bool
        /// Last progress, ms. Optional so a manifest without it still decodes (treated as stale).
        var updatedAt: UInt64?
        /// Events the source will send in total (an upper bound) and has sent so far — the target's
        /// progress bar. Optional: older manifests just show an indeterminate bar.
        var totalEvents: Int?
        var servedEvents: Int?

        func isLive(now: UInt64) -> Bool { complete || now &- (updatedAt ?? 0) < HistoryHandoffWire.staleSourceMs }
    }

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Tag byte of a sealed event envelope (core `TAG_EPOCH_EVENT`) — what progress counts.
    static let eventTag: UInt8 = 0x02
    static func eventCount(_ envelopes: [Data]) -> Int { envelopes.reduce(0) { $0 + ($1.first == eventTag ? 1 : 0) } }

    // MARK: media (direct first, relay fallback)
    //
    //   history-need/<target>/<source>/<run>/<n>              target → source: "I couldn't get page n's
    //                                                         media directly — put it on the relay"
    //   history/<target>/<source>/<run>/m/<ref>/<i>           that media, circle-sealed, 8 MB chunks
    //   history/<target>/<source>/<run>/mready/<n>            source → target: page n's media is up
    //
    // The DIRECT lane is the existing own-device media stream (frame 3 ask → frame 5 chunks sealed
    // with the account's own-media key, over the mesh and iroh). Nothing is copied to a relay unless
    // the new device asks for it, so a handoff between two phones that can reach each other never
    // parks your library on a server.

    static let mediaChunkBytes = 8 * 1024 * 1024

    static func needPrefix(_ acct: String, _ target: String, _ source: String, _ run: String) -> String {
        lane(acct) + "history-need/\(target.lowercased())/\(source.lowercased())/\(run)/"
    }
    static func needKey(_ acct: String, _ target: String, _ source: String, _ run: String, _ page: Int) -> String {
        needPrefix(acct, target, source, run) + String(page)
    }
    static func mediaChunkKey(_ acct: String, _ target: String, _ source: String, _ run: String, _ ref: String, _ i: Int) -> String {
        lane(acct) + "history/\(target.lowercased())/\(source.lowercased())/\(run)/m/\(keySafe(ref))/\(i)"
    }
    static func mediaReadyKey(_ acct: String, _ target: String, _ source: String, _ run: String, _ page: Int) -> String {
        lane(acct) + "history/\(target.lowercased())/\(source.lowercased())/\(run)/mready/\(page)"
    }
    /// Refs are `<kind>:<hash>` — keep relay path segments to plain ASCII (no dots, so no `..`).
    static func keySafe(_ ref: String) -> String {
        String(ref.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "_" })
    }

    /// One media blob a page names: its content ref and plaintext size (progress + wait budgets).
    struct MediaItem: Codable, Equatable { var ref: String; var size: Int64 }
    /// Written by the source once page n's media is on the relay. A ref it no longer holds is simply
    /// absent — the target stops waiting for it.
    struct MediaReady: Codable {
        var v = 1
        var items: [Ready]
        /// Rewritten after EACH upload so the target starts downloading while the rest goes up;
        /// `complete` once the page is done (only then may a missing ref be given up on).
        var complete: Bool?
        struct Ready: Codable { var ref: String; var chunks: Int }
    }

    /// The content refs behind a page's signed media lists: every variant marker (poster, thumb,
    /// preview, original) expands to the blobs it pairs, plain entries pass through. Deduped, in order.
    static func blobRefs(_ entries: [String]) -> [String] {
        var out: [String] = []
        func add(_ r: String) { if !r.isEmpty, !out.contains(r) { out.append(r) } }
        for e in entries {
            if let p = MediaVariants.parsePoster(e) { add(p.video); add(p.poster) }
            else if let t = MediaVariants.parseThumb(e) { add(t.content); add(t.thumb) }
            else if let v = MediaVariants.parsePreview(e) { add(v.content); add(v.preview) }
            else if let o = MediaVariants.parseOriginal(e) { add(o.optimized); add(o.original) }
            else { add(e) }
        }
        return out
    }

    // MARK: page wire format
    //
    //   v1  "HVH1" ‖ u16 circle-id length ‖ circle id ‖ u32 count ‖ count × (u32 length ‖ envelope)
    //   v2  "HVH2" ‖ (v1 body) ‖ u32 media count ‖ count × (u16 ref length ‖ ref ‖ u64 size)
    //
    // One circle per page, so a page that can't be ingested yet (its circle hasn't reached this
    // device) holds back only that circle. v1 pages (rc.1/rc.2 sources) still decode, with no media.

    static let magic = Data("HVH1".utf8)
    static let magicV2 = Data("HVH2".utf8)

    static func encodePage(circleId: String, envelopes: [Data], media: [MediaItem] = []) -> Data {
        var out = magicV2
        let cid = Data(circleId.utf8)
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        func u64(_ v: Int64) { withUnsafeBytes(of: UInt64(max(0, v)).littleEndian) { out.append(contentsOf: $0) } }
        u16(cid.count); out.append(cid)
        u32(envelopes.count)
        for e in envelopes { u32(e.count); out.append(e) }
        u32(media.count)
        for m in media { let r = Data(m.ref.utf8); u16(r.count); out.append(r); u64(m.size) }
        return out
    }

    static func decodePage(_ data: Data) -> (circleId: String, envelopes: [Data], media: [MediaItem])? {
        let b = [UInt8](data)
        guard b.count >= 10 else { return nil }
        let head = Data(b[0..<4])
        let v2 = head == magicV2
        guard v2 || head == magic else { return nil }
        var i = 4
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, i + n <= b.count else { return nil }
            defer { i += n }
            return b[i..<(i + n)]
        }
        func uint(_ n: Int) -> Int? { take(n).map { s in (0..<n).reduce(0) { $0 | Int(s[s.startIndex + $1]) << (8 * $1) } } }
        guard let cl = uint(2), let cb = take(cl), let cid = String(bytes: cb, encoding: .utf8),
              let count = uint(4) else { return nil }
        var envs: [Data] = []
        envs.reserveCapacity(count)
        for _ in 0..<count {
            guard let n = uint(4), let e = take(n) else { return nil }
            envs.append(Data(e))
        }
        var media: [MediaItem] = []
        if v2 {
            guard let mc = uint(4) else { return nil }
            for _ in 0..<mc {
                guard let rl = uint(2), let rb = take(rl), let ref = String(bytes: rb, encoding: .utf8),
                      let size = uint(8) else { return nil }
                media.append(MediaItem(ref: ref, size: Int64(size)))
            }
        }
        return (cid, envs, media)
    }
}
