import Foundation

/// Offline friend invites (`docs/OFFLINE-FRIEND-INVITES.md`): persisted ticket state + the relay
/// I/O for the token-keyed drop/grant handshake, so adding a friend needs NO simultaneous-online
/// window.
///
/// Inviter: share links carry a `?t=` ticket (one-time secret + this device's relays + dial
/// hints). The mailbox pass polls `haven/invite/<my-acct>/` on my relays; a parked acceptance
/// opens against a pending ticket and feeds the NORMAL connection-request prompt (`handleHello`
/// — the drop payload IS the acceptor's hello). Approving writes the reply hello under the
/// ticket's grant key and consumes the ticket.
///
/// Acceptor: accepting persists the ticket, parks my hello under its drop key on the INVITER's
/// relays (retried until landed — relays come from the ticket, the exact field the plain link
/// was missing), then polls the grant key; the grant is the inviter's hello, ingested through
/// the normal path, plus `adoptBootstrapRelays(ticket.relays)` so real sync (keys, history,
/// relay entries) flows through the standard mailbox machinery from there.
///
/// The live handshake lanes are untouched and still win when both sides are online — everything
/// here is the durable fallback, all blobs sealed + MAC'd from the ticket secret (the relay
/// stays blind; the link itself was always the capability).
@MainActor
final class FriendInviteStore: ObservableObject {
    static let shared = FriendInviteStore()

    struct Issued: Codable {
        let ticket: String
        let issuedAt: UInt64
        var consumedAt: UInt64?
        /// The acceptor's account hex once their drop arrived — the join key `noteApproved` uses
        /// to find which ticket's grant to write when the user taps Approve.
        var acceptorHex: String?
    }
    struct Accepted: Codable {
        let ticket: String
        let acceptedAt: UInt64
        var dropLanded: Bool
        var granted: Bool
    }

    @Published private(set) var issued: [Issued] = []
    @Published private(set) var accepted: [Accepted] = []

    private let issuedKey = "haven.friendInvites.issued"
    private let acceptedKey = "haven.friendInvites.accepted"
    private let expiryKey = "haven.friendInvites.expirySecs"
    private let maxLive = 16   // cap outstanding tickets; oldest unconsumed pruned first
    private var ticking = false

    /// "Never expire" sentinel (~a century). A real u64 timestamp, so the sealed blob's `expires`
    /// field and the relay's `expires > now` check both stay valid — the link simply never lapses.
    static let neverExpirySecs: UInt64 = 100 * 365 * 24 * 3600

    /// How long a freshly-minted invite link stays valid. User-configurable (Settings ▸ invite):
    /// 7d / 30d / 90d / 1yr / Never. Applied consistently to both the reuse/prune "is it still
    /// live" check AND the sealed blob's expiry, so changing it retroactively extends or shortens
    /// the CURRENT link (e.g. "Never" makes the link you're already sharing permanent). The link
    /// is otherwise stable — reused until it lapses or you roll it by hand; it never auto-rotates.
    @Published var expirySecs: UInt64 {
        didSet { UserDefaults.standard.set(String(expirySecs), forKey: expiryKey) }
    }

    private init() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: expiryKey), let v = UInt64(s) { expirySecs = v }
        else { expirySecs = friendInviteDefaultTtlSecs() }   // 30 days
        if let raw = d.data(forKey: issuedKey), let v = try? JSONDecoder().decode([Issued].self, from: raw) { issued = v }
        if let raw = d.data(forKey: acceptedKey), let v = try? JSONDecoder().decode([Accepted].self, from: raw) { accepted = v }
    }

    private func save() {
        let d = UserDefaults.standard
        if let raw = try? JSONEncoder().encode(issued) { d.set(raw, forKey: issuedKey) }
        if let raw = try? JSONEncoder().encode(accepted) { d.set(raw, forKey: acceptedKey) }
    }

    private static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970) }
    private static func ticket(_ text: String) -> FriendTicketFfi? { try? friendTicketParse(text: text) }
    /// Instance (not static) so it reads the user's configured `expirySecs`. "Never" always live.
    private func isLive(_ issuedAt: UInt64) -> Bool {
        if expirySecs >= Self.neverExpirySecs { return true }
        return Self.now() - min(issuedAt, Self.now()) <= expirySecs
    }

    // MARK: - Inviter: minting + the share-link value

    /// The `?t=` value for the invite screen's link/QR. Reuses the newest live ticket so
    /// re-opening the screen doesn't grow the pending set; mints when none is live. Nil when
    /// this device has no relays — there is no mailbox for an offline acceptance to land in,
    /// and the plain live-only link still works.
    func currentTicketLinkValue() -> String? {
        prune()
        if let live = issued.last(where: { $0.consumedAt == nil && isLive($0.issuedAt) }),
           let v = Self.linkValue(live.ticket) {
            return v
        }
        guard let text = mint() else { return nil }
        return Self.linkValue(text)
    }

    /// Manually roll the invite link: retire every live, unconsumed ticket and mint a fresh one,
    /// so the shared link changes on demand. Anyone holding the OLD link can no longer complete an
    /// offline add (its drop key stops being polled); live/online adds via the identity part of the
    /// link still work. Returns the new `?t=` value (nil if this device has no relays).
    @discardableResult
    func rollInviteLink() -> String? {
        for i in issued.indices where issued[i].consumedAt == nil { issued[i].consumedAt = Self.now() }
        save()
        guard let text = mint() else { return nil }
        HavenLog.net("friend-invite: link rolled by user")
        return Self.linkValue(text)
    }

    /// When the current live link lapses (nil = none live, or Never). For the settings UI.
    func currentLinkExpiry() -> Date? {
        prune()
        guard expirySecs < Self.neverExpirySecs,
              let live = issued.last(where: { $0.consumedAt == nil && isLive($0.issuedAt) }) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(live.issuedAt + expirySecs))
    }

    private static func linkValue(_ text: String) -> String? {
        text.hasPrefix("haven-friend:") ? String(text.dropFirst("haven-friend:".count)) : nil
    }

    /// Reassemble a ticket from a link's `?t=` value.
    static func ticket(fromLinkValue v: String) -> FriendTicketFfi? {
        Self.ticket("haven-friend:" + v)
    }

    private func mint() -> String? {
        let relays = RelayMailboxStore.shared.allRelays()
        guard !relays.isEmpty else {
            HavenLog.net("friend-invite: mint skipped — no relays (live-only link)")
            return nil
        }
        guard let bundle = FeedStore.shared.myPublicBundle() else { return nil }
        let hints = FeedStore.shared.inviteDeviceIds().compactMap(Self.hexData)
        guard let t = try? friendInviteIssue(accountBundle: bundle, issuedAt: Self.now(),
                                             relays: relays, deviceHints: hints),
              let text = try? friendTicketEncode(ticket: t) else { return nil }
        issued.append(Issued(ticket: text, issuedAt: Self.now(), consumedAt: nil, acceptorHex: nil))
        save()
        HavenLog.net("friend-invite: minted ticket (relays=\(relays.count))")
        return text
    }

    private func prune() {
        let before = issued.count
        issued.removeAll { $0.consumedAt == nil && !isLive($0.issuedAt) }
        while issued.filter({ $0.consumedAt == nil }).count > maxLive,
              let idx = issued.firstIndex(where: { $0.consumedAt == nil }) {
            issued.remove(at: idx)
        }
        // Completed acceptances linger for a day instead of vanishing on the next tick: a re-scan
        // of the same ticket then de-dups (the friendship is already made) instead of parking a
        // fresh drop, and the QA dump can observe `granted` — pruning it on the tick right after
        // pollGrants set it made the e2e's "friendship async-complete" step a race (2026-09-01).
        let grantedLinger: UInt64 = 24 * 3600
        accepted.removeAll { ($0.granted && Self.now() - min($0.acceptedAt, Self.now()) > grantedLinger) || !isLive($0.acceptedAt) }
        if issued.count != before { save() }
    }

    // MARK: - Acceptor: accept + drop write + grant poll

    /// The scanner accepted a ticket-bearing invite (the local contact add already ran).
    func acceptTicket(linkValue: String) {
        guard let t = Self.ticket(fromLinkValue: linkValue),
              let text = try? friendTicketEncode(ticket: t) else { return }
        guard !accepted.contains(where: { $0.ticket == text }) else { return }
        accepted.append(Accepted(ticket: text, acceptedAt: Self.now(), dropLanded: false, granted: false))
        save()
        HavenLog.net("friend-invite: accepted ticket (relays=\(t.relays.count)) — parking drop")
        Task { await self.tick() }
    }

    // MARK: - The poll pass (both roles)

    /// One pass of every pending duty. Called from the mailbox polling loop; cheap when idle
    /// (all four lists empty = no I/O). Single-flight.
    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        prune()
        await writePendingDrops()
        await pollGrants()
        await pollIncomingDrops()
    }

    private func writePendingDrops() async {
        for (i, a) in accepted.enumerated() where !a.dropLanded {
            guard let t = Self.ticket(a.ticket) else { continue }
            guard let hello = FeedStore.shared.inviteHelloBody() else { continue }
            let expires = t.issuedAt + expirySecs
            guard let key = try? friendInviteDropKey(ticket: t),
                  let blob = try? friendInviteBuildDrop(ticket: t, expires: expires, payload: hello) else { continue }
            var landed = false
            for relay in t.relays {
                // The inviter's relay can be the relay THIS device hosts (shared-relay circles,
                // and the QA fleet's stub) — RelayClients refuses self-dials, so store directly.
                if RelayHost.shared.serving, relay == RelayHost.shared.nodeId {
                    if RelayHost.shared.localPut(key, blob) { landed = true }
                    continue
                }
                if let c = await RelayClients.client(relay) {
                    if (try? await c.put(key: key, data: blob)) != nil {
                        landed = true
                        RelayHealth.shared.recordSuccess(relay)
                        HavenLog.net("friend-invite: drop landed on \(relay.prefix(8))")
                    } else {
                        RelayHealth.shared.recordFailure(relay)
                    }
                }
            }
            if landed {
                accepted[i].dropLanded = true
                save()
            }
        }
    }

    private func pollGrants() async {
        for (i, a) in accepted.enumerated() where a.dropLanded && !a.granted {
            guard let t = Self.ticket(a.ticket),
                  let key = try? friendInviteGrantKey(ticket: t) else { continue }
            for relay in t.relays {
                var fetched: Data?
                if RelayHost.shared.serving, relay == RelayHost.shared.nodeId {
                    fetched = RelayHost.shared.localGet(key)
                } else if let c = await RelayClients.client(relay) {
                    fetched = await c.get(key: key)
                }
                guard let blob = fetched, !blob.isEmpty else { continue }
                guard let hello = try? friendInviteOpenGrant(ticket: t, blob: blob, now: Self.now()) else {
                    HavenLog.net("friend-invite: grant blob refused (tamper/expiry) from \(relay.prefix(8))")
                    continue
                }
                HavenLog.net("friend-invite: grant received — completing friendship")
                // The inviter approved us: ingest their hello through the normal path (we added
                // them as a contact at accept time, so the known-account branch consumes it),
                // adopt the ticket relays as REAL relays, and let standard sync carry the rest
                // (epoch keys, history, relay entries).
                FeedStore.shared.ingestInviteHello(hello)
                RelayMailboxStore.shared.adoptBootstrapRelays(t.relays)
                accepted[i].granted = true
                save()
                FeedStore.shared.syncWithContacts(force: true)
                break
            }
        }
    }

    // MARK: - Inviter: incoming drops + grant on approval

    private func pollIncomingDrops() async {
        let pending = issued.filter { $0.consumedAt == nil && isLive($0.issuedAt) }
        guard !pending.isEmpty else { return }
        let myAcct = AccountStore.currentNodeHex().lowercased()
        guard myAcct.count == 64 else { return }
        let prefix = "haven/invite/\(myAcct)/"
        // My own relays hold the drops: the hosted relay's local store first, then each remote.
        var keys: Set<String> = []
        if RelayHost.shared.serving {
            keys.formUnion(RelayHost.shared.localList(prefix))
        }
        for relay in RelayMailboxStore.shared.allRelays() {
            if let c = await RelayClients.client(relay), let listed = try? await c.list(prefix: prefix) {
                keys.formUnion(listed)
            }
        }
        guard !keys.isEmpty else { return }
        for p in pending {
            guard let t = Self.ticket(p.ticket),
                  let dropKey = try? friendInviteDropKey(ticket: t),
                  keys.contains(dropKey) else { continue }
            var blob: Data? = RelayHost.shared.serving ? RelayHost.shared.localGet(dropKey) : nil
            if blob == nil {
                for relay in RelayMailboxStore.shared.allRelays() {
                    if let c = await RelayClients.client(relay), let b = await c.get(key: dropKey), !b.isEmpty {
                        blob = b
                        break
                    }
                }
            }
            guard let blob, let hello = try? friendInviteOpenDrop(ticket: t, blob: blob, now: Self.now()) else { continue }
            // The drop payload is the acceptor's hello. Feeding it through handleHello surfaces
            // the EXISTING approval prompt (targeted, MAC already proved link possession — this
            // is not a cold call) and holds it exactly like a held mailbox hello.
            let acceptor = FeedStore.shared.helloSenderHex(hello)
            if let idx = issued.firstIndex(where: { $0.ticket == p.ticket }), issued[idx].acceptorHex != acceptor {
                issued[idx].acceptorHex = acceptor
                save()
            }
            HavenLog.net("friend-invite: acceptance drop opened (from \(acceptor?.prefix(8) ?? "?")) — surfacing prompt")
            let consumed = FeedStore.shared.ingestInviteHello(hello)
            // Auto-consumed = we had ALREADY added them (mutual invite race): there will be no
            // approval tap, so the approval IS implicit — park the grant right now, or an offline
            // acceptor would wait on reply lanes that need them online (the exact bug this
            // feature removes).
            if consumed, let hex = acceptor {
                noteApproved(accountHex: hex)
            }
        }
    }

    /// The user approved a connection request. If it matches a pending ticket's acceptor, write
    /// the grant (my reply hello) under the ticket's grant key and consume the ticket — the
    /// acceptor's poll completes the friendship whenever they next come online.
    func noteApproved(accountHex: String) {
        let hex = accountHex.lowercased()
        let matches = issued.enumerated().filter { $0.element.consumedAt == nil && $0.element.acceptorHex == hex }
        HavenLog.net("friend-invite: noteApproved(\(hex.prefix(8))) matches=\(matches.count)")
        guard !matches.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let hello = FeedStore.shared.inviteHelloBody() else { return }
            for (idx, p) in matches {
                guard let t = Self.ticket(p.ticket),
                      let key = try? friendInviteGrantKey(ticket: t) else { continue }
                let expires = t.issuedAt + expirySecs
                guard let blob = try? friendInviteBuildGrant(ticket: t, expires: expires, payload: hello) else { continue }
                var landed = RelayHost.shared.serving && RelayHost.shared.localPut(key, blob)
                let relays = RelayMailboxStore.shared.allRelays()
                HavenLog.net("friend-invite: grant → relays=\(relays.count) serving=\(RelayHost.shared.serving)")
                for relay in relays {
                    if let c = await RelayClients.client(relay) {
                        do { try await c.put(key: key, data: blob); landed = true }
                        catch { HavenLog.net("friend-invite: grant put FAILED on \(relay.prefix(8)): \(error)") }
                    } else {
                        HavenLog.net("friend-invite: grant put — no client for \(relay.prefix(8))")
                    }
                }
                HavenLog.net("friend-invite: grant write landed=\(landed)")
                if landed, self.issued.indices.contains(idx) {
                    self.issued[idx].consumedAt = Self.now()
                    self.save()
                    HavenLog.net("friend-invite: grant parked — ticket consumed")
                }
            }
        }
    }

    // MARK: - Helpers

    private static func hexData(_ s: String) -> Data? {
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
}
