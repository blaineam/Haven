import Foundation

/// Pure mailbox-ingest decisions (HavenLogicTests): what a poll fetches from a relay this device
/// hosts, and which received envelopes fan out to my other devices / wake them with a push.
///
/// Release-gate regression (2026-09-30): a relay-hosting stub fired 200–500 silent `/notify` pushes a
/// minute. Each poll of its own relay re-offers up to `controlReofferBudget` already-SEEN control
/// envelopes (key commits / device rosters — linked-host recovery, by design), `receive` reports a
/// roster it already holds as applied, and every "applied" envelope was fanned out and pushed. The
/// seen-set itself was advancing (the log's "17 new" was the constant re-offer, not a backlog).
enum MailboxIngest {
    /// What one `receive` did. `quietRoster`: a byte-identical repeat of a device roster that landed
    /// no events — it keeps the local side effects of an applied envelope (activity, refresh) but
    /// owes no export, no fan-out and no push: my other devices already hold it.
    enum Outcome: Equatable, Sendable {
        case none, changed, quietRoster
        var applied: Bool { self != .none }
    }

    /// Only envelopes that CHANGED this engine go to my other devices (live delivery, nearby, push).
    static func fanOut<T>(_ items: [(T, Outcome)]) -> [T] {
        items.filter { $0.1 == .changed }.map(\.0)
    }

    /// The seen marks a drain pass owes: every processed key not already durably seen. A re-offered
    /// control key was marked when it first landed, so re-ingesting it owes nothing — and must not
    /// count toward the deferred-mark bound (that forced an export every other idle poll).
    static func marksOwed(_ processed: [String], durablySeen: (String) -> Bool) -> [String] {
        processed.filter { !durablySeen($0) }
    }

    /// Whether a pass asks for its own export, or lets its owed marks ride the next one. A real change
    /// or a newly unlocked circle always exports; otherwise marks defer until `cap` of them are
    /// waiting, so a kill that skips the background flush re-fetches at most `cap` keys.
    static func owesExport(changed: Bool, unlockedCircle: Bool, deferred: Int, owed: Int, cap: Int) -> Bool {
        changed || unlockedCircle || deferred + owed > cap
    }

    static let controlReofferBudget = 48
    static let controlReofferScanCap = 300

    /// One poll of a relay this device hosts: every unseen, claimable key, plus up to
    /// `controlReofferBudget` already-seen control keys re-offered for linked-host recovery (bounded
    /// by `controlReofferScanCap` files inspected). `controlTag` reads a key's first envelope byte.
    static func planOwnRelayScan(keys: [String], isSeen: (String) -> Bool, claimable: (String) -> Bool,
                                 controlTag: (String) -> UInt8?) -> (unseen: [String], reoffered: [String]) {
        let unseen = keys.filter { !isSeen($0) && claimable($0) }
        var reoffered: [String] = []
        var scanned = 0
        for key in keys where isSeen(key) && reoffered.count < controlReofferBudget && scanned < controlReofferScanCap {
            scanned += 1
            if let tag = controlTag(key), tag == 0x03 || tag == 0x04 { reoffered.append(key) }
        }
        return (unseen, reoffered)
    }
}
