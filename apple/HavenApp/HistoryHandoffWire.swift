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

    struct Request: Codable { var v = 1; var device: String; var at: UInt64; var done: Bool? }
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

        func isLive(now: UInt64) -> Bool { complete || now &- (updatedAt ?? 0) < HistoryHandoffWire.staleSourceMs }
    }

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    // MARK: page wire format
    //
    //   "HVH1" ‖ u16 circle-id length ‖ circle id ‖ u32 count ‖ count × (u32 length ‖ envelope)
    //
    // One circle per page, so a page that can't be ingested yet (its circle hasn't reached this
    // device) holds back only that circle.

    static let magic = Data("HVH1".utf8)

    static func encodePage(circleId: String, envelopes: [Data]) -> Data {
        var out = magic
        let cid = Data(circleId.utf8)
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        u16(cid.count); out.append(cid)
        u32(envelopes.count)
        for e in envelopes { u32(e.count); out.append(e) }
        return out
    }

    static func decodePage(_ data: Data) -> (circleId: String, envelopes: [Data])? {
        let b = [UInt8](data)
        guard b.count >= 10, Data(b[0..<4]) == magic else { return nil }
        var i = 4
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, i + n <= b.count else { return nil }
            defer { i += n }
            return b[i..<(i + n)]
        }
        func u16() -> Int? { take(2).map { Int($0[$0.startIndex]) | Int($0[$0.startIndex + 1]) << 8 } }
        func u32() -> Int? {
            take(4).map { s in (0..<4).reduce(0) { $0 | Int(s[s.startIndex + $1]) << (8 * $1) } }
        }
        guard let cl = u16(), let cb = take(cl), let cid = String(bytes: cb, encoding: .utf8),
              let count = u32() else { return nil }
        var envs: [Data] = []
        envs.reserveCapacity(count)
        for _ in 0..<count {
            guard let n = u32(), let e = take(n) else { return nil }
            envs.append(Data(e))
        }
        return (cid, envs)
    }
}
