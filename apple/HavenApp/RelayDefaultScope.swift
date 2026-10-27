import Foundation

/// Which circles inherit a relay they were not explicitly given: the all-circles DEFAULT relay.
///
/// The default is meant for a relay the user runs or chose. When it is a FRIEND's relay (a friend-invite
/// ticket's, a wired one, one announced for the circle we share) inheriting it puts a PRIVATE circle's
/// mailbox, enrollment and media on a relay whose operator is not in that circle — e2e `multirelay: no
/// private circle's media on a friend's relay that doesn't serve it`: the fleet's default was B's relay,
/// A's new private circle inherited it, a device enrolled the circle there, and self-sync (additive,
/// never subtractive) wrote the inherited relay into the circle's explicit list on every device, so
/// flipping the default to A's own relay afterwards changed nothing.
///
/// A relay is a friend's when its node id is a contact's account id or one of that contact's devices.
/// It is withheld from a circle that friend is not a member of. A relay no contact owns (own, hosted,
/// cloud) is inherited by every circle, a friend's relay still serves every circle the friend is IN
/// (the shared circle, DMs with them), and an explicit per-circle assignment is never filtered.
/// Mirrors Android `RelayScope` and desktop `relayscope`.
final class RelayDefaultScope: @unchecked Sendable {
    static let shared = RelayDefaultScope()

    private let lock = NSLock()
    /// circle id → the contact node ids (accounts + their devices, never mine) that are IN it.
    /// nil until the first fill: a store that never learned any membership filters nothing.
    private var members: [String: Set<String>]?
    private var friends: Set<String> = []

    init() {}

    /// Replace the whole picture (the read model changed).
    func update(members: [String: Set<String>]) {
        lock.lock(); defer { lock.unlock() }
        self.members = members
        self.friends = members.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// One circle the picture does not list yet (just created): judged on its own members, not on a
    /// stale snapshot.
    func learn(circleId: String, members ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        var m = members ?? [:]
        m[circleId] = (m[circleId] ?? []).union(ids)   // never forget members the read model already knows
        members = m
        friends.formUnion(ids)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        members = nil; friends = []
    }

    /// May `circleId` take `relay` without an explicit assignment?
    func inherits(circleId: String, relay: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let members else { return true }
        return Self.rule(relay: relay, circleMembers: members[circleId] ?? [], friends: friends)
    }

    /// The pure rule: withheld iff `relay` is a friend's node id and that friend is not in the circle.
    static func rule(relay: String, circleMembers: Set<String>, friends: Set<String>) -> Bool {
        if relay.hasPrefix("s3:") { return true }
        let hex = relay.lowercased()
        return !(friends.contains(hex) && !circleMembers.contains(hex))
    }
}
