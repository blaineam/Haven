import Foundation

/// The persisted bookkeeping behind offline friend invites (`FriendInviteStore`), split out of the
/// store so the lifecycle rules (when a ticket is still live, what pruning drops, which ticket an
/// approval belongs to, how the state round-trips through UserDefaults) are Foundation-only and run
/// in the host-less logic tests. The store keeps the FFI work (minting, relay I/O) and delegates here.

/// A ticket this device minted and shared as a `?t=` link.
struct FriendInviteIssued: Codable, Equatable {
    let ticket: String
    let issuedAt: UInt64
    var consumedAt: UInt64?
    /// The acceptor's account hex once their drop arrived — the join key `noteApproved` uses
    /// to find which ticket's grant to write when the user taps Approve.
    var acceptorHex: String?
}

/// A ticket this device accepted (scanned/pasted) from someone else's link.
struct FriendInviteAccepted: Codable, Equatable {
    let ticket: String
    let acceptedAt: UInt64
    var dropLanded: Bool
    var granted: Bool
}

enum FriendInviteRules {
    /// "Never expire" sentinel (~a century). A real u64 timestamp, so the sealed blob's `expires`
    /// field and the relay's `expires > now` check both stay valid — the link simply never lapses.
    static let neverExpirySecs: UInt64 = 100 * 365 * 24 * 3600
    /// Outstanding (unconsumed) tickets are capped; the oldest unconsumed is pruned first.
    static let maxLive = 16
    /// Completed acceptances linger for a day instead of vanishing on the next tick: a re-scan of
    /// the same ticket then de-dups (the friendship is already made) instead of parking a fresh drop.
    static let grantedLinger: UInt64 = 24 * 3600

    static let linkPrefix = "haven-friend:"

    static let issuedKey = "haven.friendInvites.issued"
    static let acceptedKey = "haven.friendInvites.accepted"
    static let expiryKey = "haven.friendInvites.expirySecs"

    /// Is a ticket minted at `issuedAt` still within the configured lifetime? "Never" is always live;
    /// a clock that moved backwards (issuedAt in the future) counts as just-minted, not as expired.
    static func isLive(_ issuedAt: UInt64, expirySecs: UInt64, now: UInt64) -> Bool {
        if expirySecs >= neverExpirySecs { return true }
        return now - min(issuedAt, now) <= expirySecs
    }

    /// The newest unconsumed, still-live ticket (what the invite screen reuses).
    static func newestLive(_ issued: [FriendInviteIssued], expirySecs: UInt64, now: UInt64) -> FriendInviteIssued? {
        issued.last(where: { $0.consumedAt == nil && isLive($0.issuedAt, expirySecs: expirySecs, now: now) })
    }

    /// When the current live link lapses (nil = none live, or Never).
    static func linkExpiry(_ issued: [FriendInviteIssued], expirySecs: UInt64, now: UInt64) -> Date? {
        guard expirySecs < neverExpirySecs,
              let live = newestLive(issued, expirySecs: expirySecs, now: now) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(live.issuedAt + expirySecs))
    }

    /// Drop lapsed unconsumed tickets, enforce the live cap (oldest unconsumed first), and age out
    /// acceptances. Returns true when the issued list changed (the caller persists then).
    @discardableResult
    static func prune(issued: inout [FriendInviteIssued], accepted: inout [FriendInviteAccepted],
                      expirySecs: UInt64, now: UInt64) -> Bool {
        let before = issued.count
        issued.removeAll { $0.consumedAt == nil && !isLive($0.issuedAt, expirySecs: expirySecs, now: now) }
        while issued.filter({ $0.consumedAt == nil }).count > maxLive,
              let idx = issued.firstIndex(where: { $0.consumedAt == nil }) {
            issued.remove(at: idx)
        }
        accepted.removeAll {
            ($0.granted && now - min($0.acceptedAt, now) > grantedLinger)
                || !isLive($0.acceptedAt, expirySecs: expirySecs, now: now)
        }
        return issued.count != before
    }

    /// Retire every live, unconsumed ticket so the shared link changes on demand.
    static func retireAll(_ issued: inout [FriendInviteIssued], now: UInt64) {
        for i in issued.indices where issued[i].consumedAt == nil { issued[i].consumedAt = now }
    }

    /// The tickets whose acceptor's drop has arrived for `accountHex` and which are not yet granted.
    static func pendingAcceptances(_ issued: [FriendInviteIssued], accountHex: String)
        -> [(offset: Int, element: FriendInviteIssued)] {
        let hex = accountHex.lowercased()
        return issued.enumerated().filter { $0.element.consumedAt == nil && $0.element.acceptorHex == hex }
    }

    /// Record an acceptance. False when this exact ticket was already accepted (a re-scan).
    @discardableResult
    static func recordAccepted(_ accepted: inout [FriendInviteAccepted], ticket: String, now: UInt64) -> Bool {
        guard !accepted.contains(where: { $0.ticket == ticket }) else { return false }
        accepted.append(FriendInviteAccepted(ticket: ticket, acceptedAt: now, dropLanded: false, granted: false))
        return true
    }

    /// `haven-friend:<value>` → `<value>` (the `?t=` payload); nil for anything else.
    static func linkValue(_ text: String) -> String? {
        text.hasPrefix(linkPrefix) ? String(text.dropFirst(linkPrefix.count)) : nil
    }

    static func hexString(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    static func hexData(_ s: String) -> Data? {
        let chars = Array(s.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    // MARK: Persistence

    struct Snapshot: Equatable {
        var issued: [FriendInviteIssued] = []
        var accepted: [FriendInviteAccepted] = []
        var expirySecs: UInt64
    }

    static func load(from d: UserDefaults, defaultExpirySecs: UInt64) -> Snapshot {
        var snap = Snapshot(expirySecs: defaultExpirySecs)
        if let s = d.string(forKey: expiryKey), let v = UInt64(s) { snap.expirySecs = v }
        if let raw = d.data(forKey: issuedKey), let v = try? JSONDecoder().decode([FriendInviteIssued].self, from: raw) { snap.issued = v }
        if let raw = d.data(forKey: acceptedKey), let v = try? JSONDecoder().decode([FriendInviteAccepted].self, from: raw) { snap.accepted = v }
        return snap
    }

    static func save(issued: [FriendInviteIssued], accepted: [FriendInviteAccepted], to d: UserDefaults) {
        if let raw = try? JSONEncoder().encode(issued) { d.set(raw, forKey: issuedKey) }
        if let raw = try? JSONEncoder().encode(accepted) { d.set(raw, forKey: acceptedKey) }
    }

    static func saveExpiry(_ secs: UInt64, to d: UserDefaults) {
        d.set(String(secs), forKey: expiryKey)
    }
}
