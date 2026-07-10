import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit

/// Short relative time ("now", "5m", "3h", "2d") from a unix-millis SENT timestamp —
/// so people see when something was sent, not when it reached them.
func relativeTimeShort(_ ms: UInt64) -> String {
    let secs = Date().timeIntervalSince1970 - Double(ms) / 1000
    switch secs {
    case ..<5: return "now"
    case ..<60: return "\(Int(secs))s"
    case ..<3600: return "\(Int(secs / 60))m"
    case ..<86_400: return "\(Int(secs / 3600))h"
    case ..<604_800: return "\(Int(secs / 86_400))d"
    case ..<2_592_000: return "\(Int(secs / 604_800))w"
    default: return "\(Int(secs / 2_592_000))mo"
    }
}

/// Reports each post card's on-screen vertical center so the feed can pick the one
/// nearest the middle of the screen as the "active" (playing) post.
struct PostCenterKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// Drives the live social demo: every action goes through the real hybrid-PQ social
/// engine (seal → open → feed) in `p2pcore`. Posts can carry media + a song.
@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var items: [FeedItemFfi] = []
    @Published private(set) var unseenCircle = 0      // new circle posts since last viewed
    @Published private(set) var unseenMessages = 0    // new DM messages since last viewed
    @Published private(set) var relayReachable = false  // the circle's relay accepted our last upload
    func markRelay(_ ok: Bool) { if relayReachable != ok { relayReachable = ok } }
    @Published private(set) var postTick = 0
    @Published private(set) var reactionTick = 0
    @Published private(set) var online = false
    /// True once we've actually exchanged a frame with a contact over that path —
    /// so the UI can show whether the internet and/or nearby links are really working.
    @Published private(set) var internetActive = false
    @Published private(set) var nearbyActive = false
    // Live media-sync counters — surfaced in the feed so the user (and I) can SEE whether media is moving
    // over the nearby mesh, instead of guessing from logs we can't read on every device.
    // Media-sync counters live in SyncMetrics (a SEPARATE ObservableObject) so updating them does NOT
    // re-render the whole feed/You tab — only the tap-to-open sync-detail popover observes them.
    // Diagnostics surfaced in Advanced → Connection.
    @Published private(set) var internetReady = false
    @Published private(set) var nodeError: String?
    @Published private(set) var lastSendError: String?
    /// Per-contact time we last received a valid frame from them — the basis for a
    /// truthful "Connected" (a live two-way link), not just "we hold their keys".
    @Published private(set) var lastHeard: [String: Date] = [:]
    /// The circles you belong to, and which one the feed is currently showing.
    @Published private(set) var circles: [CircleInfoFfi] = []
    @Published var activeCircleId = "default"
    static let shared = FeedStore()

    private var social: HavenSocial?
    private var node: HavenNode?
    /// The messaging transport node — the in-process relay ATTACHES to its endpoint (one iroh node,
    /// two ALPNs) so hosting a relay never spins up a second node (the path-churn leak).
    var transportNode: HavenNode? { node }
    /// This device's actual TRANSPORT node id hex (account id if we host the relay, else our device id).
    /// The self-dial guard skips THIS (our own relay), so a non-host still dials the host's account-id relay.
    var transportNodeHex: String { node?.nodeIdHex() ?? myNodeHex }
    private var nearby: NearbyTransport?
    private var mailboxTimer: Timer?
    private var listener: InboundBridge?
    private var syncTimer: Timer?

    // Adaptive sync cadence (device-heat control). The timers keep a cheap fixed heartbeat, but the
    // EXPENSIVE work (contact fan-out, relay LIST/poll, mesh dials) only runs when it's due. When the
    // app is idle — foregrounded but no interaction and nothing arriving — the due-interval STRETCHES,
    // so an idle phone isn't blasting hello+roster to every contact every 20s (the main heat source).
    // Any real activity (foreground, an authored post, an arriving message, a peer connecting) resets
    // it to the tight base cadence, and pushes still wake the app for immediacy either way.
    private var lastActivityMs: UInt64 = 0
    private var nextSyncDueMs: UInt64 = 0
    private var nextPollDueMs: UInt64 = 0
    /// Base cadences and the idle multipliers. Idle <3min = base; <15min = ×3; else ×6.
    private func adaptiveInterval(base: UInt64) -> UInt64 {
        let idle = now() &- lastActivityMs
        if idle < 180_000 { return base }
        if idle < 900_000 { return base * 3 }
        return base * 6
    }
    /// Mark "something is happening" → snap both timers back to their tight base cadence immediately.
    func bumpActivity() {
        lastActivityMs = now()
        nextSyncDueMs = 0
        nextPollDueMs = 0
    }

    // Chunked media reassembly: ref → temp file + which chunk indices we've received.
    // 512KB chunks overflowed MultipeerConnectivity's reliable-send buffer (small frames got through, media
    // chunks were silently dropped), so own-device media never arrived over nearby. 32KB transmits reliably
    // over a slow BLE-only link.
    private static let mediaChunkSize = 32 * 1024
    private struct IncomingMedia { let tempURL: URL; let total: Int; var got: Set<Int> }
    private var incoming: [String: IncomingMedia] = [:]

    private init() {}

    /// Initialize the real networked store once (idempotent) and bring the P2P node
    /// online. The feed works offline too; the node just enables real delivery.
    /// Re-initialize for a different identity (e.g. after restoring from a transfer code).
    /// Tears down the old engine, networking, and on-disk state, then configures fresh.
    func reconfigure(seed: Data) {
        node = nil
        nearby = nil
        social = nil
        items.removeAll()
        circles.removeAll()
        // Back up (don't hard-delete) the outgoing identity's engine state, so adopting a new identity is
        // recoverable instead of destructive. And RESET the self-sync base: a freshly-adopted (empty)
        // identity must not diff against the previous identity's base and tombstone its circles — that
        // bug propagated to the primary and wiped posts.
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let backup = stateURL.deletingLastPathComponent().appendingPathComponent("haven-feed.prev.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: stateURL, to: backup)
        }
        SelfSyncCoordinator.shared.reset()
        SharedStore.resetSeenMailbox()   // the new identity must not inherit the old ingestion cursor
        configure(seed: seed)
    }

    func configure(seed: Data) {
        guard social == nil else { return }
        social = try? HavenSocial(accountSeed: seed)
        // Multi-device reachability: iroh discovery is one-owner-per-id, so two devices on the SAME account
        // id collide (the host loses → can't be reached). Resolution:
        //  • The RELAY-HOST device keeps the ACCOUNT id — it's the always-on, reachable mailbox friends dial,
        //    and its in-app relay (shared endpoint) serves on that id. One endpoint, no leak.
        //  • A NON-HOST device takes a per-DEVICE transport id so it never competes with the host for the
        //    account id; friends learn it via the host's roster. (Sealing stays account-based either way.)
        if let social {
            // Per-INSTANCE identity: every client instance takes its OWN unique transport/relay id
            // (DeviceKeyStore — unique per install), so any number of clients can run under ONE account id
            // without colliding on iroh discovery. The account id is the IDENTITY only (signing + the
            // contact card friends pin), never a transport address. Each client hosts its relay on its own
            // id; friends reach each via the circle's relay list (the set of these ids).
            _ = social.useDeviceIdentity(deviceSeed: DeviceKeyStore.deviceAccount().secretSeed())
            HavenLog.net("configure account=\(social.myNodeHex().prefix(10)) instance=\(social.myDeviceNodeHex().prefix(10))")
        }
        loadPersisted()
        // Self-register THIS device AFTER importing persisted state. Registering first wrote a fresh
        // v1 roster that import_state's higher-version-wins restore then CLOBBERED with the persisted
        // roster — so if that roster carried a (stale) revocation of our own device id, the device
        // never effectively re-registered and stayed revoked forever (friends wouldn't dial us, and
        // the re-register/re-revoke flip-flop rotated every circle epoch on each launch).
        // Registering against the imported roster makes the re-authorization an explicit,
        // version-bumped update that propagates (see DeviceList::merge).
        if let social {
            _ = social.registerDevice(deviceBundle: DeviceKeyStore.deviceBundle(),
                                      name: DeviceKeyStore.deviceName,
                                      createdAt: UInt64(Date().timeIntervalSince1970))
        }
        social?.setKeepOwnPosts(on: SettingsStore.shared.keepMyPosts)   // apply the archive preference
        bumpActivity()   // seed activity NOW so launch starts at tight cadence (not instant max backoff)
        loadLastHeard()   // so "last seen" survives an app restart
        refreshCircles()     // also purges any contaminated DM membership (see refreshCircles)
        refresh()
        recomputeUnreadDMs()   // one-time badge compute at startup (kept OFF the per-refresh hot path)
        seedDemoIfNeeded()   // HAVEN_DEMO=1 only — PII-free synthetic dataset for screenshots
        guard ProcessInfo.processInfo.environment["HAVEN_NO_NET"] != "1" else { return }
        bringOnline(seed: seed)
        startMailboxPolling()
        ingestPushInbox()   // drain any events delivered inline by push while we were away
        RelayMailboxStore.shared.purgeStale()   // erase relays inactive AND unseen > 7 days (config else survives)
        RelayHost.shared.startIfEnabled()   // resume serving as the circle's relay if toggled on
        PresignStore.shared.remintAllOwned()   // refresh any S3 pre-signed pools I own
        // Ensure already-posted content is in the mailbox — at most once a day, not every launch.
        // This ran unconditionally at startup, and (before deterministic envelopes) every run
        // re-sealed the whole history into brand-new bytes → a NEW mailbox key per event per
        // launch. One real circle had accumulated ~6700 mailbox entries for 88 events, and every
        // cold start re-pulled + re-verified all of them — the 30-second circle-feed cold start.
        // New-relay adoption and share-history still backfill immediately (their own call sites).
        dailyMailboxRefreshIfDue()
        Task { await BackgroundUploader.shared.flush() }   // retry any posts that didn't reach the mailbox
        ScheduledStore.shared.start()   // fire any "send later" posts/DMs whose time has come
    }

    /// Once a day: re-assert everything I authored — upload anything a mailbox never saw AND
    /// TOUCH-refresh what it already holds, so relay-side mailbox GC (30-day TTL) keeps my live
    /// entries while legacy duplicates/stale-epoch copies age out. Checked at launch and from the
    /// 30s poll timer, so an always-open Mac (weeks between relaunches) still refreshes on time.
    private func dailyMailboxRefreshIfDue() {
        let backfillKey = "haven.lastMailboxBackfillAt"
        guard Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: backfillKey) > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: backfillKey)
        backfillMailbox(circleIds: circles.map(\.id))
    }

    // MARK: - Demo seeding (HAVEN_DEMO=1 only — PII-free synthetic content for screenshots)

    /// The engine handle, exposed so `DemoSeeder` can drive the real seal→open→feed pipeline
    /// with synthetic friend identities. Returns nil until `configure` has run.
    var demoEngine: HavenSocial? { social }
    /// Save the seeded state (private `persist` wrapper for `DemoSeeder`).
    func demoPersist() { persist() }
    private func seedDemoIfNeeded() {
        guard DemoEnv.isDemo, social != nil else { return }
        DemoSeeder.seed(feed: self)
        // Present the offline demo as a healthy, connected circle for the hero shots.
        online = true
        internetActive = true
        relayReachable = true
    }

    private func startMailboxPolling() {
        mailboxTimer?.invalidate()
        pollMailboxNow()
        // 10s heartbeat, but the actual poll only runs when due (30s base, stretching when idle).
        mailboxTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.now() >= self.nextPollDueMs else { return }
                self.nextPollDueMs = self.now() + self.adaptiveInterval(base: 30_000)
                self.pollMailboxNow()
                self.dailyMailboxRefreshIfDue()   // long-lived sessions refresh without a relaunch
            }
        }
    }

    // MARK: - Circles

    func refreshCircles() {
        purgeDMIntrudersRaw()           // clean DM membership every time we read circles
        circles = social?.circles() ?? []
    }

    /// Evict anyone who isn't one of a DM's two parties (full-id match). Operates directly
    /// on the engine so it can run inside refreshCircles without recursing.
    @discardableResult
    private func purgeDMIntrudersRaw() -> Bool {
        guard let social else { return false }
        var fixed = false
        for circle in social.circles() where circle.id.hasPrefix("dm:") {
            for nodeHex in social.contactNodeIds(circleId: circle.id) where !dmCircleAllows(circle.id, nodeHex) {
                social.removeFromCircle(circleId: circle.id, nodeHex: nodeHex)
                fixed = true
            }
        }
        if fixed { persist() }
        return fixed
    }

    var activeCircleName: String {
        circles.first { $0.id == activeCircleId }?.name ?? "My Circle"
    }

    func setActiveCircle(_ id: String) {
        guard id != activeCircleId else { return }
        activeCircleId = id
        refresh()
        requestMissingMedia()
    }

    /// Create a circle from scratch and switch to it. Add existing contacts next.
    func createCircle(name: String, memberIds: [String] = []) {
        guard let social else { return }
        let id = UUID().uuidString
        social.createCircle(id: id, name: name)
        for m in memberIds { try? social.addExistingToCircle(circleId: id, nodeHex: m) }
        persist(); refreshCircles()
        activeCircleId = id
        refresh()
        if !memberIds.isEmpty { syncWithContacts() }   // greet + back-fill to the new members
    }

    /// Add a known contact to the active circle, then sync so the circle forms on theirs.
    func addContactToActiveCircle(idHex: String) {
        guard let social else { return }
        ConnectionsStore.shared.clearCircleRemoval(idHex, circleId: activeCircleId)  // deliberate re-add un-bans them
        try? social.addExistingToCircle(circleId: activeCircleId, nodeHex: idHex)
        persist(); refreshCircles()
        syncWithContacts()
    }

    /// Remove a member from the active (custom) circle only — not a global block. This is durable: the
    /// member is recorded as removed so they can't auto-rejoin on their next handshake, and the core
    /// purges their posts + rotates the circle's epoch so they can't read anything posted afterward.
    func removeFromActiveCircle(_ idHex: String) { removeFromCircle(idHex, circleId: activeCircleId) }

    /// Remove a member from a specific circle — works for "default" (My Circle) too. Removing from the
    /// default circle is legitimate ("remove from My Circle"); the early-return that used to skip it meant
    /// no tombstone was ever written, so the member rejoined on their next handshake/self-sync.
    func removeFromCircle(_ idHex: String, circleId: String) {
        guard let social else { return }
        social.removeFromCircle(circleId: circleId, nodeHex: idHex)  // purges their events + rotates epoch
        ConnectionsStore.shared.removeFromCircle(idHex, circleId: circleId)  // authoritative tombstone: block re-add
        persist(); refreshCircles(); refresh()
    }

    /// Rename a circle (the default "My Circle" can be renamed too). Re-syncs so the new name
    /// propagates to members on their next handshake.
    func renameCircle(_ circleId: String, to name: String) {
        guard let social else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        social.renameCircle(id: circleId, name: trimmed)
        persist(); refreshCircles()
        syncWithContacts()
    }

    /// Node ids that are members of a circle but NOT in your own contacts — people you can
    /// see in a shared circle and choose to add to your My Circle.
    func nonContactMembers(in circleId: String) -> [String] {
        guard let social else { return [] }
        let mine = Set(ContactsStore.shared.contacts.map { $0.idHex })
        let myHex = social.myNodeHex()
        return social.contactNodeIds(circleId: circleId).filter { $0 != myHex && !mine.contains($0) }
    }

    /// Every node id to DIAL to reach a circle's members. The account id is the user-facing contact handle
    /// (QR/invite/verification) — but under the per-device transport it no longer resolves to a node, so we
    /// must dial each member's DEVICE node ids (learned from their signed roster) to actually reach them.
    /// We include the account id too, so a peer still on the pre-device-seed build (account id == node id) is
    /// reachable during cutover. De-duplicated, excludes self (both our account + device ids).
    /// dialTargets fans out to N FFI calls (deviceNodeIdsFor per member) and runs on every 20s sync
    /// tick for every circle — cache per circle for 10s. Rosters/hints change rarely; a fresh hint
    /// (recordDeviceHints) invalidates the cache so a brand-new contact is dialable immediately.
    private var dialTargetsCache: [String: (targets: [String], at: UInt64)] = [:]
    func dialTargets(_ circleId: String) -> [String] {
        guard let social else { return [] }
        if let c = dialTargetsCache[circleId], now() - c.at < 10_000 { return c.targets }
        let mineAcct = social.myNodeHex().lowercased()
        let mineDev = social.myDeviceNodeHex().lowercased()
        var out = [String]()
        var seen = Set<String>()
        func add(_ h: String) { let l = h.lowercased(); if l != mineAcct && l != mineDev && seen.insert(l).inserted { out.append(h) } }
        for a in social.contactNodeIds(circleId: circleId) {
            add(a)                                              // account id (contact handle; reaches old-build peers)
            for d in social.deviceNodeIdsFor(accountHex: a) { add(d) }   // their device node ids (actual reach)
            for h in deviceHints(for: a) { add(h) }             // invite-link hints (until their roster lands)
        }
        dialTargetsCache[circleId] = (out, now())
        return out
    }

    // MARK: - Invite device-id hints (roster-bootstrap bridge)

    /// Device ids learned from a contact's INVITE LINK (`?d=` — see InviteHints). They are the only
    /// dialable ids for a device-seed friend until their signed roster (frame 27) arrives, which the
    /// hint itself makes possible: without it neither side can deliver anything to the other.
    private let deviceHintsKey = "haven.contact.deviceHints"
    private var contactDeviceHints: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: deviceHintsKey) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: deviceHintsKey) }
    }
    func recordDeviceHints(accountHex: String, deviceIds: [String]) {
        guard !deviceIds.isEmpty else { return }
        let key = accountHex.lowercased()
        var m = contactDeviceHints
        var cur = m[key] ?? []
        let before = cur
        for d in deviceIds.map({ $0.lowercased() }) where d.count == 64 && !cur.contains(d) { cur.append(d) }
        guard cur != before else { return }   // no-op for already-known hints (fires per hello)
        m[key] = Array(cur.suffix(8))
        contactDeviceHints = m
        dialTargetsCache.removeAll()   // a new hint must be dialable immediately, not in 10s
    }
    private func deviceHints(for accountHex: String) -> [String] {
        contactDeviceHints[accountHex.lowercased()] ?? []
    }
    /// My own device ids to ride an invite link (this device first) — what a scanner dials to
    /// reach me before holding my signed roster.
    func inviteDeviceIds() -> [String] {
        guard let social else { return [] }
        let acct = social.myNodeHex().lowercased()
        var out = [social.myDeviceNodeHex()]
        for d in social.deviceNodeIdsFor(accountHex: acct)
        where d.lowercased() != acct && !out.contains(where: { $0.lowercased() == d.lowercased() }) {
            out.append(d)
        }
        return out
    }

    /// Add a member you can already see in some circle to your own My Circle (default), and
    /// record them as a contact — without needing a fresh invite.
    func addMemberToMyCircle(_ idHex: String) {
        guard let social else { return }
        try? social.addExistingToCircle(circleId: "default", nodeHex: idHex)
        if !ContactsStore.shared.contacts.contains(where: { $0.idHex == idHex }) {
            ContactsStore.shared.add(name: String(idHex.prefix(6)), idHex: idHex)
        }
        persist(); refreshCircles(); syncWithContacts()
    }

    /// Switch to a circle that isn't biometric-locked (used when an unlock is cancelled/fails,
    /// so the user lands somewhere they can actually see instead of being stuck on the lock
    /// screen). No-op if every circle requires biometrics.
    func switchToUnlockedCircle(excluding: String) {
        let cs = CircleSettingsStore.shared
        guard cs.biometricRequired(activeCircleId) else { return }   // already on an open circle
        if let open = circles.first(where: { !cs.biometricRequired($0.id) }) {
            setActiveCircle(open.id)
        }
    }

    /// Leave the active circle (you always keep the default one).
    func leaveActiveCircle() {
        guard activeCircleId != "default", let social else { return }
        social.leaveCircle(id: activeCircleId)
        persist(); refreshCircles()
        activeCircleId = "default"
        refresh()
    }

    // MARK: - Direct messages (a DM is a private 2-person circle)

    /// Non-DM circles for the feed's circle switcher.
    var feedCircles: [CircleInfoFfi] { circles.filter { !$0.id.hasPrefix("dm:") } }
    /// DM circles (shown in Messages, hidden from the feed switcher).
    var dmCircles: [CircleInfoFfi] { circles.filter { $0.id.hasPrefix("dm:") } }

    /// Deterministic DM circle id (identical on both sides). Uses the FULL sorted node ids
    /// — never truncated prefixes — so two different people can never collide into one DM.
    func dmCircleId(with idHex: String) -> String {
        let pair = [myNodeHex, idHex].sorted()
        return "dm:" + pair[0] + "-" + pair[1]
    }

    /// True only if `nodeHex` is one of the full ids encoded in a `dm:` circle id — the guard that stops
    /// a third party from handshaking their way into a private DM. Works for 1:1 (two parties) AND group
    /// DMs (a `dm:` id encoding 3+ sorted members). Old short-prefix ids fail this and get purged.
    func dmCircleAllows(_ circleId: String, _ nodeHex: String) -> Bool {
        let parts = circleId.dropFirst(3).split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return false }
        return parts.contains(nodeHex)
    }

    /// One-time repair for the old broadcast-Hello bug: drop anyone who wrongly ended up
    /// inside a DM circle, so existing threads stop leaking to non-participants.

    /// Start or open a DM with a known contact; returns the dm circle id.
    @discardableResult
    func startDM(with idHex: String, name: String) -> String {
        let id = dmCircleId(with: idHex)
        guard let social else { return id }
        social.createCircle(id: id, name: name)
        try? social.addExistingToCircle(circleId: id, nodeHex: idHex)
        persist(); refreshCircles(); syncWithContacts()
        return id
    }

    /// The deterministic `dm:` id for a group DM with a specific SET of people (sorted hexes including
    /// me) — so picking the same set again reopens the same thread instead of spawning a duplicate.
    func groupDMCircleId(members: [String]) -> String {
        let all = Set(members + [myNodeHex]).sorted()
        return "dm:" + all.joined(separator: "-")
    }

    /// Start or reopen a group DM (1:n) with a subset of people; returns the dm circle id. A group DM is
    /// just a `dm:` circle with 3+ members — every point-to-point/no-broadcast DM rule already applies.
    @discardableResult
    func startGroupDM(members: [String], name: String) -> String {
        let id = groupDMCircleId(members: members)
        guard let social else { return id }
        social.createCircle(id: id, name: name)
        for hex in members where hex != myNodeHex { try? social.addExistingToCircle(circleId: id, nodeHex: hex) }
        persist(); refreshCircles(); syncWithContacts()
        return id
    }

    /// All the OTHER members of a DM/group-DM (everyone but me) — used to ring everyone on a group call.
    func dmMemberHexes(_ circleId: String) -> [String] {
        (social?.contactNodeIds(circleId: circleId) ?? []).filter { $0 != myNodeHex }
    }

    /// The display title of a DM: the other person's name for a 1:1, or a joined list for a group DM
    /// ("Alice, Bob & Carol").
    func dmPartnerName(_ circleId: String) -> String {
        let others = (social?.contactNodeIds(circleId: circleId) ?? []).filter { $0 != myNodeHex }
        let names = others.map { ContactsStore.shared.name(forNodePrefix: $0) ?? "Someone" }.sorted()
        switch names.count {
        case 0: return "Direct message"
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " & " + (names.last ?? "")
        }
    }

    /// The other person's node id in a DM (for placing a call).
    func dmPartnerHex(_ circleId: String) -> String? {
        (social?.contactNodeIds(circleId: circleId) ?? []).first { $0 != myNodeHex }
    }

    // MARK: - Connection approval + block

    /// Approve a pending request: add them as a contact, complete the handshake (add
    /// their bundle, Hello back, back-fill posts), then clear the request.
    func approveConnection(_ req: ConnectionRequest, shareHistory: Bool) {
        guard let social else { return }
        // Approving IS a deliberate re-add: clear any old removal tombstone for them, or their
        // hellos stay silently dropped (isRemovedFromCircle guard) and self-sync re-severs them
        // on every pass — the "removed a friend once, could never re-add them" bug.
        ConnectionsStore.shared.clearCircleRemoval(req.idHex, circleId: "default")
        let vhex = try? social.bundleVerificationHex(bundle: req.bundle)
        ContactsStore.shared.add(name: req.name, idHex: req.idHex, verificationHex: vhex)
        social.createCircle(id: "default", name: "Your circle")
        _ = try? social.addContactBundle(circleId: "default", bundle: req.bundle)
        dialTargetsCache.removeAll()   // the new friend must be dialable now, not when the 10s cache expires
        ContactsStore.shared.setAuthoritativeName(idHex: req.idHex, req.name)
        recordHeard(req.idHex)
        if !shareHistory { ConnectionsStore.shared.setNoHistory(req.idHex) }
        persist(); refreshCircles()
        if let hello = helloPayload(circleId: "default", circleName: "Your circle") {
            sendIroh(0, hello, to: req.idHex); nearbyBroadcast(0, hello)
        }
        if shareHistory {
            // Back-fill your past posts to them (and ensure the shared store has them).
            for env in social.syncEnvelopes(circleId: "default") {
                sendIroh(1, eventPayload("default", env), to: req.idHex)
                Task { await SharedStore.uploadEvent(circleId: "default", env: env) }
            }
            // Make sure the relay also holds the MEDIA for that history ASAP, so the new member can
            // pull it from the relay if the direct transfer doesn't reach them — no fragmented posts.
            backfillMailboxMedia(circleIds: ["default"])
        }
        ConnectionsStore.shared.removePending(req.idHex)
        refresh()
    }

    /// Block a node id: remember it, purge them from every circle (engine), drop them
    /// from contacts. Future posts/messages/calls/handshakes from them are dropped.
    func blockConnection(_ idHex: String) {
        ConnectionsStore.shared.block(idHex)
        social?.blockMember(nodeHex: idHex)
        if let c = ContactsStore.shared.contacts.first(where: { $0.idHex == idHex }) {
            ContactsStore.shared.remove(c)
        }
        ModerationLedger.record(action: "block", subject: idHex, reason: "")
        persist(); refreshCircles(); refresh()
    }

    /// A per-DM "cleared before" watermark (ms). Deleting a conversation records now() here; because a DM's
    /// circle id is deterministic, re-starting it re-syncs the old messages (from the relay / the other
    /// party / your other device) — true network deletion is impossible in P2P. The watermark hides
    /// everything from before the clear, so a re-started DM shows fresh. Persisted so it survives relaunch.
    private var dmClearedBefore: [String: UInt64] {
        get { (UserDefaults.standard.dictionary(forKey: "haven.dm.clearedBefore") as? [String: UInt64]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "haven.dm.clearedBefore") }
    }
    func clearDMBefore(_ circleId: String) { var m = dmClearedBefore; m[circleId] = now(); dmClearedBefore = m }

    /// Messages of a circle (for a DM thread) without disturbing the main feed.
    func messages(in circleId: String) -> [FeedItemFfi] {
        let all = social?.feed(circleId: circleId, nowMs: now(), viewerRetentionSecs: CircleSettingsStore.shared.retentionSecs(circleId)) ?? []
        guard let cutoff = dmClearedBefore[circleId] else { return all }
        return all.filter { $0.createdAt >= cutoff }   // hide messages exchanged before this DM was cleared
    }

    /// Send a text message into a DM circle + broadcast it.
    func sendMessage(to circleId: String, _ body: String) {
        sendMessage(to: circleId, body, media: [], music: nil)
    }

    /// Send a DM with optional media (photos/videos/audio), a song, and optional
    /// disappearing retention (seconds; the message auto-deletes after that).
    func sendMessage(to circleId: String, _ body: String, media: [String], music: TrackRefFfi?, retentionSecs: UInt64? = nil) {
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: media, music: music, retentionSecs: retentionSecs, story: false, muteVideo: false, createdAt: now()) else { return }
        broadcastEvent(circleId, env)
        postTick += 1
        let circle = circleId
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: circle, social: social) }
    }

    /// Edit one of your own messages in a specific (DM) circle.
    func editMessage(in circleId: String, _ id: String, _ body: String) {
        guard let social, let env = try? social.edit(circleId: circleId, target: id, body: body, media: [], music: nil, muteVideo: false, createdAt: now()) else { return }
        broadcastEvent(circleId, env); postTick += 1; refresh()
    }

    /// Delete (retract) one of your own messages in a specific (DM) circle.
    func deleteMessage(in circleId: String, _ id: String) {
        guard let social, let env = try? social.unsend(circleId: circleId, target: id, createdAt: now()) else { return }
        broadcastEvent(circleId, env); postTick += 1; refresh()
    }

    /// Delete a whole DM conversation locally (also clears any old contaminated thread).
    func deleteConversation(_ circleId: String) {
        guard let social, circleId.hasPrefix("dm:") else { return }
        clearDMBefore(circleId)   // watermark so re-syncing (or re-starting) this DM won't restore old messages
        social.leaveCircle(id: circleId)
        persist(); refreshCircles(); refresh()
    }

    /// Node ids in a circle for whom we hold keys (handshake complete).
    func handshaked(in circleId: String) -> [String] {
        social?.contactNodeIds(circleId: circleId) ?? []
    }

    // MARK: - Persistence (so posts + contacts survive restarts and updates)

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-feed.json")
    }
    private func loadPersisted() {
        // Demo mode reseeds a fresh deterministic dataset on every launch, so it must NOT load
        // (or, below, persist) engine state — otherwise the synthetic posts/DMs/contacts compound
        // across the many per-scene launches the screenshot harness makes.
        guard !DemoEnv.isDemo else { return }
        guard let social, let data = try? Data(contentsOf: stateURL) else { return }
        social.importState(data: data)
    }
    private func persist() {
        guard !DemoEnv.isDemo, let social else { return }
        // exportState() serializes the WHOLE engine (100s of ms on a large account) and the atomic
        // write hits disk — both used to run on the main actor after every post/ingest burst and
        // froze the UI. The actor serializes writers so an older export can never clobber a newer one.
        let url = stateURL
        Task.detached(priority: .utility) {
            await StatePersister.shared.persist(social: social, to: url)
        }
    }

    private func bringOnline(seed: Data) {
        // Nearby Bluetooth / Wi-Fi mesh — works even with no internet at all.
        if let social {
            // Display name must be UNIQUE PER DEVICE, not per account: two of my own devices share the
            // account node hex, so an account-hex name made the "smaller name invites" tie-breaker a
            // no-op between them (displayName == displayName) — they NEVER connected over the mesh, which
            // is why local self-sync silently did nothing. Mix in the per-device key hex. (Identity is
            // still proven by the Hello bundle, so this only affects who-invites-whom.)
            let nearbyName = String(social.myNodeHex().prefix(28)) + "-" + String(DeviceKeyStore.deviceNodeHex().prefix(28))
            let nt = NearbyTransport(
                displayName: nearbyName,
                onInbound: { [weak self] data in Task { @MainActor in self?.handleInbound(data, viaNearby: true) } },
                onPeerConnected: { [weak self] in Task { @MainActor in self?.nearbyPeerConnected() } }
            )
            nt.start()
            nearby = nt
            online = true
        }
        // Internet path (iroh + n0 discovery/relays).
        let bridge = InboundBridge { [weak self] fromHex, data in
            Task { @MainActor in self?.handleInbound(data, viaNearby: false, senderDevice: fromHex.isEmpty ? nil : fromHex) }
        }
        listener = bridge
        Task { @MainActor in
            do {
                // TRANSPORT = per-DEVICE seed → unique per-device relay/node id (NEVER the account id). The
                // account id is the sealing/trust anchor + contact handle only. The self-connect leak this
                // re-triggered is defended at the CORE chokepoint now (haven-net Node refuses to open a
                // connection to our OWN node id), so no app-level dial path can loop it.
                // DIAGNOSTIC: capture iroh/noq connection-level logs to Application Support/iroh-trace.log
                // BEFORE the node starts, so we can compare both sides of the multipath handshake.
                if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    initLogging(dir: dir.path)
                }
                let deviceSeed = DeviceKeyStore.deviceAccount().secretSeed()
                let n = try await HavenNode.start(accountSeed: deviceSeed, listener: bridge)
                self.node = n
                self.internetReady = true
                self.online = true
                HavenLog.net("node started id=\(n.nodeIdHex().prefix(10)) account=\(social?.myNodeHex().prefix(10) ?? "?")")
                // The node's reachable address (direct addrs + iroh relay url). If this is empty or has no
                // relay, NOTHING can reach us regardless of identity — that's a network/discovery problem.
                Task {
                    // REACHABILITY PROBE: keep re-reading the ticket (discovery + DERP take a few seconds to
                    // populate) and dump it to a readable file so we can SEE whether this device node has an
                    // internet-reachable path (a DERP relay url in the ticket) at all — the fact that decides
                    // whether relay timeouts are the network or a node-publish bug. Remove once settled.
                    for delay in [0.0, 3.0, 8.0, 20.0] {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        let t = (try? await n.ticket()) ?? ""
                        let report = "nodeId=\(n.nodeIdHex())\naccount=\(social?.myNodeHex() ?? "?")\nticketLen=\(t.count)\nticket=\(t)\n"
                        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                            try? report.write(to: dir.appendingPathComponent("haven-node-ticket.txt"), atomically: true, encoding: .utf8)
                        }
                        HavenLog.net(t.isEmpty ? "node TICKET = EMPTY (no reachable path)" : "node TICKET len=\(t.count)")
                    }
                }
                self.startSyncTimer()
                // Sync soon (discovery needs a moment to resolve), then keep retrying.
                for delay in [1.0, 4.0, 10.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.syncWithContacts()
                    }
                }
            } catch {
                self.nodeError = error.localizedDescription
            }
        }
    }

    // Diagnostics accessors.
    var myNodeIdShort: String { social.map { String($0.myNodeHex().prefix(16)) } ?? "—" }
    var myNodeHex: String { social?.myNodeHex() ?? "" }
    var contactCount: Int { ContactsStore.shared.contacts.count }
    var handshakedCount: Int { social?.contactNodeIds(circleId: activeCircleId).count ?? 0 }
    /// True once we hold this contact's verified public bundle (handshake complete) —
    /// the point at which we can seal to / open from them.
    func isHandshaked(_ idHex: String) -> Bool {
        social?.contactNodeIds(circleId: activeCircleId).contains(idHex) ?? false
    }
    /// True only if we've actually heard from them recently — a real live link, not
    /// just holding (possibly stale) keys.
    func isConnected(_ idHex: String) -> Bool {
        guard let t = lastHeard[idHex] else { return false }
        return Date().timeIntervalSince(t) < 120
    }

    private let lastHeardKey = "haven.lastHeard"
    /// Note that we just heard from a peer (drives both "online" and "last seen"), persisting
    /// it so the last-seen time survives an app restart.
    func recordHeard(_ idHex: String) {
        guard !idHex.isEmpty else { return }
        lastHeard[idHex] = Date()
        UserDefaults.standard.set(lastHeard.mapValues { $0.timeIntervalSince1970 }, forKey: lastHeardKey)
    }
    private func loadLastHeard() {
        guard let raw = UserDefaults.standard.dictionary(forKey: lastHeardKey) as? [String: Double] else { return }
        lastHeard = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }
    func forceSync() { bumpActivity(); ingestPushInbox(); syncWithContacts(); forceSelfSyncNextPoll(); pollMailboxNow() }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        // 10s heartbeat, but the expensive fan-out (hello+roster to every contact, relay re-announce,
        // mesh dials) only runs when due — 20s base, stretching to 60s/120s as the app sits idle. This
        // is the primary device-heat fix: an open-but-idle phone no longer blasts the radio every 20s.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.now() >= self.nextSyncDueMs else { return }
                self.nextSyncDueMs = self.now() + self.adaptiveInterval(base: 20_000)
                self.syncWithContacts()
                // Persistently retry any media an interrupted nearby/iroh transfer left incomplete —
                // re-request direct from contacts AND pull from the circle relay if one exists.
                self.requestMissingMedia()
                RelayHost.shared.meshSyncTick()   // if we host a relay, pull from sibling relays
                RelayMailboxStore.shared.purgeStale()   // GC relays inactive + unseen > 7 days
            }
        }
    }

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// Stale-result guard for the off-main feed rebuild: only the newest refresh may publish.
    private var refreshGeneration: UInt64 = 0
    func refresh() {
        guard let social else { items = []; return }
        // Snapshot the main-actor state, then run the engine read (`feed()` decodes + re-opens every
        // envelope — real CPU) and the O(posts) filter OFF the main actor. This used to run on main
        // on every 20s tick and every ingest burst — the single biggest source of feed jank.
        refreshGeneration += 1
        let gen = refreshGeneration
        let circleId = activeCircleId
        let retention = CircleSettingsStore.shared.retentionSecs(circleId)
        let blocked = ConnectionsStore.shared.blocked
        let removed = ConnectionsStore.shared.removedHexes(inCircle: circleId)   // explicit severances
        let showHidden = HiddenStore.shared.showHidden
        let hidden = HiddenStore.shared.hidden
        let nowMs = now()
        Task.detached(priority: .userInitiated) { [weak self] in
            let raw = social.feed(circleId: circleId, nowMs: nowMs, viewerRetentionSecs: retention)
            // Hide posts from blocked people and from anyone no longer in this circle (removed
            // members), so a removal actually clears their content. My own posts always stay.
            // Prefix-matching because a feed item carries the author's short id.
            let members = social.contactNodeIds(circleId: circleId)
            let filtered = raw.filter { fi in
                // Personal per-post hide (reversible via the "show hidden" toggle).
                if !showHidden && hidden.contains(fi.id) { return false }
                // Explicitly removed/blocked authors are ALWAYS hidden — even if the engine's
                // membership list lags the severance. (Before isMe so a removal can't be defeated.)
                if blocked.contains(where: { $0.hasPrefix(fi.authorShort) }) { return false }
                if removed.contains(where: { $0.hasPrefix(fi.authorShort) }) { return false }
                if fi.isMe { return true }
                // empty list = a genuine solo circle → hide everyone else (incl. re-synced removed)
                return members.contains(where: { $0.hasPrefix(fi.authorShort) })
            }
            await MainActor.run {
                guard let self, self.refreshGeneration == gen, self.activeCircleId == circleId else { return }
                self.items = filtered
                self.sensitiveCache.removeAll()   // a refresh may have ingested new SensitiveFlag events
                self.reportsCache.removeAll()     // …and new Report events
                SpotlightIndex.reindexAll()       // no-op unless the user enabled Spotlight indexing
                // NB: recomputeUnreadDMs() is NOT called here. It decodes a full feed per DM circle
                // on the main actor (real crypto, takes the engine lock), and refresh() fires on
                // every sync tick / ingest — running it here stalled scrolling. It's event-driven
                // instead: bumpUnseen (DM ingest), markThreadRead (read), and configure (startup).
            }
        }
    }

    private var refreshPending = false
    /// Coalesced refresh — collapses a BURST of refresh requests (many media chunks / events arriving during
    /// a sync) into a single feed rebuild ~250ms later, instead of rebuilding the whole feed per item (which
    /// janked the UI). Use this on the high-frequency inbound/sync paths; keep refresh() for user actions.
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            refreshPending = false
            refresh()
        }
    }

    private var persistPending = false
    private var missingMediaPending = false
    /// Coalesced persist — receiving a burst of posts called persist() (serialize + write the whole engine
    /// state) per post. Debounce it so a sync burst writes once, not per event.
    func schedulePersist() {
        guard !persistPending else { return }
        persistPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            persistPending = false
            persist()
        }
    }
    /// Coalesced "pull missing media" — it scans the whole feed; calling it per received event was O(events×items).
    func scheduleRequestMissingMedia() {
        guard !missingMediaPending else { return }
        missingMediaPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            missingMediaPending = false
            requestMissingMedia()
        }
    }

    /// Delivery status for a circle, for the composer's status light. green = a relay holds your content
    /// (or, with no relay, a nearby member has it); yellow = still syncing; red = only on this device.
    func syncStatus(circleId: String) -> PostSyncStatus {
        let relays = RelayMailboxStore.shared.relays(forCircle: circleId)
        // If THIS device HOSTS a relay serving this circle, the mailbox is literally on this machine —
        // you're the relay, so you're synced. (Don't sit on "Syncing…" trying to client-connect to your
        // own in-process relay, which is exactly why the relay-hosting Mac showed perpetual yellow.)
        if RelayHost.shared.serving, !RelayHost.shared.nodeId.isEmpty, relays.contains(RelayHost.shared.nodeId) {
            return .synced
        }
        if !relays.isEmpty {
            // A relay holds posts for offline members. Show yellow ONLY while a flush is ACTIVELY running
            // (a real, transient upload) — NOT whenever the queue is non-empty. A stuck/unreachable item
            // retries silently in the background; it must not pin the badge to "Syncing…" forever (the
            // post already went directly to any online members; the relay copy is best-effort).
            return BackgroundUploader.shared.isFlushing ? .pending : .synced
        }
        if nearby?.hasConnectedPeers == true { return .synced }   // delivered directly to ≥1 nearby member
        // No relay + no nearby peer. Without a relay there's no "uploading" state to resolve — posts go
        // best-effort directly to whoever's reachable over iroh. So online = done-what-we-can (green, no
        // nag); only genuinely OFFLINE is the device-only warning.
        return online ? .synced : .stuck
    }

    // MARK: - Sensitive content (federated SCA flags)

    /// Cache of sensitive media refs per circle (from the shared event log). Cleared on each refresh.
    private var sensitiveCache: [String: Set<String>] = [:]

    /// Media refs flagged sensitive in a circle by ANY member — so a viewer with no Sensitive
    /// Content Analysis (Android/desktop) is still protected once one member with SCA flags it.
    func sensitiveRefs(circleId: String) -> Set<String> {
        if let c = sensitiveCache[circleId] { return c }
        let refs = Set(social?.sensitiveRefs(circleId: circleId) ?? [])
        sensitiveCache[circleId] = refs
        return refs
    }

    /// Flag a media ref as sensitive for the whole circle (called when on-device SCA flags it, or
    /// the sender confirms a flagged send). Deduped, then broadcast like any event so it traverses.
    func flagSensitive(circleId: String, ref: String) {
        guard let social, !sensitiveRefs(circleId: circleId).contains(ref) else { return }
        guard let env = try? social.flagSensitive(circleId: circleId, target: ref, createdAt: now()) else { return }
        sensitiveCache[circleId, default: []].insert(ref)   // optimistic local
        broadcastEvent(circleId, env)
        objectWillChange.send()
    }

    // MARK: - Reports (decentralized moderation)

    /// My ACCOUNT node hex (the contact handle) — the ledger's pseudonymous actor id.
    var myAccountHex: String { social?.myNodeHex() ?? "" }

    /// Apply the "keep my own posts" archive preference live (Settings toggle) + refresh the feed.
    func setKeepOwnPosts(_ on: Bool) { social?.setKeepOwnPosts(on: on); refresh() }

    /// Cache of reports per circle, keyed by the reported event id. Cleared on each refresh.
    private var reportsCache: [String: [String: [ReportFfi]]] = [:]

    /// Reports filed in a circle by ANY member, keyed by the reported event id. Circles have no
    /// owner — every member sees every report and acts with the power they already hold
    /// (hide for themselves, remove the author from their circle, block).
    func reports(circleId: String) -> [String: [ReportFfi]] {
        if let c = reportsCache[circleId] { return c }
        let grouped = Dictionary(grouping: social?.reports(circleId: circleId) ?? [], by: { $0.target })
        reportsCache[circleId] = grouped
        return grouped
    }

    /// File a report against a post/message: hide it locally right away (the reporter never sees it
    /// again), broadcast the sealed report to the whole circle, and append a content-free
    /// identity-vs-identity entry to the developer ledger. Returns the reported author's FULL node
    /// hex (resolved by the core from the event log) so the caller can offer an immediate block.
    @discardableResult
    func report(circleId: String, target: String, reason: String, comment: String) -> String? {
        guard let social, let env = try? social.report(circleId: circleId, target: target, reason: reason, comment: comment, createdAt: now()) else { return nil }
        broadcastEvent(circleId, env)
        HiddenStore.shared.hide(target)
        reportsCache.removeValue(forKey: circleId)
        let author = reports(circleId: circleId)[target]?.first?.author
        ModerationLedger.record(action: "report", subject: author ?? "", reason: reason)
        refresh()
        return author
    }

    /// The current user's own posts — their personal archive.
    var myPosts: [FeedItemFfi] { items.filter { $0.isMe && !$0.story } }
    var myStories: [FeedItemFfi] { items.filter { $0.isMe && $0.story && !$0.unsent && !$0.media.isEmpty } }

    // MARK: - Authoring (seal locally, then broadcast to contacts)

    func post(_ body: String, media: [String] = [], music: TrackRefFfi? = nil, retentionSecs: UInt64? = nil, story: Bool = false, muteVideo: Bool = false) {
        guard let social, let env = try? social.post(circleId: activeCircleId, body: body, media: media, music: music, retentionSecs: retentionSecs, story: story, muteVideo: muteVideo, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); postTick += 1; refresh()
        let circle = activeCircleId
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: circle, social: social) }
    }

    /// Post to a SPECIFIC circle (used by the scheduler when a queued post fires — the target
    /// circle may not be the active one). Same seal → broadcast → mailbox-backup path as `post`.
    func postScheduled(circleId: String, body: String, media: [String]) {
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: media, music: nil, retentionSecs: nil, story: false, muteVideo: false, createdAt: now()) else { return }
        broadcastEvent(circleId, env); postTick += 1
        if circleId == activeCircleId { refresh() }
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: circleId, social: social) }
    }

    /// Post text to a specific circle (used by App Intents with a circle filter).
    func post(_ body: String, toCircle circleId: String) {
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: [], music: nil, retentionSecs: nil, story: false, muteVideo: false, createdAt: now()) else { return }
        broadcastEvent(circleId, env); postTick += 1; refresh()
    }

    /// Post a full-screen story to the active circle — auto-expires after 24h (retention).
    /// Stories can carry a caption (the post body) and a song (played in the viewer).
    func postStory(media: [String], caption: String = "", music: TrackRefFfi? = nil) {
        post(caption, media: media, music: music, retentionSecs: 86_400, story: true)
    }

    /// Stories in the active circle (full-screen, ephemeral), newest first.
    var stories: [FeedItemFfi] { items.filter { $0.story && !$0.unsent && !$0.media.isEmpty } }

    /// Stories grouped by author — each user's stories play together, oldest→newest,
    /// and the groups are ordered by who posted most recently.
    var groupedStories: [(author: String, items: [FeedItemFfi])] {
        Dictionary(grouping: stories) { $0.authorShort }
            .map { (author: $0.key, items: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { ($0.items.last?.createdAt ?? 0) > ($1.items.last?.createdAt ?? 0) }
    }
    /// All stories in grouped order (what the viewer pages through).
    var groupedStoriesFlat: [FeedItemFfi] { groupedStories.flatMap { $0.items } }
    /// The index in the flat list where a given group starts.
    func storyStartIndex(forGroup g: Int) -> Int {
        groupedStories.prefix(g).reduce(0) { $0 + $1.items.count }
    }
    /// The regular feed (stories live in the tray, not the main list).
    var feedItems: [FeedItemFfi] { items.filter { !$0.story } }
    func comment(_ id: String, _ body: String, _ media: [String] = []) {
        guard let social, let env = try? social.comment(circleId: activeCircleId, target: id, body: body, media: media, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); refresh()
    }
    func react(_ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(circleId: activeCircleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); reactionTick += 1; refresh()
    }
    /// Remove my own reaction (emoji) from a post/comment in the active circle.
    func unreact(_ id: String, _ emoji: String) {
        guard let social, let env = try? social.unreact(circleId: activeCircleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); reactionTick += 1; refresh()
    }
    /// React to a message in a specific (DM) circle.
    func reactMessage(in circleId: String, _ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(circleId: circleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(circleId, env); reactionTick += 1; refresh()
    }
    /// Remove my own reaction from a message in a specific (DM) circle.
    func unreactMessage(in circleId: String, _ id: String, _ emoji: String) {
        guard let social, let env = try? social.unreact(circleId: circleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(circleId, env); reactionTick += 1; refresh()
    }
    /// Comment on a post in a specific circle (used by the deep-link post viewer).
    func commentMessage(in circleId: String, _ id: String, _ body: String, _ media: [String] = []) {
        guard let social, let env = try? social.comment(circleId: circleId, target: id, body: body, media: media, createdAt: now()) else { return }
        broadcastEvent(circleId, env); refresh()
    }
    /// Auto-save freshly-received media to Photos (Haven ▸ Received) when "Save to Photos" is on.
    func autoSaveReceived(_ ref: String) {
        if let item = MediaStore.shared.item(ref) { PhotoSaver.saveIfEnabled(item, to: .received, circleId: activeCircleId) }
    }

    /// Whether a DM's partner is currently reachable, and when we last heard from them.
    func dmPresence(_ circleId: String) -> (online: Bool, lastSeen: Date?) {
        guard let hex = dmPartnerHex(circleId) else { return (false, nil) }
        return (isConnected(hex), lastHeard[hex])
    }
    func edit(_ id: String, _ body: String, media: [String] = [], music: TrackRefFfi? = nil, muteVideo: Bool = false) {
        guard let social, let env = try? social.edit(circleId: activeCircleId, target: id, body: body, media: media, music: music, muteVideo: muteVideo, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); refresh()
        let circle = activeCircleId
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: circle, social: social) }
    }
    func unsend(_ id: String) {
        guard let social, let env = try? social.unsend(circleId: activeCircleId, target: id, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env); refresh()
    }

    // MARK: - Wire protocol  [type][payload]: 0 Hello, 1 Event, 3 MediaReq, 5 MediaChunk
    //   Hello payload = [LP circleId][LP circleName][LP bundle][signed profile]
    //   Event payload = [LP circleId][sealed envelope]

    /// On add / online / timer: for every circle, send each member our Hello + that
    /// circle's posts, so the circle forms on their side and back-fills.
    private var lastHistoryResendMs: UInt64 = 0
    private var lastMediaBackfillMs: UInt64 = 0
    func syncWithContacts() {
        guard let social else { return }
        // Re-blasting our ENTIRE history (every post → every contact) on every 20s tick flooded the
        // network with hundreds of thousands of frames (drowning real delivery). The hello goes out every
        // tick (cheap, and it's what bootstraps + keeps connections warm); the full history re-send is
        // throttled to occasional — offline members get history from the mailbox/relay, and a freshly-added
        // contact is back-filled directly by the share-history flow, not this periodic sweep.
        let nowMs = now()
        // Proactively announce MY device roster to every contact each cycle (small, signed, idempotent —
        // the receiver version-checks + dedups). Device-id transport means a friend can only AUTHORIZE +
        // dial my specific device once they hold my roster; without this it rode only rare circle
        // key-commits, so a freshly-flipped device stayed "forbidden" at friends' relays. Type 27.
        let rosterWire = social.myDeviceRosterWire()
        // The nearby broadcast is a single LOCAL fan-out (not × contacts) and is the own-device
        // (iPhone↔Mac) sync path, so it stays every cycle.
        let resendHistory = nowMs - lastHistoryResendMs > 180_000   // ~3 min; gates the WHOLE history re-send
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            // syncEnvelopes RE-SEALS every one of my events — expensive. Calling it for every circle on every
            // 20s tick pinned the main thread → iOS watchdog SIGKILL (macOS has no watchdog, so it was fine
            // there). Only do it on the throttled cadence: new events reach devices immediately via
            // broadcastEvent, a freshly-connected sibling gets full history via nearbyPeerConnected, and this
            // periodic full re-broadcast is just redundancy.
            let envs = resendHistory ? social.syncEnvelopes(circleId: circle.id) : []
            // The default circle bootstraps with ALL QR contacts (newly-added ones aren't
            // members yet — this is how we get their bundle). Other circles target members.
            var targets = Set(dialTargets(circle.id))   // account id (handle) + device ids (actual reach)
            if circle.id == "default" {
                for c in ContactsStore.shared.contacts { targets.insert(c.idHex) }
            }
            for nodeHex in targets {
                sendIroh(0, hello, to: nodeHex)
                if !rosterWire.isEmpty { sendIroh(27, rosterWire, to: nodeHex) }   // announce my device roster
                // Per-contact history re-send is the flood — throttle it (offline members get history
                // from the mailbox; new contacts via the share-history flow).
                if !envs.isEmpty, ConnectionsStore.shared.sharesHistory(nodeHex) {
                    for env in envs { sendIroh(1, eventPayload(circle.id, env), to: nodeHex) }
                }
            }
            // Bootstrap the device-id exchange over the RELAY. When a friend flips to the per-device
            // transport their ACCOUNT id stops resolving, so a direct send can't reach them to deliver my
            // roster — but their relay node (== their device messaging endpoint, one-endpoint design) IS
            // reachable. Push my roster there so the relay-hosting friend learns + authorizes my device id
            // (that's what lets me then read their mailbox). Skip my own hosted relay.
            if !rosterWire.isEmpty {
                // Exclude OUR OWN ids: sending to our device id (RelayHost.nodeId) or our account id is a
                // self-dial. A stale relay-list entry == our account id (pre-device-seed leftover) that
                // resolves back to us sends iroh path discovery into the runaway loop (the 100GB leak). We
                // never need to announce our roster to ourselves anyway.
                let myAcct = AccountStore.currentNodeHex().lowercased()
                let myDev = RelayHost.shared.nodeId.lowercased()
                for relayHex in RelayMailboxStore.shared.relays(forCircle: circle.id) {
                    let h = relayHex.lowercased()
                    if h == myDev || h == myAcct || h.hasPrefix("s3:") { continue }
                    sendIroh(27, rosterWire, to: relayHex)
                }
            }
            // Only the OPEN default circle broadcasts its handshake to nearby. Custom + DM
            // circles must NOT — a broadcast Hello let any nearby contact handshake their way
            // into a circle they were never added to (membership contamination).
            if circle.id == "default" { nearbyBroadcast(0, hello) }
            // (Own-device nearby catch-up of events moved below — every cycle, off-main.)
            // Mesh: let a relay carry our handshake to members we can't reach directly.
            originateRelay(dests: Array(targets), inner: frame(0, hello))
        }
        if resendHistory { lastHistoryResendMs = nowMs }
        // Own-device catch-up over NEARBY, every cycle: a sibling that missed the instant broadcastEvent
        // (e.g. nearby was reconnecting when I posted) shows my latest post within a cycle (~20s) instead of
        // waiting for the 3-min full re-send. Re-seal (the expensive part) runs OFF the main thread; only the
        // cheap fan-out hops back to main. Capped to recent events so it isn't a congestion/CPU sink. The
        // receiver dedups known events, so re-broadcasting is harmless.
        // Own-device nearby catch-up RE-SEALS up to 50 events per circle (a hybrid signature each) —
        // real CPU. Only worth doing when a nearby sibling is actually connected to receive it;
        // otherwise it was pure heat every 20s on a phone with no Mac nearby. When no nearby peer is
        // present the internet + mailbox paths already carry everything.
        if nearby?.hasConnectedPeers == true {
            let cidsForNearby = circles.map(\.id)
            Task.detached(priority: .utility) { [weak self, social] in
                var work: [(String, [Data])] = []
                for cid in cidsForNearby {
                    // export_recent_envelopes = ALL authors (mine + received), so a sibling catches up on friends'
                    // posts/DMs I received too — not just my own (which syncEnvelopes was limited to).
                    let envs = social.exportRecentEnvelopes(circleId: cid, limit: 50)
                    if !envs.isEmpty { work.append((cid, envs)) }
                }
                await MainActor.run {
                    guard let self else { return }
                    for (cid, envs) in work { for env in envs { self.nearbyBroadcast(1, self.eventPayload(cid, env)) } }
                }
            }
        }
        reannounceOwnRelay()   // frame 19 was a one-shot at relay start; re-emit so peers reliably learn it
        // Push MY media up to every circle relay periodically. The nearby request/response (frame 3→5) was
        // unreliable (0 chunks served), so instead each device durably mirrors its own media to the relays
        // it knows — including a sibling's hosted relay — and the other side reads it locally via poll OWN.
        // backup() is idempotent (skips blobs already on a relay), so this just fills gaps. Throttled.
        if nowMs - lastMediaBackfillMs > 120_000 {
            lastMediaBackfillMs = nowMs
            backfillMailboxMedia(circleIds: circles.map { $0.id })
        }
        // Only push media over nearby when a sibling is actually connected (else it's idle work).
        if nearby?.hasConnectedPeers == true { pushOwnMediaNearby() }
        requestMissingMedia()
    }

    /// Re-emit EVERY relay this device knows for each circle (nearby + direct + mesh), WITHOUT
    /// adoptRelayNode's heavy backfill. frame 19 used to fire only once (relay start / adopt), so a
    /// sibling/friend that wasn't reachable at that instant never learned the relay — which is why
    /// the iPhone "sees the Mac nearby but won't show its relay", and why an adopted EXTERNAL relay
    /// (NAS docker daemon) never reached circle members at all: only the self-hosted relay was ever
    /// re-announced. Android already re-announces all circle relays per hello — this is that parity.
    /// Cheap (one small sealed announce per relay per circle), so it's safe every sync tick.
    func reannounceOwnRelay() {
        guard let social else { return }
        for ci in circles {
            // Active relays for the circle (adopted external + all-circles default) plus the relay
            // THIS device hosts. Skip s3: pseudo-relays — those share via the S3-config frame, and
            // handleRelayNode expects a 64-hex node id.
            // ONLY announce relays WE have proof of life for (a successful op within 5 min) or the
            // one we host. Re-announcing everything we'd ever LEARNED turned dead relay ids into a
            // permanent echo: every member kept re-broadcasting them, receivers reactivated them
            // (announce = "the owner says it's back"), and media paths burned timeouts on ghosts.
            // A live relay is re-proven constantly by the 20s mailbox poll, so this gates nothing real.
            var hexes = RelayMailboxStore.shared.relays(forCircle: ci.id).filter {
                !$0.hasPrefix("s3:") && RelayHealth.shared.provenAlive($0, withinMs: 300_000)
            }
            if RelayHost.shared.serving, RelayHost.shared.nodeId.count == 64,
               !hexes.contains(RelayHost.shared.nodeId) {
                hexes.append(RelayHost.shared.nodeId)
            }
            guard !hexes.isEmpty else { continue }
            let members = dialTargets(ci.id)
            for hex in hexes where hex.count == 64 {
                let data = relayAnnounceData(hex)
                guard let sealed = try? social.sealCircleMedia(circleId: ci.id, data: data) else { continue }
                var p = Data(); lpAppend(&p, Data(ci.id.utf8)); p.append(sealed)
                nearbyBroadcast(19, p)
                for m in members { sendIroh(19, p, to: m) }
                originateRelay(dests: members, inner: frame(19, p))
            }
        }
    }

    /// The frame-19 announce body for one relay: the legacy bare 64-hex node id, or — once the
    /// relay's plain-HTTP interface is known — JSON `{"node":hex,"urls":[…],"token":…}` so members
    /// also learn the reliable cross-NAT media path. Sealed to the circle either way; a legacy
    /// receiver that expects a bare hex simply ignores the JSON form (wrong length).
    private func relayAnnounceData(_ hex: String) -> Data {
        // Always carry the relay's adoption timestamp so receivers can LWW a stale tombstone. Use the
        // JSON form whenever we have EITHER an HTTP interface or a non-zero adoption stamp; a legacy
        // receiver ignores JSON it can't parse as a bare hex (wrong length), so this stays compatible.
        let addedAt = RelayMailboxStore.shared.addedAtMs(hex)
        let http = RelayMailboxStore.shared.httpInterface(hex)
        if http != nil || addedAt > 0 {
            var obj: [String: Any] = ["node": hex, "addedAt": addedAt]
            if let http { obj["urls"] = http.urls; obj["token"] = http.token }
            if let json = try? JSONSerialization.data(withJSONObject: obj) { return json }
        }
        return Data(hex.utf8)
    }

    /// A nearby peer just connected over Bluetooth/Wi-Fi — say hello + back-fill (all circles).
    private func nearbyPeerConnected() {
        guard let social else { return }
        nearbyActive = true
        bumpActivity()   // a peer just appeared → sync tight for the catch-up burst
        reannounceOwnRelay()   // a freshly-connected sibling/friend immediately learns this host's relay
        // FIRST: offer this device's sealed self-sync slot to nearby peers. ONLY our own devices (same
        // seed) can open it — it's how a linked Mac/phone bootstraps circles + profile + posts LOCALLY,
        // with no relay or S3 at all (the local "handshake" sync). Sent before the post events below so
        // the receiver learns the circles before their posts arrive.
        if let slot = SelfSyncCoordinator.shared.sealedLocalSlot(social: social) { nearbyBroadcast(23, slot) }
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            if circle.id == "default" { nearbyBroadcast(0, hello) }   // only the open circle broadcasts handshake
            // DMs + RECEIVED events included — export_recent_envelopes re-broadcasts ALL authors' recent
            // events (not just mine), so a freshly-connected sibling catches up on friends' posts/DMs I
            // received too. Sealed, so a nearby non-member just drops it.
            for env in social.exportRecentEnvelopes(circleId: circle.id, limit: 150) { nearbyBroadcast(1, eventPayload(circle.id, env)) }
        }
        pushOwnMediaNearby(freshPeer: true)   // a newly-connected sibling has nothing — push it my media now
        refresh()
    }

    /// A self-sync slot arrived from another of the user's OWN devices over the nearby mesh (only our
    /// own seed can have produced one we can open). Merge it — this is what makes a linked device's
    /// circles/profile/posts appear locally without any relay.
    private func handleNearbySelfSync(_ payload: Data) {
        if SelfSyncCoordinator.shared.ingestPeerSlot(payload, social: social) {
            refreshCircles()   // a newly-synced circle must enter the polled list + pull its history
        }
    }

    private func helloPayload(circleId: String, circleName: String) -> Data? {
        guard let social else { return nil }
        let myName = ProfileStore.shared.displayName.isEmpty ? "Someone" : ProfileStore.shared.displayName
        var p = Data()
        lpAppend(&p, Data(circleId.utf8))
        lpAppend(&p, Data(circleName.utf8))
        lpAppend(&p, social.myBundle())
        // rest = signed business card (name + bio + link)
        p.append(social.mySignedProfile(name: myName, bio: ProfileStore.shared.bio, link: ProfileStore.shared.link,
                                        avatar: ProfileStore.shared.avatarBase64, emoji: ProfileStore.shared.emoji))
        return p
    }

    /// Re-send my handshake (which carries my signed profile card) to everyone I'm connected to,
    /// so a profile change — new photo, emoji, name, bio, or link — reaches them without waiting
    /// for a fresh handshake. Call this whenever the user edits their profile.
    func rebroadcastProfile() {
        guard let social else { return }
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            for hex in dialTargets(circle.id) { sendIroh(0, hello, to: hex) }
        }
    }

    private func eventPayload(_ circleId: String, _ env: Data) -> Data {
        var p = Data(); lpAppend(&p, Data(circleId.utf8)); p.append(env); return p
    }

    private func broadcastEvent(_ circleId: String, _ env: Data) {
        bumpActivity()   // I just posted/messaged → keep sync tight
        let payload = eventPayload(circleId, env)
        let members = social?.contactNodeIds(circleId: circleId) ?? []
        // Build the push banner once: title = my name, body keyed to the circle. We seal it
        // *per recipient* below so the relay only ever forwards ciphertext.
        let myName = ProfileStore.shared.displayName.isEmpty ? "Someone" : ProfileStore.shared.displayName
        let isDM = circleId.hasPrefix("dm:")
        let circleName = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        let body = isDM ? "Sent you a message" : "Posted in \(circleName)"
        // `c` lets the recipient's NSE redact the banner if *they've* locked this circle.
        let notifJSON = (try? JSONSerialization.data(withJSONObject: ["t": myName, "b": body, "c": circleId])) ?? Data()
        let eventB64 = env.base64EncodedString()   // the sealed circle event, for push-inline sync
        PushManager.shared.syncSelf(event: eventB64)   // multi-device: deliver to my own other devices
        // Deliver the event to each member's DEVICE node ids (+ account id for old-build peers) — the account
        // id alone no longer resolves under device-seed. Notification sealing below stays per-ACCOUNT recipient.
        for t in dialTargets(circleId) { sendIroh(1, payload, to: t) }
        for nodeHex in members {
            // Seal + SIGN the banner to this recipient; the relay forwards it blind, their NSE
            // decrypts AND verifies it really came from us (audit H2).
            let sealed = notifJSON.isEmpty ? nil : try? social?.sealSignedNotification(recipientNodeHex: nodeHex, data: notifJSON)
            PushManager.shared.wake(nodeHex, ciphertext: sealed?.base64EncodedString(), event: eventB64)
        }
        nearbyBroadcast(1, payload)   // sealed — only members + the user's own devices open it, so a DM syncs to your other device too
        originateRelay(dests: members, inner: frame(1, payload))   // reach members behind a relay
        // Store-and-forward mailbox upload, queued so it finishes in the background if the user
        // leaves the app before it lands (and is retried on next launch). The epoch HEAD (my roster
        // + current key commit) rides along: with the full-history backfill throttled to daily, a
        // relay-only peer could otherwise pull this event long before the commit that opens it (it
        // would sit in their pending-epoch buffer). Cheap — the commit is cached until the epoch or
        // recipient set changes, and the persisted seen-set dedupes the re-upload.
        if let social {
            for head in social.exportEpochHead(circleId: circleId) {
                BackgroundUploader.shared.enqueue(circleId: circleId, env: head)
            }
        }
        BackgroundUploader.shared.enqueue(circleId: circleId, env: env)
        persist()   // we just authored something — save it
    }

    /// Poll the shared mailbox and ingest any envelopes uploaded while we (or the sender)
    /// were offline. This is what delivers posts without both ends being online at once.
    private var lastSelfSyncMs: UInt64 = 0
    /// Force the next poll to run self-sync even if inside the throttle window (device link, foreground).
    func forceSelfSyncNextPoll() { lastSelfSyncMs = 0 }

    func pollMailboxNow() {
        guard social != nil else { return }
        // Multi-device self-sync (profile, pins, contacts, read watermarks, circles) syncs the user's
        // OWN devices and changes rarely — running its full LIST+FETCH+merge on every 30s poll was
        // constant idle CPU/radio for no benefit. Throttle to ~2 min (convergence in 2 min instead of
        // 30s is imperceptible); explicit triggers call forceSelfSyncNextPoll to bypass it.
        let nowMs = now()
        if nowMs - lastSelfSyncMs > 120_000 {
            lastSelfSyncMs = nowMs
            selfSyncAndPull()
        } else {
            Task { @MainActor in await self.pullMailbox(circleIds: self.circles.map { $0.id }) }
        }
    }

    private func selfSyncAndPull() {
        Task { @MainActor in
            if await SelfSyncCoordinator.shared.sync(social: self.social) {
                // refreshCircles() — NOT just refresh() — so a circle synced from another of MY devices
                // actually enters the polled list; otherwise its mailbox is never pulled and the linked
                // device shows the circle but none of its posts.
                self.persist(); self.refreshCircles(); self.refresh()
                // Pull that circle's history from its relay now (it has structure but no posts yet),
                // and push my own already-posted content up so my other device can pull it too.
                let synced = self.circles.map(\.id)
                self.backfillMailbox(circleIds: synced)
                await self.pullMailbox(circleIds: synced)
            }
        }
        Task { @MainActor in await self.pullMailbox(circleIds: self.circles.map { $0.id }) }
    }

    /// Pull every sealed post/DM waiting in the given circles' relay mailboxes and ingest them.
    @MainActor func pullMailbox(circleIds ids: [String]) async {
        guard let social, ids.contains(where: { SharedStore.hasMailbox($0) }) else { return }
        let msgs = await SharedStore.pollMailbox(circleIds: ids)
        guard !msgs.isEmpty else { return }
        // receive() does real crypto per envelope; a backlog drain used to run the whole loop on
        // the main actor and freeze the UI for the duration. Ingest the batch off-main, then hop
        // back once with the circles that changed.
        let ingested: [String] = await Task.detached(priority: .utility) {
            var changed: [String] = []
            for (cid, env) in msgs where (try? social.receive(circleId: cid, envelope: env)) == true {
                changed.append(cid)
            }
            return changed
        }.value
        // Persist whenever we ran ANY receive: an envelope that only BUFFERED (event arrived before
        // its key commit / the sender's roster) mutated the now-durable pending_epoch buffer, and the
        // mailbox already marked its key seen at fetch time — so if we don't save the engine state
        // here, a kill before the key arrives loses the buffered event forever (the exact
        // random-non-delivery failure). Cheap: msgs is only non-empty when the mailbox served bytes.
        persist()
        guard !ingested.isEmpty else { return }
        bumpActivity()   // a message arrived → keep sync tight while the conversation is live
        var dmIngested = false
        for cid in ingested {
            notifyNewest(in: cid)
            if cid.hasPrefix("dm:") { dmIngested = true } else { bumpUnseen(cid) }
        }
        if dmIngested { recomputeUnreadDMs() }   // once for the whole batch, not per DM circle
        refresh(); requestMissingMedia()
    }

    /// Drain events that arrived inline in a push (stashed by the NSE) and ingest them — silent
    /// sync with no mailbox round-trip. We don't carry the circle id in cleartext, so we try each
    /// circle until one opens the envelope (a wrong circle just ignores it).
    func ingestPushInbox() {
        guard let social else { return }
        let envs = SharedInbox.drain()
        guard !envs.isEmpty else { return }
        let ids = circles.map { $0.id }
        // Trying every circle per envelope multiplies the receive() crypto — run the whole batch
        // off-main and apply the result in one main-actor hop (same shape as pullMailbox).
        Task.detached(priority: .utility) { [weak self] in
            var ingested: [String] = []
            for env in envs {
                for cid in ids where (try? social.receive(circleId: cid, envelope: env)) == true {
                    ingested.append(cid); break
                }
            }
            guard !ingested.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                for cid in ingested { self.notifyNewest(in: cid); self.bumpUnseen(cid) }
                self.persist(); self.refresh(); self.requestMissingMedia()
            }
        }
    }

    // Length-prefixed field helpers ([u16 LE len][bytes]).
    private func lpAppend(_ d: inout Data, _ field: Data) {
        let n = UInt16(field.count)
        d.append(UInt8(n & 0xff)); d.append(UInt8(n >> 8)); d.append(field)
    }
    private func lpRead(_ d: Data, _ off: inout Int) -> Data? {
        guard d.count >= off + 2 else { return nil }
        let s = d.startIndex
        let n = Int(UInt16(d[s + off]) | UInt16(d[s + off + 1]) << 8)
        off += 2
        guard d.count >= off + n else { return nil }
        let field = d.subdata(in: (s + off)..<(s + off + n))
        off += n
        return field
    }

    private func frame(_ type: UInt8, _ payload: Data) -> Data {
        var f = Data([type]); f.append(payload); return f
    }
    private func sendIroh(_ type: UInt8, _ payload: Data, to nodeHex: String) {
        guard let node else { return }
        let f = frame(type, payload)
        // Option 1 transport edge: callers pass an ACCOUNT id (so all the social/allow logic stays on
        // account ids); here we expand to that account's authorized DEVICE ids (or the account id itself
        // for a pre-multidevice peer) and deliver to each, so the post reaches whichever device is online.
        Task { [weak self] in
            // Expand to device ids OFF the main thread — this crosses the FFI, and on a busy sync cycle
            // sendIroh fires dozens of times; doing it (and the send) on a background Task keeps the feed
            // scroll smooth. (Per-send logging was removed: building those strings on every send was itself
            // measurable main-thread churn during sync.)
            var targets = self?.social?.deviceNodeIdsFor(accountHex: nodeHex) ?? [nodeHex]
            // Invite-link dial hints bridge the roster bootstrap: until this contact's signed
            // roster lands, their account id resolves to no node — the hint is the only real id.
            if let hints = self?.deviceHints(for: nodeHex) {
                for h in hints where !targets.contains(where: { $0.lowercased() == h }) { targets.append(h) }
            }
            var anyOk = false
            var lastErr: String?
            for t in targets {
                do { try await node.sendToNode(nodeIdHex: t, payload: f); anyOk = true }
                catch { lastErr = error.localizedDescription }
            }
            await MainActor.run { self?.lastSendError = anyOk ? nil : lastErr }
        }
    }
    private func nearbyBroadcast(_ type: UInt8, _ payload: Data) {
        nearby?.broadcast(frame(type, payload))
    }

    /// `senderDevice` = the AUTHENTICATED transport id the frame arrived from (nil for nearby /
    /// relay-unwrapped frames). A direct HELLO teaches us a dialable device id for its account —
    /// the reply-path bootstrap (an invitee holds no invite hints for the initiator).
    private func handleInbound(_ data: Data, viaNearby: Bool, senderDevice: String? = nil) {
        guard let type = data.first else { return }
        if viaNearby { nearbyActive = true } else { internetActive = true }
        let payload = Data(data.dropFirst())
        // Frames that lead with a 64-char sender id (media req + calls + camera state): drop if
        // blocked (audit F4 — 22 was previously missing from this list).
        if [3, 10, 11, 12, 13, 15, 16, 17, 18, 21, 22].contains(type) {
            let head = String(data: payload.prefix(64), encoding: .utf8) ?? ""
            if head.count == 64, ConnectionsStore.shared.isBlocked(head) { return }
        }
        switch type {
        case 0: handleHello(payload, viaNearby: viaNearby, senderDevice: senderDevice)
        case 1: handleEvent(payload)
        case 3: handleMediaRequest(payload)
        case 5: handleMediaChunk(payload)
        case 9: handleRelay(payload)
        case 10: CallManager.shared.handleInvite(payload)
        case 11: CallManager.shared.handleAccept(payload)
        case 12: CallManager.shared.handleHangup(payload)
        case 13: CallManager.shared.handleAudio(payload)
        case 14: handleBucketConfig(payload)
        case 15: CallManager.shared.handleVideo(payload)
        case 16: CallManager.shared.handleOffer(payload)    // WebRTC SDP offer
        case 17: CallManager.shared.handleAnswer(payload)   // WebRTC SDP answer
        case 18: CallManager.shared.handleIce(payload)      // WebRTC ICE candidate
        case 19: handleRelayNode(payload)                   // circle relay/mailbox node id
        case 20: handlePresignBootstrap(payload)            // pre-signed S3 pool bootstrap url
        case 21: CallManager.shared.handleGroupInvite(payload)  // WebRTC mesh group-call invite
        case 22: CallManager.shared.handleCameraState(payload)  // peer toggled their camera on/off
        case 23: handleNearbySelfSync(payload)                  // another of MY devices' self-sync slot (local, relay-free)
        case 24: handleDeviceEnrollmentRequest(payload)         // a device of mine asks to be authorized with its own key
        case 25: handleDeviceEnrollmentGrant(payload)           // the primary granted my device a credential
        case 26: handleRequestFullState(payload)                // a newly-linked device of mine asks for my full state
        case 27: handleDeviceRosterAnnounce(payload)            // a friend's signed device roster (device-id auth/dial)
        default: break
        }
    }

    /// A friend announced their signed device roster (type 27). Ingest it so we learn their DEVICE node
    /// ids, then refresh our relay's circle authorization — otherwise a friend on the per-device transport
    /// connects with a device id our relay's member list doesn't recognize and every fetch is "forbidden".
    private func handleDeviceRosterAnnounce(_ payload: Data) {
        guard let social else { return }
        if social.ingestRosterWire(wire: payload) {
            RelayHost.shared.authorizeMembership()   // authorize the newly-learned device ids at our relay
            dialTargetsCache.removeAll()             // newly-learned device ids must be dialable now
        }
    }

    /// Ask the device that holds the master seed (over the local mesh) to authorize THIS device with its
    /// own key. The grant comes back as a type-25 message carrying our credential.
    func requestDeviceEnrollment() {
        var p = Data()
        lpAppend(&p, DeviceKeyStore.deviceBundle())
        lpAppend(&p, Data(DeviceKeyStore.deviceName.utf8))
        lpAppend(&p, Data(DeviceKeyStore.deviceNodeHex().utf8))
        nearbyBroadcast(24, p)
        if let hex = social?.myNodeHex() { sendIroh(24, p, to: hex) }  // also try the iroh path
        let connected = nearby?.hasConnectedPeers ?? false
        NotificationManager.shared.notify(
            title: connected ? "Asked your primary device" : "Looking for your primary device…",
            body: connected ? "Pulling your profile + posts…"
                            : "Keep your primary device (iPhone) open on the same Wi-Fi/Bluetooth.",
            dedupeKey: "device-resync-request", persist: false)   // deliberate flow — may recur later
    }

    /// Turn on device-key multi-device on THIS (primary) device — register the account key as the
    /// primary "device #0". Only the master-seed holder can. Idempotent.
    func enableDeviceRoster() {
        guard let seed = AccountStore.storedSeed(),
              let bundle = (try? Account.fromSeed(seed: seed))?.publicBundle() else { return }
        DeviceRosterManager.shared.enable(social: social, accountSeed: seed, accountBundle: bundle, accountHex: AccountStore.currentNodeHex())
    }

    /// Step this device down from being the primary (master-key) device — for when the wrong device
    /// claimed the role. It then shows the link button so it can be linked to the real primary.
    func stepDownAsPrimary() {
        DeviceRosterManager.shared.stepDown()
    }

    /// Revoke a linked device (primary only). It stops being a recipient of future circle key commits.
    func revokeDevice(_ nodeHex: String) {
        guard let seed = AccountStore.storedSeed() else { return }
        DeviceRosterManager.shared.revoke(nodeHex, social: social, accountSeed: seed)
    }

    /// I hold the master seed → I can authorize. Issue the requesting device a credential, add it to my
    /// signed roster, and broadcast the grant back. (The requester keeps working as-is; the seed-drop
    /// that makes revocation final is a separate, guarded step.)
    private func handleDeviceEnrollmentRequest(_ payload: Data) {
        guard let seed = AccountStore.storedSeed() else { return }   // only the seed-holder can authorize
        var off = 0
        guard let bundle = lpRead(payload, &off),
              let nameData = lpRead(payload, &off),
              let hexData = lpRead(payload, &off) else { return }
        let name = String(data: nameData, encoding: .utf8) ?? "Device"
        let hex = String(data: hexData, encoding: .utf8) ?? ""
        guard !hex.isEmpty, hex != DeviceKeyStore.deviceNodeHex() else { return }   // not my own device's request
        guard let accountBundle = (try? Account.fromSeed(seed: seed))?.publicBundle() else { return }
        let accountHex = AccountStore.currentNodeHex()
        DeviceRosterManager.shared.enable(social: social, accountSeed: seed, accountBundle: accountBundle, accountHex: accountHex)
        guard let cred = DeviceRosterManager.shared.addLinkedDevice(bundle: bundle, nodeHex: hex, name: name, social: social, accountSeed: seed) else { return }
        var grant = Data()
        lpAppend(&grant, Data(hex.utf8))
        lpAppend(&grant, cred)
        sendToMyDevices(25, grant)
        // CRITICAL: linking must SYNC STATE, not just hand over a credential. Push my full account state
        // (profile photo/bio/link + circles + posts) to the newly-linked device right now, over both
        // transports (the request reached me, but a nearby-only response may never get back).
        pushFullStateToMyDevices()
    }

    /// The primary granted my device its credential. Store it, then ASK the primary to send me its full
    /// state (so my profile photo/bio/link + posts populate), and refresh. (Engine still runs under the
    /// shared seed for now — the seed-drop that finalizes revocation is a later, guarded step.)
    private func handleDeviceEnrollmentGrant(_ payload: Data) {
        var off = 0
        guard let targetHexData = lpRead(payload, &off), let cred = lpRead(payload, &off) else { return }
        let targetHex = String(data: targetHexData, encoding: .utf8) ?? ""
        guard targetHex == DeviceKeyStore.deviceNodeHex() else { return }   // not for this device
        DeviceCredentialStore.save(cred)
        sendToMyDevices(26, Data(targetHex.utf8))   // "send me your full state" (both transports)
        refresh(); requestMissingMedia()
        NotificationManager.shared.notify(title: "Device authorized",
                                          body: "This device is now a secure linked device — syncing your stuff…",
                                          dedupeKey: "device-auth-grant", persist: false)   // deliberate flow — may recur later
    }

    /// Another of my devices asked for my full state (after being authorized). Push it: profile + circles
    /// + posts. (Same payload the passive nearby-connect sends, but triggered explicitly by linking.)
    private func handleRequestFullState(_ payload: Data) {
        guard AccountStore.storedSeed() != nil else { return }   // only a seed-holder can push the account state
        pushFullStateToMyDevices()
    }

    /// Send to MY OWN other devices over BOTH transports — the local mesh AND iroh (directed at my own
    /// node id, which reaches my other devices). Device-link messages must not assume the nearby mesh is
    /// up; if the two are connected over iroh instead, nearby-only sends silently go nowhere.
    private func sendToMyDevices(_ type: UInt8, _ payload: Data) {
        nearbyBroadcast(type, payload)
        if let hex = social?.myNodeHex() { sendIroh(type, payload, to: hex) }
    }

    /// Push my full account state (profile/circles/contacts slot + every circle's posts) to my other
    /// devices over both transports, so a freshly-linked device populates regardless of which is up.
    private func pushFullStateToMyDevices() {
        guard let social else { return }
        if let slot = SelfSyncCoordinator.shared.sealedLocalSlot(social: social) { sendToMyDevices(23, slot) }
        let myHex = social.myNodeHex()
        for circle in circles {
            for env in social.syncEnvelopes(circleId: circle.id) {
                let payload = eventPayload(circle.id, env)
                if circle.id.hasPrefix("dm:") {
                    // DMs (incl. MY OWN sent messages) must reach my OTHER devices — but ONLY mine: send
                    // directed over iroh to my own node id, never a nearby broadcast, which would leak the
                    // DM relationship (the circle id encodes both parties) to nearby contacts.
                    sendIroh(1, payload, to: myHex)
                } else {
                    sendToMyDevices(1, payload)
                }
            }
        }
        refresh()
    }

    /// Share my S3 bucket as the active circle's mailbox — WITHOUT sending the credentials.
    /// Instead, mint a pool of pre-signed URLs the circle uses; the access key/secret never
    /// leave this device. I keep the creds locally (StorageStore) and use them directly.
    func shareBucketWithCircle() {
        guard let social, let s3 = SharedStore.ownerS3() else { return }
        let cid = activeCircleId
        // Remember I own this circle's bucket so it gets re-minted on launch / silent push.
        var owned = PresignStore.shared.ownedCircles; owned.append(cid); PresignStore.shared.ownedCircles = owned
        PushManager.shared.registerStorageOwner()
        let members = social.contactNodeIds(circleId: cid)
        Task { await PresignStore.shared.mintAndPublish(circleId: cid, members: members, s3: s3) }
    }

    private func handleBucketConfig(_ payload: Data) {
        guard let social else { return }
        var off = 0
        guard let cidData = lpRead(payload, &off) else { return }
        let circleId = String(data: cidData, encoding: .utf8) ?? ""
        let sealed = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        guard !circleId.isEmpty, !sealed.isEmpty,
              let data = social.openCircleMedia(circleId: circleId, sealed: sealed),
              let cfg = try? JSONDecoder().decode(S3Config.self, from: data) else { return }
        SharedMailboxStore.shared.set(cfg)
        pollMailboxNow()   // immediately pull from the newly-shared bucket
    }

    /// Tell every circle to use a Haven relay (this device, or another that turned on the relay
    /// toggle) as their mailbox. The relay node id is sealed to each circle and broadcast.
    /// The relay link to hand an external `haven-relay` daemon for a circle (circle tag + the
    /// circle's member node ids — all public routing data, no keys). Defaults to the active circle.
    func relayLink(forCircle cid: String? = nil) -> String? {
        guard let social else { return nil }
        let circle = cid ?? activeCircleId
        var members = social.contactNodeIds(circleId: circle)
        members.append(myNodeHex)
        return makeRelayLink(circle: circle, members: members)
    }

    /// Adopt a relay node as the mailbox for specific circles (and optionally make it the default
    /// every present + future circle inherits). Each circle's members are told over frame 19.
    func adoptRelayNode(_ nodeHex: String, circleIds: [String], setDefault: Bool) {
        let hex = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let social, hex.count == 64 else { return }
        let data = relayAnnounceData(hex)
        RelayMailboxStore.shared.unforget(hex)   // explicit adoption overrides a prior Forget
        if setDefault { RelayMailboxStore.shared.defaultNodeHex = hex }
        for cid in circleIds {
            RelayMailboxStore.shared.add(circleId: cid, nodeHex: hex)   // ADD (append), don't replace
            guard let sealed = try? social.sealCircleMedia(circleId: cid, data: data) else { continue }
            var p = Data(); lpAppend(&p, Data(cid.utf8)); p.append(sealed)
            let members = dialTargets(cid)
            for m in members { sendIroh(19, p, to: m) }
            nearbyBroadcast(19, p)
            originateRelay(dests: members, inner: frame(19, p))
        }
        // A mailbox just came online → backfill EVERYTHING I already posted in these circles (so a
        // member who was offline when I posted can still fetch it), push up anything still pending,
        // and pull anything waiting for us.
        backfillMailbox(circleIds: circleIds)
        Task { await BackgroundUploader.shared.flush() }
        pollMailboxNow()
    }

    /// Forget a relay across every circle (and as the default) — drops its cached connection and
    /// health, mirroring desktop `forget_relay`. Local only: other members keep their own pools.
    func forgetRelay(_ nodeHex: String) {
        RelayMailboxStore.shared.forget(nodeHex: nodeHex)
    }

    /// Add an S3 bucket as a (store-and-forward) relay: persist its creds via SharedMailboxStore
    /// (secret → Keychain), record a RelayEntry(isS3:true) so it shows in the Relays list, and
    /// associate it with the given circles. Returns the synthetic relay id.
    @discardableResult
    func addS3Relay(_ cfg: S3Config, name: String, circleIds: [String], setDefault: Bool) -> String {
        SharedMailboxStore.shared.set(cfg)
        let hex = "s3:\(cfg.bucket)"
        let targets = circleIds.isEmpty ? circles.map(\.id) : circleIds
        for cid in targets { RelayMailboxStore.shared.add(circleId: cid, nodeHex: hex, name: name, isS3: true) }
        if setDefault { RelayMailboxStore.shared.setDefault(hex) }
        backfillMailbox(circleIds: targets)
        Task { await BackgroundUploader.shared.flush() }
        pollMailboxNow()
        return hex
    }

    /// Apply a single relay (Haven or S3) to exactly one circle's override set, replacing nothing else.
    func setCircleRelay(_ nodeHex: String, circleId: String, on: Bool) {
        if on { RelayMailboxStore.shared.add(circleId: circleId, nodeHex: nodeHex, isS3: nodeHex.hasPrefix("s3:")) }
        else { RelayMailboxStore.shared.remove(circleId: circleId, nodeHex: nodeHex) }
        pollMailboxNow()
    }

    /// Re-upload every post I've ALREADY authored in these circles to their mailbox. Fixes the
    /// case where you set up a relay/bucket *after* posting — those posts never reached the
    /// mailbox, so offline members couldn't get them. Idempotent (content-addressed keys — and
    /// event envelopes now re-seal deterministically, so a re-run reproduces the SAME keys and
    /// the persisted seen-set/`has()` checks skip everything already uploaded). The re-seal is
    /// still real CPU (a hybrid signature per event), so it runs off the main actor.
    func backfillMailbox(circleIds: [String]) {
        guard let social else { return }
        let ids = circleIds.filter { SharedStore.hasMailbox($0) }
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) {
            for cid in ids {
                let envs = social.exportMyEnvelopes(circleId: cid)
                for env in envs {
                    await SharedStore.uploadEvent(circleId: cid, env: env)
                }
                // TOUCH the same refs on every relay so mailbox GC keeps them (uploadEvent is
                // seen-set-skipped once an envelope landed ONCE — without this, nothing would
                // ever refresh a live entry and the relay's 30-day TTL would eat real history).
                // The relay replies with keys it lacks and those are re-PUT inside, so the
                // daily refresh also repairs a relay that GC'd us while we were away.
                await SharedStore.refreshMailbox(circleId: cid, envelopes: envs)
                // ALSO keep alive posts I RECEIVED (didn't author): TOUCH every mailbox key I hold.
                // Without this a post was refreshed ONLY by its author, so if the author was offline
                // for 30 days it was swept even though active readers still wanted it — the
                // "relay copy expires too quickly" report. Any active member now keeps a post alive.
                await SharedStore.touchHeldKeys(circleId: cid)
            }
        }
    }

    /// Push every media blob I hold for a circle to its relay/mailbox, so a member pulling EVENTS
    /// from the relay can also pull the MEDIA (instead of receiving fragmented posts). No-op without
    /// a mailbox. Used when sharing history with a new member and when a new relay is adopted.
    func backfillMailboxMedia(circleIds: [String]) {
        guard let social else { return }
        for cid in circleIds where SharedStore.hasMailbox(cid) {
            let feed = social.feed(circleId: cid, nowMs: now(),
                                   viewerRetentionSecs: CircleSettingsStore.shared.retentionSecs(cid))
            var refs = Set<String>()
            for item in feed {
                refs.formUnion(item.media)
                for c in item.comments { refs.formUnion(c.media) }
            }
            for ref in refs where MediaStore.shared.has(ref) {
                MediaBackupQueue.shared.enqueue(ref, circleId: cid, social: social)
            }
        }
    }

    /// Apply a relay to every circle + make it the default (used by the in-app RelayHost).
    func broadcastRelayNode(_ nodeHex: String) {
        adoptRelayNode(nodeHex, circleIds: circles.map(\.id), setDefault: true)
    }

    private func handleRelayNode(_ payload: Data) {
        guard let social else { return }
        var off = 0
        guard let cidData = lpRead(payload, &off) else { return }
        let circleId = String(data: cidData, encoding: .utf8) ?? ""
        let sealed = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        guard !circleId.isEmpty, !sealed.isEmpty,
              let opened = social.openCircleMediaSender(circleId: circleId, sealed: sealed),
              var nodeHex = String(data: opened.data, encoding: .utf8) else { return }
        let announcerHex = opened.senderHex.lowercased()   // authenticated envelope sender (account id)
        let data = opened.data
        // Extended announce: JSON {node, urls, token} also carries the relay's plain-HTTP media
        // interface (the reliable cross-NAT path). Legacy announces are the bare 64-hex id.
        var announcedUrls: [String] = []
        var announcedToken = ""
        var announcedAddedAt: UInt64 = 0
        if nodeHex.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            announcedUrls = (obj["urls"] as? [String] ?? []).filter { $0.hasPrefix("http") }
            announcedToken = obj["token"] as? String ?? ""
            announcedAddedAt = (obj["addedAt"] as? NSNumber)?.uint64Value ?? 0
            nodeHex = (obj["node"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard nodeHex.count == 64 else { return }
        // A contact RE-ANNOUNCED a circle relay. Reactivating a deactivated/forgotten entry is allowed
        // ONLY when the announce comes from the relay's OWNER — the announced id is one of the sender's
        // own authorized device ids (their in-app relay; that's what lets your Mac's relay come back on
        // your iPhone when the Mac itself re-announces it), or their account id (a legacy account-id
        // relay). A THIRD-PARTY echo must never resurrect it: every member re-announces every relay
        // they hold proof-of-life for, so a relay the user deliberately deleted — but which is still
        // RUNNING somewhere (an old docker container, a forgotten daemon) — bounced back within one
        // sync tick, forever (the "deleted relays keep coming back" zombie loop). Non-owner announces
        // of a tombstoned relay are dropped entirely; brand-new relays still auto-pool below.
        let lower = nodeHex.lowercased()
        let ownerDevices = social.deviceNodeIdsFor(accountHex: announcerHex).map { $0.lowercased() }
        let announcerOwnsRelay = lower == announcerHex || ownerDevices.contains(lower)
        if RelayMailboxStore.shared.isForgotten(lower) || !RelayMailboxStore.shared.isActive(lower) {
            // Reactivate when EITHER the announcer owns the relay (their in-app/account relay — the
            // original gate, keeps a Mac's relay coming back on the iPhone), OR the announce is a
            // genuinely NEWER re-add than our forget (LWW). The latter is what lets an EXTERNAL relay
            // (a docker daemon, whose id is nobody's device id) be re-added by whoever manages it and
            // repopulate to every member — while a stale third-party echo, carrying the relay's
            // ORIGINAL (older) adoption stamp, still loses and stays forgotten (no zombie loop).
            let forgotMs = RelayMailboxStore.shared.forgottenAtMs(lower)
            let newerReAdd = announcedAddedAt > 0 && announcedAddedAt > forgotMs
            guard announcerOwnsRelay || newerReAdd else { return }
            RelayMailboxStore.shared.reactivate(lower, adoptedAtMs: announcedAddedAt)
        }
        // A contact advertised their circle relay → ADD it to our redundant set for this circle, so
        // members automatically pool relays (more redundancy, no manual setup) — desktop parity.
        let wasNew = !RelayMailboxStore.shared.relays(forCircle: circleId).contains(lower)
        // Propagate the announced adoption stamp (not now()) so the freshest legit re-add flows across
        // the circle without any echo fabricating a new timestamp.
        RelayMailboxStore.shared.add(circleId: circleId, nodeHex: nodeHex, adoptedAtMs: announcedAddedAt)
        // Record the relay's announced HTTP media interface (the reliable cross-NAT path).
        if !announcedUrls.isEmpty, !announcedToken.isEmpty {
            RelayMailboxStore.shared.setHttpInterface(lower, urls: announcedUrls, token: announcedToken)
        }
        // SUPERSEDE stale account-id relays. Under the per-device transport a relay is ALWAYS a device id,
        // never an account id. A relay-list entry equal to a member's (or our own) ACCOUNT id is a dead
        // leftover from the pre-device-seed transport (when the relay WAS the account id) — nothing serves it,
        // and every media fetch burns a full 30s timeout on it (the "2 relays, one is the account id" bug).
        // Learning a real (device) relay for this circle means those account-id entries are obsolete → drop
        // them so the reachable device relay is what gets dialed. (Safe under the all-devices-on-154 cutover.)
        var staleAccounts = Set(memberHexes(circleId: circleId).map { $0.lowercased() })
        staleAccounts.insert(AccountStore.currentNodeHex().lowercased())
        for a in staleAccounts where a != lower && a.count == 64 {
            RelayMailboxStore.shared.remove(circleId: circleId, nodeHex: a)
        }
        if wasNew {
            backfillMailbox(circleIds: [circleId])        // mirror my past posts to the new relay…
            backfillMailboxMedia(circleIds: [circleId])   // …and their media, so it's a complete fallback
        }
        Task { await BackgroundUploader.shared.flush() }   // deliver posts we couldn't send before
        pollMailboxNow()
    }

    // MARK: - Pre-signed S3 pool (advanced mailbox without sharing credentials)

    func memberHexes(circleId: String) -> [String] { social?.contactNodeIds(circleId: circleId) ?? [] }

    /// (circleId, all member hexes incl. me) for every circle — the relay's membership allow-list
    /// (audit transport-F4). `social` is private, so RelayHost gets the data through this accessor.
    func circleMemberships() -> [(String, [String])] {
        guard let social else { return [] }
        return social.circles().map { c in
            var accounts = memberHexes(circleId: c.id)
            if !myNodeHex.isEmpty, !accounts.contains(myNodeHex) { accounts.append(myNodeHex) }
            // Authorize each member at the TRANSPORT layer by their DEVICE ids (Option 1 — peers connect as
            // their device), keeping the account id too for any pre-multidevice peer. Includes MY OWN device
            // ids, so a sibling device can read this host's mailbox. De-duplicated.
            var ids: [String] = []
            for a in accounts {
                if !ids.contains(a) { ids.append(a) }
                for d in social.deviceNodeIdsFor(accountHex: a) where !ids.contains(d) { ids.append(d) }
            }
            return (c.id, ids)
        }
    }
    func sealCirclePresign(circleId: String, data: Data) -> Data? { try? social?.sealCircleMedia(circleId: circleId, data: data) }
    func openCirclePresign(circleId: String, sealed: Data) -> Data? { social?.openCircleMedia(circleId: circleId, sealed: sealed) }

    /// Broadcast the bootstrap GET URL for a circle's pre-signed-URL pool (sealed to the circle).
    func broadcastPresignBootstrap(circleId: String, getURL: String) {
        guard let social, let data = getURL.data(using: .utf8),
              let sealed = try? social.sealCircleMedia(circleId: circleId, data: data) else { return }
        var p = Data(); lpAppend(&p, Data(circleId.utf8)); p.append(sealed)
        let members = dialTargets(circleId)
        for m in members { sendIroh(20, p, to: m) }
        nearbyBroadcast(20, p)
        originateRelay(dests: members, inner: frame(20, p))
    }

    private func handlePresignBootstrap(_ payload: Data) {
        guard let social else { return }
        var off = 0
        guard let cidData = lpRead(payload, &off) else { return }
        let circleId = String(data: cidData, encoding: .utf8) ?? ""
        let sealed = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        guard !circleId.isEmpty, !sealed.isEmpty,
              let data = social.openCircleMedia(circleId: circleId, sealed: sealed),
              let url = String(data: data, encoding: .utf8), url.hasPrefix("http") else { return }
        PresignStore.shared.setBootstrap(circleId: circleId, getURL: url)
        backfillMailbox(circleIds: [circleId])             // re-upload my past posts to the pool
        Task { await BackgroundUploader.shared.flush() }   // deliver posts we couldn't send before
        pollMailboxNow()
    }

    /// Send a call signaling/audio frame to a peer (direct, over the internet transport).
    func sendCallFrame(_ type: UInt8, _ payload: Data, to nodeHex: String) {
        sendIroh(type, payload, to: nodeHex)
        // Cross-NAT fallback: hop the same frame LIVE through the circle relays (frame 9 — the
        // relay host unwraps + sends it onward over its own connections). The nearby originateRelay
        // flood never leaves the room, so a callee whose direct dial back to the caller failed had
        // NO way to deliver the ACCEPT — the push rang her, but the answer died in the NAT.
        var dests = social?.deviceNodeIdsFor(accountHex: nodeHex) ?? [nodeHex]
        for h in deviceHints(for: nodeHex) where !dests.contains(where: { $0.lowercased() == h }) { dests.append(h) }
        originateRelayInternet(dests: dests, inner: frame(type, payload))
    }

    /// Originate a frame-9 live forward of `inner` to `dests` via up to 3 adopted INTERNET relays
    /// (same wire format as emitRelay, but sent over iroh to the relay host instead of flooded to
    /// the nearby mesh). The host's handleRelay forwards `inner` to each dest it can reach.
    private func originateRelayInternet(dests: [String], inner: Data) {
        let destBytes = dests.compactMap { nodeIdBytes($0) }
        guard !destBytes.isEmpty else { return }
        let id = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        seenRelay.insert(id.map { String(format: "%02x", $0) }.joined())   // don't reprocess our own
        var p = Data()
        p.append(id)
        p.append(Self.relayTTL)
        p.append(UInt8(min(destBytes.count, 255)))
        for d in destBytes.prefix(255) { p.append(d) }
        p.append(inner)
        let myAcct = AccountStore.currentNodeHex().lowercased()
        let myDev = social?.myDeviceNodeHex().lowercased() ?? ""
        var sent = 0
        for relayHex in RelayMailboxStore.shared.allRelays() {
            let h = relayHex.lowercased()
            if h.hasPrefix("s3:") || h == myAcct || h == myDev { continue }
            sendIroh(9, p, to: relayHex)
            sent += 1
            if sent >= 3 { break }
        }
    }

    /// Notify a callee via push that a call is coming in (so they're alerted even if the app
    /// isn't foregrounded). A sealed "Incoming call" banner the NSE decrypts. (True ring-from-
    /// killed needs a VoIP push — a follow-on.)
    func pushCallInvite(to nodeHex: String, callerName: String) {
        guard let social else { return }
        // Seal {caller name, caller node id} to the callee. Their PushKit handler decrypts it and
        // shows the system incoming-call screen via CallKit (ring-from-killed). Worker stays blind.
        let json = (try? JSONSerialization.data(withJSONObject: ["t": callerName, "h": myNodeHex])) ?? Data()
        let sealed = try? social.sealSignedNotification(recipientNodeHex: nodeHex, data: json)
        PushManager.shared.callPush(to: nodeHex, ciphertext: sealed?.base64EncodedString())
    }

    // MARK: - Mesh relay  [9] payload = [msgId(16)][ttl(1)][destCount(1)][dest×32…][inner frame]
    // Lets an internet-connected nearby peer forward a sealed frame it can't read toward
    // its destination. The routing header is cleartext (dest ids + msg id + ttl); the
    // wrapped payload stays end-to-end encrypted. Relays never decrypt — they just route.

    private static let relayTTL: UInt8 = 4
    private var seenRelay = Set<String>()

    /// Originate a relayable copy of a frame, flooded over the nearby mesh.
    private func originateRelay(dests: [String], inner: Data) {
        var id = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        seenRelay.insert(id.map { String(format: "%02x", $0) }.joined())
        emitRelay(msgId: &id, ttl: Self.relayTTL, dests: dests, inner: inner)
    }

    private func emitRelay(msgId: inout Data, ttl: UInt8, dests: [String], inner: Data) {
        let destBytes = dests.compactMap { nodeIdBytes($0) }
        guard !destBytes.isEmpty else { return }
        var p = Data()
        p.append(msgId)
        p.append(ttl)
        p.append(UInt8(min(destBytes.count, 255)))
        for d in destBytes.prefix(255) { p.append(d) }
        p.append(inner)
        nearby?.broadcast(frame(9, p))
    }

    private func handleRelay(_ payload: Data) {
        guard payload.count >= 18 else { return }
        let s = payload.startIndex
        var msgId = payload.subdata(in: s..<(s + 16))
        let key = msgId.map { String(format: "%02x", $0) }.joined()
        guard !seenRelay.contains(key) else { return }   // dedup / loop protection
        seenRelay.insert(key)
        if seenRelay.count > 2000 { seenRelay.removeAll() }
        let ttl = payload[s + 16]
        let destCount = Int(payload[s + 17])
        var off = 18
        guard payload.count >= off + destCount * 32 else { return }
        var dests: [String] = []
        for _ in 0..<destCount {
            dests.append(nodeHex(payload.subdata(in: (s + off)..<(s + off + 32))))
            off += 32
        }
        let inner = payload.subdata(in: (s + off)..<payload.endIndex)
        guard !inner.isEmpty else { return }

        let me = myNodeHex
        // If it's for me, process it as a normal inbound frame.
        if dests.contains(me) {
            handleInbound(inner, viaNearby: true)
        }
        // Forward to any other destinations we can reach, and keep it hopping nearby.
        guard ttl > 0 else { return }
        for dest in dests where dest != me {
            sendRaw(inner, to: dest)            // over the internet, if we can reach them
        }
        emitRelay(msgId: &msgId, ttl: ttl - 1, dests: dests, inner: inner)   // re-flood nearby
    }

    /// Send an already-framed payload as-is (used to forward relayed frames).
    private func sendRaw(_ framed: Data, to nodeHex: String) {
        guard let node else { return }
        Task { [weak self] in
            do {
                try await node.sendToNode(nodeIdHex: nodeHex, payload: framed)
                await MainActor.run { self?.lastSendError = nil }
            }
            catch { await MainActor.run { self?.lastSendError = error.localizedDescription } }
        }
    }

    private func nodeIdBytes(_ hexStr: String) -> Data? {
        guard hexStr.count == 64 else { return nil }
        var d = Data(); var i = hexStr.startIndex
        while i < hexStr.endIndex {
            let j = hexStr.index(i, offsetBy: 2)
            guard let b = UInt8(hexStr[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        return d
    }

    // MARK: - Media transfer  [3] request(ref) → [4] sealed media back

    /// Ask contacts for any media our feed references but we don't hold the bytes for.
    /// Actively (re-)request one media ref from every contact, nearby, and the shared
    /// store. Safe to call repeatedly — re-sent chunks just fill the gaps a lossy transfer
    /// left, which is what large videos need (one dropped chunk otherwise hangs forever).
    func requestMedia(_ ref: String) {
        guard let social, !MediaStore.isSynthetic(ref), !MediaStore.shared.has(ref) else { return }
        let myHex = social.myNodeHex()
        var payload = Data(myHex.utf8); payload.append(Data(ref.utf8))
        for contact in ContactsStore.shared.contacts { sendIroh(3, payload, to: contact.idHex) }
        nearbyBroadcast(3, payload)
        let circleIds = circles.map { $0.id }
        Task { @MainActor in   // also pull from the circle's shared store if one exists
            if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                MediaStore.shared.store(ref, data); autoSaveReceived(ref); scheduleRefresh()
            }
        }
    }

    private var mediaReqAt: [String: UInt64] = [:]   // ref → last direct-request ms (throttle)
    private var lastMediaScanMs: UInt64 = 0
    private func requestMissingMedia() {
        guard let social, node != nil || nearby != nil else { return }
        // The scan below is O(items × media) with a stat() per ref (MediaStore.has) — cap it to
        // once per 2s on the main actor; per-ref request throttles below stay unchanged.
        let nowMs = now()
        guard nowMs - lastMediaScanMs > 2_000 else { return }
        lastMediaScanMs = nowMs
        let myHex = social.myNodeHex()
        var missing = Set<String>()
        // Skip synthetic refs (geo: location pins): they carry no fetchable bytes, so counting them
        // keeps nbMediaPending pinned above 0 forever and fires a doomed restore each sweep.
        for item in items {
            for ref in item.media where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref) { missing.insert(ref) }
            for c in item.comments { for ref in c.media where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref) { missing.insert(ref) } }
        }
        let circleIds = circles.map { $0.id }
        SyncMetrics.shared.nbMediaPending = missing.count
        // THROTTLE: a missing ref was re-requested from every contact on every sync, so a backlog of
        // missing media flooded the network with hundreds of thousands of frames per cycle (drowning real
        // delivery). Direct-request each ref at most once per 5 min, and only a handful per cycle — the
        // mailbox/relay restore below is the real path and it's idempotent.
        // Rate-limit the WHOLE request per ref (nearby + iroh + mailbox restore) to once per 90s, capped per
        // cycle. Previously the nearby ask + a restore Task fired for EVERY missing ref EVERY cycle, so media
        // neither device can reach (e.g. an offline friend's) was re-requested + re-served forever — it never
        // settled. Available media still arrives quickly (a request lands within a cycle); unreachable media
        // just retries occasionally instead of churning.
        var budget = 12
        let hasMailbox = circleIds.contains(where: { SharedStore.hasMailbox($0) })
        for ref in missing {
            let stale = (mediaReqAt[ref].map { nowMs - $0 > 90_000 } ?? true)
            guard stale, budget > 0 else { continue }
            mediaReqAt[ref] = nowMs
            budget -= 1
            var payload = Data(myHex.utf8)          // 64-byte requester id
            payload.append(Data(ref.utf8))
            let directAsk = {
                self.nearbyBroadcast(3, payload)
                for contact in ContactsStore.shared.contacts { self.sendIroh(3, payload, to: contact.idHex) }
            }
            // RELAY-FIRST: pull the stored copy from the circle's mailbox (own hosted store → relay
            // HTTP :8674 → S3 → iroh blob, in that order inside restore). Only if there is NO mailbox,
            // or the stored copy can't be fetched, fall back to asking an online author/peer directly.
            // Previously the direct ask fired FIRST alongside the restore, so an online sender streamed
            // the bytes peer-to-peer (heat + bandwidth on both) even though the relay already held them.
            if hasMailbox {
                Task { @MainActor in
                    if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                        MediaStore.shared.store(ref, data); autoSaveReceived(ref); scheduleRefresh()
                    } else {
                        directAsk()   // relay didn't have it (or unreachable) → ask a peer
                    }
                }
            } else {
                directAsk()           // no mailbox in any circle → peer-to-peer is the only path
            }
        }
        if mediaReqAt.count > 4000 { mediaReqAt.removeAll() }   // bound the throttle map
    }

    private func handleMediaRequest(_ payload: Data) {
        guard payload.count > 64 else { return }
        let requesterHex = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        let ref = String(data: payload.dropFirst(64), encoding: .utf8) ?? ""
        guard requesterHex.count == 64, !ref.isEmpty else { return }
        let haveLocal = MediaStore.shared.storagePath(for: ref).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        HavenLog.net("media REQ ref=\(ref.prefix(12)) have=\(haveLocal) from=\(requesterHex.prefix(8))")
        if let url = MediaStore.shared.storagePath(for: ref), FileManager.default.fileExists(atPath: url.path) {
            if shouldServeNearby(ref) { sendMediaChunks(ref: ref, fileURL: url, to: requesterHex) }
            return
        }
        // I don't hold it locally — if I'm the circle's backup, restore it and serve.
        guard SharedStore.isVolunteering, let social else { return }
        let circleIds = circles.map { $0.id }
        Task { @MainActor in
            if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                MediaStore.shared.store(ref, data)
                if let url = MediaStore.shared.storagePath(for: ref) {
                    sendMediaChunks(ref: ref, fileURL: url, to: requesterHex)
                }
            }
        }
    }

    private var servedAt: [String: UInt64] = [:]
    /// Rate-limit serving a media ref over nearby: the Mac re-requests every cycle while it waits, so
    /// without this the iPhone re-served the same blobs hundreds of times (↑323 for ~18 items), flooding
    /// MultipeerConnectivity's serial send queue so NOTHING actually drained to the peer. One serve per ref
    /// per 25s lets the queue clear and the chunks really deliver.
    private func shouldServeNearby(_ ref: String) -> Bool {
        let nowMs = now()
        if let last = servedAt[ref], nowMs - last < 25_000 { return false }
        servedAt[ref] = nowMs
        if servedAt.count > 4000 { servedAt.removeAll() }
        return true
    }

    private var pushedNearby = Set<String>()
    /// Opportunistically PUSH the media I hold to nearby own devices, sealed to my account (only my own
    /// devices can open it). Rides the nearby mesh — the reliable own-device channel when iroh is blocked —
    /// so a linked Mac gets my photos WITHOUT relying on the request/response round-trip (which wasn't
    /// delivering). Deduplicated (each ref pushed once per peer session) + budgeted, and every item is an
    /// independent broadcast so one large/slow item can't stall the rest. `freshPeer` re-pushes everything
    /// for a newly-connected sibling that has nothing yet.
    private func pushOwnMediaNearby(freshPeer: Bool = false) {
        guard let social, nearby != nil else { return }
        if freshPeer { pushedNearby.removeAll() }
        let me = social.myNodeHex()
        var refs: [String] = []
        for item in items { refs.append(contentsOf: item.media); for c in item.comments { refs.append(contentsOf: c.media) } }
        var budget = 2   // only a couple per pass — the link is slow; the rest follow on later ticks
        for ref in refs {
            if budget <= 0 { break }
            if pushedNearby.contains(ref) || SharedLocation.parse(ref) != nil { continue }
            guard let url = MediaStore.shared.storagePath(for: ref), FileManager.default.fileExists(atPath: url.path) else { continue }
            pushedNearby.insert(ref)
            guard shouldServeNearby(ref) else { continue }
            sendMediaChunks(ref: ref, fileURL: url, to: me)
            budget -= 1
        }
        if pushedNearby.count > 5000 { pushedNearby.removeAll() }
    }

    /// A symmetric key derived from the ACCOUNT seed — both of the user's own devices derive the identical
    /// key, so own-device media chunks sealed with it always open on the sibling. KEM-sealing-to-self was
    /// unreliable (the engine's per-device identity made decap fail), which is why media between a user's
    /// own devices never decrypted. Mirrors how the (working) self-sync slot uses an account-derived key.
    static func ownMediaKey() -> SymmetricKey? {
        guard let seed = AccountStore.storedSeed() else { return nil }
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seed),
                                       salt: Data("haven-own-media-v1".utf8),
                                       info: Data(), outputByteCount: 32)
        return k
    }

    /// Stream a media file to the requester as individually-sealed chunks — low memory,
    /// large-file friendly. Chunk N's plaintext goes at offset N*chunkSize on reassembly.
    private func sendMediaChunks(ref: String, fileURL url: URL, to requesterHex: String) {
        guard let social, let handle = try? FileHandle(forReadingFrom: url) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let total = max(1, (size + Self.mediaChunkSize - 1) / Self.mediaChunkSize)
        SyncMetrics.shared.nbMediaOut += 1
        let refData = Data(ref.utf8)
        let chunkSize = Self.mediaChunkSize
        let nearby = self.nearby
        let node = self.node
        // OWN-device (requester is my own account): read + symmetric-seal + broadcast entirely on a
        // BACKGROUND queue. This loop streams thousands of chunks; running it on the main actor (as it did)
        // made the whole UI lag while syncing. It needs no engine, so it's safe off-main.
        if requesterHex == social.myNodeHex(), let ownKey = Self.ownMediaKey() {
            DispatchQueue.global(qos: .utility).async {
                defer { try? handle.close() }
                var index = 0
                while true {
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    guard let sealed = try? AES.GCM.seal(chunk, using: ownKey).combined else { break }
                    nearby?.broadcast(Data([5]) + Self.chunkFrame(refData: refData, index: index, total: total, sealed: sealed))
                    index += 1
                    Thread.sleep(forTimeInterval: 0.030)   // pace so we don't outrun a slow link → unbounded send backlog
                    // Stop early if the send backlog is already high — the rest re-pushes next tick.
                    if (nearby?.sendBacklogHigh ?? false) { break }
                }
            }
            return
        }
        // FRIEND path: per-recipient KEM seal needs the engine, so keep it on the main actor (rare +
        // reachability-gated, so it isn't the lag source).
        Task { @MainActor in
            defer { try? handle.close() }
            var index = 0
            while true {
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                guard let sealed = try? social.sealMedia(recipientNodeHex: requesterHex, data: chunk) else { break }
                let out = Data([5]) + Self.chunkFrame(refData: refData, index: index, total: total, sealed: sealed)
                nearby?.broadcast(out)
                if let node { Task.detached { try? await node.sendToNode(nodeIdHex: requesterHex, payload: out) } }
                index += 1
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
        }
    }

    private static func chunkFrame(refData: Data, index: Int, total: Int, sealed: Data) -> Data {
        var f = Data()
        let rl = UInt16(refData.count)
        f.append(UInt8(rl & 0xff)); f.append(UInt8(rl >> 8))
        f.append(refData)
        for v in [UInt32(index), UInt32(total)] {
            f.append(UInt8(v & 0xff)); f.append(UInt8((v >> 8) & 0xff))
            f.append(UInt8((v >> 16) & 0xff)); f.append(UInt8((v >> 24) & 0xff))
        }
        f.append(sealed)
        return f
    }

    private func handleMediaChunk(_ payload: Data) {
        guard let social, payload.count >= 2 else { return }
        let lb = [UInt8](payload.prefix(2))
        let refLen = Int(UInt16(lb[0]) | UInt16(lb[1]) << 8)
        guard payload.count >= 2 + refLen + 8 else { return }
        let ref = String(data: payload.subdata(in: 2..<(2 + refLen)), encoding: .utf8) ?? ""
        var off = 2 + refLen
        let index = Int(Self.readU32(payload, off)); off += 4
        let total = Int(Self.readU32(payload, off)); off += 4
        let sealed = payload.subdata(in: off..<payload.count)
        guard !ref.isEmpty, total > 0, !MediaStore.shared.has(ref) else { return }

        // Reassembly entry (temp file) is created on the main actor; the heavy decrypt + disk write run on a
        // dedicated SERIAL queue (serial = no concurrent writes to the same temp file), so thousands of
        // chunks never block the UI. Only the cheap bookkeeping returns to main.
        let entry = incoming[ref] ?? IncomingMedia(tempURL: MediaStore.shared.makeTempFile(), total: total, got: [])
        incoming[ref] = entry
        let tempURL = entry.tempURL
        let chunkSize = Self.mediaChunkSize
        let ownKey = Self.ownMediaKey()
        // Receive backpressure: if the decrypt+write queue is already backed up, DROP this chunk — the
        // reassembly stays incomplete and it's re-requested / re-sent. Prevents an unbounded queue → jetsam.
        Self.mediaBacklogLock.lock()
        let drop = Self.mediaBacklogBytes > Self.mediaBacklogCap
        if !drop { Self.mediaBacklogBytes += sealed.count }
        Self.mediaBacklogLock.unlock()
        if drop { return }
        Self.mediaQueue.async { [weak self] in
            defer { Self.mediaBacklogLock.lock(); Self.mediaBacklogBytes -= sealed.count; Self.mediaBacklogLock.unlock() }
            // Own-device chunks are symmetric (account-key); friend chunks are KEM. Try symmetric first.
            var plain: Data? = nil
            if let ownKey, let box = try? AES.GCM.SealedBox(combined: sealed), let p = try? AES.GCM.open(box, using: ownKey) {
                plain = p
            }
            if let plain {
                if let fh = try? FileHandle(forWritingTo: tempURL) {
                    try? fh.seek(toOffset: UInt64(index) * UInt64(chunkSize)); fh.write(plain); try? fh.close()
                }
                Task { @MainActor in self?.finishChunk(ref: ref, index: index) }
            } else {
                // KEM (friend) open needs the engine → hop to main, open + write there (rare path).
                Task { @MainActor in
                    guard let self, let kp = self.social?.openMedia(sealed: sealed) else { return }
                    if let fh = try? FileHandle(forWritingTo: tempURL) {
                        try? fh.seek(toOffset: UInt64(index) * UInt64(chunkSize)); fh.write(kp); try? fh.close()
                    }
                    self.finishChunk(ref: ref, index: index)
                }
            }
        }
    }

    private static let mediaQueue = DispatchQueue(label: "haven.media.reassembly", qos: .utility)
    // Backpressure for the receive queue: chunks arriving faster than they're decrypted+written piled up
    // here and ballooned memory to multi-GB → jetsam. Drop incoming chunks past this cap (re-requested).
    private static let mediaBacklogLock = NSLock()
    private static var mediaBacklogBytes = 0
    private static let mediaBacklogCap = 8 * 1024 * 1024

    /// Bookkeeping after a chunk's plaintext is written to the temp file (main-actor state).
    @MainActor private func finishChunk(ref: String, index: Int) {
        guard var entry = incoming[ref] else { return }
        entry.got.insert(index)
        incoming[ref] = entry
        guard entry.got.count >= entry.total else { return }
        MediaStore.shared.adopt(ref, from: entry.tempURL)
        SyncMetrics.shared.nbMediaIn += 1
        autoSaveReceived(ref)
        incoming[ref] = nil
        scheduleRefresh()   // re-render so the media appears (coalesced — many chunks complete in bursts)
        if SharedStore.isVolunteering, let social {
            let circle = activeCircleId
            MediaBackupQueue.shared.enqueue(ref, circleId: circle, social: social)
        }
    }

    private static func readU32(_ d: Data, _ off: Int) -> UInt32 {
        let s = d.startIndex + off
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }

    private func nodeHex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func isContact(_ idHex: String) -> Bool {
        ContactsStore.shared.contacts.contains { $0.idHex == idHex }
    }

    private func handleHello(_ payload: Data, viaNearby: Bool = false, senderDevice: String? = nil) {
        guard let social else { return }
        // [LP circleId][LP circleName][LP bundle][signed profile]
        var off = 0
        guard let circleIdData = lpRead(payload, &off),
              let circleNameData = lpRead(payload, &off),
              let bundle = lpRead(payload, &off), bundle.count >= 32 else { return }
        let circleId = String(data: circleIdData, encoding: .utf8) ?? ""
        let circleName = String(data: circleNameData, encoding: .utf8) ?? "Circle"
        guard !circleId.isEmpty else { return }
        let profileBlob = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        let idHex = nodeHex(bundle.prefix(32))
        // A hello delivered DIRECTLY teaches us the sender's dialable device id for this account —
        // the reply-path bootstrap (their signed roster supersedes; a wrong hint only misroutes
        // sealed frames, same trust model as invite-link hints).
        if let senderDevice, senderDevice.count == 64, senderDevice.lowercased() != idHex.lowercased() {
            recordDeviceHints(accountHex: idHex, deviceIds: [senderDevice])
        }
        // A handshake from ANOTHER OF MY OWN DEVICES (linked → same identity, same node id). NEVER treat
        // it as a stranger's connection request ("connect with yourself") — just trade self-sync slots so
        // the two devices converge. This is the fix for the "asked to connect with an identity of myself
        // when linking my Mac" bug.
        if idHex == social.myNodeHex() {
            if let slot = SelfSyncCoordinator.shared.sealedLocalSlot(social: social) { nearbyBroadcast(23, slot) }
            return
        }
        // Blocked people get dropped entirely — no add, no re-add.
        if ConnectionsStore.shared.isBlocked(idHex) { return }
        // Someone new reaching us through our invite → hold for approval (don't auto-add).
        // One person scans; the other gets asked, with safety words to verify.
        if !isContact(idHex) {
            // BUT: a non-contact Hello that arrived over the NEARBY mesh is just proximity — another
            // Haven user happened to be in Bluetooth/Wi-Fi range. That must NOT pop a connection request
            // (it did, repeatedly, for everyone nearby). Real new connections come from scanning an
            // invite, which sends a TARGETED Hello over iroh/relay (viaNearby == false) — those still ask.
            if viaNearby { return }
            let name = social.verifyProfile(bundle: bundle, blob: profileBlob) ?? "Someone"
            let vhex = (try? social.bundleVerificationHex(bundle: bundle)) ?? ""
            let display = name.isEmpty ? "Someone" : name
            ConnectionsStore.shared.addPending(ConnectionRequest(
                idHex: idHex, name: display, bundle: bundle,
                safetyWords: SafetyWords.words(fromHex: vhex)))
            NotificationManager.shared.notify(title: "New connection",
                                              body: "\(display) wants to connect",
                                              dedupeKey: "req-\(idHex)")
            return
        }
        if let expected = ContactsStore.shared.verification(forNodePrefix: idHex),
           let actual = try? social.bundleVerificationHex(bundle: bundle),
           expected != actual {
            return
        }
        // A DM circle is strictly its two encoded parties — never let a third party (e.g. a
        // contact who picked up a broadcast Hello) handshake their way into someone else's DM.
        if circleId.hasPrefix("dm:") && !dmCircleAllows(circleId, idHex) { return }
        // A member you explicitly removed from this circle must NOT auto-rejoin on their handshake.
        if ConnectionsStore.shared.isRemovedFromCircle(idHex, circleId: circleId) { return }
        // Ensure the circle exists on our side, then add the sender to it.
        let isNewCircle = circleId != "default" && !circles.contains { $0.id == circleId }
        social.createCircle(id: circleId, name: circleName)
        if isNewCircle {
            let who = ContactsStore.shared.name(forNodePrefix: idHex) ?? "Someone"
            NotificationManager.shared.notify(title: "Added to a circle",
                                              body: "\(who) added you to “\(circleName)”",
                                              dedupeKey: "circle-\(circleId)")
        }
        guard (try? social.addContactBundle(circleId: circleId, bundle: bundle)) != nil else { return }
        dialTargetsCache.removeAll()   // a just-handshaked member must be dialable now, not in 10s
        recordHeard(idHex)
        persist(); refreshCircles()
        if !profileBlob.isEmpty,
           let card = social.verifyProfileCard(bundle: bundle, blob: profileBlob), !card.name.isEmpty {
            ContactsStore.shared.setCard(idHex: idHex, name: card.name, bio: card.bio, link: card.link,
                                         avatar: card.avatar, emoji: card.emoji)
        }
        // Reply so the circle is mutual + back-fill its posts to them — but at most once per peer
        // per cooldown window. A hello reply is itself a hello, so a peer that echoes ours back
        // (e.g. a different client that doesn't suppress its own reply) would otherwise trigger an
        // INFINITE handshake ping-pong, each round re-verifying signatures + re-rendering our
        // avatar + re-sending every post — which pins the main thread and freezes the app.
        let replyKey = "\(idHex)|\(circleId)"
        let now = Date()
        if let last = lastHelloReply[replyKey], now.timeIntervalSince(last) < 20 {
            refresh(); return   // already handshaked this peer/circle very recently — don't echo back
        }
        lastHelloReply[replyKey] = now
        let isDM = circleId.hasPrefix("dm:")
        if let hello = helloPayload(circleId: circleId, circleName: circleName) {
            sendIroh(0, hello, to: idHex)
            if circleId == "default" { nearbyBroadcast(0, hello) }
        }
        for env in social.syncEnvelopes(circleId: circleId) {
            sendIroh(1, eventPayload(circleId, env), to: idHex)
            if !isDM { nearbyBroadcast(1, eventPayload(circleId, env)) }
        }
        refresh()
    }
    /// Cooldown to break handshake ping-pong (see handleHello). Keyed by "<peerHex>|<circleId>".
    private var lastHelloReply: [String: Date] = [:]

    private func handleEvent(_ payload: Data) {
        guard let social else { return }
        // [LP circleId][sealed envelope]
        var off = 0
        guard let circleIdData = lpRead(payload, &off) else { return }
        let circleId = String(data: circleIdData, encoding: .utf8) ?? ""
        let envelope = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        guard !circleId.isEmpty, !envelope.isEmpty else { return }
        // receive() verifies + decrypts — real CPU per frame, and event frames arrive in BURSTS
        // during a sync. Do the crypto off-main; hop back only for the (already-coalesced) applies.
        Task.detached(priority: .utility) { [weak self] in
            guard (try? social.receive(circleId: circleId, envelope: envelope)) == true else { return }
            await MainActor.run {
                guard let self else { return }
                // Hearing a message is proof of life — refresh "last seen" for a DM's partner.
                if circleId.hasPrefix("dm:"), let partner = self.dmPartnerHex(circleId) { self.recordHeard(partner) }
                self.schedulePersist()             // coalesced — a sync burst writes once, not per event
                self.scheduleRefresh()             // coalesced feed rebuild
                self.scheduleRequestMissingMedia() // coalesced media pull (scans the whole feed)
                self.notifyNewest(in: circleId)
                self.bumpUnseen(circleId)
            }
        }
    }

    func markCircleSeen() { unseenCircle = 0 }

    /// Inbound messages in a DM newer than its read watermark (see `DMReadStore`).
    func unreadMessages(in circleId: String) -> Int {
        let wm = DMReadStore.shared.watermark(circleId)
        return messages(in: circleId).filter { !$0.isMe && !$0.unsent && $0.createdAt > wm }.count
    }

    /// The user is viewing a DM thread: advance its watermark past the newest visible message and
    /// refresh the badges. (Opening the Messages TAB marks nothing read — only actually viewing a
    /// conversation does.)
    func markThreadRead(_ circleId: String) {
        let newest = messages(in: circleId).map(\.createdAt).max() ?? 0
        DMReadStore.shared.markRead(circleId, newestMessageAt: newest)
        recomputeUnreadDMs()
    }

    /// Messages-tab badge = number of CONVERSATIONS with unread messages. Watermark-based, not a
    /// session counter — it survives relaunch and clears only when threads are actually read.
    func recomputeUnreadDMs() {
        let n = dmCircles.reduce(0) { $0 + (unreadMessages(in: $1.id) > 0 ? 1 : 0) }
        if n != unseenMessages { unseenMessages = n }
    }

    /// Count a fresh inbound item as "unseen" for the badge (ignores historical back-fill).
    private func bumpUnseen(_ circleId: String) {
        if circleId.hasPrefix("dm:") { recomputeUnreadDMs(); return }   // DMs: watermark-based, always exact
        let inbound = messages(in: circleId).filter { !$0.isMe && !$0.unsent }
        guard let newest = inbound.max(by: { $0.createdAt < $1.createdAt }) else { return }
        guard now() &- newest.createdAt < 5 * 60 * 1000 else { return }   // recent only
        unseenCircle += 1
    }

    /// Post a local notification for the newest inbound item in a circle (no server).
    private func notifyNewest(in circleId: String) {
        let inbound = messages(in: circleId).filter { !$0.isMe && !$0.unsent }
        guard let newest = inbound.max(by: { $0.createdAt < $1.createdAt }) else { return }
        // FRESH items only (mirrors bumpUnseen). This fires on ANY change in the circle — a
        // history backfill, an epoch-rotation re-seal, a reaction to an old post — and then
        // notifies about the newest EXISTING message, not what actually arrived. Combined with
        // a wiped/fresh dedupe store that meant the same old message notified again and again;
        // an old message re-surfacing is never worth a banner.
        guard now() &- newest.createdAt < 10 * 60 * 1000 else { return }
        let name = ContactsStore.shared.name(forNodePrefix: newest.authorShort) ?? "Someone"
        // A biometric-locked circle must not spill its content (or even who/where) onto the lock
        // screen — mirror the NSE's redaction for this in-process notification path too.
        if CircleSettingsStore.shared.biometricRequired(circleId) {
            NotificationManager.shared.notify(title: "Haven", body: "New activity", dedupeKey: newest.id)
            return
        }
        let body = newest.story ? "shared a story" : (newest.body.isEmpty ? "sent you media" : newest.body)
        let title = circleId.hasPrefix("dm:") ? name : "\(name) in your circle"
        NotificationManager.shared.notify(title: title, body: body, dedupeKey: newest.id)
    }
}

/// Delivery state of a circle's authored content (the composer status light).
enum PostSyncStatus: Equatable {
    case synced, pending, stuck
    var color: Color { switch self { case .synced: return .green; case .pending: return .yellow; case .stuck: return .red } }
    var label: String {
        switch self {
        case .synced: return "Synced"
        case .pending: return "Syncing…"
        case .stuck: return "On this device only"
        }
    }
}

/// A small green/yellow/red light + label showing whether posts in this circle are getting out. Recomputed
/// on a light timer so it reflects an upload finishing or a peer connecting without needing a manual refresh.
/// Live media-sync counters, kept OUT of FeedStore so incrementing them never re-renders the feed/You
/// tab (that was the sync-time lag). Only the tap-to-open SyncDetailView observes this.
@MainActor final class SyncMetrics: ObservableObject {
    static let shared = SyncMetrics()
    private init() {}
    @Published var nbMediaOut = 0       // media items served/pushed over nearby
    @Published var nbMediaIn = 0        // media items fully received over nearby
    @Published var nbMediaPending = 0   // media refs still missing locally
}

struct SyncStatusBadge: View {
    let circleId: String
    @ObservedObject private var store = FeedStore.shared
    @State private var showDetail = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.5)) { _ in
            let s = store.syncStatus(circleId: circleId)
            // Only surface the pill when there's something to know — "Syncing…" or "device-only". When
            // everything's synced it collapses to nothing so it doesn't pad out the composer.
            if s != .synced {
                Button { showDetail = true } label: {
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                            .shadow(color: s.color.opacity(0.6), radius: 2)
                        Text(s.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Tap for live sync detail. Yellow: still syncing. Red: only on this device.")
                .transition(.opacity)
                .popover(isPresented: $showDetail, arrowEdge: .bottom) { SyncDetailView() }
            }
        }
    }
}

/// The "magical details" behind the sync light — surfaced only when the user taps the yellow/red pill, so
/// it's there when they want to monitor a sync but never clutters (or re-renders) the feed otherwise.
struct SyncDetailView: View {
    @ObservedObject private var m = SyncMetrics.shared
    @ObservedObject private var store = FeedStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync activity").font(.headline)
            Label("\(m.nbMediaOut) media sent", systemImage: "arrow.up.circle")
            Label("\(m.nbMediaIn) media received", systemImage: "arrow.down.circle")
            Label("\(m.nbMediaPending) media waiting", systemImage: "clock")
            Divider()
            Label(store.nearbyActive ? "Nearby devices: connected" : "Nearby devices: not connected",
                  systemImage: store.nearbyActive ? "antenna.radiowaves.left.and.right"
                                                  : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(store.nearbyActive ? HavenTheme.pink : .secondary)
            Text("Updates live while your devices and circles sync.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
        .padding(16)
        .frame(minWidth: 240, alignment: .leading)
        // On iPhone a popover adapts to a sheet — pin it to a small detent so it's a compact card, not full-screen.
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

struct FeedView: View {
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var gate = BiometricGate.shared
    let account: Account
    let friendName: String
    let seed: Data
    @State private var showCircle = false

    @State private var compose = ""
    @State private var attachedMedia: [String] = []
    @State private var attachedTrack: TrackRefFfi?
    @State private var muteVideo = false   // author's audio choice for attached video(s)
    @State private var pendingSensitive: [String]?   // attachments SCA flagged, awaiting send-anyway
    @State private var showLocation = false   // opt-in: tag the post with a photo's reverse-geocoded place
    @State private var showSchedule = false   // "send later" date picker
    @State private var dropActive = false   // drag-and-drop media onto the composer (macOS/iPadOS)
    @State private var showFilesImporter = false   // pick media from the Files app (iOS/iPadOS)
    @State private var showFilePicker = false      // macOS file browser (NSOpenPanel)
    @State private var showMediaPicker = false
    @State private var showCamera = false
    @State private var showSongPicker = false
    @State private var showLocationPicker = false
    @State private var composeRetention: UInt64?
    @State private var showNewCircle = false
    @State private var newCircleName = ""
    @State private var showStoryCamera = false
    @State private var showStories = false
    @State private var storyIndex = 0
    @State private var trimmingRef: TrimTarget?
    @State private var showRequests = false
    @ObservedObject private var connections = ConnectionsStore.shared
    @FocusState private var composeFocused: Bool
    @State private var commentingActive = false   // a post's comment field is focused → hide composer

    struct TrimTarget: Identifiable { let id = UUID(); let ref: String }

    init(account: Account, seed: Data, friendName: String) {
        self.account = account
        self.seed = seed
        self.friendName = friendName
    }

    /// The "My Circles" switcher (also: show/hide hidden posts, new circle). Extracted so it can be
    /// placed centered on iOS but pinned leading on macOS (where it would otherwise shove the top tabs).
    @ViewBuilder private var circlePicker: some View {
        Menu {
            ForEach(store.feedCircles, id: \.id) { c in
                Button { store.setActiveCircle(c.id) } label: {
                    Label(c.name, systemImage: c.id == store.activeCircleId ? "checkmark" : "circle.dashed")
                }
            }
            Divider()
            if !HiddenStore.shared.hidden.isEmpty {
                Button {
                    HiddenStore.shared.toggleShowHidden(); store.refresh()
                } label: {
                    Label(HiddenStore.shared.showHidden ? "Hide hidden posts" : "Show hidden posts (\(HiddenStore.shared.hidden.count))",
                          systemImage: HiddenStore.shared.showHidden ? "eye.slash" : "eye")
                }
            }
            Button { newCircleName = ""; showNewCircle = true } label: {
                Label("New circle…", systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.activeCircleName).font(.headline)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(.primary)
        }
        .menuIndicator(.hidden)   // macOS adds its own chevron; keep only our styled one
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                    .contentShape(Rectangle())
                    .onTapGesture { composeFocused = false }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        banner
                        if !connections.pending.isEmpty { pendingBanner }
                        storiesTray
                        if store.feedItems.isEmpty {
                            emptyState
                        }
                        ForEach(store.feedItems, id: \.id) { item in
                            PostCard(
                                item: item, friendName: friendName,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onUnreact: { e in withAnimation(HavenTheme.bouncy) { store.unreact(item.id, e) } },
                                onComment: { b, m in
                                    withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) }
                                    // Reveal the freshly added reply (it lands at the post's bottom).
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        withAnimation(HavenTheme.smooth) { proxy.scrollTo(item.id, anchor: .bottom) }
                                    }
                                },
                                onEdit: { b in withAnimation(HavenTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(HavenTheme.smooth) { store.unsend(item.id) } },
                                onCommentFocus: { focused in
                                    // Hide the feed composer while commenting (it overlapped the
                                    // comment), and lift the focused post above the keyboard.
                                    commentingActive = focused
                                    if focused {
                                        withAnimation(HavenTheme.smooth) { proxy.scrollTo(item.id, anchor: .bottom) }
                                    }
                                }
                            )
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PostCenterKey.self,
                                                       value: [item.id: geo.frame(in: .global).midY])
                            })
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                removal: .opacity))
                        }
                    }
                    .animation(HavenTheme.bouncy, value: store.items.count)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 130)
                }
                .scrollDismissesKeyboard(.immediately)
                .onPreferenceChange(PostCenterKey.self) { centers in
                    // The post nearest the vertical center of the screen becomes active.
                    let target = PlatformScreen.bounds.midY
                    let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                    AudioCoordinator.shared.center(nearest?.key)
                }
                }   // ScrollViewReader
                // Hide the "Share something" composer while a comment field is focused so it
                // doesn't float over the comment you're writing.
                if !commentingActive { composerBar }
            }
            .overlay {
                // Biometric-locked circle: cover its feed until Face ID unlocks it. The toolbar
                // circle-switcher stays usable so you can navigate away without unlocking.
                if gate.isLocked(store.activeCircleId) {
                    CircleLockView(circleName: store.activeCircleName, circleId: store.activeCircleId)
                }
            }
            .navigationTitle(store.activeCircleName)
            .havenInlineNavTitle()
            .toolbar {
                #if os(macOS)
                // On macOS the TabView's tabs (Circle / Messages / You) sit centered at the top; a
                // centered (.principal) circle switcher fought them for space and shoved them around as
                // its label width changed. Pin the switcher to the leading edge so the tabs stay put.
                ToolbarItem(placement: .havenLeading) { circlePicker }
                #else
                ToolbarItem(placement: .principal) { circlePicker }
                #endif
                // Manage this circle (members, invite, settings) — lives on the circle, not You.
                ToolbarItem(placement: .havenTrailing) {
                    Button { showCircle = true } label: { Image(systemName: "person.2.fill") }
                        .buttonStyle(HavenGlassIcon())
                        .accessibilityLabel("Manage circle")
                }
            }
            .sheet(isPresented: $showCircle) {
                NavigationStack { CircleView(account: account) }.macSheetClose()
            }
            .sheet(isPresented: $showNewCircle) {
                NewCircleView { name, members in store.createCircle(name: name, memberIds: members) }.macSheetClose()
            }
            .onAppear {
                store.configure(seed: seed)
                // Screenshot harness: open the full-screen story viewer for its hero shot.
                // The feed rebuild is async now, so RETRY until the demo stories are published
                // (a single fixed delay raced the off-main refresh and silently skipped the scene).
                if DemoEnv.scene == .story {
                    func tryPresent(_ attempt: Int = 0) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            if !store.groupedStoriesFlat.isEmpty {
                                storyIndex = 0; showStories = true
                            } else if attempt < 10 {
                                tryPresent(attempt + 1)
                            }
                        }
                    }
                    tryPresent()
                }
            }
            .sensoryFeedback(.success, trigger: store.postTick)
            .sensoryFeedback(.impact(weight: .light), trigger: store.reactionTick)
            .sheet(isPresented: $showMediaPicker) {
                MediaPicker { refs in attachedMedia.append(contentsOf: refs) }.macSheetClose()
            }
            #if os(macOS)
            .sheet(isPresented: $showFilePicker) {
                FilePicker { refs in attachedMedia.append(contentsOf: refs) }.macSheetFrame()
            }
            #endif
            .sheet(isPresented: $showLocationPicker) {
                LocationPicker { ref in attachedMedia.append(ref) }.macSheetClose()
            }
            .havenFullScreenCover(isPresented: $showCamera) {
                CameraView { refs in attachedMedia.append(contentsOf: refs) }.ignoresSafeArea()
            }
            .sheet(isPresented: $showSongPicker) {
                SongPicker { track in attachedTrack = track }.macSheetFrame()
            }
            .sheet(isPresented: $showSchedule) {
                SchedulePicker(circleId: store.activeCircleId, isDM: false) { date in scheduleCurrentPost(at: date) }.macSheetFrame()
            }
            .fileImporter(isPresented: $showFilesImporter,
                          allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                importFiles(urls)
            }
            .confirmationDialog("This media may be sensitive",
                                isPresented: Binding(get: { pendingSensitive != nil },
                                                     set: { if !$0 { pendingSensitive = nil } }),
                                titleVisibility: .visible) {
                Button("Send anyway", role: .destructive) {
                    let f = pendingSensitive ?? []; pendingSensitive = nil; doSend(flagged: f)
                }
                Button("Cancel", role: .cancel) { pendingSensitive = nil }
            } message: {
                Text("On-device analysis flagged one or more attachments as sensitive. If you send, they'll be blurred for everyone in the circle until each person taps to reveal.")
            }
            .havenFullScreenCover(isPresented: $showStoryCamera) {
                StoryCameraView { ref, caption, track in
                    Task { @MainActor in
                        // A long video becomes up to 5 consecutive story slides.
                        let refs = await MediaStore.shared.splitStoryVideo(ref)
                        for r in refs { store.postStory(media: [r], caption: caption, music: track) }
                    }
                }
            }
            .sheet(isPresented: $showRequests) { ConnectionRequestsView().macSheetClose() }
            .havenFullScreenCover(isPresented: $showStories) {
                // `.id(storyIndex)` forces a fresh StoryViewer per tapped user — otherwise SwiftUI reuses
                // the view identity and its @State `index` sticks at the first value, so every tap opened
                // the lineup from the far-left user instead of the one tapped.
                StoryViewer(stories: store.groupedStoriesFlat, index: storyIndex, friendName: friendName)
                    .id(storyIndex)
            }
            .havenFullScreenCover(item: $trimmingRef) { target in
                if let url = MediaStore.shared.storagePath(for: target.ref) {
                    VideoTrimmer(path: url.path) { trimmed in
                        replaceAttached(target.ref, with: MediaStore.shared.importTrimmed(trimmed))
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40)).foregroundStyle(HavenTheme.pink)
            Text("Nothing here yet")
                .font(.headline)
            Text("Share your first moment below. As your circle connects, their posts show up here too.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60).padding(.horizontal, 24)
    }

    private var pendingBanner: some View {
        Button { showRequests = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark.fill")
                    .font(.title2).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connections.pending.count == 1 ? "1 connection request" : "\(connections.pending.count) connection requests")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("Tap to review who wants to connect").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.85))
            }
            .padding(14)
            .background(HavenTheme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var storiesTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button { showStoryCamera = true } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().strokeBorder(HavenTheme.brandHorizontal, lineWidth: 2).frame(width: 62, height: 62)
                            Image(systemName: "camera.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                        }
                        Text("Add").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                ForEach(Array(store.groupedStories.enumerated()), id: \.element.author) { gi, group in
                    Button { storyIndex = store.storyStartIndex(forGroup: gi); showStories = true } label: {
                        VStack(spacing: 6) {
                            storyThumb(group.items.last ?? group.items[0])   // latest as the cover
                            Text((group.items.first?.isMe ?? false) ? "You" : (ContactsStore.shared.name(forNodePrefix: group.author) ?? friendName))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
        }
    }

    private func storyThumb(_ s: FeedItemFfi) -> some View {
        let img = s.media.first.flatMap { MediaStore.shared.item($0)?.image }
        return ZStack {
            Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
            if let img {
                Image(platformImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
            } else {
                Circle().fill(Color(.secondarySystemBackground)).frame(width: 56, height: 56)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Circle().fill(store.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(connectionText)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private var connectionText: String {
        guard store.online else { return "Offline — posts sync when you reconnect" }
        var paths: [String] = []
        if store.internetActive { paths.append("internet") }
        if store.nearbyActive { paths.append("nearby") }
        if paths.isEmpty { return "Online — looking for your circle…" }
        return "Connected · " + paths.joined(separator: " + ")
    }

    private var composerBar: some View {
        VStack { Spacer()
            VStack(spacing: 8) {
                // Delivery status for this circle: green = safely in your relay / reached a member,
                // yellow = still syncing, red = only on this device. So you know if a post got out.
                // Delivery light: tap the yellow/red pill to dive into live sync detail (sent/received/waiting).
                HStack { Spacer(); SyncStatusBadge(circleId: store.activeCircleId) }
                if !attachedMedia.isEmpty || attachedTrack != nil || composeRetention != nil { attachmentTray }
                // Opt-in location tag — only when a photo/video with GPS is attached. Default off.
                if MediaStore.shared.anyLocated(attachedMedia) {
                    Toggle(isOn: $showLocation) {
                        Label("Show location", systemImage: "mappin.and.ellipse").font(.caption.weight(.medium))
                    }
                    .tint(HavenTheme.pink)
                    .padding(.horizontal, 4)
                }
                HStack(spacing: 10) {
                    Menu {
                        Button { showMediaPicker = true } label: { Label("Photo or Video", systemImage: "photo.on.rectangle") }
                        Button {
                            #if os(iOS)
                            showFilesImporter = true   // Files app
                            #else
                            showFilePicker = true       // macOS file browser (NSOpenPanel)
                            #endif
                        } label: { Label("Files…", systemImage: "folder") }
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                        Button { showSongPicker = true } label: { Label("Add a song", systemImage: "music.note") }
                        Button { showLocationPicker = true } label: { Label("Pin a location", systemImage: "mappin.and.ellipse") }
                        Divider()
                        Menu {
                            Button("Off") { composeRetention = nil }
                            Button("1 hour") { composeRetention = 3_600 }
                            Button("1 day") { composeRetention = 86_400 }
                            Button("1 week") { composeRetention = 604_800 }
                        } label: { Label("Disappears after…", systemImage: "timer") }
                        if !compose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedMedia.isEmpty {
                            Button { showSchedule = true } label: { Label("Send later…", systemImage: "clock") }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title).foregroundStyle(HavenTheme.pink)
                    }
                    .accessibilityIdentifier("attachMenu")
                    .menuIndicator(.hidden)   // no macOS disclosure chevron next to the + button
                    #if os(macOS)
                    .menuStyle(.borderlessButton)   // drop the rectangular button chrome — just the circle
                    .fixedSize()
                    #endif

                    TextField("Share something…", text: $compose, axis: .vertical)
                        .accessibilityIdentifier("composeField")
                        .focused($composeFocused)
                        .textFieldStyle(.plain)   // drop the macOS system focus ring/border — matches iOS
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        // A fixed-radius rounded rect — a Capsule's radius grows with height and
                        // clips into the text once the field wraps to multiple lines.
                        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08)))

                    Button { send() } label: {
                        Image(systemName: "paperplane.fill").foregroundStyle(.white)
                            .padding(13).background(HavenTheme.brand, in: Circle())
                            .shadow(color: HavenTheme.pink.opacity(0.4), radius: 8, y: 4)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("composeSend")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                if dropActive {
                    Rectangle().fill(HavenTheme.pink.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(HavenTheme.pink, style: StrokeStyle(lineWidth: 2, dash: [6])))
                        .overlay(Label("Drop to attach", systemImage: "tray.and.arrow.down.fill").font(.subheadline.weight(.semibold)).foregroundStyle(HavenTheme.pink))
                        .allowsHitTesting(false)
                }
            }
            // Drag media in from Finder / Files / Photos and it becomes attachments on the next post.
            .onDrop(of: [.image, .movie, .fileURL], isTargeted: $dropActive) { providers in
                handleComposerDrop(providers)
            }
        }
    }

    /// Load dropped images/videos into MediaStore and attach them to the composer. Returns true if at
    /// least one provider is a media type we can ingest.
    private func handleComposerDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                handled = true
                p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url else { return }
                    // The provided URL is a short-lived temp; copy it before the closure returns.
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drop_\(UUID().uuidString).\(ext)")
                    try? FileManager.default.copyItem(at: url, to: tmp)
                    Task { @MainActor in
                        let ref = await MediaStore.shared.addVideo(url: tmp)
                        attachedMedia.append(ref)
                    }
                }
            } else if p.canLoadObject(ofClass: PlatformImage.self) {
                handled = true
                _ = p.loadObject(ofClass: PlatformImage.self) { obj, _ in
                    guard let img = obj as? PlatformImage else { return }
                    Task { @MainActor in attachedMedia.append(MediaStore.shared.addImage(img)) }
                }
            }
        }
        return handled
    }

    /// Ingest files chosen from the Files app. Each URL is security-scoped, so access must be opened
    /// around the read and the bytes copied into MediaStore before the scope closes.
    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if let type, type.conforms(to: .movie) {
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("files_\(UUID().uuidString).\(ext)")
                try? FileManager.default.copyItem(at: url, to: tmp)
                if scoped { url.stopAccessingSecurityScopedResource() }
                Task { @MainActor in attachedMedia.append(await MediaStore.shared.addVideo(url: tmp)) }
            } else if let data = try? Data(contentsOf: url), let img = PlatformImage(data: data) {
                if scoped { url.stopAccessingSecurityScopedResource() }
                attachedMedia.append(MediaStore.shared.addImage(img))
            } else if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedMedia, id: \.self) { ref in
                    if let m = MediaStore.shared.item(ref), let img = MediaStore.shared.thumbnail(ref, maxDimension: 160) {
                        ZStack(alignment: .topTrailing) {
                            Image(platformImage: img).resizable().scaledToFill()
                                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .bottomLeading) {
                                    if m.kind == .video { videoEditMenu(ref) }
                                }
                            removeChip { attachedMedia.removeAll { $0 == ref } }
                        }
                    } else if SharedLocation.parse(ref) != nil {
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 2) {
                                Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                                Text("Location").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(width: 56, height: 56)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            removeChip { attachedMedia.removeAll { $0 == ref } }
                        }
                    }
                }
                if let track = attachedTrack {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                        Text(track.title).font(.caption2).lineLimit(1)
                        Button { attachedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(HavenTheme.brandHorizontal.opacity(0.18), in: Capsule())
                }
                // Per-post video audio: only meaningful with a video and no song (a song
                // always plays over a muted video). Toggles between the video's own sound
                // and a silent share.
                if attachedTrack == nil && attachedMedia.contains(where: { MediaStore.shared.item($0)?.kind == .video }) {
                    Button { muteVideo.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: muteVideo ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            Text(muteVideo ? "Video muted" : "Video sound").font(.caption2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .foregroundStyle(muteVideo ? AnyShapeStyle(.secondary) : AnyShapeStyle(HavenTheme.pink))
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let secs = composeRetention {
                    HStack(spacing: 6) {
                        Image(systemName: "timer")
                        Text("Disappears: \(Self.retentionLabel(secs))").font(.caption2).lineLimit(1)
                        Button { composeRetention = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
        }
    }

    private static func retentionLabel(_ secs: UInt64) -> String {
        switch secs {
        case ..<3_600: return "\(secs / 60)m"
        case ..<86_400: return "\(secs / 3_600)h"
        case ..<604_800: return "\(secs / 86_400)d"
        default: return "\(secs / 604_800)w"
        }
    }

    private func removeChip(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.white)
                .background(Circle().fill(.black.opacity(0.5)))
        }
        .padding(3)
    }

    private func videoEditMenu(_ ref: String) -> some View {
        Menu {
            if MediaStore.shared.canTrim(ref) {
                Button { trimmingRef = TrimTarget(ref: ref) } label: { Label("Trim", systemImage: "scissors") }
            }
            Button { muteVideo.toggle() } label: {
                Label(muteVideo ? "Play video sound" : "Mute video sound",
                      systemImage: muteVideo ? "speaker.wave.2" : "speaker.slash")
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.white)
                .padding(4).background(.ultraThinMaterial, in: Circle())
        }
        .padding(3)
    }

    private func replaceAttached(_ old: String, with new: String) {
        if let i = attachedMedia.firstIndex(of: old) { attachedMedia[i] = new }
    }

    /// Queue the current composer contents to post at a future time, then clear the field.
    private func scheduleCurrentPost(at date: Date) {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedMedia.isEmpty else { return }
        ScheduledStore.shared.schedule(circleId: store.activeCircleId, isDM: false, body: text, media: attachedMedia, at: date)
        compose = ""; attachedMedia = []; attachedTrack = nil; composeRetention = nil; muteVideo = false; showLocation = false
        composeFocused = false
    }

    private func send() {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedMedia.isEmpty || attachedTrack != nil else { return }
        // Sender-side check: if on-device Sensitive Content Analysis flags an attachment, ask before
        // sending. (Only when the user has SCA on; otherwise post straight away.)
        let media = attachedMedia
        guard SensitiveContentScanner.shared.isEnabled, !media.isEmpty else { doSend(flagged: []); return }
        Task { @MainActor in
            var flagged: [String] = []
            for ref in media where await SensitiveContentScanner.shared.isSensitive(ref: ref) { flagged.append(ref) }
            if flagged.isEmpty { doSend(flagged: []) } else { pendingSensitive = flagged }
        }
    }

    /// Actually post, then federate a flag for any attachment confirmed sensitive so recipients
    /// without SCA (Android/desktop) blur it too. If "Show location" is on, a photo's GPS is
    /// reverse-geocoded into a tappable map pin attached to the post.
    private func doSend(flagged: [String]) {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        // Snapshot compose state, then clear the UI immediately (the geocode is async).
        let base = attachedMedia, track = attachedTrack, retention = composeRetention, mute = muteVideo
        let wantLocation = showLocation
        let cid = store.activeCircleId
        compose = ""; attachedMedia = []; attachedTrack = nil; composeRetention = nil; muteVideo = false
        showLocation = false; composeFocused = false
        Task { @MainActor in
            var media = base
            if wantLocation,
               let located = base.first(where: { MediaStore.shared.location(for: $0) != nil }),
               let coord = MediaStore.shared.location(for: located) {
                let name = await SharedLocation.placeName(coord)
                media.insert(SharedLocation.ref(lat: coord.latitude, lon: coord.longitude, label: name), at: 0)
            }
            store.post(text, media: media, music: track, retentionSecs: retention, muteVideo: mute)
            for ref in flagged { store.flagSensitive(circleId: cid, ref: ref) }
        }
    }
}

struct PostCard: View {
    let item: FeedItemFfi
    let friendName: String
    let onReact: (String) -> Void
    var onUnreact: (String) -> Void = { _ in }
    let onComment: (String, [String]) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void
    /// When true (the "show all comments" sheet) every comment is shown; otherwise the inline
    /// list is capped at 3 with a "show all" control.
    var expandAllComments = false
    /// Called when the "Add a reply…" field gains focus so the enclosing scroll view (which owns
    /// the ScrollViewReader proxy) can lift this post above the keyboard.
    var onCommentFocus: ((Bool) -> Void)? = nil

    @ObservedObject private var audio = AudioCoordinator.shared
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var feed = FeedStore.shared
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isPortraitPhone: Bool { hSizeClass == .compact }
    #else
    private var isPortraitPhone: Bool { false }
    #endif
    /// A single photo/video sizes to fill the WIDTH on a portrait phone (a tall shot fills the column
    /// instead of shrinking to a narrow sliver), but fits the WHOLE image within a shorter cap on wider
    /// layouts (iPad / landscape / macOS) so you can see all of it at once.
    private var singleMediaMaxHeight: CGFloat { isPortraitPhone ? 680 : 460 }
    @State private var showAllComments = false
    @State private var commentText = ""
    @State private var commentMedia: [String] = []
    @State private var showCommentMediaPicker = false
    @State private var showAudioRecorder = false
    @State private var showEdit = false
    @State private var showReport = false
    @State private var zoomTarget: ZoomTarget?
    @State private var players: [String: AVPlayer] = [:]
    @State private var playerObservers: [String: NSObjectProtocol] = [:]   // loop observers, removed on teardown
    @State private var showReactionPicker = false
    @State private var editCommentId: String?
    @State private var editCommentText = ""
    @State private var editCommentMedia: [String] = []
    @State private var commentReactTarget: CommentReactTarget?
    @FocusState private var commentFieldFocused: Bool

    struct CommentReactTarget: Identifiable { let id: String }
    @State private var currentPage = 0
    @State private var carouselScrubbing = false   // hides the carousel dots while a video is being scrubbed
    @State private var showHeart = false
    @State private var showReactionDetail = false

    private var isActive: Bool { audio.centeredPostId == item.id }

    /// Display name for the post's author — resolved from your contacts by node id.
    private var authorName: String {
        if item.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? friendName
    }
    private func commentAuthorName(_ c: FeedCommentFfi) -> String {
        if c.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: c.authorShort) ?? friendName
    }

    private var primaryVideoPlayer: AVPlayer? {
        guard item.media.count == 1, let ref = item.media.first, isVideo(ref) else { return nil }
        return players[ref]
    }
    /// A post that is exactly one video — the GestureVideoPlayer owns all of its gestures.
    private var isSingleVideoPost: Bool {
        item.media.count == 1 && (item.media.first.map(isVideo) ?? false)
    }
    private func isVideo(_ ref: String) -> Bool { MediaStore.shared.item(ref)?.kind == .video }

    private func react(_ e: String) { EmojiStore.shared.record(e); onReact(e) }

    /// Double-tap a post to ❤️ it (with an Instagram-style heart pop).
    private func heartIt() {
        react("❤️")
        withAnimation(HavenTheme.bouncy) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(HavenTheme.smooth) { showHeart = false }
        }
    }

    /// Single-tap a post's media to mute/unmute its sound (video audio or its song).
    private func togglePostMute() {
        let hasVideo = item.media.contains(where: isVideo)
        // Make sure this post is the active audio source first, so the toggle acts on it.
        if (hasVideo || item.music != nil), audio.activePostId != item.id {
            audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo)
        }
        if hasVideo {
            // Tapping a video toggles *its own* sound (same as the speaker button) — overriding
            // the author's mute and any global silence so a tap always brings the audio up.
            if SettingsStore.shared.silent { SettingsStore.shared.silent = false }
            audio.toggleVideoAudio()
        } else {
            // A photo / song-only post: a tap still toggles the app's global mute.
            SettingsStore.shared.silent.toggle()
        }
    }

    private var heartBurst: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 86)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 10)
            .scaleEffect(showHeart ? 1 : 0.4)
            .opacity(showHeart ? 0.95 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Another member reported this post → surface the circle's shared moderation signal
            // with per-viewer actions (hide / remove from circle / block). The reporter themselves
            // never sees it — reporting hid the post for them.
            if !item.isMe, let reps = feed.reports(circleId: feed.activeCircleId)[item.id], !reps.isEmpty {
                ReportedBanner(item: item, authorName: authorName, reports: reps)
            }
            if item.unsent {
                Label("Message unsent", systemImage: "minus.circle")
                    .font(.subheadline).italic().foregroundStyle(.secondary)
            } else {
                if !item.body.isEmpty { LinkedText(text: item.body) }
                // Rich Open Graph preview for the first link in a text post (no media of its own).
                if item.media.isEmpty, let url = LinkScanner.urls(in: item.body).first {
                    LinkPreviewCard(url: url)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, 8).padding(.horizontal, 2)
                }
                if !item.media.isEmpty {
                    // For a single-video post the GestureVideoPlayer owns tap/double-tap/hold/
                    // scrub itself (so its hold-to-pause and drag-to-scrub aren't stolen). For
                    // everything else the post-level tap gestures drive mute + heart.
                    if isSingleVideoPost {
                        mediaView
                            .overlay { if showHeart { heartBurst } }
                    } else {
                        mediaView
                            .overlay { if showHeart { heartBurst } }
                            .onTapGesture(count: 2) { heartIt() }       // double-tap to heart
                            .onTapGesture(count: 1) { togglePostMute() } // tap to mute/unmute
                    }
                }
                if let track = item.music { NowPlayingPill(track: track, animating: true) }
                reactionsRow
                if !item.comments.isEmpty { commentsList }
                commentField
            }
        }
        .havenCard()
        .onAppear { syncPlayback() }
        .onDisappear { teardownPlayers() }
        .onChange(of: audio.centeredPostId) { syncPlayback() }
        .onChange(of: currentPage) { if isActive { playVisibleVideo() } }
        .sheet(isPresented: $showEdit) { EditPostSheet(item: item).macSheetFrame() }
        .sheet(isPresented: $showReport) { ReportSheet(item: item, authorName: authorName) }
        .havenFullScreenCover(item: $zoomTarget, wide: true) { t in MediaZoomViewer(refs: t.refs, index: t.index) }
        .alert("Edit comment", isPresented: Binding(get: { editCommentId != nil }, set: { if !$0 { editCommentId = nil } })) {
            TextField("Comment", text: $editCommentText)
            Button("Save") { if let id = editCommentId { feed.edit(id, editCommentText, media: editCommentMedia) }; editCommentId = nil }
            Button("Cancel", role: .cancel) { editCommentId = nil }
        }
    }

    /// A shared location is encoded as a synthetic `geo:` ref inside `media` (index 0). It is NOT real
    /// media, so it must be drawn as a map and kept OUT of the photo grid / zoom viewer — otherwise it
    /// degrades to a forever-spinner tile (MediaStore has no file for it).
    private var realMedia: [String] { item.media.filter { SharedLocation.parse($0) == nil } }

    @ViewBuilder private var mediaView: some View {
        VStack(spacing: 8) {
            if let geo = item.media.first(where: { SharedLocation.parse($0) != nil }),
               let loc = SharedLocation.parse(geo) {
                LocationMapView(lat: loc.lat, lon: loc.lon, label: loc.label)
            }
            let media = realMedia
            if media.count == 1, let ref = media.first {
                let video = isVideo(ref)
                ZStack(alignment: .bottomTrailing) {
                    mediaPage(ref)
                    if video { muteButton }
                }
                // Size to the media's own aspect. On a portrait phone the taller cap lets a tall photo fill
                // the column width (was capped at 480 → a narrow "square" sliver); wider layouts fit the
                // whole image within a shorter cap.
                .aspectRatio(singleAspect(ref), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: singleMediaMaxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                // Tap-to-zoom only for images. For a video, the player owns the single tap
                // (mute) / hold (pause) / drag (scrub); a zoom tap here would swallow them.
                .modifier(ConditionalTap(enabled: !video) { zoomTarget = ZoomTarget(refs: media, index: 0) })
            } else if media.count <= 7, allSameAspect(media) {
                mediaCarousel(media)   // uniform-aspect set → a swipeable pager (autoplays the visible video)
            } else if !media.isEmpty {
                masonry   // mixed aspects or a big set → the staggered grid; tap any to zoom
            }
        }
    }

    /// True when a small media set all share (near-)equal aspect ratios — the case where a full-width
    /// swipeable carousel looks clean (vs a staggered grid for mixed shapes).
    private func allSameAspect(_ media: [String]) -> Bool {
        guard let a0 = media.first.map(singleAspect) else { return false }
        return media.allSatisfy { abs(singleAspect($0) - a0) < 0.06 }
    }

    /// A full-width swipeable pager for a uniform-aspect set. The visible page's video autoplays as you
    /// swipe (playVisibleVideo keys off `currentPage`), matching the single-media behavior.
    @ViewBuilder private func mediaCarousel(_ media: [String]) -> some View {
        let aspect = singleAspect(media[0])
        // A ScrollView pager (NOT TabView) so it works on macOS too — a TabView renders its pages as
        // tab-bar items on macOS, dumping the dots into the nav toolbar. Custom dots overlay the carousel.
        // showsIndicators:false in the initializer (not just the .scrollIndicators modifier) — on macOS the
        // modifier alone doesn't suppress AppKit's legacy scroller, which showed an ugly bar under the dots.
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(Array(media.enumerated()), id: \.offset) { i, ref in
                    ZStack(alignment: .bottomTrailing) {
                        // The player scrubs only from the bottom 1/3 (top 2/3 pages the carousel); a photo
                        // page has no scrub strip so the whole page pages.
                        mediaPage(ref, inCarousel: true, onScrubbing: { carouselScrubbing = $0 })
                        if isVideo(ref) { muteButton }
                    }
                    .containerRelativeFrame(.horizontal)   // each page == the carousel's width
                    .modifier(ConditionalTap(enabled: !isVideo(ref)) { zoomTarget = ZoomTarget(refs: media, index: i) })
                    .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding<Int?>(get: { currentPage }, set: { currentPage = $0 ?? currentPage }))
        .scrollIndicators(.hidden)
        .scrollDisabled(carouselScrubbing)   // while scrubbing a video, don't let a swipe page the carousel
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: singleMediaMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            // Dots hide while scrubbing so the scrub bar doesn't collide with them.
            if media.count > 1 && !carouselScrubbing { carouselDots(media.count) }
        }
    }

    private func carouselDots(_ count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(.white.opacity(i == currentPage ? 0.95 : 0.4)).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    /// Horizontally-scrolling staggered gallery: items flow across two fixed-height rows and
    /// you swipe sideways through them. Each tile keeps its natural aspect (width = row · aspect).
    private var masonry: some View {
        let rows = 2
        let rowHeight: CGFloat = 150
        let media = realMedia
        let rowItems = (0..<rows).map { ri in
            media.enumerated().filter { $0.offset % rows == ri }.map { $0.element }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<rows, id: \.self) { ri in
                    HStack(spacing: 6) {
                        ForEach(rowItems[ri], id: \.self) { ref in masonryTile(ref, height: rowHeight) }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: rowHeight * CGFloat(rows) + 6)
    }

    @ViewBuilder private func masonryTile(_ ref: String, height: CGFloat) -> some View {
        // Use a downscaled thumbnail (≈3× the row height for retina), not the full-res image — rendering a
        // 2560px bitmap in a 150px tile was the scroll lag. Full-res stays for the zoom viewer.
        // Use MediaKind(ref:) (a cheap string parse) for the play badge — NOT item(ref), which would
        // generate the video poster on the main thread as each tile scrolls into view (the scroll lag).
        // thumbnail(_:) now produces video posters off-main and fills them in via a refresh.
        if let img = MediaStore.shared.thumbnail(ref, maxDimension: height * 3) {
            // Aspect width for the fixed row height, clamped so a panorama/portrait stays sane.
            let aspect = min(2.4, max(0.6, img.size.width / max(img.size.height, 1)))
            Image(platformImage: img).resizable().scaledToFill()
                .frame(width: height * aspect, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .center) {
                    if MediaKind(ref: ref) == .video {
                        Image(systemName: "play.circle.fill").font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
                    }
                }
                // Blur media flagged sensitive — by this device's SCA or any circle member's
                // federated flag (protects viewers whose platform has no SCA).
                .sensitiveContentGuard(ref: ref, circleId: FeedStore.shared.activeCircleId, scan: !item.isMe)
                .onTapGesture {
                    let media = realMedia
                    if let idx = media.firstIndex(of: ref) { zoomTarget = ZoomTarget(refs: media, index: idx) }
                }
        } else {
            // Not downloaded yet — a compact loading tile keeps the gallery layout intact.
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill))
                ProgressView()
            }
            .frame(width: height * 1.2, height: height)
        }
    }

    @ViewBuilder private func mediaPage(_ ref: String, inCarousel: Bool = false,
                                        onScrubbing: @escaping (Bool) -> Void = { _ in }) -> some View {
        if isVideo(ref) {
            // No contextMenu for videos — the long-press is reserved for the player's
            // hold-to-pause. Save/Share live in the mute control's menu instead.
            mediaPageContent(ref, inCarousel: inCarousel, onScrubbing: onScrubbing)
        } else {
            mediaPageContent(ref)
                .contextMenu {
                    Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    if let url = shareURL(ref) {
                        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                }
        }
    }

    /// The on-disk file to hand to the system share sheet (video file, else the image).
    private func shareURL(_ ref: String) -> URL? {
        guard let m = MediaStore.shared.item(ref) else { return nil }
        return m.kind == .video ? m.videoURL : MediaStore.shared.storagePath(for: ref)
    }

    @ViewBuilder private func mediaPageContent(_ ref: String, inCarousel: Bool = false,
                                               onScrubbing: @escaping (Bool) -> Void = { _ in }) -> some View {
        if let m = MediaStore.shared.item(ref) {
            if m.kind == .video, let url = m.videoURL {
                // The player owns its gestures: tap → mute, double-tap → heart,
                // hold → pause, horizontal drag → scrub. Letterboxed, loops continuously.
                GestureVideoPlayer(player: playerFor(ref, url),
                                   onTap: { togglePostMute() },
                                   onDoubleTap: { heartIt() },
                                   inCarousel: inCarousel,
                                   onScrubbing: onScrubbing)
            } else if let img = MediaStore.shared.thumbnail(ref, maxDimension: 1200) ?? m.image {
                // A ~1200px thumbnail (not the 2560px original) keeps the single-image post crisp at the
                // feed's ≤480pt frame without re-sampling a giant bitmap every scroll frame. Zoom uses full-res.
                Image(platformImage: img).resizable().scaledToFit()      // show the whole image (no crop)
            } else {
                mediaLoadingPlaceholder(ref)
            }
        } else {
            // Referenced but not here yet — it's still coming from the sender / mailbox.
            mediaLoadingPlaceholder(ref)
        }
    }

    /// Shown for a media reference whose bytes haven't arrived yet, so the post doesn't look
    /// broken while it's still downloading from the sender, a relay, or the shared mailbox.
    @ViewBuilder private func mediaLoadingPlaceholder(_ ref: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemFill))
            VStack(spacing: 8) {
                ProgressView()
                Text(isVideo(ref) ? "Video still loading…" : "Media still loading…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// The single-media tile's aspect ratio, taken from the image (or a video's thumbnail).
    private func singleAspect(_ ref: String) -> CGFloat {
        // Read pixel dimensions from the file header (ImageIO) — NOT item()?.image.size, which decoded the
        // whole bitmap on the main thread just to get an aspect ratio (a scroll hitch per single-media post).
        if let sz = MediaStore.shared.pixelSize(ref), sz.width > 0, sz.height > 0 {
            return sz.width / sz.height
        }
        return 4.0 / 3.0
    }

    @ViewBuilder private var muteButton: some View {
        let ref = item.media.first
        Button {
            if audio.activePostId != item.id { audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo) }
            audio.toggleVideoAudio()
        } label: {
            Image(systemName: audio.activePostId == item.id && audio.videoUnmuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(.white)
        }
        // A glass circle chip and nothing else — the default button style painted its own
        // rounded-rect bezel BEHIND the circle on macOS (the doubled-background look).
        .buttonStyle(GlassIconButtonStyle(tint: .white))
        .padding(10)
        // Save/Share lives here for videos (the player's long-press is hold-to-pause, so the
        // video itself no longer carries a contextMenu).
        .contextMenu {
            if let ref {
                Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                if let url = shareURL(ref) {
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }

    private func playerFor(_ ref: String, _ url: URL) -> AVPlayer {
        if let p = players[ref] { return p }
        let p = AVPlayer(url: url)
        p.volume = 0
        p.actionAtItemEnd = .none
        // When the clip ends, loop it (muted) and — if we're still on this post —
        // bring the song back, so the music never stays paused under an idle video.
        let postId = item.id
        // CRITICAL: capture the player WEAKLY. addObserver(forName:) returns a token whose closure is
        // retained by NotificationCenter until removed — a strong `p` capture meant every AVPlayer (and
        // its video decode buffers) lived forever even after the card scrolled away. That was the runaway
        // leak (memory climbed into the tens of GB). We also store the token and remove it on teardown.
        let token = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                               object: p.currentItem, queue: .main) { [weak p] _ in
            guard let p else { return }
            MainActor.assumeIsolated {   // observer is delivered on .main, so this is genuinely isolated
                p.seek(to: .zero)
                if AudioCoordinator.shared.centeredPostId == postId {
                    p.play()
                    AudioCoordinator.shared.videoFinished()
                }
            }
        }
        DispatchQueue.main.async {
            players[ref] = p
            playerObservers[ref] = token
            if isActive { playVisibleVideo() }
        }
        return p
    }

    /// Drive this card's media from whether it's the centered post: the active post
    /// plays its song + the visible carousel video; an inactive post pauses everything.
    private func syncPlayback() {
        if isActive {
            audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo)
            audio.ensureMusicPlaying()   // resume the song if a video had paused it
            playVisibleVideo()
        } else {
            pauseVideos()
        }
    }

    private func pauseVideos() { players.values.forEach { $0.pause() } }

    /// Fully release this card's video players when it scrolls off-screen — pause, replace each item with
    /// nothing (frees the decode pipeline), remove the loop observers, and drop the dicts. Without this an
    /// off-screen card kept buffering video forever; combined with the leaked observers it ran to ~100 GB.
    private func teardownPlayers() {
        for (_, token) in playerObservers { NotificationCenter.default.removeObserver(token) }
        for (_, p) in players { p.pause(); p.replaceCurrentItem(with: nil) }
        playerObservers.removeAll()
        players.removeAll()
    }

    private func playVisibleVideo() {
        guard isActive else { return }
        let visibleRef: String? = item.media.isEmpty
            ? nil
            : item.media[min(max(currentPage, 0), item.media.count - 1)]
        #if os(iOS)
        // A post's music plays on the system music player; without mixing, that music takes the audio
        // session and INTERRUPTS the video's AVPlayer, so the (muted) video just froze. Mix so the video
        // plays alongside the music. Safe when the video is unmuted too (it simply mixes its own audio).
        if let visibleRef, isVideo(visibleRef) {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
        }
        #endif
        for (ref, player) in players {
            if ref == visibleRef && isVideo(ref) {
                player.seek(to: .zero)
                player.play()
            } else {
                player.pause()
            }
        }
    }

    @ViewBuilder private var avatar: some View {
        if item.isMe {
            HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 34)
        } else {
            PeerAvatar(nodeHex: item.authorShort, name: authorName, size: 34)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if item.isMe {
                avatar
                Text(authorName).font(.subheadline.weight(.semibold))
            } else {
                NavigationLink {
                    UserProfileView(authorHex: item.authorShort, name: authorName)
                } label: {
                    HStack(spacing: 10) {
                        avatar
                        Text(authorName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
            Text(relativeTimeShort(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
            if item.edited {
                Text("edited").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
            }
            // Sync state for your own posts, only when a shared store is in play (else
            // posts deliver peer-to-peer and there's no "backed up" notion to show).
            if item.isMe && !item.unsent && SharedStore.isVolunteering {
                Image(systemName: feed.relayReachable ? "cloud.fill" : "cloud")
                    .font(.caption2)
                    .foregroundStyle(feed.relayReachable ? AnyShapeStyle(HavenTheme.pink) : AnyShapeStyle(Color.secondary))
                    .help(feed.relayReachable ? "Backed up to your circle's store" : "Waiting to sync")
            }
            Spacer()
            if !item.unsent {
                Menu {
                    if let url = DeepLink.postURL(circleId: feed.activeCircleId, postId: item.id) {
                        ShareLink(item: url) { Label("Share post", systemImage: "square.and.arrow.up") }
                    }
                    if item.isMe {
                        Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { onUnsend() } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
                    }
                    // Hide any post from my own feed (reversible). Local + per-device.
                    let isHidden = HiddenStore.shared.isHidden(item.id)
                    Button {
                        if isHidden { HiddenStore.shared.unhide(item.id) } else { HiddenStore.shared.hide(item.id) }
                        feed.refresh()
                    } label: { Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash") }
                    if !item.isMe {
                        Button(role: .destructive) { showReport = true } label: {
                            Label("Report", systemImage: "flag")
                        }
                    }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(6) }
            }
        }
    }

    // Show only the most-reacted few chips so a post with many distinct emoji can't flood the row and
    // break the layout; the rest collapse into a "+N" chip that opens the full who-reacted sheet. A chip
    // the user owns is always kept visible (so they can untap it), even if it's not in the top counts.
    private static let maxReactionChips = 4
    private var visibleReactions: [ReactionFfi] { Self.cappedReactions(item.reactions, cap: Self.maxReactionChips) }
    private var hiddenReactionCount: Int { max(0, item.reactions.count - visibleReactions.count) }

    /// The most-reacted `cap` chips, always keeping the user's own (so they can untap it) — sorted by
    /// count descending. Used to bound both the post- and comment-level reaction rows.
    static func cappedReactions(_ reactions: [ReactionFfi], cap: Int) -> [ReactionFfi] {
        var shown = Array(reactions.sorted { $0.count > $1.count }.prefix(cap))
        if let mine = reactions.first(where: { $0.mine }), !shown.contains(where: { $0.emoji == mine.emoji }) {
            if shown.count >= cap { shown.removeLast() }
            shown.append(mine)
        }
        return shown
    }

    private var reactionsRow: some View {
        HStack(spacing: 8) {
            ForEach(visibleReactions, id: \.emoji) { r in
                // Tap a chip to toggle your own reaction; press-and-hold to see who reacted.
                HStack(spacing: 3) {
                    Text(r.emoji).font(.caption)
                    Text("\(r.count)").font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(r.mine ? AnyShapeStyle(HavenTheme.pink) : AnyShapeStyle(.secondary))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(r.mine ? HavenTheme.pink.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture { if r.mine { onUnreact(r.emoji) } else { react(r.emoji) } }
                .onLongPressGesture(minimumDuration: 0.3) { showReactionDetail = true }
                .transition(.scale.combined(with: .opacity))
            }
            if hiddenReactionCount > 0 {
                Text("+\(hiddenReactionCount)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                    .contentShape(Capsule())
                    .onTapGesture { showReactionDetail = true }
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 8)
            ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                Button(e) { react(e) }.font(.body).buttonStyle(PressableStyle())
            }
            Button { showReactionPicker = true } label: {
                Image(systemName: "plus.circle").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .animation(HavenTheme.bouncy, value: item.reactions.count)
        .sheet(isPresented: $showReactionPicker) {
            ReactionPicker { e in onReact(e) }.macSheetFrame()
        }
        .sheet(isPresented: $showReactionDetail) {
            ReactionDetailView(reactions: item.reactions, onUnreact: { e in onUnreact(e) }).macSheetFrame()
        }
    }

    private var commentsList: some View {
        // Inline we show at most 3; the "show all" sheet shows every comment.
        let shown = expandAllComments ? item.comments : Array(item.comments.prefix(3))
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(shown, id: \.id) { c in commentRow(c) }
            if !expandAllComments && item.comments.count > 3 {
                Button { showAllComments = true } label: {
                    Text("Show all \(item.comments.count) comments")
                        .font(.caption.weight(.semibold)).foregroundStyle(HavenTheme.pink)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $showAllComments) {
            PostCommentsSheet(item: item, friendName: friendName,
                              onReact: onReact, onUnreact: onUnreact, onComment: onComment, onEdit: onEdit, onUnsend: onUnsend)
                .macSheetFrame()
        }
        .sheet(item: $commentReactTarget) { t in
            ReactionPicker { e in feed.react(t.id, e) }.macSheetFrame()
        }
    }

    /// One comment: tappable avatar + name (→ profile), time, body, media, reactions.
    @ViewBuilder private func commentRow(_ c: FeedCommentFfi) -> some View {
        HStack(alignment: .top, spacing: 8) {
            commentAuthorLink(c) { commentAvatar(c) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    commentAuthorLink(c) {
                        Text(commentAuthorName(c)).font(.caption.weight(.semibold))
                            .foregroundStyle(c.isMe ? HavenTheme.pink : .primary)
                    }
                    Text(relativeTimeShort(c.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                    if c.edited && !c.unsent { Text("(edited)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                }
                if c.unsent {
                    Text("unsent").font(.caption).italic().foregroundStyle(.secondary)
                } else if !c.body.isEmpty {
                    LinkedText(text: c.body, font: .caption)
                    if let url = LinkScanner.urls(in: c.body).first { LinkPreviewCard(url: url).padding(.top, 6) }
                }
                if !c.unsent && !c.media.isEmpty { commentMediaRow(c.media) }
                if !c.unsent { commentReactionsRow(c) }
            }
        }
        .contextMenu {
            if !c.unsent {
                ControlGroup {
                    ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                        Button(e) { EmojiStore.shared.record(e); feed.react(c.id, e) }
                    }
                }
                Button { commentReactTarget = CommentReactTarget(id: c.id) } label: { Label("More reactions…", systemImage: "face.smiling") }
                if c.isMe {
                    if !c.body.isEmpty {
                        Button { editCommentId = c.id; editCommentText = c.body; editCommentMedia = c.media } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) { feed.unsend(c.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    /// Reactions under a comment: existing reaction chips (tap to toggle your own, like the
    /// post-level row) plus a small react button that opens the emoji picker. The core
    /// `react`/`unreact` work on ANY event id, so a comment id is targeted exactly like a post.
    @ViewBuilder private func commentReactionsRow(_ c: FeedCommentFfi) -> some View {
        // Cap the chips (most-reacted first, always keep mine) so a comment can't flood its row.
        let visible = Self.cappedReactions(c.reactions, cap: 5)
        let hidden = max(0, c.reactions.count - visible.count)
        HStack(spacing: 4) {
            ForEach(visible, id: \.emoji) { r in
                Text("\(r.emoji)\(r.count > 1 ? " \(r.count)" : "")")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(r.mine ? AnyShapeStyle(HavenTheme.brandHorizontal.opacity(0.22)) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                    .overlay(Capsule().strokeBorder(r.mine ? HavenTheme.pink.opacity(0.5) : .clear))
                    .contentShape(Capsule())
                    .onTapGesture {
                        if r.mine { feed.unreact(c.id, r.emoji) }
                        else { EmojiStore.shared.record(r.emoji); feed.react(c.id, r.emoji) }
                    }
            }
            if hidden > 0 {
                Text("+\(hidden)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
            }
            Button { commentReactTarget = CommentReactTarget(id: c.id) } label: {
                Image(systemName: "face.smiling").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .animation(HavenTheme.bouncy, value: c.reactions.count)
    }

    /// A commenter's avatar — mine is my real photo/emoji; others use their synced photo/emoji.
    @ViewBuilder private func commentAvatar(_ c: FeedCommentFfi) -> some View {
        if c.isMe {
            HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 24)
        } else {
            PeerAvatar(nodeHex: c.authorShort, name: commentAuthorName(c), size: 24)
        }
    }

    /// Wrap a commenter's avatar/name so tapping opens their profile (no link for yourself).
    @ViewBuilder private func commentAuthorLink<Content: View>(_ c: FeedCommentFfi, @ViewBuilder _ content: () -> Content) -> some View {
        if c.isMe {
            content()
        } else {
            NavigationLink {
                UserProfileView(authorHex: c.authorShort, name: commentAuthorName(c))
            } label: { content() }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func commentMediaRow(_ refs: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(refs, id: \.self) { ref in
                if let m = MediaStore.shared.item(ref) {
                    switch m.kind {
                    case .audio:
                        if let u = m.videoURL { AudioPlayerPill(url: u) }
                    case .video:
                        if let img = m.image {
                            thumb(img).overlay(Image(systemName: "play.circle.fill").foregroundStyle(.white).font(.title3))
                        }
                    case .image:
                        if let img = m.image { thumb(img) }
                    }
                }
            }
        }
    }
    private func thumb(_ img: PlatformImage) -> some View {
        Image(platformImage: img).resizable().scaledToFill()
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var commentField: some View {
        VStack(spacing: 6) {
            if !commentMedia.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(commentMedia, id: \.self) { commentAttachChip($0) } }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    Button { showCommentMediaPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                    Button { showAudioRecorder = true } label: { Label("Audio reply", systemImage: "mic") }
                } label: { Image(systemName: "paperclip").foregroundStyle(.secondary) }
                .menuIndicator(.hidden)   // no macOS disclosure chevron next to the paperclip
                #if os(macOS)
                .menuStyle(.borderlessButton).fixedSize()
                #endif
                TextField("Add a reply…", text: $commentText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)   // drop the macOS system focus ring — matches iOS
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .focused($commentFieldFocused)
                    // Report focus up so the feed lifts this post above the keyboard AND hides the
                    // "Share something" composer (which otherwise floats over the comment). The
                    // keyboard dismisses by dragging the feed (scrollDismissesKeyboard) — no toolbar
                    // Done, which was duplicating once per visible post.
                    .onChange(of: commentFieldFocused) { _, focused in
                        onCommentFocus?(focused)
                    }
                Button { sendComment() } label: {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large).foregroundStyle(HavenTheme.pink)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .sheet(isPresented: $showCommentMediaPicker) { MediaPicker { refs in commentMedia.append(contentsOf: refs) }.macSheetFrame() }
        .sheet(isPresented: $showAudioRecorder) { AudioRecorderView { ref in commentMedia.append(ref) }.macSheetFrame() }
    }

    private func commentAttachChip(_ ref: String) -> some View {
        let m = MediaStore.shared.item(ref)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let img = m?.image { Image(platformImage: img).resizable().scaledToFill() }
                else { Image(systemName: "waveform").frame(maxWidth: .infinity, maxHeight: .infinity).background(HavenTheme.brandHorizontal.opacity(0.25)) }
            }
            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            Button { commentMedia.removeAll { $0 == ref } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white).background(Circle().fill(.black.opacity(0.5)))
            }
        }
    }

    private func sendComment() {
        let t = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !commentMedia.isEmpty else { return }
        onComment(t, commentMedia)
        commentText = ""; commentMedia = []
    }
}

/// Your profile / archive: every post you've shared, kept as a copy on your device.
/// Another person's profile — their posts + a stories ring row. Opened by tapping a
/// name or avatar anywhere.
/// A focused sheet for a single post with ALL its comments expanded, so you can read and
/// interact with just that post and its commenters (shown when a post has more than 3 comments).
struct PostCommentsSheet: View {
    let item: FeedItemFfi
    let friendName: String
    let onReact: (String) -> Void
    var onUnreact: (String) -> Void = { _ in }
    let onComment: (String, [String]) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void
    @ObservedObject private var feed = FeedStore.shared
    @Environment(\.dismiss) private var dismiss

    /// The live post, so comments you add in the sheet appear immediately.
    private var live: FeedItemFfi { feed.feedItems.first { $0.id == item.id } ?? item }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollViewReader { proxy in
                    ScrollView {
                        PostCard(item: live, friendName: friendName,
                                 onReact: onReact, onUnreact: onUnreact, onComment: onComment, onEdit: onEdit, onUnsend: onUnsend,
                                 expandAllComments: true,
                                 onCommentFocus: { focused in
                                     // Lift the reply field above the keyboard so typing is visible.
                                     if focused { withAnimation(HavenTheme.smooth) { proxy.scrollTo(live.id, anchor: .bottom) } }
                                 })
                            .id(live.id)
                            .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .navigationTitle("Comments")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmLeading) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }
    }
}

struct UserProfileView: View {
    let authorHex: String
    let name: String
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @State private var showStories = false
    @State private var showNickname = false
    @State private var nicknameDraft = ""

    /// Reflects a nickname edit live (the passed `name` is a snapshot).
    private var resolvedName: String { contacts.name(forNodePrefix: authorHex) ?? name }

    private var posts: [FeedItemFfi] {
        store.items.filter { $0.authorShort == authorHex && !$0.story && !$0.unsent }
    }
    private var userStories: [FeedItemFfi] {
        store.items.filter { $0.authorShort == authorHex && $0.story && !$0.unsent && !$0.media.isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        // Use the contact's real signed avatar/emoji (PeerAvatar resolves it from their
                        // card), falling back to the initial — not a hardcoded initial circle.
                        PeerAvatar(nodeHex: authorHex, name: resolvedName, size: 76)
                        HStack(spacing: 6) {
                            Text(resolvedName).font(.title3.bold())
                            Button { nicknameDraft = contacts.contacts.first { $0.idHex.hasPrefix(authorHex) }?.nickname ?? ""; showNickname = true } label: {
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(posts.count) post\(posts.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        if let card = contacts.card(forNodePrefix: authorHex) {
                            if let bio = card.bio, !bio.isEmpty {
                                Text(bio).font(.subheadline).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                            }
                            if let link = card.link, !link.isEmpty {
                                Button { LinkPresenter.shared.open(link) } label: {
                                    Label(link, systemImage: "link")
                                        .font(.footnote.weight(.medium)).foregroundStyle(HavenTheme.pink).lineLimit(1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                    if !userStories.isEmpty {
                        Button { showStories = true } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 58, height: 58)
                                    if let img = userStories.last?.media.first.flatMap({ MediaStore.shared.item($0)?.image }) {
                                        Image(platformImage: img).resizable().scaledToFill().frame(width: 50, height: 50).clipShape(Circle())
                                    }
                                }
                                Text("\(userStories.count) active stor\(userStories.count == 1 ? "y" : "ies")").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .havenCard()
                        }
                        .buttonStyle(.plain)
                    }
                    if posts.isEmpty {
                        ContentUnavailableView("No posts yet", systemImage: "tray",
                                               description: Text("\(name)'s posts will appear here."))
                            .padding(.top, 30)
                    } else {
                        ForEach(posts, id: \.id) { item in
                            PostCard(
                                item: item, friendName: name,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onUnreact: { e in withAnimation(HavenTheme.bouncy) { store.unreact(item.id, e) } },
                                onComment: { b, m in withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { _ in },
                                onUnsend: { }
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(resolvedName)
        .havenInlineNavTitle()
        .toolbar {
            if let url = DeepLink.profileURL(authorHex) {
                ToolbarItem(placement: .havenTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .havenFullScreenCover(isPresented: $showStories) {
            StoryViewer(stories: userStories, index: 0, friendName: resolvedName)
        }
        .alert("Nickname", isPresented: $showNickname) {
            TextField("Nickname", text: $nicknameDraft)
            Button("Save") { ContactsStore.shared.setNickname(idHex: authorHex, nicknameDraft) }
            Button("Clear", role: .destructive) { ContactsStore.shared.setNickname(idHex: authorHex, "") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Set how \(name) shows up for you.") }
    }
}

/// Create a custom circle and pick which contacts go in it.
struct NewCircleView: View {
    var onCreate: (String, [String]) -> Void
    @ObservedObject private var contacts = ContactsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                Form {
                    Section("Name") { TextField("Circle name (e.g. Family)", text: $name) }
                    Section("Who's in it") {
                        if contacts.contacts.isEmpty {
                            Text("Add some people first.").foregroundStyle(.secondary)
                        }
                        ForEach(contacts.contacts) { c in
                            Button {
                                if selected.contains(c.idHex) { selected.remove(c.idHex) } else { selected.insert(c.idHex) }
                            } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(LinearGradient(colors: [HavenTheme.amber, HavenTheme.pink], startPoint: .top, endPoint: .bottom))
                                        .frame(width: 34, height: 34)
                                        .overlay(Text(String(c.displayName.prefix(1)).uppercased()).font(.subheadline.bold()).foregroundStyle(.white))
                                    Text(c.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: selected.contains(c.idHex) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(c.idHex) ? HavenTheme.pink : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New circle")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { dismiss() }.havenToolbarPill() }
                ToolbarItem(placement: .havenTrailing) {
                    Button("Create") {
                        onCreate(name.trimmingCharacters(in: .whitespaces), Array(selected))
                        dismiss()
                    }
                    .havenToolbarPill(tint: HavenTheme.pink)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct ProfileView: View {
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    let friendName: String
    @State private var showStories = false
    @State private var storyIndex = 0

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if !store.myStories.isEmpty { storiesRow }
                    if store.myPosts.isEmpty {
                        ContentUnavailableView(
                            "No posts yet",
                            systemImage: "tray",
                            description: Text("Everything you share lives here — and a copy stays on your device.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(store.myPosts, id: \.id) { item in
                            PostCard(
                                item: item, friendName: friendName,
                                onReact: { e in withAnimation(HavenTheme.bouncy) { store.react(item.id, e) } },
                                onUnreact: { e in withAnimation(HavenTheme.bouncy) { store.unreact(item.id, e) } },
                                onComment: { b, m in withAnimation(HavenTheme.smooth) { store.comment(item.id, b, m) } },
                                onEdit: { b in withAnimation(HavenTheme.smooth) { store.edit(item.id, b) } },
                                onUnsend: { withAnimation(HavenTheme.smooth) { store.unsend(item.id) } }
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Your posts")
        .havenInlineNavTitle()
        .havenFullScreenCover(isPresented: $showStories) {
            StoryViewer(stories: store.myStories, index: storyIndex, friendName: friendName)
        }
    }

    private var storiesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your stories").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(store.myStories.enumerated()), id: \.element.id) { idx, s in
                        Button { storyIndex = idx; showStories = true } label: {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 64, height: 64)
                                if let img = s.media.first.flatMap({ MediaStore.shared.item($0)?.image }) {
                                    Image(platformImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 76)
            Text(profile.displayName.isEmpty ? "You" : profile.displayName).font(.title3.bold())
            Text("\(store.myPosts.count) post\(store.myPosts.count == 1 ? "" : "s") · a copy lives on your device")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}
