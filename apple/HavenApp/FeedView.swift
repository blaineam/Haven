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

/// Set while a capture session (story / post camera) owns the audio session. An AVCaptureSession
/// configures the SHARED session for recording; having feed playback asynchronously stomp it back to
/// `.playback` mid-startup makes the two fight and can wedge the camera. While this is true, playback
/// never touches the session — the camera is the only owner.
nonisolated(unsafe) var havenCaptureOwnsAudioSession = false

/// How many camera surfaces are on screen right now (story camera, post camera, any viewfinder).
/// While ANY is open the system music player stays silent: a post's song playing behind a viewfinder is
/// never wanted, and it fights the capture session for the audio route. Counted rather than a Bool so a
/// camera presented over another camera can't clear the flag early.
nonisolated(unsafe) var havenCameraUIOpen = 0
/// True while any camera UI is up — the single gate every playback entry point checks.
var havenCameraIsOpen: Bool { havenCameraUIOpen > 0 || havenCaptureOwnsAudioSession }

/// Set while the story composer is deliberately previewing its attached song. The composer plays through
/// the SAME shared system music player the feed uses, so the "stop the post song behind this overlay"
/// paths must not touch it: a sheet appearing over the composer (or the composer's own onAppear re-firing
/// as the song picker dismissed) was calling stop() on the preview we had just started — which is why the
/// song played through the dismiss animation and then went silent.
nonisolated(unsafe) var havenStoryPreviewActive = false

#if os(iOS)
private let havenAudioSessionQueue = DispatchQueue(label: "haven.audioSession")

/// Configure the shared audio session for muted-video-over-music playback exactly once, OFF the main
/// thread. setCategory/setActive are synchronous and can stall the main thread for tens of ms; calling
/// them from `playVisibleVideo` on every scroll was the video "stick then continue". Idempotent — it
/// no-ops when the session is already playback + mixWithOthers (so a call that changed the category
/// still gets it reconfigured next time a video plays).
/// `force` = the caller definitively owns playback right now (the story editor, where capture is over).
/// Without it the async re-check below could be beaten by the camera view re-claiming the session as the
/// editor came up, and the whole configuration would silently no-op.
/// `then` runs on the main queue once the session is actually configured. Anything that STARTS audio must
/// use it: the configuration happens off-main, so starting a song on the line after the call began playback
/// while the session was still non-mixing — the muted canvas clip then held the route exclusively and
/// suppressed the song. (That's why the preview only worked on a second toggle: by then the first call's
/// configuration had landed.) Always invoked, including on the early-outs, so callers can't stall.
func ensureHavenPlaybackSession(force: Bool = false, then: (() -> Void)? = nil) {
    func finish() { if let then { DispatchQueue.main.async(execute: then) } }
    if !force, havenCaptureOwnsAudioSession { finish(); return }   // the camera owns the session — hands off
    havenAudioSessionQueue.async {
        if !force, havenCaptureOwnsAudioSession { finish(); return }   // the camera may have opened since
        let s = AVAudioSession.sharedInstance()
        if s.category != .playback || !s.categoryOptions.contains(.mixWithOthers) {
            // NB: this THROWS while a capture session is live — the category then silently stays
            // PlayAndRecord (non-mixing) and interrupts anything we start. Capture is stopped before the
            // composer opens precisely so this call can succeed.
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        // ALWAYS activate, even when the category already looked right. A capture session tearing down
        // leaves the session INACTIVE while the category still reads playback+mixWithOthers — skipping
        // activation there meant the next player to start grabbed the session in default (non-mixing)
        // mode and interrupted whatever was already playing.
        try? s.setActive(true)
        finish()
    }
}
#endif

/// Reports each post card's on-screen vertical center so the feed can pick the one
/// nearest the middle of the screen as the "active" (playing) post.
struct PostCenterKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// Drives the live social demo: every action goes through the real hybrid-PQ social
/// engine (seal → open → feed) in `haven-p2p`. Posts can carry media + a song.
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
    /// Count of per-post-hidden items in the CURRENTLY SELECTED circle (the "Show hidden posts (N)"
    /// menu is per-circle, not a global tally across every circle).
    @Published private(set) var hiddenInActiveCircle = 0
    @Published var activeCircleId = "default" {
        didSet {
            guard oldValue != activeCircleId else { return }
            // Leaving a circle stops any audio it was playing — a post's song or a video's sound must
            // not keep playing under the circle you just switched to. Covers every switch path (picker,
            // deep link, create/upgrade) since it hangs off the property itself.
            AudioCoordinator.shared.stop()
            AudioCoordinator.shared.centeredPostId = nil
        }
    }
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
    /// Thermal pressure and super data saver stretch further so a warm phone (or one the user
    /// asked to go easy on the radio) isn't also blasting hello+roster at the tight cadence.
    private func adaptiveInterval(base: UInt64) -> UInt64 {
        let idle = now() &- lastActivityMs
        var mult: UInt64
        if idle < 180_000 { mult = 1 }
        else if idle < 900_000 { mult = 3 }
        else { mult = 6 }
        #if os(iOS)
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: mult *= 2
        case .fair: mult = (mult * 3) / 2
        default: break
        }
        #endif
        if SettingsStore.shared.superDataSaver { mult = (mult * 3) / 2 }
        return base * max(1, mult)
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
        // Switch-Flip: identity-scoped bookkeeping must not leak across identities — a stale
        // "account leaf retired" flag would wrongly skip migration for a legacy multi-device account.
        SwitchFlipMigration.clear()
        CircleCreatorStore.clear()
        configure(seed: seed)
    }

    /// How the engine boots (plan §5, Apple column): a SEEDED device (today's path — primary/legacy
    /// link, holds the account master seed) or a SEEDLESS device (S4 — holds only the account public
    /// bundle + its device seed, runs under `HavenSocial.newSeedless` and never signs a roster).
    enum BootMode {
        case seeded(Data)
        case seedless(accountBundle: Data, deviceSeed: Data)
    }

    /// Legacy entry point — unchanged callers keep working. Seedless devices boot via `configure(mode:)`.
    func configure(seed: Data) { configure(mode: .seeded(seed)) }

    /// Boot the engine in whichever mode this device is persisted as: seedless (S4 — account public
    /// bundle + device seed) or seeded (account master seed). The single boot entry the app/scene
    /// call sites use so a seedless device never accidentally boots seeded off a throwaway seed.
    func configureForCurrentIdentity() {
        if SeedlessState.isEnabled, let bundle = AccountPublicStore.load() {
            configure(mode: .seedless(accountBundle: bundle, deviceSeed: DeviceKeyStore.deviceAccount().secretSeed()))
        } else if let seed = AccountStore.storedSeed() {
            configure(seed: seed)
        }
    }

    func configure(mode: BootMode) {
        guard social == nil else { return }
        let seedless: Bool
        switch mode {
        case .seeded(let seed):
            seedless = false
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
        case .seedless(let bundle, let deviceSeed):
            seedless = true
            // The engine runs under the DEVICE key with the account PUBLIC bundle as its trust anchor.
            // `newSeedless` adopts the device identity internally, so no separate useDeviceIdentity call.
            social = try? HavenSocial.newSeedless(accountPublicBundle: bundle, deviceSeed: deviceSeed)
            if let social {
                // Reinstall the primary-signed roster wire we persisted at enrollment (VERBATIM, incl. the
                // SeedDropCapability trailer) so this device is authorized + rebroadcasts the exact bytes.
                if let wire = SeedlessRosterStore.load(), !wire.isEmpty { _ = social.ingestRosterWire(wire: wire) }
                HavenLog.net("configure SEEDLESS account=\(social.myNodeHex().prefix(10)) instance=\(social.myDeviceNodeHex().prefix(10))")
            }
        }
        loadPersisted()
        // Self-register THIS device AFTER importing persisted state. Registering first wrote a fresh
        // v1 roster that import_state's higher-version-wins restore then CLOBBERED with the persisted
        // roster — so if that roster carried a (stale) revocation of our own device id, the device
        // never effectively re-registered and stayed revoked forever (friends wouldn't dial us, and
        // the re-register/re-revoke flip-flop rotated every circle epoch on each launch).
        // Registering against the imported roster makes the re-authorization an explicit,
        // version-bumped update that propagates (see DeviceList::merge).
        // SEEDLESS: skip it entirely — a seedless device has no account key to sign a roster with
        // (register_device returns empty; the primary is the sole roster authority, plan §2.2 A1). Its
        // authorization comes from the primary-signed roster wire ingested above.
        if let social, !seedless {
            _ = social.registerDevice(deviceBundle: DeviceKeyStore.deviceBundle(),
                                      name: DeviceKeyStore.deviceName,
                                      createdAt: UInt64(Date().timeIntervalSince1970))
        }
        social?.setKeepOwnPosts(on: SettingsStore.shared.keepMyPosts)   // apply the archive preference
        ensureDefaultCircle()   // a brand-new identity must have its own "default" circle to post into
        bumpActivity()   // seed activity NOW so launch starts at tight cadence (not instant max backoff)
        loadLastHeard()   // so "last seen" survives an app restart
        refreshCircles()     // also purges any contaminated DM membership (see refreshCircles)
        reconcileRemovals()  // heal old-build damage: purge engine members that are still client-tombstoned
        applyCryptoSwitches(seedless: seedless)   // Switch-Flip 1.0.7: re-apply the non-persisted crypto switches
        refresh()
        if let social { MediaBackupQueue.shared.drainPersisted(social: social) }   // finish uploads killed mid-flight
        recomputeUnreadDMs()   // one-time badge compute at startup (kept OFF the per-refresh hot path)
        seedDemoIfNeeded()   // HAVEN_DEMO=1 only — PII-free synthetic dataset for screenshots
        restoreReassemblies()   // pick half-finished media transfers back up instead of restarting them
        // Reclaim leaked produce/reassembly scratch every launch (an interrupted big-video export or a
        // failed reassembly leaves mint_/incoming_ behind — invisible to Manage media, but counted in
        // storage). Off-main, and only touches scratch untouched for an hour. Partials belonging to a
        // live reassembly are spared (see sweepStaleScratch) — restoring them first is what makes
        // resume real: without it this sweep deleted the 99%-complete file every launch.
        Task.detached(priority: .utility) {
            let f = MediaStore.sweepStaleScratch()
            if f.files > 0 { HavenLog.sync("media scratch sweep: freed \(f.bytes)B across \(f.files) files") }
        }
        #if DEBUG
        CallManager.shared.debugSimulateIncomingRing()   // HAVEN_RING_TEST=1 only — bounded-ring self-test
        #endif
        guard ProcessInfo.processInfo.environment["HAVEN_NO_NET"] != "1" else { return }
        bringOnline()
        startMailboxPolling()
        if let social { MediaRecovery.runOnceIfNeeded(social: social) }   // one-time re-seal of my 1.0.7-era media
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
        // A circle I've upgraded (or followed an upgrade off of) is SUPERSEDED — the owned successor
        // carries its name + members + history. The earlier fix only hid it via the per-device
        // `supersededCircleIds()`, which is NOT synced: my Mac (which didn't run the upgrade) kept showing
        // the legacy circle, and additive circle-sync round-trips let it "return" and duplicate. Convert
        // supersession into the SAME synced, LWW deletion tombstone used for deleting a circle — self-sync
        // honors it on every device and can never resurrect it. This also HEALS circles already upgraded
        // before this fix (they get tombstoned on the next read).
        var changed = false
        for legacy in social?.supersededCircleIds() ?? [] where !CircleDeletionStore.isDeleted(legacy) {
            let succ = social?.circleSuccessor(circleId: legacy)   // capture BEFORE leaving (lookup needs the circle)
            CircleDeletionStore.markDeleted(legacy)                 // LWW tombstone → syncs to all my devices
            social?.leaveCircle(id: legacy)                        // drop the duplicate row from the engine
            if activeCircleId == legacy, let succ { activeCircleId = succ }
            changed = true
        }
        let all = social?.circles() ?? []
        // Belt-and-suspenders: also filter any tombstoned circle that a sync race re-materialized before
        // its own `circle-deleted:` record applied.
        circles = all.filter { !CircleDeletionStore.isDeleted($0.id) }
        // If I'm still sitting on a superseded/deleted circle (persisted active id, or a sibling's upgrade
        // synced in), move to its successor, else fall back to the default circle rather than a blank feed.
        if CircleDeletionStore.isDeleted(activeCircleId) {
            activeCircleId = social?.circleSuccessor(circleId: activeCircleId) ?? "default"
        }
        if changed { persist() }   // leaveCircle mutated the engine; the tombstone must survive relaunch
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
        displayName(forCircle: activeCircleId)
    }

    /// What to SHOW a circle as: my own private nickname if I've set one, else its real name. The
    /// real name is what travels on the wire and what everyone else sees — renaming it for myself
    /// must never rename it for them, so the nickname is resolved only at display time.
    func displayName(forCircle id: String) -> String {
        let real = circles.first { $0.id == id }?.name ?? "My Circle"
        return CircleSettingsStore.shared.displayName(id, real: real)
    }

    func setActiveCircle(_ id: String) {
        guard id != activeCircleId else { return }
        activeCircleId = id
        refresh()
        requestMissingMedia()
    }

    /// Create a circle from scratch and switch to it. Add existing contacts next.
    /// A fresh identity has no circle to post into: the "default" circle ("Your circle") was only
    /// ever created as a side effect of accepting your first connection. That left a brand-new user's
    /// very first post silently dropped — `post(circleId: "default")` targets a circle the engine
    /// doesn't hold yet, so `social.post` returns nil and the composer clears with nothing to show.
    /// Create it up front (seed-holders only; a seedless device receives it from the primary's roster
    /// sync) so posting works the moment the app opens. Idempotent — a no-op once the circle exists.
    private func ensureDefaultCircle() {
        guard let social, AccountStore.storedSeed() != nil else { return }   // seed-holder only
        guard !social.circles().contains(where: { $0.id == "default" }) else { return }
        social.createCircle(id: "default", name: "Your circle")
        _ = social.setCircleCreator(circleId: "default", accountHex: social.myNodeHex())
        CircleCreatorStore.markCreated("default")
        persist()
    }

    // MARK: - Carrying an older circle onto one with a verified owner

    /// Upgrade offers on `circleId` that I haven't followed — "so-and-so says this circle's replacement
    /// is theirs". Verified as genuinely from the signer, but NOT as proof they made the circle; the
    /// user decides. See `CircleUpgradeBanner`.
    func pendingUpgrades(_ circleId: String) -> [CircleUpgradeOffer] {
        social?.pendingCircleUpgrades(circleId: circleId) ?? []
    }

    /// A legacy circle with no verified owner yet — the app can offer to upgrade it, and the offer
    /// card is shown to ANY member (no device records who made a pre-1.0.7 circle; the follow side
    /// names each claimant so members pick the real creator). Excludes owned (`c1`) ids, the personal
    /// `default` circle, and two-party `dm:` threads. The empty-admin check is the core's authoritative
    /// "no owner root yet" signal (`circle_admins`), so this no longer depends on a per-device
    /// created-circles record that legacy circles never had.
    func circleIsUpgradable(_ circleId: String) -> Bool {
        guard !circleId.hasPrefix(OwnedCircle.prefix), circleId != "default", !circleId.hasPrefix("dm:") else { return false }
        return (social?.circleAdmins(circleId: circleId) ?? []).isEmpty
    }

    /// Offer to upgrade a circle I made: mints its replacement, carries the members over, and puts the
    /// signed offer on the old circle's lane. Returns the new circle's id.
    @discardableResult
    func offerCircleUpgrade(_ circleId: String) -> String? {
        guard let new = social?.upgradeCircle(legacyCircleId: circleId) else { return nil }
        CircleCreatorStore.markCreated(new)   // re-pin the owner on every launch, like any circle I made
        persist(); refreshCircles()
        activeCircleId = new
        refresh()
        return new
    }

    /// Follow someone's offer: stand up the replacement and pin them as its verified owner.
    @discardableResult
    func followCircleUpgrade(_ circleId: String, to newId: String) -> Bool {
        guard social?.acceptCircleUpgrade(circleId: circleId, newCircleId: newId) == true else { return false }
        persist(); refreshCircles()
        activeCircleId = newId
        refresh()
        return true
    }

    func createCircle(name: String, memberIds: [String] = []) {
        guard let social else { return }
        // Mint a creator-BOUND id: it commits to my account, so every member establishes this circle's
        // creator from the id itself rather than from a claim on the wire. This also pins + announces
        // the creator (the propagating self-grant), so no separate setCircleCreator is needed here.
        let id = social.createCircleOwned(name: name)
        CircleDeletionStore.markRecreated(id)   // a freshly-created circle is not deleted (LWW)
        // Switch-Flip §2: record it so the pin is re-applied on every launch.
        CircleCreatorStore.markCreated(id)
        for m in memberIds { try? social.addExistingToCircle(circleId: id, nodeHex: m) }
        persist(); refreshCircles()
        activeCircleId = id
        refresh()
        if !memberIds.isEmpty { syncWithContacts() }   // greet + back-fill to the new members
    }

    /// Lift a member's removal both client-side (the guard set) and in the engine (the authoritative
    /// tombstone) — a DELIBERATE re-add. The add paths refuse a tombstoned member, so this must run
    /// first. Exposed so views outside the store (e.g. ConnectView) can un-ban before re-adding.
    func clearCircleRemovalEverywhere(idHex: String, circleId: String) {
        ConnectionsStore.shared.clearCircleRemoval(idHex, circleId: circleId)
        social?.clearCircleRemoval(circleId: circleId, nodeHex: idHex)
    }

    /// Add a known contact to the active circle, then sync so the circle forms on theirs.
    func addContactToActiveCircle(idHex: String) {
        guard let social else { return }
        ConnectionsStore.shared.clearCircleRemoval(idHex, circleId: activeCircleId)  // deliberate re-add un-bans them
        social.clearCircleRemoval(circleId: activeCircleId, nodeHex: idHex)          // …and lift the engine tombstone
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

    /// Rip a member out of EVERY group circle at once — each removal is LWW-tombstoned so they can't
    /// rejoin any of them. This is the "get this person out of everything" action for when removing them
    /// from one circle keeps leaving them in the others. Leaves `dm:` threads alone (deleting a DM is a
    /// separate, destructive choice). Returns how many circles they were pulled from.
    @discardableResult
    func removeFromAllCircles(_ idHex: String) -> Int {
        guard let social else { return 0 }
        var count = 0
        for c in social.circles() where !c.id.hasPrefix("dm:") {
            if social.contactNodeIds(circleId: c.id).contains(idHex) {
                social.removeFromCircle(circleId: c.id, nodeHex: idHex)          // purge + engine tombstone + epoch rotate
                ConnectionsStore.shared.removeFromCircle(idHex, circleId: c.id)  // LWW client tombstone (now())
                count += 1
            }
        }
        persist(); refreshCircles(); refresh()
        return count
    }

    /// Self-heal old-build damage. A build BEFORE the authoritative-tombstone fix could re-add a member
    /// you'd removed — the automatic add cleared the ENGINE tombstone while the CLIENT tombstone stayed
    /// set. The result: the member is hidden in the UI (client filter) yet still lives in the engine's
    /// member list, so posts/sealing/roster still treat them as present and it "never sticks". On launch,
    /// purge any engine member that's still client-tombstoned — re-running the removal that was undone.
    /// Idempotent; a no-op once the fleet is on the fixed build. Logs what it heals.
    func reconcileRemovals() {
        guard let social else { return }
        var healed = 0
        for key in ConnectionsStore.shared.circleRemovals {
            guard let bar = key.firstIndex(of: "|") else { continue }
            let circleId = String(key[key.startIndex..<bar])
            let hex = String(key[key.index(after: bar)...])
            guard !circleId.isEmpty, !hex.isEmpty else { continue }
            if social.contactNodeIds(circleId: circleId).contains(hex) {
                social.removeFromCircle(circleId: circleId, nodeHex: hex)   // purge + re-tombstone in the engine
                healed += 1
            }
        }
        if healed > 0 { persist(); refreshCircles(); refresh() }
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
        CircleDeletionStore.markDeleted(activeCircleId)   // LWW tombstone so a sibling can't re-create it
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
        CircleDeletionStore.markRecreated(id)   // re-opening a DM lifts any prior deletion (LWW)
        social.createCircle(id: id, name: name)
        social.setCircleLiveLane(circleId: id, on: true)   // Switch-Flip §5: DM per-message forward secrecy
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
        CircleDeletionStore.markRecreated(id)   // re-opening lifts any prior deletion (LWW)
        social.createCircle(id: id, name: name)
        social.setCircleLiveLane(circleId: id, on: true)   // Switch-Flip §5: DM per-message forward secrecy
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
        social.clearCircleRemoval(circleId: "default", nodeHex: req.idHex)   // lift the engine tombstone too
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
    ///
    /// Entirely local — a block never leaves the device (audit F1). Deciding you don't want to see
    /// someone is nobody's business but yours; only an explicit report notifies the developer.
    func blockConnection(_ idHex: String) {
        ConnectionsStore.shared.block(idHex)
        social?.blockMember(nodeHex: idHex)
        if let c = ContactsStore.shared.contacts.first(where: { $0.idHex == idHex }) {
            ContactsStore.shared.remove(c)
        }
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
        maybePurgeExpiredMedia(circleId, retention: CircleSettingsStore.shared.retentionSecs(circleId))
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
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        broadcastEvent(circleId, env, banner: .forPost(circleId: circleId, circleName: name, body: body, media: media, story: false))
        postTick += 1
        let circle = circleId
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: circle, social: social) }
    }

    /// Edit one of your own messages in a specific (DM) circle.
    ///
    /// `media` and `music` REPLACE what the message carries — the reducer assigns rather than merges
    /// (see the tests in `haven-p2p`'s `social.rs`). This defaulted to empty, so editing the text of
    /// a DM that had a photo or a song deleted it for both people. DMs carry attachments exactly
    /// like posts do; the empty array was only ever right for a message that had none.
    func editMessage(in circleId: String, _ id: String, _ body: String,
                     media: [String] = [], music: TrackRefFfi? = nil) {
        guard let social, let env = try? social.edit(circleId: circleId, target: id, body: body, media: media, music: music, muteVideo: false, createdAt: now()) else { return }
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        broadcastEvent(circleId, env, banner: .forEdit(circleId: circleId, circleName: name)); postTick += 1; refresh()
    }

    /// Delete (retract) one of your own messages in a specific (DM) circle.
    func deleteMessage(in circleId: String, _ id: String) {
        guard let social, let env = try? social.unsend(circleId: circleId, target: id, createdAt: now()) else { return }
        broadcastEvent(circleId, env, banner: .forUnsend(circleId: circleId)); postTick += 1; refresh()
    }

    /// Delete a whole DM conversation locally (also clears any old contaminated thread).
    func deleteConversation(_ circleId: String) {
        guard let social, circleId.hasPrefix("dm:") else { return }
        clearDMBefore(circleId)   // watermark so re-syncing (or re-starting) this DM won't restore old messages
        CircleDeletionStore.markDeleted(circleId)   // LWW tombstone so self-sync can't re-create it from a sibling
        social.leaveCircle(id: circleId)
        persist(); refreshCircles(); refresh()
        HavenLog.sync("DELETE-DM \(circleId.prefix(24))")
    }

    /// Node ids in a circle for whom we hold keys (handshake complete).
    func handshaked(in circleId: String) -> [String] {
        social?.contactNodeIds(circleId: circleId) ?? []
    }

    // MARK: - Media GC (purge-linked deletion + orphan sweep)
    //
    // `feed()` only HIDES expired posts; `purgeExpired` really drops the events and returns their
    // media refs so the blobs can finally leave disk too. Deletion is gated on an in-use check —
    // the same photo may ride another live post (any circle, DMs included), a comment, or a
    // scheduled send, and those must keep their bytes.

    /// Circles already purged this app session (purging is idempotent; once per session is plenty).
    private var purgedCircles = Set<String>()

    /// Really delete expired content for a circle and GC the blobs the purge orphaned. Called from
    /// the feed/messages refresh paths with the SAME retention they pass to `feed` — throttled to
    /// once per circle per app session so a hot refresh loop never re-runs engine purges.
    func maybePurgeExpiredMedia(_ circleId: String, retention: UInt64?) {
        guard let social, !DemoEnv.isDemo, !purgedCircles.contains(circleId) else { return }
        purgedCircles.insert(circleId)
        let nowMs = now()
        let scheduledRefs = ScheduledStore.shared.items.flatMap(\.media)
        let pinnedStems = PinnedMediaStore.shared.inUseStems()   // device-pinned blobs are cleanup-exempt
        Task.detached(priority: .utility) { [weak self] in
            let purged = social.purgeExpired(circleId: circleId, viewerRetentionSecs: retention, nowMs: nowMs)
            guard !purged.isEmpty else { return }
            // Anything a LIVE event anywhere still names keeps its bytes (content addressing means
            // one blob can back many posts). Built AFTER the purge so this circle's dropped events
            // no longer count as users. Device-pinned blobs are held regardless of referencedness.
            var inUse = Self.mediaInUseStems(social: social)
            for r in scheduledRefs { inUse.formUnion(MediaStore.storedStems(for: r)) }
            inUse.formUnion(pinnedStems)
            let inUseFinal = inUse
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Persist FIRST: once the blobs are gone, the purged events must not resurrect from
                // a stale state file and re-request their (now deleted) media forever.
                self.persist()
                var freed: Int64 = 0
                for ref in purged where !MediaStore.isSynthetic(ref) {
                    if MediaStore.storedStems(for: ref).isDisjoint(with: inUseFinal) {
                        freed += MediaStore.shared.delete(ref)
                    }
                }
                if freed > 0 { HavenLog.sync("media GC purge \(circleId): freed \(freed)B") }
            }
        }
    }

    /// The stem (on-disk basename) of every media ref a live event still references — every circle's
    /// feed (retention nil: expired-but-unpurged events still hold their bytes until purged) plus
    /// every comment. `nonisolated` because `feed()` re-opens every envelope (real CPU) and the
    /// sweep runs it for ALL circles — never on the main actor.
    nonisolated static func mediaInUseStems(social: HavenSocial) -> Set<String> {
        var stems = Set<String>()
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        for c in social.circles() {
            for item in social.feed(circleId: c.id, nowMs: nowMs, viewerRetentionSecs: nil) {
                for r in item.media { stems.formUnion(MediaStore.storedStems(for: r)) }
                for cm in item.comments {
                    for r in cm.media { stems.formUnion(MediaStore.storedStems(for: r)) }
                }
            }
        }
        return stems
    }

    /// Walk haven-media and delete every blob no event anywhere references (Settings' "Clean up
    /// unused media" and the weekly sweep). Returns what was freed.
    func cleanupUnusedMedia() async -> (bytes: Int64, files: Int) {
        guard let social, !DemoEnv.isDemo else { return (0, 0) }
        let scheduledRefs = ScheduledStore.shared.items.flatMap(\.media)
        let pinnedStems = PinnedMediaStore.shared.inUseStems()   // device-pinned blobs are cleanup-exempt
        let result = await Task.detached(priority: .utility) { () -> (Int64, Int) in
            var inUse = Self.mediaInUseStems(social: social)
            for r in scheduledRefs { inUse.formUnion(MediaStore.storedStems(for: r)) }
            inUse.formUnion(pinnedStems)
            return MediaStore.performOrphanSweep(inUse: inUse)
        }.value
        if result.1 > 0 {
            MediaStore.shared.clearMemoryCache()   // deleted files may still be decoded in the caches
            HavenLog.sync("media GC sweep: freed \(result.0)B across \(result.1) files")
        }
        return result
    }

    private var weeklySweepInFlight = false
    /// Run the orphan sweep at most once a week (persisted stamp), piggybacked on the sync timer.
    private func maybeWeeklyMediaSweep() {
        guard !DemoEnv.isDemo, !weeklySweepInFlight else { return }
        let key = "haven.mediagc.lastSweep"
        let last = UserDefaults.standard.double(forKey: key)
        guard Date().timeIntervalSince1970 - last > 7 * 24 * 3600 else { return }
        weeklySweepInFlight = true
        Task { @MainActor in
            _ = await self.cleanupUnusedMedia()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
            self.weeklySweepInFlight = false
        }
    }

    // MARK: - Cleanup screen (#1) — size-sorted inventory + multi-select delete

    /// Every stored media blob, joined to the post/DM/comment that references it (best-effort), sorted
    /// by size DESCENDING for the "Manage media" screen. A blob no live event names is an ORPHAN. The
    /// event/metadata is untouched by a delete here — only the local bytes go, so the item re-renders as
    /// a downloadable placeholder.
    func mediaInventory() async -> [MediaInventoryRow] {
        guard let social else { return [] }
        let pinned = PinnedMediaStore.shared.refs
        let circleNames = Dictionary(circles.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var scheduledStems = Set<String>()
        for r in ScheduledStore.shared.items.flatMap(\.media) { scheduledStems.formUnion(MediaStore.storedStems(for: r)) }
        return await Task.detached(priority: .userInitiated) { () -> [MediaInventoryRow] in
            // stem -> the event that references it (first/newest wins). Built from every circle's feed
            // + comments so a row can name where its bytes came from.
            var owner: [String: (circleId: String, snippet: String, ts: UInt64)] = [:]
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            for c in social.circles() {
                for item in social.feed(circleId: c.id, nowMs: nowMs, viewerRetentionSecs: nil) {
                    let snip = item.body.isEmpty ? "" : String(item.body.prefix(80))
                    func attribute(_ refs: [String], _ snippet: String, _ ts: UInt64) {
                        for r in refs {
                            for stem in MediaStore.storedStems(for: r) where owner[stem] == nil {
                                owner[stem] = (c.id, snippet, ts)
                            }
                        }
                    }
                    attribute(item.media, snip, item.createdAt)
                    for cm in item.comments {
                        attribute(cm.media, cm.body.isEmpty ? "" : String(cm.body.prefix(80)), cm.createdAt)
                    }
                }
            }
            return MediaStore.storedBlobs().map { blob -> MediaInventoryRow in
                let kind = MediaKind(ref: blob.ref)
                let scheduled = !MediaStore.storedStems(for: blob.ref).isDisjoint(with: scheduledStems)
                if let o = owner[blob.ref] {
                    let isDM = o.circleId.hasPrefix("dm:")
                    return MediaInventoryRow(
                        ref: blob.ref, bytes: blob.bytes, mtime: blob.mtime, kind: kind,
                        circleId: o.circleId,
                        circleName: isDM ? "Direct message" : (circleNames[o.circleId] ?? "A circle"),
                        snippet: o.snippet.isEmpty ? nil : o.snippet,
                        eventMs: o.ts, isOrphan: false,
                        isPinned: pinned.contains(blob.ref))
                }
                return MediaInventoryRow(
                    ref: blob.ref, bytes: blob.bytes, mtime: blob.mtime, kind: kind,
                    circleId: nil,
                    circleName: scheduled ? "Scheduled to send" : "Unused",
                    snippet: nil, eventMs: UInt64(blob.mtime.timeIntervalSince1970 * 1000),
                    isOrphan: !scheduled, isPinned: pinned.contains(blob.ref))
            }.sorted { $0.bytes > $1.bytes }
        }.value
    }

    /// Delete the LOCAL blobs for these refs (the event/metadata stays). A ref a live event still
    /// references is recorded in the evicted set with its size, so it renders as a "Download X MB"
    /// placeholder instead of being auto-refetched (that would undo the cleanup). Returns freed bytes.
    @discardableResult
    func deleteSelectedMedia(_ rows: [MediaInventoryRow]) async -> Int64 {
        guard let social else { return 0 }
        let inUse = await Task.detached(priority: .utility) { Self.mediaInUseStems(social: social) }.value
        var freed: Int64 = 0
        for row in rows where !row.isPinned {
            let referenced = !MediaStore.storedStems(for: row.ref).isDisjoint(with: inUse)
            freed += MediaStore.shared.delete(row.ref)
            if referenced { EvictedMediaStore.shared.mark(row.ref, bytes: row.bytes) }
        }
        if freed > 0 { scheduleRefresh() }
        return freed
    }

    // MARK: - Re-optimize media I already shared
    //
    // These two live here rather than in MediaReoptimize.swift only because `social` and
    // `broadcastEvent` are private to this store. Everything else about the feature — deciding what
    // needs rewriting, encoding it, driving the UI — is in that file.

    /// Every post and comment I AUTHORED that carries real media, across every circle including DMs.
    ///
    /// Authored, because re-optimizing means re-publishing: the swap below is an Edit event, and an
    /// Edit is signed by the author. I cannot re-point someone else's post at new bytes, and I should
    /// not be able to — that would be rewriting another person's signed content. So this button
    /// improves what I put into my circles, and media others sent me is left exactly as it arrived.
    ///
    /// Stories are excluded: they expire on their own, so rewriting one spends an encode and a
    /// re-upload on bytes that are about to be dropped anyway. Unsent (retracted) items too.
    func reoptimizeTargets() -> [ReoptimizeTarget] {
        guard let social else { return [] }
        var out: [ReoptimizeTarget] = []
        let nowMs = now()
        for c in social.circles() {
            // viewerRetentionSecs nil: retention hides old posts from MY feed, but they are still
            // live on everyone else's devices and still costing them the old bytes.
            for item in social.feed(circleId: c.id, nowMs: nowMs, viewerRetentionSecs: nil) {
                if item.isMe, !item.unsent, !item.story, !item.media.isEmpty {
                    out.append(ReoptimizeTarget(circleId: c.id, eventId: item.id, body: item.body,
                                                media: item.media, music: item.music,
                                                muteVideo: item.muteVideo, createdAtMs: item.createdAt))
                }
                for cm in item.comments where cm.isMe && !cm.unsent && !cm.media.isEmpty {
                    out.append(ReoptimizeTarget(circleId: c.id, eventId: cm.id, body: cm.body,
                                                media: cm.media, music: nil, muteVideo: false,
                                                createdAtMs: cm.createdAt))
                }
            }
        }
        return out
    }

    /// Re-point one of my posts/comments at the newly-encoded refs and re-share it.
    ///
    /// This is an ordinary Edit — the same event `EditPostSheet` writes when you change a caption.
    /// It keeps the item's id, author, thread position and timestamp, so nobody's feed reorders and
    /// no notification fires; only the media array changes. The new blob is then queued for the
    /// relay exactly as a fresh post's would be, so members who are offline right now still find it
    /// waiting for them.
    @discardableResult
    func applyReoptimized(_ target: ReoptimizeTarget, media: [String]) -> Bool {
        guard let social,
              let env = try? social.edit(circleId: target.circleId, target: target.eventId,
                                         body: target.body, media: media, music: target.music,
                                         muteVideo: target.muteVideo, createdAt: now())
        else { return false }
        // SILENT: this republish carries no news — it re-points an existing post at a smaller copy of
        // the same media. Notifying normally would fire one alert per rewritten post at every member
        // (25 per tap), for content nobody wrote. The event still delivers and still syncs.
        broadcastEvent(target.circleId, env, silent: true)
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: target.circleId, social: social) }
        return true
    }

    // MARK: - Local limits (#4) — age/size caps

    private var lastLimitSweepAt: TimeInterval = 0
    private var limitSweepInFlight = false
    /// Enforce the device-local age/size caps (Settings ▸ Storage). Deletes local blobs (metadata stays
    /// → placeholder) oldest-first, skipping pinned + in-flight media. `force` bypasses the throttle
    /// (used when the setting changes). No-op when both caps are off.
    func enforceLocalLimits(force: Bool = false) {
        guard !DemoEnv.isDemo, let social, !limitSweepInFlight else { return }
        let maxDays = SettingsStore.shared.localMediaMaxDays
        let maxGB = SettingsStore.shared.localMediaMaxGB
        guard maxDays > 0 || maxGB > 0 else { return }
        let nowSecs = Date().timeIntervalSince1970
        guard force || nowSecs - lastLimitSweepAt > 600 else { return }   // at most every 10 min otherwise
        lastLimitSweepAt = nowSecs
        limitSweepInFlight = true
        let pinnedStems = PinnedMediaStore.shared.inUseStems()
        Task.detached(priority: .utility) { [weak self] in
            let inUse = Self.mediaInUseStems(social: social)
            let r = MediaStore.performLimitSweep(maxDays: maxDays, maxGB: maxGB, pinnedStems: pinnedStems, inUse: inUse)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.limitSweepInFlight = false
                guard r.files > 0 else { return }
                for (stem, bytes) in r.evict { EvictedMediaStore.shared.mark(stem, bytes: bytes) }
                MediaStore.shared.clearMemoryCache()
                self.scheduleRefresh()
                HavenLog.sync("media limit sweep: freed \(r.bytes)B across \(r.files) files")
            }
        }
    }

    // MARK: - On-demand download of an evicted blob (#3)

    /// Refs a Download tap is actively fetching, and refs the relay no longer has — drive the
    /// placeholder's spinner / "no longer available" states.
    @Published var downloadingMedia: Set<String> = []
    @Published var unavailableMedia: Set<String> = []

    /// User tapped "Download" on a placeholder for a blob we deliberately evicted: clear the eviction
    /// (so the normal missing-media path may fetch it), request it now, and surface a spinner. If it
    /// hasn't arrived in ~45s, mark it unavailable (the relay/peers don't have it either).
    func downloadEvicted(_ ref: String) {
        EvictedMediaStore.shared.clear(ref)
        unavailableMedia.remove(ref)
        guard !MediaStore.shared.has(ref) else { scheduleRefresh(); return }
        downloadingMedia.insert(ref)
        requestMedia(ref)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            downloadingMedia.remove(ref)
            if !MediaStore.shared.has(ref) { unavailableMedia.insert(ref) }
        }
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

    private func bringOnline() {
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.syncWithContacts()
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
    private var lastHeardPersistPending = false
    func recordHeard(_ idHex: String) {
        guard !idHex.isEmpty else { return }
        lastHeard[idHex] = Date()
        // Debounce the disk write. This used to serialize the WHOLE dict to UserDefaults on the main
        // thread on every call — and recordHeard fires per DM message during a sync burst. Coalesce to
        // one write per few seconds ("last seen" is coarse; sub-second precision on disk is pointless).
        guard !lastHeardPersistPending else { return }
        lastHeardPersistPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.lastHeardPersistPending = false
            UserDefaults.standard.set(self.lastHeard.mapValues { $0.timeIntervalSince1970 }, forKey: self.lastHeardKey)
        }
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
                self.maybeWeeklyMediaSweep()      // orphaned media blobs (at most once a week)
                self.enforceLocalLimits()         // device-local age/size caps (throttled ~10 min; no-op if off)
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
        maybePurgeExpiredMedia(circleId, retention: retention)   // feed refresh = the purge hook (throttled)
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
            let hiddenHere = raw.reduce(into: 0) { if hidden.contains($1.id) { $0 += 1 } }   // hidden IN THIS circle
            await MainActor.run { [weak self] in
                guard let self, self.refreshGeneration == gen, self.activeCircleId == circleId else { return }
                // Only republish when the content ACTUALLY changed. A refresh triggered incidentally during
                // a scroll (media backfill, a poster landing, a periodic tick) usually produces an identical
                // list; assigning it anyway re-diffs the LazyVStack and nudged the scroll offset — the
                // "position jumps around before settling" on fast flings.
                if self.items != filtered { self.items = filtered }
                if self.hiddenInActiveCircle != hiddenHere { self.hiddenInActiveCircle = hiddenHere }
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
        broadcastEvent(circleId, env, silent: true)   // not user-facing news
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
    /// again), broadcast the sealed report to the whole circle, and append a content-free, signed
    /// entry (subject + category, no reporter) to the developer ledger. Returns the reported author's FULL node
    /// hex (resolved by the core from the event log) so the caller can offer an immediate block.
    @discardableResult
    func report(circleId: String, target: String, reason: String, comment: String) -> String? {
        guard let social, let env = try? social.report(circleId: circleId, target: target, reason: reason, comment: comment, createdAt: now()) else { return nil }
        broadcastEvent(circleId, env, silent: true)   // deliver the report without a lock-screen banner
        HiddenStore.shared.hide(target)
        reportsCache.removeValue(forKey: circleId)
        let author = reports(circleId: circleId)[target]?.first?.author
        ModerationLedger.report(subject: author ?? "", reason: reason)
        refresh()
        return author
    }

    /// The current user's own posts — their personal archive.
    var myPosts: [FeedItemFfi] { items.filter { $0.isMe && !$0.story && !$0.unsent } }
    /// My stories for MY PROFILE: the live ones, plus any I chose to keep whose event has since
    /// expired. Kept stories appear here and here only — the circle's story row reads the live feed,
    /// so a kept story still leaves everyone else's stories when its 24 hours are up, which is the
    /// whole point of keeping it rather than re-posting it.
    var myStories: [FeedItemFfi] {
        let live = items.filter { $0.isMe && $0.story && !$0.unsent && !$0.media.isEmpty }
        let liveIds = Set(live.map(\.id))
        // Only the kept ones the feed no longer has — while a story is still live it IS the live item
        // (comments, reactions and all); the snapshot is a fallback for after it's purged.
        let revived: [FeedItemFfi] = KeptStoriesStore.shared.kept
            .filter { !liveIds.contains($0.id) && !$0.media.isEmpty }
            .map { k in
                let music: TrackRefFfi? = k.musicCatalogId.map {
                    TrackRefFfi(catalogId: $0, title: k.musicTitle ?? "", artist: k.musicArtist ?? "",
                                artworkUrl: k.musicArtworkUrl ?? "", durationMs: k.musicDurationMs ?? 0)
                }
                return FeedItemFfi(id: k.id, authorShort: myNodeHex, isMe: true, createdAt: k.createdAt,
                                   body: k.body, media: k.media, music: music, edited: false, unsent: false,
                                   story: true, muteVideo: false, comments: [], reactions: [], poll: nil)
            }
        return (live + revived).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Authoring (seal locally, then broadcast to contacts)

    func post(_ body: String, media: [String] = [], music: TrackRefFfi? = nil, retentionSecs: UInt64? = nil, story: Bool = false, muteVideo: Bool = false) {
        guard let social, let env = try? social.post(circleId: activeCircleId, body: body, media: media, music: music, retentionSecs: retentionSecs, story: story, muteVideo: muteVideo, createdAt: now()) else { return }
        let cid = activeCircleId
        let name = circles.first(where: { $0.id == cid })?.name ?? "your circle"
        broadcastEvent(cid, env, banner: .forPost(circleId: cid, circleName: name, body: body, media: media, story: story))
        postTick += 1; refresh()
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: cid, social: social) }
    }

    /// Post to a SPECIFIC circle (used by the scheduler when a queued post fires — the target
    /// circle may not be the active one). Same seal → broadcast → mailbox-backup path as `post`.
    func postScheduled(circleId: String, body: String, media: [String]) {
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: media, music: nil, retentionSecs: nil, story: false, muteVideo: false, createdAt: now()) else { return }
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        broadcastEvent(circleId, env, banner: .forPost(circleId: circleId, circleName: name, body: body, media: media, story: false))
        postTick += 1
        if circleId == activeCircleId { refresh() }
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: circleId, social: social) }
    }

    /// Post text to a specific circle (used by App Intents with a circle filter).
    func post(_ body: String, toCircle circleId: String) {
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: [], music: nil, retentionSecs: nil, story: false, muteVideo: false, createdAt: now()) else { return }
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        broadcastEvent(circleId, env, banner: .forPost(circleId: circleId, circleName: name, body: body, media: [], story: false))
        postTick += 1; refresh()
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
    /// The regular feed (stories live in the tray, not the main list). Unsent posts are gone —
    /// a "Message unsent" tombstone in the feed is clutter, not information.
    var feedItems: [FeedItemFfi] { items.filter { !$0.story && !$0.unsent } }
    func comment(_ id: String, _ body: String, _ media: [String] = []) {
        guard let social, let env = try? social.comment(circleId: activeCircleId, target: id, body: body, media: media, createdAt: now()) else { return }
        let cid = activeCircleId
        let name = circles.first(where: { $0.id == cid })?.name ?? "your circle"
        broadcastEvent(cid, env, banner: .forComment(body: body, circleId: cid, circleName: name)); refresh()
    }
    func react(_ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(circleId: activeCircleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env, banner: .forReaction(emoji: emoji, circleId: activeCircleId))
        reactionTick += 1; refresh()
    }
    /// Remove my own reaction (emoji) from a post/comment in the active circle.
    /// Silent: un-react is not news worth a lock-screen banner (and would look like a new reaction).
    func unreact(_ id: String, _ emoji: String) {
        guard let social, let env = try? social.unreact(circleId: activeCircleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env, silent: true); reactionTick += 1; refresh()
    }
    /// React to a message in a specific (DM) circle.
    func reactMessage(in circleId: String, _ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(circleId: circleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(circleId, env, banner: .forReaction(emoji: emoji, circleId: circleId))
        reactionTick += 1; refresh()
    }
    /// Remove my own reaction from a message in a specific (DM) circle. Silent (see `unreact`).
    func unreactMessage(in circleId: String, _ id: String, _ emoji: String) {
        guard let social, let env = try? social.unreact(circleId: circleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(circleId, env, silent: true); reactionTick += 1; refresh()
    }
    /// Comment on a post in a specific circle (used by the deep-link post viewer).
    func commentMessage(in circleId: String, _ id: String, _ body: String, _ media: [String] = []) {
        guard let social, let env = try? social.comment(circleId: circleId, target: id, body: body, media: media, createdAt: now()) else { return }
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        broadcastEvent(circleId, env, banner: .forComment(body: body, circleId: circleId, circleName: name)); refresh()
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
        let cid = activeCircleId
        let name = circles.first(where: { $0.id == cid })?.name ?? "your circle"
        broadcastEvent(cid, env, banner: .forEdit(circleId: cid, circleName: name)); refresh()
        for ref in media { MediaBackupQueue.shared.enqueue(ref, circleId: cid, social: social) }
    }
    func unsend(_ id: String) {
        guard let social, let env = try? social.unsend(circleId: activeCircleId, target: id, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env, banner: .forUnsend(circleId: activeCircleId)); refresh()
    }

    // MARK: - Wire protocol  [type][payload]: 0 Hello, 1 Event, 3 MediaReq, 5 MediaChunk
    //   Hello payload = [LP circleId][LP circleName][LP bundle][signed profile]
    //   Event payload = [LP circleId][sealed envelope]

    /// On add / online / timer: for every circle, send each member our Hello + that
    /// circle's posts, so the circle forms on their side and back-fills.
    private var lastHistoryResendMs: UInt64 = 0
    private var lastMediaBackfillMs: UInt64 = 0
    /// Last own-device catch-up sweep. Throttled hard (5 min): it re-seals every envelope it sends,
    /// so it must not ride the 20s sync tick. See the sweep for why it exists.
    private var lastOwnDeviceCatchupMs: UInt64 = 0
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
        // PULL the rosters we're missing. Announcing ours (frame 27, above) only works when the
        // contact is DIRECTLY reachable; between two CGNAT networks it never lands in either
        // direction, so neither side can resolve the other's devices — and a device-signed call
        // frame, the ACCEPT included, then fails the declared-vs-signer check and is dropped as a
        // forgery. Their roster is already sitting on the relay, so ask for it. Cheap and idempotent:
        // only contacts we currently can't resolve, and the ingest is a no-op once we hold it.
        //
        // STRICTLY BOUNDED, and it must stay that way. A contact whose roster is on NO relay never
        // becomes resolvable, so an unguarded version of this re-dials them forever: one pass per 20s
        // tick, every relay, per contact, with 60s HTTP timeouts — so passes overlap and pile up
        // without limit. That is a dial storm, and iroh answers a dial storm with unbounded
        // path-discovery churn (the self-connect leak and the open_path_on_conn OOM). It took a Mac
        // to 28 GB. Hence: one pass at a time, a few contacts per pass, and a long per-contact
        // backoff so a permanently-unresolvable contact costs almost nothing.
        if !rosterPullInFlight {
            let due = ContactsStore.shared.contacts
                .map(\.idHex)
                .filter { hex in social.deviceNodeIdsFor(accountHex: hex).allSatisfy { $0.lowercased() == hex.lowercased() } }
                .filter { SharedStore.rosterPullDue($0) }
                .prefix(3)
            if !due.isEmpty {
                rosterPullInFlight = true
                HavenLog.sync("devroster: pulling \(due.count) contact roster(s) from relays")
                Task { @MainActor in
                    defer { rosterPullInFlight = false }
                    for hex in due {
                        SharedStore.noteRosterPullAttempt(hex)
                        await SharedStore.fetchContactRoster(accountHex: hex, social: social)
                    }
                }
            }
        }
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
                let workFinal = work
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (cid, envs) in workFinal { for env in envs { self.nearbyBroadcast(1, self.eventPayload(cid, env)) } }
                }
            }
        }
        // Own-device catch-up over the INTERNET. The nearby sweep above only runs when a sibling is
        // physically connected — so two devices on different networks never reconciled, and anything
        // that reached only ONE of them stayed there. That is the "a DM landed on my Mac and never on
        // my iPhone" case, and fixing the receive-time fan-out alone would not have repaired the
        // messages already sitting on one device.
        //
        // BOUNDED, deliberately: only when I actually have other devices, at most 50 events per
        // circle, and no more than every 5 minutes — this re-seals per envelope, so it is real CPU
        // and must not ride the 20s tick. Siblings dedupe, so a repeat sweep is harmless.
        if nowMs - lastOwnDeviceCatchupMs > 300_000, !myOtherDeviceTargets().isEmpty {
            lastOwnDeviceCatchupMs = nowMs
            let cidsForDevices = circles.map(\.id)
            Task.detached(priority: .utility) { [weak self, social] in
                var work: [(String, [Data])] = []
                for cid in cidsForDevices {
                    // ALL authors — the point is my friends' messages that reached one device only.
                    let envs = social.exportRecentEnvelopes(circleId: cid, limit: 50)
                    if !envs.isEmpty { work.append((cid, envs)) }
                }
                let workFinal = work
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (cid, envs) in workFinal {
                        self.liveDeliverManyToMyDevices(1, envs.map { self.eventPayload(cid, $0) })
                    }
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
            // Re-publish our account-signed device roster to every known relay, so a HEADLESS relay
            // (which only knows account ids from its link) authorizes THIS device's id and stops
            // ERR-forbidding our mailbox ops — the "my own NAS relay rejects my phone" fix.
            Task { await SharedStore.publishDeviceRoster(social: social) }
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
    /// relay's plain-HTTP interface is known — JSON `{"node":hex,"urls":[…],"token":…,"derp":…}` so
    /// members also learn the media path **and** the Haven DERP fabric URL (n0-free NAT).
    private func relayAnnounceData(_ hex: String) -> Data {
        // Always carry the relay's adoption timestamp so receivers can LWW a stale tombstone. Use the
        // JSON form whenever we have EITHER an HTTP interface or a non-zero adoption stamp; a legacy
        // receiver ignores JSON it can't parse as a bare hex (wrong length), so this stays compatible.
        let addedAt = RelayMailboxStore.shared.addedAtMs(hex)
        let http = RelayMailboxStore.shared.httpInterface(hex)
        let derp = RelayMailboxStore.shared.entries[hex.lowercased()]?.derpUrl
            ?? RelayMailboxStore.shared.entries[hex]?.derpUrl
        if http != nil || addedAt > 0 || (derp?.isEmpty == false) {
            var obj: [String: Any] = ["node": hex, "addedAt": addedAt]
            if let http { obj["urls"] = http.urls; obj["token"] = http.token }
            if let derp, !derp.isEmpty { obj["derp"] = derp }
            if let json = try? JSONSerialization.data(withJSONObject: obj) { return json }
        }
        return Data(hex.utf8)
    }

    /// A nearby peer just connected over Bluetooth/Wi-Fi — say hello + back-fill (all circles).
    private func nearbyPeerConnected() {
        guard let social else { return }
        nearbyActive = true
        bumpActivity()   // a peer just appeared → sync tight for the catch-up burst
        // S4: if this device is mid seedless-enrollment, a primary that only just came into range now
        // gets our frame-28 request (the ticket is single-use but the request is safe to resend).
        if pendingEnrollTicket != nil { sendEnrollRequest() }
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
        guard social != nil else { return }
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            for hex in dialTargets(circle.id) { sendIroh(0, hello, to: hex) }
        }
    }

    private func eventPayload(_ circleId: String, _ env: Data) -> Data {
        var p = Data(); lpAppend(&p, Data(circleId.utf8)); p.append(env); return p
    }

    /// `silent` suppresses the recipient banner — the event still delivers and still syncs. Use it for
    /// a republish that is not news (see the re-optimize pass) or un-reacts; everything a person
    /// actually wrote should notify with a kind-specific `banner`.
    ///
    /// `banner` is the lock-screen copy the recipient's NSE will show after decrypting. The NSE has
    /// the seed alone and cannot open circle events, so richness (reaction vs story vs DM preview)
    /// MUST be decided here at send time. Nil falls back to the legacy generic line.
    private func broadcastEvent(_ circleId: String, _ env: Data, silent: Bool = false,
                                banner: PushBanner? = nil) {
        bumpActivity()   // I just posted/messaged → keep sync tight
        let payload = eventPayload(circleId, env)
        let members = social?.contactNodeIds(circleId: circleId) ?? []
        // Build the push banner once: title = my name, body keyed to the KIND of event. We seal it
        // *per recipient* below so the relay only ever forwards ciphertext.
        let myName = ProfileStore.shared.displayName.isEmpty ? "Someone" : ProfileStore.shared.displayName
        let isDM = circleId.hasPrefix("dm:")
        let circleName = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        let resolved = banner ?? .generic(isDM: isDM, circleName: circleName)
        // `c` lets the recipient's NSE redact the banner if *they've* locked this circle.
        // `k`/`e` let a modern NSE group and format; older NSEs ignore unknown keys.
        let notifJSON = (try? JSONSerialization.data(
            withJSONObject: resolved.jsonObject(title: myName, circleId: circleId))) ?? Data()
        let eventB64 = env.base64EncodedString()   // the sealed circle event, for push-inline sync
        PushManager.shared.syncSelf(event: eventB64)   // multi-device: deliver to my own other devices
        // Deliver the event to each member's DEVICE node ids (+ account id for old-build peers) — the account
        // id alone no longer resolves under device-seed. Notification sealing below stays per-ACCOUNT recipient.
        for t in dialTargets(circleId) { sendIroh(1, payload, to: t) }
        // Live delivery (D16 Phase 4b): dialTargets deliberately excludes us, so my OTHER devices only
        // ever learned about this post from the mailbox poll (~120s) or an APNs wake. Hand it to them
        // now while they're online. Strictly an optimisation — the mailbox enqueue below is unconditional
        // and remains what a sleeping/not-yet-linked device gets.
        liveDeliverToMyDevices(1, payload)
        for nodeHex in members {
            // Seal + SIGN the banner to this recipient; the relay forwards it blind, their NSE
            // decrypts AND verifies it really came from us (audit H2).
            let sealed = (notifJSON.isEmpty || silent) ? nil
                : try? social?.sealSignedNotification(recipientNodeHex: nodeHex, data: notifJSON)
            PushManager.shared.wake(nodeHex, ciphertext: sealed?.base64EncodedString(),
                                    event: eventB64, silent: silent)
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

    private var lastPushPollMs: UInt64 = 0
    /// A push landed — go and FETCH, rather than trusting it to have carried the event.
    ///
    /// The push worker inlines the sealed event (`ev`) only if the whole APNs payload stays under
    /// ~3900 bytes, and silently drops it when it doesn't. So a large event produces a banner with no
    /// content attached, nothing for the NSE to stash, and — until now — nothing that made the app go
    /// look for it either: the notification was the ONLY signal that something existed, and it carried
    /// no way to get it. The result was a banner for a message that never appeared, not even after a
    /// relaunch, because there was never anything queued to ingest.
    ///
    /// Treat every push as "something is waiting" and pull the mailbox. Throttled to once per 10s so a
    /// burst of notifications can't turn into a burst of LIST+FETCH round-trips — a peer sending twenty
    /// messages must not cost twenty mailbox sweeps.
    func syncBecauseOfPush() {
        let nowMs = now()
        guard nowMs - lastPushPollMs > 10_000 else { return }
        lastPushPollMs = nowMs
        pollMailboxNow()
    }

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
        var dmCircles = Set<String>()
        for cid in ingested {
            notifyNewest(in: cid)
            if cid.hasPrefix("dm:") { dmIngested = true; dmCircles.insert(cid) } else { bumpUnseen(cid) }
        }
        if dmIngested { recomputeUnreadDMs() }   // once for the whole batch, not per DM circle
        refresh(); requestMissingMedia()
        // `requestMissingMedia` only ever scans `items` — the ACTIVE CIRCLE's feed — so it has never
        // asked for anything a DM references. The thread view now asks when you open it, but that is
        // not enough on its own: nothing bumps `postTick` on RECEIVE (only your own send/edit/delete
        // do), so a picture arriving while you sit in the conversation was fetched by nothing at all,
        // and one arriving while the app ran only downloaded if you left the thread and came back.
        // Ask HERE, where we know exactly which DM circles just received something — so it lands
        // whether or not the thread is open.
        for cid in dmCircles { requestMissingDMMedia(cid) }
    }

    /// Fetch media the NEWEST messages in a DM circle reference and we don't hold.
    ///
    /// Bounded hard, because this runs off an ingest and a peer decides when that happens: newest
    /// messages only, a handful of refs, and `requestMedia` no-ops for anything already held. It
    /// deliberately does not walk the whole conversation — history fills in when you open the thread.
    @MainActor func requestMissingDMMedia(_ circleId: String) {
        let recent = messages(in: circleId).sorted { $0.createdAt > $1.createdAt }.prefix(8)
        var budget = 4
        let dataSaver = SettingsStore.shared.superDataSaver
        for item in recent {
            let candidates = dataSaver
                ? MediaVariants.dataSaverPrefetchRefs(item.media)
                : item.media.filter { !MediaStore.isSynthetic($0) }
            for ref in candidates where !MediaStore.shared.has(ref) {
                guard budget > 0 else { return }
                budget -= 1
                requestMedia(ref, circleId: circleId)
            }
        }
    }

    /// Drain events that arrived inline in a push (stashed by the NSE) and ingest them — silent
    /// sync with no mailbox round-trip. We don't carry the circle id in cleartext, so we try each
    /// circle until one opens the envelope (a wrong circle just ignores it).
    ///
    /// Mirrors `pullMailbox`'s post-ingest work: DM badges, DM media fetch, and live fan-out to the
    /// user's other devices. The old path only bumped the *feed* unseen counter and scanned the
    /// active circle's feed for missing media — so a DM that arrived inline as a push notified
    /// every device, landed on the one that opened the envelope, and left siblings with a banner
    /// and an empty thread (and never asked the mailbox for the attached photo).
    func ingestPushInbox() {
        guard let social else { return }
        let envs = SharedInbox.drain()
        guard !envs.isEmpty else { return }
        let ids = circles.map { $0.id }
        // Trying every circle per envelope multiplies the receive() crypto — run the whole batch
        // off-main and apply the result in one main-actor hop (same shape as pullMailbox).
        Task.detached(priority: .utility) { [weak self] in
            var ingested: [(circleId: String, envelope: Data)] = []
            for env in envs {
                for cid in ids where (try? social.receive(circleId: cid, envelope: env)) == true {
                    ingested.append((cid, env)); break
                }
            }
            guard !ingested.isEmpty else { return }
            let ingestedFinal = ingested
            await MainActor.run { [weak self] in
                guard let self else { return }
                var dmCircles = Set<String>()
                for (cid, env) in ingestedFinal {
                    self.notifyNewest(in: cid)
                    if cid.hasPrefix("dm:") {
                        dmCircles.insert(cid)
                    } else {
                        self.bumpUnseen(cid)
                    }
                    // Fan out to my other online devices — same contract as handleEvent. The push
                    // worker delivers to every device token, but the *event body* only rides the
                    // push when it fits under ~3900 bytes; larger DMs notify every device and only
                    // inline on none of them. Live-delivering the sealed envelope we just opened
                    // is what makes "I got the banner on my phone AND my Mac shows the message"
                    // true when both are awake. Mailbox poll still covers the asleep case.
                    self.liveDeliverToMyDevices(1, self.eventPayload(cid, env))
                }
                if !dmCircles.isEmpty { self.recomputeUnreadDMs() }
                self.persist(); self.refresh(); self.requestMissingMedia()
                for cid in dmCircles { self.requestMissingDMMedia(cid) }
                // Also pull the mailbox — the push may have been one of several, and siblings that
                // only got a banner (no inline body) still need the store-and-forward path.
                self.pollMailboxNow()
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
    /// My OWN other devices' transport ids — the live-delivery fan-out set (D16 Phase 4b).
    /// Excludes this device (dialing our own id loops iroh's path discovery unboundedly — the
    /// self-connect leak) and the account id (a contact handle that resolves to NO endpoint under
    /// per-device transport seeds, so dialing it is a guaranteed ~30s timeout, not a sibling).
    private func myOtherDeviceTargets() -> [String] {
        guard let social else { return [] }
        let mineAcct = social.myNodeHex().lowercased()
        let mineDev = social.myDeviceNodeHex().lowercased()
        return social.deviceNodeIdsFor(accountHex: social.myNodeHex())
            .map { $0.lowercased() }
            .filter { $0 != mineAcct && $0 != mineDev }
    }

    /// Push a frame straight to my own other devices while they're online (see `haven_net::livedelivery`).
    /// Best-effort by contract: a sibling that's asleep is the EXPECTED case, not an error — so this
    /// never touches `lastSendError` (that surfaces "we couldn't reach your contact", which this isn't)
    /// and the caller's durable mailbox path always runs regardless of what happens here.
    private func liveDeliverToMyDevices(_ type: UInt8, _ payload: Data) {
        let targets = myOtherDeviceTargets()
        guard !targets.isEmpty, let node else { return }
        let f = frame(type, payload)
        Task {
            for t in targets { try? await node.sendToNode(nodeIdHex: t, payload: f) }
        }
    }

    /// Batched [`liveDeliverToMyDevices`] — one Task for MANY frames rather than one per frame.
    /// A catch-up sweep hands over dozens of envelopes at once; spawning a Task each would be a
    /// needless pile of concurrent sends to the same few devices.
    private func liveDeliverManyToMyDevices(_ type: UInt8, _ payloads: [Data]) {
        let targets = myOtherDeviceTargets()
        guard !targets.isEmpty, !payloads.isEmpty, let node else { return }
        let frames = payloads.map { frame(type, $0) }
        Task {
            for t in targets {
                for f in frames { try? await node.sendToNode(nodeIdHex: t, payload: f) }
            }
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
        // Publish ONLY on the actual false→true transition. `@Published` fires objectWillChange even
        // when the value is unchanged, and this runs on EVERY inbound frame (every hello, every media
        // chunk). Setting `= true` unconditionally re-rendered the ENTIRE UI observing FeedStore per
        // frame — during a media transfer or a post-background reconnection burst that's hundreds of
        // whole-UI re-renders/sec: the app-wide scroll jank + device heat. The guard makes it publish
        // once per transition instead of once per packet.
        if viaNearby { if !nearbyActive { nearbyActive = true } }
        else { if !internetActive { internetActive = true } }
        var payload = Data(data.dropFirst())
        // Call-signaling frames are SEALED + SIGNED to us (audit R1). Open + verify BEFORE anything
        // else: reject any frame we can't decrypt or whose signature doesn't verify (a relay-forged,
        // relay-rewritten, or replayed-as-another-type frame all fail here), and reject one whose
        // proven sender doesn't match the self-declared `from` prefix the call handlers key on. This
        // runs identically for direct and frame-9-relayed frames — authentication is the signature,
        // not the transport id the relay path lacks. Only after this do we have a PROVEN sender hex to
        // block-check and to hand (as unchanged plaintext) to CallManager.
        // 30 (handled-elsewhere) rides the same sealed+signed path: it can silence a ringing device,
        // so it must be no more forgeable than an invite or a hangup.
        // 31/32 (media wanted / media back) ride the same sealed+signed path: one asks an author to
        // re-upload, the other triggers a notification and a fetch, so neither may be forgeable.
        let callFrameTypes: Set<UInt8> = [10, 11, 12, 16, 17, 18, 21, 22, 30, 31, 32]
        if callFrameTypes.contains(type) {
            // Every rejection below is silent by design — a forged frame shouldn't announce itself.
            // But that also means a LEGITIMATE frame dropped by one of these guards is invisible, and
            // "the callee answers, the caller sits on Calling forever" is exactly what that looks
            // like: the accept (11) is dropped here and nothing, anywhere, records that it arrived.
            // Log which guard fired. The frame is already authenticated-or-not by this point, so the
            // log leaks nothing an attacker doesn't already know they sent.
            guard let opened = social?.openCallFrame(frameType: type, blob: payload) else {
                // "seal/signature did not verify" collapsed two opposite causes into one line. Ask
                // which: a decrypt failure means the frame wasn't sealed to a key we hold, while a
                // signature failure means it WAS addressed to us and the signature is checked against
                // the wrong id of ours. Diagnostics only — the frame is already refused either way.
                let why = social?.diagnoseCallFrame(frameType: type, blob: payload) ?? "no social"
                HavenLog.call("call frame type=\(type) DROPPED — \(why)")
                return
            }
            let verified = opened.senderHex.lowercased()
            let plaintext = Data(opened.data)
            let declared = String(data: plaintext.prefix(64), encoding: .utf8)?.lowercased() ?? ""
            // The signer's ACCOUNT. A SEEDLESS sender (S4, D9) signs call/notification frames with its
            // DEVICE key and carries the device bundle, so `verified` is a device id — resolve it to the
            // account that authorized it (a seeded sender signs with the account key, where the account
            // resolves to itself). This is the receive-side half of accepting device-signed frames.
            let resolved = social?.accountForDevice(deviceHex: verified)?.lowercased()
            let signerAccount = resolved ?? verified
            guard verified.count == 64, declared == signerAccount else {   // proven signer's account == self-declared
                // If `resolved` is nil the sender signed as a DEVICE we can't map to an account —
                // i.e. we don't hold their device roster — so a perfectly genuine frame from a
                // seedless/linked device fails this check. That is a roster-propagation problem
                // wearing a signature-mismatch costume; it is NOT a forgery.
                HavenLog.call("call frame type=\(type) DROPPED — declared=\(declared.prefix(8)) != signerAccount=\(signerAccount.prefix(8)) (signer device=\(verified.prefix(8)), device→account \(resolved == nil ? "UNRESOLVED — we lack their roster" : "resolved"))")
                return
            }
            // Defense in depth: when the transport gave us a verified device id, it must resolve to the
            // SAME account as the signer (nil on the relay path, where the signature already did the work).
            if let senderDevice, senderDevice.count == 64,
               let acct = social?.accountForDevice(deviceHex: senderDevice)?.lowercased(),
               acct != signerAccount {
                HavenLog.call("call frame type=\(type) DROPPED — transport device \(senderDevice.prefix(8)) maps to \(acct.prefix(8)), signer is \(signerAccount.prefix(8))")
                return
            }
            if ConnectionsStore.shared.isBlocked(verified) {
                HavenLog.call("call frame type=\(type) DROPPED — sender \(verified.prefix(8)) is blocked")
                return
            }
            HavenLog.call("call frame type=\(type) accepted from \(signerAccount.prefix(8))")
            payload = plaintext
        } else if [3, 13, 15, 33].contains(type) {
            // Remaining sender-prefixed frames (media req + resume req + call audio/video
            // placeholders): drop if blocked (audit F4). These are not call SIGNALING and keep the
            // plaintext-prefix check. 33 sits here rather than in the sealed set above because it asks
            // for a SUBSET of what frame 3 already asks for in the clear — see handleMediaResumeRequest.
            let head = String(data: payload.prefix(64), encoding: .utf8) ?? ""
            if head.count == 64, ConnectionsStore.shared.isBlocked(head) { return }
        }
        switch type {
        case 0: handleHello(payload, viaNearby: viaNearby, senderDevice: senderDevice)
        case 1: handleEvent(payload, senderDevice: senderDevice, viaNearby: viaNearby)
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
        case 28: handleSeedlessEnrollRequest(payload)           // S4: a new seedless device asks my primary to enroll it
        case 29: handleSeedlessEnrollGrant(payload)             // S4: the primary granted my new device its seedless identity
        case 30: CallManager.shared.handleHandledElsewhere(payload)  // another of MY devices took/declined this call
        case 31: handleMediaWanted(payload)                          // someone wants media I authored, that a relay swept
        case 32: handleMediaAvailable(payload)                       // media I asked about is back on a relay
        case 33: handleMediaResumeRequest(payload)                   // re-request carrying a bitmap of what they already have
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

    /// Revoke a linked device (primary only). It stops being a recipient of future circle key commits,
    /// and — Switch-Flip §6 — the account-state self-sync key is ROTATED so the revoked device (which
    /// keeps its stale key) can neither read nor LWW-write my account state afterward.
    func revokeDevice(_ nodeHex: String) {
        guard let seed = AccountStore.storedSeed(), let social else { return }
        guard DeviceRosterManager.shared.revoke(nodeHex, social: social, accountSeed: seed) else { return }
        rotateSelfSyncAfterRevocation(revokedHex: nodeHex, accountSeed: seed, social: social)
    }

    // MARK: - Switch-Flip 1.0.7 (docs/SWITCH-FLIP-1.0.7.md) — turn the new crypto ON, per-circle-gated.

    /// Re-apply the NON-PERSISTED crypto switches every launch (§3/§4/§2/§5). Every switch is gated in
    /// core — a circle stays byte-identical to 1.0.6 until its whole membership is capable — so this is
    /// safe to run unconditionally. A `seedless` device sets keying + DM live-lanes but never the
    /// primary-only ops (seed-drop retirement, account-leaf migration, self-sync rotation): the primary
    /// that holds the account key owns those.
    private func applyCryptoSwitches(seedless: Bool) {
        guard let social else { return }
        // §3 MLS keying master switch — every device (off→shadow→live handled by the all-joined gate).
        social.setMlsKeying(on: true)
        // §4 seed-drop retirement — PRIMARY only (a seedless device holds no bare account key to drop).
        if !seedless { social.setSeedDropRetire(on: true) }
        // §2 creator authority root + §5 DM live-ratchet lanes, re-marked for every current circle.
        let myHex = social.myNodeHex()
        for c in social.circles() {
            // §5 mark dm: circles as per-message forward-secrecy lanes (consulted only once keying-live;
            // a no-op for content while the master switch/gate is unmet, so feed circles stay epoch-keyed).
            if c.id.hasPrefix("dm:") { social.setCircleLiveLane(circleId: c.id, on: true) }
            // §2 pin the creator on circles I own — the PRIMARY issues the self-grant that propagates the
            // pin on the control lane. The default "My Circle" is always mine. A seedless device can't
            // sign the grant, so it leaves creator-pinning to the primary and learns it via that grant.
            if !seedless, c.id == "default" || CircleCreatorStore.iCreated(c.id) {
                _ = social.setCircleCreator(circleId: c.id, accountHex: myHex)
            }
        }
        // §1 MIGRATION — shed the legacy bare account leaf once (see below).
        if !seedless { migrateRetireAccountLeafIfNeeded() }
    }

    /// §1: retire the bare account leaf so the roster reaches the DEVICE-ONLY shape that live MLS keying
    /// and account-key retirement require. Gated + idempotent in core (a no-op until the fleet is fully
    /// device-capable), and guarded here by a one-time flag so a migrated roster isn't rebroadcast every
    /// launch. Runs only on a seed-holding primary with multi-device enabled; a brand-new device-only
    /// install technically never needs it, but the call is harmless there (it just marks the sticky flag).
    private func migrateRetireAccountLeafIfNeeded() {
        guard let social, !SwitchFlipMigration.accountLeafRetired else { return }
        guard AccountStore.storedSeed() != nil, DeviceRosterManager.shared.isEnabled else { return }
        if social.retireAccountLeaf() {
            SwitchFlipMigration.accountLeafRetired = true
            // Rebroadcast the now device-only roster wire to my own devices (and, via the normal circle /
            // self-sync roster export, to friends) — higher-version-wins supersedes the legacy roster.
            let wire = social.myDeviceRosterWire()
            if !wire.isEmpty { sendToMyDevices(27, wire) }   // type-27 = signed device-roster announce
            HavenLog.net("switch-flip: retired bare account leaf → device-only roster rebroadcast")
        } else if social.accountLeafRetired() {
            // Already retired on a prior launch / another device — record the flag so we stop retrying.
            SwitchFlipMigration.accountLeafRetired = true
        }
    }

    /// §6: on a device revocation, rotate the self-sync key. GATED exactly like retirement
    /// (`self_sync_key_should_rotate`): a no-op (v0, byte-identical) until the switch is ON and every own
    /// device is seed-drop-capable — which is precisely when the account leaf is retired (v0 authority
    /// dropped fleet-wide). When it fires: mint a fresh key at the next epoch, re-grant it ONLY to
    /// still-authorized devices, persist it locally (so seal/open switch to the v1 dual-key path), and
    /// re-publish account state under the new key. The self-sync BASE content is untouched — rotation
    /// changes only the sealing key, never diffs an empty/stale base into a tombstone (§7 ordering guard).
    private func rotateSelfSyncAfterRevocation(revokedHex: String, accountSeed: Data, social: HavenSocial) {
        let capable = social.accountLeafRetired()   // proxy for "all own devices seed-drop-capable"
        guard selfSyncKeyShouldRotate(retireSwitchOn: SwitchFlipMigration.retireSwitchOn,
                                      ownDevicesAllSeedDropCapable: capable) else { return }
        let newEpoch = SelfSyncEpochStore.epoch + 1
        let key = mintSelfSyncKey()
        // Adopt the rotated key locally FIRST (so seal/open switch to v1), re-grant it ONLY to
        // still-authorized DEVICE bundles — the revoked device is simply not a recipient and keeps only
        // its stale key — then re-publish state sealed under it (the old v0 slot becomes unreadable to
        // the revoked device — the cut). sync() folds local into the EXISTING base first (no tombstone).
        SelfSyncEpochStore.save(epoch: newEpoch, key: key)
        // §6: hand the rotated key to every still-authorized device via the canonical keygrant mailbox
        // (SelfSyncCoordinator.publishEpochGrants), then re-publish state under it. Same per-device slot on
        // iOS/desktop/Android, so a rotated key crosses platforms.
        Task {
            await SelfSyncCoordinator.shared.publishEpochGrants()
            _ = await SelfSyncCoordinator.shared.sync(social: social)
        }
        HavenLog.net("switch-flip: rotated self-sync key → epoch \(newEpoch) after revoking \(revokedHex.prefix(10))")
    }

    /// §2: promote a circle member to admin (creator/admin only; account-key-signed, propagates on the
    /// control lane). An admin can author `mls_remove_member`. The wiring point for a future "make admin"
    /// affordance; returns whether the grant was authored (false when unauthorized / unknown circle).
    @discardableResult
    func promoteToCircleAdmin(_ memberHex: String, in circleId: String) -> Bool {
        guard let social else { return false }
        let ok = social.grantCircleAdmin(circleId: circleId, adminHex: memberHex)
        if ok { persist() }
        return ok
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

    // MARK: - Seedless enrollment (seed-drop S4) — frames 28 (request) / 29 (grant)
    //
    // The seedless linking flow. A NEW device holds only its device key: it scans a `haven-enroll:`
    // ticket, sends a self-authenticating frame-28 request (MAC'd under the ticket secret), and the
    // seed-holding PRIMARY answers with a frame-29 grant carrying the account public bundle, an
    // account-signed device credential, the primary-signed roster wire, and a self-sync-key grant.
    // Only after all four verify does the new device flip into seedless mode — never a half-identity.

    /// One verified frame-28 request awaiting the primary user's confirmation ("Link 'device name'?").
    struct PendingEnrollRequest: Identifiable {
        let id = UUID()
        let deviceBundle: Data
        let deviceHex: String
        let name: String
    }
    /// Set on the PRIMARY when a valid frame-28 arrives → drives the confirmation sheet.
    @Published var pendingEnrollRequest: PendingEnrollRequest?
    /// Surfaced to the new-device linking UI so a failed grant is visible (device stays re-scannable).
    @Published var seedlessEnrollFailed = false

    /// PRIMARY side: the currently-advertised enrollment ticket (single-use, short-lived). The secret
    /// verifies the incoming request's MAC; `enrollTicket` is what the QR encodes.
    private var activeEnrollTicket: EnrollTicketFfi?
    /// NEW-DEVICE side: the ticket this device is enrolling with (kept to open the frame-29 grant).
    private var pendingEnrollTicket: EnrollTicketFfi?

    /// PRIMARY: mint a fresh enrollment ticket to advertise as a `haven-enroll:` QR. Only a seed-holding
    /// primary can (it must issue credentials + seal the self-sync grant). Returns nil if not a primary.
    func mintEnrollTicket() -> EnrollTicketFfi? {
        guard let seed = AccountStore.storedSeed(),
              let accountBundle = (try? Account.fromSeed(seed: seed))?.publicBundle(),
              let primaryDevice = DeviceRosterManager.hexToData(DeviceKeyStore.deviceNodeHex()) else { return nil }
        let relays = RelayMailboxStore.shared.allRelays()
        let ticket = try? enrollIssueTicket(accountBundle: accountBundle, primaryDevice: primaryDevice,
                                            issuedAt: UInt64(Date().timeIntervalSince1970), relays: relays)
        activeEnrollTicket = ticket
        return ticket
    }

    /// NEW DEVICE: begin enrolling with a scanned/pasted `haven-enroll:` ticket. Adopts the bootstrap
    /// relays so the directed request can reach the primary, then sends frame-28 over both rails.
    /// Idempotent — safe to call again if the first attempt didn't land (the ticket is re-scannable).
    func beginSeedlessEnroll(ticket: EnrollTicketFfi) {
        pendingEnrollTicket = ticket
        seedlessEnrollFailed = false
        if !ticket.relays.isEmpty { RelayMailboxStore.shared.adoptBootstrapRelays(ticket.relays) }
        sendEnrollRequest()
    }

    /// Re-send the frame-28 request for the pending ticket (called on begin and on a nearby peer
    /// connecting, so a primary that only just came into range still receives it).
    func sendEnrollRequest() {
        guard let ticket = pendingEnrollTicket else { return }
        let name = DeviceKeyStore.deviceName
        guard let wire = try? enrollBuildRequest(secret: ticket.secret,
                                                 deviceBundle: DeviceKeyStore.deviceBundle(),
                                                 name: name, ts: UInt64(Date().timeIntervalSince1970)) else { return }
        nearbyBroadcast(28, wire)
        // Directed to the primary's device transport id from the ticket (the reliable rail).
        let primaryHex = ticket.primaryDevice.map { String(format: "%02x", $0) }.joined()
        sendToDeviceHex(28, wire, primaryHex)
    }

    /// PRIMARY: a frame-28 request arrived. Verify its MAC + freshness against our active ticket; on
    /// success surface a confirmation sheet (only the user's confirm issues the grant). Never
    /// auto-grants — unlike the legacy type-24 path, S4 authorization is an explicit, MAC-gated step.
    private func handleSeedlessEnrollRequest(_ payload: Data) {
        guard AccountStore.storedSeed() != nil, let ticket = activeEnrollTicket else { return }   // only a primary with a live ticket
        guard let req = try? enrollVerifyRequest(secret: ticket.secret, wire: payload,
                                                 now: UInt64(Date().timeIntervalSince1970), maxAgeSecs: 600) else { return }
        let deviceHex = nodeHex(req.deviceBundle.prefix(32))
        guard deviceHex != DeviceKeyStore.deviceNodeHex() else { return }   // not our own device
        // Idempotent: don't stack duplicate sheets while one is already up for this device.
        if pendingEnrollRequest?.deviceHex == deviceHex { return }
        pendingEnrollRequest = PendingEnrollRequest(deviceBundle: req.deviceBundle, deviceHex: deviceHex,
                                                    name: req.name.isEmpty ? "New device" : req.name)
    }

    /// PRIMARY: the user confirmed the link. Issue the credential + union the device into the roster +
    /// seal the self-sync-key grant, assemble frame 29, and send it (directed to the requester + to my
    /// own devices), then push full state so the new device populates. Consumes the ticket (single-use).
    func confirmSeedlessEnroll(_ request: PendingEnrollRequest) {
        defer { pendingEnrollRequest = nil }
        guard let seed = AccountStore.storedSeed(), let ticket = activeEnrollTicket else { return }
        let now = UInt64(Date().timeIntervalSince1970)
        // Ensure roster is enabled (this device becomes/confirms primary) and union the new device in —
        // the same path legacy linking uses, so the roster wire we then export carries the new device.
        guard let accountBundle = (try? Account.fromSeed(seed: seed))?.publicBundle() else { return }
        DeviceRosterManager.shared.enable(social: social, accountSeed: seed, accountBundle: accountBundle,
                                          accountHex: AccountStore.currentNodeHex())
        _ = DeviceRosterManager.shared.addLinkedDevice(bundle: request.deviceBundle, nodeHex: request.deviceHex,
                                                       name: request.name, social: social, accountSeed: seed)
        // The primary-signed roster WIRE (verbatim, incl. capability trailer) the new device installs.
        let rosterWire = social?.myDeviceRosterWire() ?? Data()
        let relays = RelayMailboxStore.shared.allRelays()
        // Convenience path: issues the credential, unions the device, and seals the self-sync grant.
        guard let grant = try? enrollAssembleGrant(accountSeed: seed, ticketSecret: ticket.secret,
                                                   deviceBundle: request.deviceBundle, name: request.name,
                                                   createdAt: now, rosterWire: rosterWire, relays: relays) else { return }
        nearbyBroadcast(29, grant)
        sendToDeviceHex(29, grant, request.deviceHex)   // directed to the requester
        activeEnrollTicket = nil                          // single-use — consume it
        // Populate the newly-seedless device: its self-sync base initializes from this pushed slot.
        pushFullStateToMyDevices()
        NotificationManager.shared.notify(title: "New device linked",
                                          body: "“\(request.name)” is now a secure linked device.",
                                          dedupeKey: "seedless-enroll-\(request.deviceHex)", persist: false)
    }

    /// PRIMARY: the user declined the link. Drop the pending request; the ticket stays live so a genuine
    /// device can retry (or the user can revoke the ticket by leaving the QR screen).
    func declineSeedlessEnroll() { pendingEnrollRequest = nil }

    /// NEW DEVICE: a frame-29 grant arrived. Open it against our pending ticket (all-positive: MAC,
    /// account-bundle tamper-check, credential names this device, roster authorizes us, self-sync grant
    /// opens with our device key). Only on full success do we persist + flip to seedless — otherwise the
    /// device stays in linking mode, idempotent + re-scannable (never a half-identity).
    private func handleSeedlessEnrollGrant(_ payload: Data) {
        guard let ticket = pendingEnrollTicket, !SeedlessState.isEnabled else { return }   // ignore once already seedless
        let deviceSeed = DeviceKeyStore.deviceAccount().secretSeed()
        guard let grant = try? enrollOpenGrant(deviceSeed: deviceSeed, ticket: ticket, wire: payload) else {
            seedlessEnrollFailed = true
            return
        }
        // ORDERED grant acceptance (plan §7 absence-as-deletion guard):
        // 1. Persist the seedless secrets/anchors — BEFORE booting so the engine reads them.
        SelfSyncKeyStore.save(grant.selfSyncKey)
        SeedlessRosterStore.save(grant.rosterWire)
        DeviceCredentialStore.save(grant.credential)
        AccountStore.adoptSeedless(accountBundle: grant.accountBundle)   // account public bundle + flag + drop throwaway seed
        if !grant.relays.isEmpty { RelayMailboxStore.shared.adoptBootstrapRelays(grant.relays) }
        // 2. RESET the self-sync base so the freshly-seedless engine never diffs its empty state against
        //    a STALE base (the throwaway pre-enroll identity's, or nothing) and tombstones the account.
        //    The primary's pushed slot (type-23, arriving next) becomes the authoritative base via
        //    ingestPeerSlot against this empty base — the initialize-before-first-diff ordering.
        SelfSyncCoordinator.shared.reset()
        SharedStore.resetSeenMailbox()
        pendingEnrollTicket = nil
        // 3. Tear down the throwaway engine + its on-disk state, then boot SEEDLESS.
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let backup = stateURL.deletingLastPathComponent().appendingPathComponent("haven-feed.prev.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: stateURL, to: backup)
        }
        node = nil; nearby = nil; social = nil; items.removeAll(); circles.removeAll()
        configure(mode: .seedless(accountBundle: grant.accountBundle, deviceSeed: deviceSeed))
        // 4. Ask the primary to push full state now (profile/circles/posts) → it answers with the
        //    type-23 slot that seeds our base, plus the circle events.
        sendToMyDevices(26, Data(DeviceKeyStore.deviceNodeHex().utf8))
        NotificationManager.shared.notify(title: "Device linked",
                                          body: "This device is now linked — syncing your circles…",
                                          dedupeKey: "seedless-grant", persist: false)
    }

    /// Send a frame directly to one 64-hex device transport id (no account→device expansion). Used for
    /// the enrollment request (dial the primary's device from the ticket) and the directed grant.
    private func sendToDeviceHex(_ type: UInt8, _ payload: Data, _ deviceHex: String) {
        guard let node, deviceHex.count == 64 else { return }
        let f = frame(type, payload)
        Task { try? await node.sendToNode(nodeIdHex: deviceHex, payload: f) }
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
        // Switch-Flip §6: re-hand the rotated self-sync key to my devices via the canonical keygrant mailbox
        // so a device that missed the revocation rotation (offline / enrolled afterward) can open the
        // v1-sealed slot below.
        Task { await SelfSyncCoordinator.shared.publishEpochGrants() }
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

    /// A relay link granting EVERY circle I'm in — the one to hand a relay you want to serve all of
    /// them, which is what picking a default relay in the app already implies.
    ///
    /// A relay authorizes exactly what its link grants. Pasting a single-circle link and then
    /// setting that relay as the default left every other circle answering `ERR forbidden` forever,
    /// with no self-heal: republishing a device roster only adds DEVICE ids to circles the relay
    /// already knows, so a circle it was never granted has nothing to expand into. The visible
    /// symptom was media that "isn't on any relay" while the relay was holding it.
    func relayLinkForAllCircles() -> String? {
        guard let social else { return nil }
        let ids = circles.map(\.id)
        guard !ids.isEmpty else { return nil }
        // Parallel arrays: UniFFI has no Vec<Vec<String>>, so members ride comma-separated.
        let membersPerCircle = ids.map { cid -> String in
            var m = social.contactNodeIds(circleId: cid)
            m.append(myNodeHex)
            return m.joined(separator: ",")
        }
        return makeRelayLinkMulti(circles: ids, membersPerCircle: membersPerCircle)
    }

    /// Adopt a relay node as the mailbox for specific circles (and optionally make it the default
    /// every present + future circle inherits). Each circle's members are told over frame 19.
    /// Adopt a relay. Accepts a bare 64-hex node id, or the JSON interface blob printed by
    /// `haven-relay` (`{"node","urls","token","derp"}`) so media HTTP + Haven DERP fabric are
    /// learned in one paste and re-announced to the circle (frame 19).
    func adoptRelayNode(_ nodeHex: String, circleIds: [String], setDefault: Bool) {
        var hex = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines)
        var announcedUrls: [String] = []
        var announcedToken = ""
        var announcedDerp: String?
        if hex.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: Data(hex.utf8)) as? [String: Any] {
            announcedUrls = (obj["urls"] as? [String] ?? []).filter { $0.hasPrefix("http") }
            announcedToken = obj["token"] as? String ?? ""
            if let d = obj["derp"] as? String, d.hasPrefix("http") {
                announcedDerp = d.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            hex = (obj["node"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        hex = hex.lowercased()
        guard let social, hex.count == 64 else { return }
        RelayMailboxStore.shared.unforget(hex)   // explicit adoption overrides a prior Forget
        if !announcedUrls.isEmpty, !announcedToken.isEmpty {
            RelayMailboxStore.shared.setHttpInterface(hex, urls: announcedUrls, token: announcedToken)
        }
        if let announcedDerp {
            RelayMailboxStore.shared.setDerpUrl(hex, url: announcedDerp)
        }
        let data = relayAnnounceData(hex)
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
            for ref in refs where MediaStore.shared.has(ref) && !MediaBackupBackoff.shouldSkip(ref) {
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
        _ = opened.senderHex.lowercased()   // authenticated envelope sender (account id); reserved for future owner-gate
        let data = opened.data
        // Extended announce: JSON {node, urls, token} also carries the relay's plain-HTTP media
        // interface (the reliable cross-NAT path). Legacy announces are the bare 64-hex id.
        var announcedUrls: [String] = []
        var announcedToken = ""
        var announcedAddedAt: UInt64 = 0
        var announcedDerp: String?
        if nodeHex.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            announcedUrls = (obj["urls"] as? [String] ?? []).filter { $0.hasPrefix("http") }
            announcedToken = obj["token"] as? String ?? ""
            announcedAddedAt = (obj["addedAt"] as? NSNumber)?.uint64Value ?? 0
            if let d = obj["derp"] as? String, d.hasPrefix("http") { announcedDerp = d }
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
        // A relay the user DELETED must STAY deleted — a passive frame-19 re-announce (from ANY
        // device, including the relay's owner reopening the app) must NEVER auto-resurrect it. That
        // auto-resurrect was the "I delete a relay and it keeps coming back" loop: an owner echo (or a
        // re-adopt feedback loop) carried an adoption stamp newer than our deletion and un-forgot it
        // every sync tick. A deleted relay now comes back ONLY when the USER explicitly re-adds it in
        // the UI (adoptRelayNode → self-sync `relay-readd`, LWW), never from an announce. So: drop the
        // announce entirely for a forgotten relay, and never re-add it below.
        if RelayMailboxStore.shared.isForgotten(lower) { return }
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
        // Haven fabric: DERP URL so peers prefer this box over n0 for live NAT.
        if let announcedDerp {
            RelayMailboxStore.shared.setDerpUrl(lower, url: announcedDerp)
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
    ///
    /// The frame is SEALED + SIGNED to the recipient before it leaves this device (audit R1): the
    /// SDP/ICE/control body is encrypted so a relay on the frame-9 forward path can neither read
    /// candidate IPs nor rewrite the DTLS-SRTP fingerprint, and it carries our Ed25519 signature so
    /// the recipient proves the sender instead of trusting the plaintext `from` prefix. If sealing
    /// fails (no engine, or the recipient isn't a known member we can seal to) we send NOTHING —
    /// there is deliberately no plaintext fallback, so a relay can't force a downgrade to the old
    /// spoofable/rewritable form.
    // MARK: - "Tell me when this media is back"

    /// Ask a post's AUTHOR to re-upload media a relay has swept, and remember that I asked.
    ///
    /// The request rides the sealed frame path, which means the circle mailbox carries it: an author
    /// who is offline for a week gets it the moment they next sync. That is the whole mechanism —
    /// nothing is parked on a relay by hand, and no relay change was needed.
    func requestMediaWhenAvailable(ref: String, circleId: String, postId: String, authorShort: String) {
        guard let authorHex = ContactsStore.shared.idHex(forNodePrefix: authorShort) else {
            HavenLog.sync("media-wanted \(ref.prefix(10)): author not resolvable — cannot ask")
            return
        }
        MediaWantedStore.shared.add(ref)
        var f = Data(myNodeHex.utf8)
        lpAppend(&f, Data(ref.utf8))
        lpAppend(&f, Data(circleId.utf8))
        lpAppend(&f, Data(postId.utf8))
        sendCallFrame(31, f, to: authorHex)
        HavenLog.sync("media-wanted \(ref.prefix(10)) → author \(authorHex.prefix(8))")
    }

    /// Author side: someone wants media from a post of mine that a relay no longer holds. If I still
    /// have the original, put it back on a relay we share and tell them when it lands.
    ///
    /// This is the point of the feature: media stays reachable for as long as its AUTHOR keeps a
    /// copy, rather than for as long as a relay's retention window.
    private func handleMediaWanted(_ payload: Data) {
        guard payload.count > 64, let social else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64, isContact(from) else { return }   // only my circle may ask
        let body = payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex)
        var off = 0
        guard let refD = lpRead(body, &off), let cidD = lpRead(body, &off), let pidD = lpRead(body, &off) else { return }
        let ref = String(data: refD, encoding: .utf8) ?? ""
        let circleId = String(data: cidD, encoding: .utf8) ?? ""
        let postId = String(data: pidD, encoding: .utf8) ?? ""
        guard !ref.isEmpty, !circleId.isEmpty else { return }
        // Only serve a circle they're actually in — a request names a circle, and naming one is not
        // the same as belonging to it.
        guard memberHexes(circleId: circleId).contains(where: { $0.hasPrefix(from.prefix(16)) }) else {
            HavenLog.sync("media-wanted \(ref.prefix(10)) from \(from.prefix(8)) — not a member of \(circleId.prefix(12)), ignoring")
            return
        }
        guard MediaStore.shared.has(ref) else {
            HavenLog.sync("media-wanted \(ref.prefix(10)) from \(from.prefix(8)) — I don't hold it either")
            return
        }
        // BOUNDED. Re-uploading a whole blob is expensive and TRIGGERED BY SOMEONE ELSE, so an
        // unbounded version lets any circle member spend my upload bandwidth by asking repeatedly,
        // and lets concurrent asks for one ref each start their own upload. Not the sync-tick shape
        // of the roster leak, but the same class: an attacker-triggered unbounded network operation.
        //
        // A repeat ask inside the cooldown is ANSWERED from the earlier upload rather than ignored —
        // cheaper and also honest, since the blob really is back on the relay.
        if mediaWantedInFlight.contains(ref) {
            HavenLog.sync("media-wanted \(ref.prefix(10)): already uploading — \(from.prefix(8)) will get the reply")
            return
        }
        if let at = mediaWantedServedAt[ref], Date().timeIntervalSince(at) < 600 {
            HavenLog.sync("media-wanted \(ref.prefix(10)): served recently — answering \(from.prefix(8)) without re-uploading")
            sendMediaAvailable(ref: ref, circleId: circleId, postId: postId, to: from)
            return
        }
        HavenLog.sync("media-wanted \(ref.prefix(10)) from \(from.prefix(8)) — re-uploading to a shared relay")
        mediaWantedInFlight.insert(ref)
        Task { @MainActor in
            defer { self.mediaWantedInFlight.remove(ref) }
            let ok = await SharedStore.backup(ref: ref, circleId: circleId, social: social, force: true)
            guard ok else {
                HavenLog.sync("media-wanted \(ref.prefix(10)): re-upload failed — they'll re-ask")
                return
            }
            self.mediaWantedServedAt[ref] = Date()
            if self.mediaWantedServedAt.count > 500 { self.mediaWantedServedAt.removeAll() }
            self.sendMediaAvailable(ref: ref, circleId: circleId, postId: postId, to: from)
            HavenLog.sync("media-wanted \(ref.prefix(10)): back on a relay, told \(from.prefix(8))")
        }
    }

    /// Refs currently being re-uploaded, and when each was last served — see the bounding note above.
    private func sendMediaAvailable(ref: String, circleId: String, postId: String, to peer: String) {
        var f = Data(myNodeHex.utf8)
        lpAppend(&f, Data(ref.utf8))
        lpAppend(&f, Data(circleId.utf8))
        lpAppend(&f, Data(postId.utf8))
        sendCallFrame(32, f, to: peer)
    }

    /// Requester side: media I asked about is back. Notify with a deep link straight to the post.
    private func handleMediaAvailable(_ payload: Data) {
        guard payload.count > 64 else { return }
        let from = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        guard from.count == 64, isContact(from) else { return }
        let body = payload.subdata(in: (payload.startIndex + 64)..<payload.endIndex)
        var off = 0
        guard let refD = lpRead(body, &off), let cidD = lpRead(body, &off), let pidD = lpRead(body, &off) else { return }
        let ref = String(data: refD, encoding: .utf8) ?? ""
        let circleId = String(data: cidD, encoding: .utf8) ?? ""
        let postId = String(data: pidD, encoding: .utf8) ?? ""
        // Only act on something I actually asked for — an unsolicited "it's back" is just noise.
        guard MediaWantedStore.shared.isWanted(ref) else { return }
        MediaWantedStore.shared.clear(ref)
        unavailableMedia.remove(ref)
        EvictedMediaStore.shared.clear(ref)
        requestMedia(ref)   // pull it now, while we know it's there
        let who = ContactsStore.shared.name(forNodePrefix: from) ?? "Someone"
        NotificationManager.shared.notify(
            title: "Media is available again",
            body: "\(who) put back the media you asked for.",
            dedupeKey: "media-back-\(ref)",
            deepLink: postId.isEmpty ? nil : "haven://p/\(circleId)/\(postId)")
        HavenLog.sync("media-wanted \(ref.prefix(10)): author says it's back — fetching")
    }

    /// My OWN other devices' node ids (excluding this one and my account id) — who to tell when a
    /// ringing call has been handled here. Empty until their roster is known, which is the honest
    /// answer: with no roster there is no way to address them.
    func myOtherDeviceHexes() -> [String] {
        guard let social else { return [] }
        let mine = social.myDeviceNodeHex().lowercased()
        let account = social.myNodeHex().lowercased()
        return social.deviceNodeIdsFor(accountHex: account)
            .map { $0.lowercased() }
            .filter { $0 != mine && $0 != account }
    }

    func sendCallFrame(_ type: UInt8, _ payload: Data, to nodeHex: String) {
        // `seal_media` can only seal to a recipient it can RESOLVE to a bundle: our own account, a
        // circle member, or a known device bundle. If none match it throws and this guard drops the
        // frame silently — nothing is transmitted and nothing is recorded. For an ACCEPT (11) that is
        // indistinguishable from the network eating it: the callee has already flipped itself in-call,
        // so it looks connected while the caller waits out the full invite timer. Say so.
        let sealedOpt = try? social?.sealCallFrame(recipientNodeHex: nodeHex, frameType: type, data: payload)
        guard let sealed = sealedOpt, !sealed.isEmpty else {
            let known = (social?.deviceNodeIdsFor(accountHex: nodeHex).count ?? 0)
            HavenLog.call("call frame type=\(type) NOT SENT to \(nodeHex.prefix(8)) — seal failed (recipient unresolvable: \(known) known device id(s), \(sealedOpt == nil ? "threw" : "empty"))")
            return
        }
        sendIroh(type, sealed, to: nodeHex)
        // Cross-NAT fallback: hop the same SEALED frame LIVE through the circle relays (frame 9 — the
        // relay host unwraps + sends it onward over its own connections). The nearby originateRelay
        // flood never leaves the room, so a callee whose direct dial back to the caller failed had
        // NO way to deliver the ACCEPT — the push rang her, but the answer died in the NAT. The relay
        // only ever handles the sealed blob; it cannot read or alter the signaling.
        var dests = social?.deviceNodeIdsFor(accountHex: nodeHex) ?? [nodeHex]
        for h in deviceHints(for: nodeHex) where !dests.contains(where: { $0.lowercased() == h }) { dests.append(h) }
        originateRelayInternet(dests: dests, inner: frame(type, sealed))
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
        guard let social else {
            HavenLog.call("pushCallInvite SKIPPED for \(nodeHex.prefix(8)) — no social handle yet")
            return
        }
        // Seal {caller name, caller node id} to the callee. Their PushKit handler decrypts it and
        // shows the system incoming-call screen via CallKit (ring-from-killed). Worker stays blind.
        let json = (try? JSONSerialization.data(withJSONObject: ["t": callerName, "h": myNodeHex])) ?? Data()
        let sealed = try? social.sealSignedNotification(recipientNodeHex: nodeHex, data: json)
        // A nil seal still rings (the callee falls back to "Someone"), but it means the recipient
        // bundle didn't resolve — worth knowing, since that same lookup gates the call frames.
        if sealed == nil { HavenLog.call("pushCallInvite: seal FAILED for \(nodeHex.prefix(8)) — ringing unnamed") }
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

    // The circle each in-flight media ref was requested for — so when a peer delivers it we re-mirror
    // the blob to THAT circle's relay (sealing under the right circle), making friends' media durable.
    private var mediaReqCircle: [String: String] = [:]

    // MARK: - Media transfer  [3] request(ref) → [4] sealed media back

    /// Ask contacts for any media our feed references but we don't hold the bytes for.
    /// Actively (re-)request one media ref from every contact, nearby, and the shared
    /// store. Safe to call repeatedly — re-sent chunks just fill the gaps a lossy transfer
    /// left, which is what large videos need (one dropped chunk otherwise hangs forever).
    /// `circleId` names the circle the ref belongs to — it defaults to the active one, but a DM thread
    /// must pass its own: the active circle is whatever feed is behind the conversation, and using it
    /// would re-mirror a DM's media to the wrong circle's relay.
    func requestMedia(_ ref: String, circleId: String? = nil) {
        guard let social, !MediaStore.isSynthetic(ref), !MediaStore.shared.has(ref) else { return }
        let circle = circleId ?? activeCircleId
        mediaReqCircle[ref] = circle   // remember the circle so a peer-delivered blob re-mirrors correctly
        let myHex = social.myNodeHex()
        var payload = Data(myHex.utf8); payload.append(Data(ref.utf8))
        askForMedia(ref: ref, myHex: myHex, plain: payload)   // resumes from a partial when we have one
        // Always include the ref's OWN circle, even if it isn't in `circles` yet — a DM's relay copy
        // lives under its dm: circle, and restoring only from the circles list would skip it.
        var circleIds = circles.map { $0.id }
        if !circleIds.contains(circle) { circleIds.append(circle) }
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
        // Skip refs the user DELIBERATELY evicted (cleanup screen / local-limit sweep). Auto-refetching
        // them would silently undo the space the user just freed — they re-download only on an explicit
        // "Download" tap (downloadEvicted clears the eviction first). Still fetch media never seen yet.
        let dataSaver = SettingsStore.shared.superDataSaver
        for item in items {
            // Super data saver: only prefetch posters/images/audio/files — never full videos or
            // original companions. Videos download when the user taps play; originals via the menu.
            let candidates: [String] = dataSaver
                ? MediaVariants.dataSaverPrefetchRefs(item.media)
                : item.media
            for ref in candidates where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref) && !EvictedMediaStore.shared.contains(ref) {
                missing.insert(ref)
            }
            for c in item.comments {
                let cands: [String] = dataSaver ? MediaVariants.dataSaverPrefetchRefs(c.media) : c.media
                for ref in cands where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref) && !EvictedMediaStore.shared.contains(ref) {
                    missing.insert(ref)
                }
            }
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
            mediaReqCircle[ref] = activeCircleId   // these refs come from the active circle's feed
            budget -= 1
            var payload = Data(myHex.utf8)          // 64-byte requester id
            payload.append(Data(ref.utf8))
            let directAsk = { self.askForMedia(ref: ref, myHex: myHex, plain: payload) }
            // RELAY-FIRST: pull the stored copy from the circle's mailbox (own hosted store → relay
            // HTTP :8674 → S3 → iroh blob, in that order inside restore). Only if there is NO mailbox,
            // or the stored copy can't be fetched, fall back to asking an online author/peer directly.
            // Previously the direct ask fired FIRST alongside the restore, so an online sender streamed
            // the bytes peer-to-peer (heat + bandwidth on both) even though the relay already held them.
            if hasMailbox {
                Task { @MainActor in
                    if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                        HavenLog.relay("MEDIA-FETCH ok ref=\(ref.prefix(10)) bytes=\(data.count) via=relay")
                        MediaStore.shared.store(ref, data); autoSaveReceived(ref); scheduleRefresh()
                    // A relay REFUSED us rather than lacking the blob: publish our device roster to it
                    // and try once more. Without this the fetch degrades to a peer ask that only works
                    // while the author happens to be online — which is exactly how media a few days old
                    // became permanently unreachable while fresh media (author still around) looked fine.
                    } else if await SharedStore.healForbiddenRelays(social: social),
                              let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                        HavenLog.relay("MEDIA-FETCH ok ref=\(ref.prefix(10)) bytes=\(data.count) via=relay (after roster publish)")
                        MediaStore.shared.store(ref, data); autoSaveReceived(ref); scheduleRefresh()
                    } else {
                        HavenLog.relay("MEDIA-FETCH miss ref=\(ref.prefix(10)) — relay had none, asking peers")
                        directAsk()   // relay didn't have it (or unreachable) → ask a peer
                    }
                }
            } else {
                HavenLog.relay("MEDIA-FETCH ref=\(ref.prefix(10)) no-mailbox → peer-only")
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
            if servingNow.contains("\(ref)|\(requesterHex)") {
                HavenLog.net("media REQ ref=\(ref.prefix(12)) — already streaming to \(requesterHex.prefix(8)), ignoring")
            } else if shouldServeNearby(ref) {
                sendMediaChunks(ref: ref, fileURL: url, to: requesterHex)
            }
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

    /// Frame 33 — a RESUME request: `[requesterHex 64][u16 refLen][ref][u32 total][bitmap]`.
    ///
    /// Frame 3 is deliberately left exactly as it was for a first request — the ref is its unlengthed
    /// remainder, so there is nowhere to put a resume hint without breaking every existing parser, and
    /// a first request has no bitmap to send anyway. This is the re-request that carries one, so the
    /// serve can skip everything the requester already holds. An un-upgraded peer simply ignores it
    /// and the requester falls back to frame 3, so nothing regresses.
    ///
    /// Carries strictly LESS authority than frame 3 (it asks for a subset of the same bytes), so it
    /// gets frame 3's treatment — plaintext with the blocked-sender check — rather than the sealed
    /// call-frame path. Sealing it would buy nothing while making it fail wherever its own fallback
    /// still works.
    private func handleMediaResumeRequest(_ payload: Data) {
        guard let (requesterHex, ref, claimed, bitmap) = ReassemblyStore.decodeResume(payload) else { return }
        guard let url = MediaStore.shared.storagePath(for: ref),
              FileManager.default.fileExists(atPath: url.path) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let total = max(1, (size + Self.mediaChunkSize - 1) / Self.mediaChunkSize)
        // A total that disagrees with ours means their partial was built against different bytes —
        // their bitmap indexes something else, so honouring it would leave permanent holes. Send the
        // whole file and let the content-address check at adopt() sort out which copy is real.
        // This check is also what bounds the expansion below: the bitmap only becomes a set of indices
        // once its size is pinned to a file WE hold, never to a total the peer picked.
        let missing = Set(0..<total).subtracting(total == claimed ? ReassemblyStore.indices(bitmap, total: total) : [])
        guard !missing.isEmpty else { return }   // they have it all; the last chunk is presumably in flight
        HavenLog.net("media RESUME ref=\(ref.prefix(12)) from=\(requesterHex.prefix(8)): \(missing.count)/\(total) chunks still needed")
        if servingNow.contains("\(ref)|\(requesterHex)") {
            HavenLog.net("media RESUME ref=\(ref.prefix(12)) — already streaming to \(requesterHex.prefix(8)), ignoring")
        } else if shouldServeNearby(ref) {
            sendMediaChunks(ref: ref, fileURL: url, to: requesterHex, missing: missing)
        }
    }

    /// Rebuild in-memory reassembly state from disk at launch, so a transfer that was 99% done when
    /// the app died continues instead of starting over.
    @MainActor private func restoreReassemblies() {
        for r in ReassemblyStore.shared.restore() {
            let url = MediaStore.storageDir.appendingPathComponent(r.part)
            // Already adopted while we were away (relay restore, another device) — drop the scratch.
            guard !MediaStore.shared.has(r.ref) else {
                try? FileManager.default.removeItem(at: url)
                ReassemblyStore.shared.clear(r.ref)
                continue
            }
            let got = ReassemblyStore.indices(r.got, total: r.total)
            incoming[r.ref] = IncomingMedia(tempURL: url, total: r.total, got: got)
            HavenLog.net("media RESUME restored ref=\(r.ref.prefix(12)): \(got.count)/\(r.total) chunks already on disk")
        }
    }

    /// The ask for a ref we hold a partial of: frame 33 with our bitmap, else the plain frame 3.
    ///
    /// Returns nil when there's nothing to resume, so callers keep their existing frame-3 path
    /// byte-for-byte — the common case stays compatible with every peer in the field.
    @MainActor private func resumeAsk(ref: String, myHex: String) -> Data? {
        guard let entry = incoming[ref], !entry.got.isEmpty, entry.total > 0 else { return nil }
        return ReassemblyStore.encodeResume(myHex: myHex, ref: ref, total: entry.total, got: entry.got)
    }

    /// Refs with a resume ask outstanding, so a burst of requests can't spawn a fallback task each.
    private var resumeFallbackPending: Set<String> = []

    /// Ask for the missing chunks, falling back to a full frame-3 request if nothing comes back.
    ///
    /// An un-upgraded peer drops frame 33 on the floor and says nothing, so silence is the only signal
    /// we get. One bounded task per ref (never more — a peer re-requesting can't pile these up), and
    /// it does nothing at all if chunks did start arriving.
    @MainActor private func askForMedia(ref: String, myHex: String, plain: Data) {
        guard let resume = resumeAsk(ref: ref, myHex: myHex) else {
            nearbyBroadcast(3, plain)
            for contact in ContactsStore.shared.contacts { sendIroh(3, plain, to: contact.idHex) }
            return
        }
        nearbyBroadcast(33, resume)
        for contact in ContactsStore.shared.contacts { sendIroh(33, resume, to: contact.idHex) }
        guard resumeFallbackPending.insert(ref).inserted else { return }
        let before = incoming[ref]?.got.count ?? 0
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self else { return }
            self.resumeFallbackPending.remove(ref)
            guard !MediaStore.shared.has(ref), (self.incoming[ref]?.got.count ?? 0) == before else { return }
            HavenLog.net("media RESUME ref=\(ref.prefix(12)): no answer to frame 33 — falling back to a full request")
            self.nearbyBroadcast(3, plain)
            for contact in ContactsStore.shared.contacts { self.sendIroh(3, plain, to: contact.idHex) }
        }
    }

    /// Serves currently streaming, keyed `ref|requester`.
    ///
    /// A serve is SLOW by construction — 32 KB chunks, a KEM seal each, 12 ms apart — so a 50 MB
    /// video takes ~19s and a 200 MB one over a minute. The requester re-asks every ~30s while it
    /// waits, and the 25s throttle below would happily let that second request start ANOTHER full
    /// serve of the same file. Three or four of those pile up, compete on the main actor, and none
    /// of them ever finishes — so the media never arrives and the requester asks again, forever.
    /// (Field evidence: one video re-requested 16 times in 20 minutes.)
    ///
    /// One serve per ref per requester at a time. A re-request during a transfer is exactly the
    /// case where doing nothing is right — the bytes are already on their way.
    private var servingNow: Set<String> = []
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
    ///
    /// `missing` (from a resume request, frame 33) restricts the stream to the chunks the requester
    /// says it still needs. Skipping is free — no seal, no send, no pacing sleep — so a transfer that
    /// died on its last chunk costs one chunk to finish rather than the whole file again. `nil` sends
    /// everything, which is what a first request (frame 3) always means.
    private func sendMediaChunks(ref: String, fileURL url: URL, to requesterHex: String, missing: Set<Int>? = nil) {
        guard let social, let handle = try? FileHandle(forReadingFrom: url) else { return }
        // Marked for the whole stream and cleared when it ends (however it ends) — see `servingNow`.
        let serveKey = "\(ref)|\(requesterHex)"
        servingNow.insert(serveKey)
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
            // NearbyTransport is not Sendable; broadcast/backlog APIs are used from this exclusive
            // utility queue only for the duration of the serve (same process, serialized by us).
            nonisolated(unsafe) let mesh = nearby
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    try? handle.close()
                    Task { @MainActor in self?.servingNow.remove(serveKey) }
                }
                for index in 0..<total {
                    if let missing, !missing.contains(index) { continue }   // requester already has it
                    try? handle.seek(toOffset: UInt64(index) * UInt64(chunkSize))
                    let chunk = handle.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    guard let sealed = try? AES.GCM.seal(chunk, using: ownKey).combined else { break }
                    let frame = Self.chunkFrame(refData: refData, index: index, total: total, sealed: sealed)
                    mesh?.broadcast(Data([5]) + frame)
                    Thread.sleep(forTimeInterval: 0.030)   // pace so we don't outrun a slow link → unbounded send backlog
                    // Stop early if the send backlog is already high — the rest re-pushes next tick.
                    if (mesh?.sendBacklogHigh ?? false) { break }
                }
            }
            return
        }
        // FRIEND path: per-recipient KEM seal needs the engine, so keep it on the main actor (rare +
        // reachability-gated, so it isn't the lag source).
        Task { @MainActor in
            defer {
                try? handle.close()
                self.servingNow.remove(serveKey)
            }
            for index in 0..<total {
                if let missing, !missing.contains(index) { continue }   // requester already has it
                try? handle.seek(toOffset: UInt64(index) * UInt64(chunkSize))
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                // A failed seal abandons the transfer MID-FILE, leaving the requester with a partial
                // set it can never complete — say so rather than stopping silently. (With resume, that
                // partial is no longer a dead end: the requester re-asks for exactly what's missing.)
                guard let sealed = try? social.sealMedia(recipientNodeHex: requesterHex, data: chunk) else {
                    HavenLog.net("media serve ref=\(ref.prefix(12)) → \(requesterHex.prefix(8)): seal FAILED at chunk \(index); transfer abandoned")
                    break
                }
                let out = Data([5]) + Self.chunkFrame(refData: refData, index: index, total: total, sealed: sealed)
                nearby?.broadcast(out)
                if let node { Task.detached { try? await node.sendToNode(nodeIdHex: requesterHex, payload: out) } }
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
        }
    }

    /// Pure frame layout — `nonisolated` so media serve can build frames off the main actor.
    nonisolated private static func chunkFrame(refData: Data, index: Int, total: Int, sealed: Data) -> Data {
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
        guard social != nil, payload.count >= 2 else { return }
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
        // A chunk whose total disagrees with the partial we're building means the sender is streaming
        // DIFFERENT bytes than the ones already on disk (a re-encode, or a resumed transfer against a
        // changed file). Mixing the two would interleave two files at the same offsets and only surface
        // as a digest mismatch after the whole thing finished — throw the stale partial away and start
        // this one clean. Matters more now that partials outlive the app and can be days old.
        if let prior = incoming[ref], prior.total != total {
            HavenLog.net("media ref=\(ref.prefix(12)): chunk total \(total) != partial's \(prior.total) — discarding the stale partial")
            try? FileManager.default.removeItem(at: prior.tempURL)
            ReassemblyStore.shared.clear(ref)
            incoming[ref] = nil
        }
        let fresh = incoming[ref] == nil
        let entry = incoming[ref] ?? IncomingMedia(tempURL: MediaStore.shared.makeTempFile(), total: total, got: [])
        incoming[ref] = entry
        let tempURL = entry.tempURL
        // Register the reassembly the moment it starts, so even a transfer interrupted seconds in has
        // a durable home to resume into (and so the launch sweep knows to spare its partial).
        if fresh {
            ReassemblyStore.shared.note(ref: ref, part: tempURL.lastPathComponent,
                                        total: entry.total, got: entry.got, force: true)
        }
        let chunkSize = Self.mediaChunkSize
        let ownKey = Self.ownMediaKey()
        // Receive backpressure: if the decrypt+write queue is already backed up, DROP this chunk — the
        // reassembly stays incomplete and it's re-requested / re-sent. Prevents an unbounded queue → jetsam.
        if Self.mediaBacklogWouldDrop(adding: sealed.count, cap: Self.mediaBacklogCap) { return }
        Self.mediaQueue.async { [weak self] in
            defer { Self.adjustMediaBacklog(-sealed.count) }
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

    /// Thread-safe backlog accounting for the reassembly queue (not MainActor — called from
    /// `mediaQueue` and the main actor receive path).
    nonisolated private static func adjustMediaBacklog(_ delta: Int) {
        mediaBacklogLock.lock(); mediaBacklogBytes += delta; mediaBacklogLock.unlock()
    }
    nonisolated private static func mediaBacklogWouldDrop(adding n: Int, cap: Int) -> Bool {
        mediaBacklogLock.lock(); defer { mediaBacklogLock.unlock() }
        if mediaBacklogBytes > cap { return true }
        mediaBacklogBytes += n
        return false
    }
    // Backpressure for the receive queue: chunks arriving faster than they're decrypted+written piled up
    // here and ballooned memory to multi-GB → jetsam. Drop incoming chunks past this cap (re-requested).
    nonisolated private static let mediaBacklogLock = NSLock()
    nonisolated(unsafe) private static var mediaBacklogBytes = 0
    nonisolated private static let mediaBacklogCap = 8 * 1024 * 1024

    /// Bookkeeping after a chunk's plaintext is written to the temp file (main-actor state).
    @MainActor private func finishChunk(ref: String, index: Int) {
        guard var entry = incoming[ref] else { return }
        entry.got.insert(index)
        incoming[ref] = entry
        guard entry.got.count >= entry.total else {
            // Checkpoint the progress (debounced inside the store) so an interruption resumes here
            // rather than at chunk 0. Recorded only AFTER the bytes are on disk — see ReassemblyStore.
            ReassemblyStore.shared.note(ref: ref, part: entry.tempURL.lastPathComponent,
                                        total: entry.total, got: entry.got)
            return
        }
        // Whether adopt succeeds or rejects the bytes on a digest mismatch, this reassembly is over:
        // on rejection it has already discarded the temp file, so leaving the record behind would
        // resurrect a bitmap whose bytes are gone and stall the ref forever.
        MediaStore.shared.adopt(ref, from: entry.tempURL)
        ReassemblyStore.shared.clear(ref)
        SyncMetrics.shared.nbMediaIn += 1
        autoSaveReceived(ref)
        incoming[ref] = nil
        scheduleRefresh()   // re-render so the media appears (coalesced — many chunks complete in bursts)
        // DURABILITY: this blob just arrived peer-to-peer, which means the relay didn't have it (or we'd
        // have restored it from there). Re-mirror it to the circle's relay so it survives the author going
        // offline or the relay evicting the author's copy — any online member repopulates it. Sealing uses
        // the circle we requested it for. The backup ledger + probe make redundant re-mirrors a cheap no-op.
        if let social {
            let circle = mediaReqCircle[ref] ?? activeCircleId
            mediaReqCircle[ref] = nil
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
            // D8: a seedless device can't MINT its own account-signed profile card (no account key), so it
            // caches the primary's signed card — carried on this self-hello — and rebroadcasts it verbatim.
            if SeedlessState.isEnabled, !profileBlob.isEmpty { social.setCachedProfile(blob: profileBlob) }
            if let slot = SelfSyncCoordinator.shared.sealedLocalSlot(social: social) { nearbyBroadcast(23, slot) }
            return
        }
        // A hello carrying a DEVICE bundle of an account we ALREADY know is not a new person. A linked
        // (seedless) device signs with its own key and carries its own bundle, so without this it lands
        // as a SECOND contact for someone we're already connected to: a connection request from an
        // identity we're already connected to, which — once accepted — shows as "Someone" and is never
        // online, because a contact record built from a device id names no account to route to.
        //
        // The device→account mapping comes from their ACCOUNT-SIGNED roster (`verify_devroster`), so a
        // stranger cannot claim to be somebody's device; an unknown device id maps to nothing and still
        // takes the normal approval path below.
        if let account = social.accountForDevice(deviceHex: idHex)?.lowercased(),
           account != idHex.lowercased() {
            recordDeviceHints(accountHex: account, deviceIds: [idHex])
            HavenLog.sync("hello from \(idHex.prefix(8)) is a DEVICE of known account \(account.prefix(8)) — recorded as their device, not a new contact")
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
        // A circle/DM the user DELETED must not be re-created by a bare handshake (LWW) — respect the
        // deletion. The user re-opens it explicitly (startDM/createCircle) if they want it back.
        if circleId != "default", CircleDeletionStore.isDeleted(circleId) { return }
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

    /// `senderDevice` = the authenticated transport id this frame arrived from (nil for nearby /
    /// relay-unwrapped frames), used to tell a CONTACT's delivery apart from one of my own devices'.
    private func handleEvent(_ payload: Data, senderDevice: String? = nil, viaNearby: Bool = false) {
        guard let social else { return }
        // [LP circleId][sealed envelope]
        var off = 0
        guard let circleIdData = lpRead(payload, &off) else { return }
        let circleId = String(data: circleIdData, encoding: .utf8) ?? ""
        let envelope = payload.subdata(in: (payload.startIndex + off)..<payload.endIndex)
        guard !circleId.isEmpty, !envelope.isEmpty else { return }
        // Did this come from one of MY devices? Those already have it, and re-sharing it back is how
        // a fan-out becomes a loop. Nearby frames are broadcast to every device in range already.
        let mine = Set(social.deviceNodeIdsFor(accountHex: social.myNodeHex()).map { $0.lowercased() })
            .union([social.myNodeHex().lowercased()])
        let fromOwnDevice = viaNearby || (senderDevice.map { mine.contains($0.lowercased()) } ?? false)
        // receive() verifies + decrypts — real CPU per frame, and event frames arrive in BURSTS
        // during a sync. Do the crypto off-main; hop back only for the (already-coalesced) applies.
        Task.detached(priority: .utility) { [weak self] in
            guard (try? social.receive(circleId: circleId, envelope: envelope)) == true else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // FAN OUT to my other devices. A sender dials the device ids its copy of my roster
                // resolves — often just one — so a DM delivered straight to my Mac never reached my
                // iPhone, which was left waiting on a mailbox poll (and got nothing at all if the
                // relay refused it). The send path has always done this for my OWN posts via
                // liveDeliverToMyDevices; the receive path did not, so anything a CONTACT sent
                // stopped at whichever device they happened to reach.
                //
                // Cannot loop: `receive` returns true only for a genuinely NEW event, so a sibling
                // that already holds it stops here — and a frame that came FROM one of my devices is
                // never re-shared at all.
                if !fromOwnDevice { self.liveDeliverToMyDevices(1, payload) }
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

    /// True while a contact-roster pull pass is running. Without it the 20s sync tick spawned a fresh
    /// pass every time regardless of whether the previous one had finished — and each pass makes
    /// network calls with 60s timeouts, so they overlapped and accumulated without bound.
    private var rosterPullInFlight = false

    /// Media re-uploads someone else asked for: what's in flight, and when each ref was last served.
    /// Both bound an operation a PEER triggers — without them a circle member can spend my upload
    /// bandwidth at will, and concurrent asks for one ref each start their own upload.
    private var mediaWantedInFlight: Set<String> = []
    private var mediaWantedServedAt: [String: Date] = [:]

    /// The newest inbound item already counted toward each circle's badge.
    ///
    /// Without this the badge only ever climbed. `bumpUnseen` runs on ANY change in a circle — a
    /// history backfill, an epoch-rotation re-seal, a reaction to an old post, a re-sync of a message
    /// already shown — and it incremented every time as long as the newest inbound item happened to
    /// be less than five minutes old. So ONE recent post could raise the badge indefinitely while
    /// nothing new had actually arrived. `notifyNewest` right below already dedupes by item id for
    /// precisely this reason; the badge never did.
    ///
    /// Deliberately NOT cleared by `markCircleSeen`: after you've read the circle, a later re-sync of
    /// that same message must not be counted as new again.
    private var lastCountedUnseen: [String: String] = [:]

    /// Count a fresh inbound item as "unseen" for the badge (ignores historical back-fill).
    private func bumpUnseen(_ circleId: String) {
        if circleId.hasPrefix("dm:") { recomputeUnreadDMs(); return }   // DMs: watermark-based, always exact
        let inbound = messages(in: circleId).filter { !$0.isMe && !$0.unsent }
        guard let newest = inbound.max(by: { $0.createdAt < $1.createdAt }) else { return }
        guard now() &- newest.createdAt < 5 * 60 * 1000 else { return }   // recent only
        guard lastCountedUnseen[circleId] != newest.id else { return }    // already counted this one
        lastCountedUnseen[circleId] = newest.id
        if lastCountedUnseen.count > 500 { lastCountedUnseen.removeAll() }   // bound it
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
                    .havenGlass(in: Capsule())
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
            if store.hiddenInActiveCircle > 0 || HiddenStore.shared.showHidden {
                Button {
                    HiddenStore.shared.toggleShowHidden(); store.refresh()
                } label: {
                    Label(HiddenStore.shared.showHidden ? "Hide hidden posts" : "Show hidden posts (\(store.hiddenInActiveCircle))",
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
        #if os(macOS)
        .menuStyle(.borderlessButton)   // else macOS wraps the title+chevron in a popup-button bezel
        .fixedSize()
        #endif
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
                        CircleUpgradeBanner(circleId: store.activeCircleId)
                        RelayNudgeBanner(circleId: store.activeCircleId)
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
                    let target = PlatformScreen.contentCenterY
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
                #if os(macOS)
                CircleView(account: account)   // HavenMacSheet brings its own frame, gradient, and close
                #else
                NavigationStack { CircleView(account: account) }.macSheetClose()
                #endif
            }
            .sheet(isPresented: $showNewCircle) {
                #if os(macOS)
                NewCircleView { name, members in store.createCircle(name: name, memberIds: members) }
                #else
                NewCircleView { name, members in store.createCircle(name: name, memberIds: members) }.macSheetClose()
                #endif
            }
            .onAppear {
                store.configureForCurrentIdentity()   // seeded or seedless (S4) — never boot off a throwaway seed
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
                          allowedContentTypes: [.image, .movie, .item, .data, .archive, .folder],
                          allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                Task { @MainActor in
                    let refs = await MediaImport.importURLs(urls)
                    if !refs.isEmpty { attachedMedia.append(contentsOf: refs) }
                }
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
            .sheet(isPresented: $showRequests) { ConnectionRequestsView() }
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
        // The ring identifies WHOSE story it is → show the sharer's profile picture (mine, or the
        // friend's synced avatar), not the story media itself. Resolved the same way as avatars
        // everywhere else so it stays in sync.
        ZStack {
            Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64, height: 64)
            if s.isMe {
                HavenAvatar(image: ProfileStore.shared.avatar, emoji: ProfileStore.shared.emoji, size: 56)
            } else {
                PeerAvatar(nodeHex: s.authorShort,
                           name: ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? friendName, size: 56)
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
                MediaProcessingCard()   // spinner while a video encodes — see MediaProcessing
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
                        // ONE glass surface. A fixed-radius rounded rect (not havenPillField's Capsule):
                        // a Capsule's radius grows with height and clips into the text once the field
                        // wraps to multiple lines.
                        .havenGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

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
            // NO band behind the composer: a material slab here read as a detached grey bar pasted
            // under the gradient. The field / + / send each carry their own surface and float over
            // the backdrop instead. contentShape keeps the whole bar a drop target without one.
            .contentShape(Rectangle())
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
                        let bundle = await MediaStore.shared.prepareVideo(url: tmp)
                        // prepareVideo returns empty mediaRefs when it REFUSES the clip (over the
                        // 15-minute limit). Appending nothing is correct — never attach an empty ref.
                        guard !bundle.isEmpty else { return }
                        attachedMedia.append(contentsOf: bundle.mediaRefs)
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

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Hide synthetic markers and original companions from the tray — they ride with
                // the playable ref and would just look like duplicate chips.
                ForEach(MediaVariants.displayRefs(attachedMedia), id: \.self) { ref in
                    if let m = MediaStore.shared.item(ref), let img = MediaStore.shared.thumbnail(ref, maxDimension: 160) {
                        ZStack(alignment: .topTrailing) {
                            Image(platformImage: img).resizable().scaledToFill()
                                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .bottomLeading) {
                                    if m.kind == .video { videoEditMenu(ref) }
                                }
                            removeChip {
                                // Drop the playable AND any poster/original companions tied to it.
                                attachedMedia.removeAll { r in
                                    if r == ref { return true }
                                    if let p = MediaVariants.parsePoster(r), p.video == ref || p.poster == ref { return true }
                                    if let o = MediaVariants.parseOriginal(r), o.optimized == ref || o.original == ref { return true }
                                    if MediaVariants.poster(for: ref, in: attachedMedia) == r { return true }
                                    if MediaVariants.original(for: ref, in: attachedMedia) == r { return true }
                                    return false
                                }
                            }
                        }
                    } else if MediaKind(ref: ref) == .file {
                        ZStack(alignment: .topTrailing) {
                            RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill))
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Image(systemName: "doc.zipper").font(.title3).foregroundStyle(.secondary)
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
                            .buttonStyle(.plain).foregroundStyle(.secondary)
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
                            .buttonStyle(.plain).foregroundStyle(.secondary)
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
        .buttonStyle(.plain)   // the glyph IS the circle — no macOS bezel behind it
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
                .padding(4).havenGlass(in: Circle())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)   // just the glass circle — no popup-button bezel behind it
        .fixedSize()
        #endif
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

/// The feed column's content width, remembered across cards. Every PostCard in a feed lays out at the
/// SAME width, but each one is created as it scrolls into view with its own `@State` starting at zero —
/// and a zero width made `pageHeight` fall back to `singleMediaMaxHeight`, so the card first rendered at
/// full height and then snapped to its real aspect the instant the width preference landed. That resize,
/// once per card, is what made the feed jump up and down during a scroll (for photos as much as videos).
/// Seeding a new card from the last measured width lets it compute the correct height on its FIRST pass.
/// Written and read only from SwiftUI layout on the main thread.
nonisolated(unsafe) private var lastKnownMediaWidth: CGFloat = 0

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
    /// Observed so "Keep on this device" visibly changes state. Reading the store WITHOUT observing
    /// it meant the pin was recorded but nothing on screen moved — the menu closed and the post
    /// looked identical, so a working toggle read as a dead button.
    @ObservedObject private var pinned = PinnedMediaStore.shared
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
    @State private var linkCopied = false
    /// Set when the backup indicator is tapped — "which relays actually hold this?"
    @State private var showBackupDetail = false
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
    /// The card's content width, measured. The media page spans it EDGE TO EDGE: sizing the page to the
    /// media's own aspect (the old `.aspectRatio(_, .fit)`) parked a tall clip in a narrow centre column
    /// with the card's grey either side on any wide window — the page must own the width, and the media
    /// letterboxes INSIDE it against its own blurred copy.
    @State private var mediaWidth: CGFloat = lastKnownMediaWidth
    @State private var showHeart = false
    @State private var showReactionDetail = false
    /// A "share this post as a story" composer session (nil = not sharing).
    @State private var storyShare: StoryShareTarget?

    private var isActive: Bool { audio.centeredPostId == item.id }

    /// The post's real media, minus synthetic refs (a `geo:` location pin has no bytes). A story needs
    /// something to show, so this is what gates the "Share as story" action.
    private var storyableMedia: [String] { realMedia.filter { !MediaStore.isSynthetic($0) } }

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
    /// Kind from the REF (a cheap string parse — refs encode img_/vid_/aud_), never `item(ref)`. `item(_:)`
    /// decodes the bitmap / generates the video poster on the main thread on a cache miss, and this is
    /// called per media ref all over layout and scrolling (mediaView, isSingleVideoPost, primaryVideoPlayer,
    /// playVisibleVideo). On a carousel or photo-grid post that was several decodes per layout pass — the
    /// same trap the masonry tile already documents.
    private func isVideo(_ ref: String) -> Bool { MediaKind(ref: ref) == .video }

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
            audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo, immediateMusic: true)
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
        .sheet(isPresented: $showEdit) { EditPostSheet(item: item) }
        .sheet(isPresented: $showReport) { ReportSheet(item: item, authorName: authorName) }
        .havenFullScreenCover(item: $zoomTarget, wide: true) { t in MediaZoomViewer(refs: t.refs, index: t.index) }
        // Share-as-story runs through the SAME composer as a camera story (filters, caption styling,
        // music, reframing) — the only difference is that the published body carries the source post's
        // ref, so the story deep-links back to it.
        .havenFullScreenCover(item: $storyShare) { target in
            StoryComposerView(draft: target.draft) { ref, caption, track in
                Task { @MainActor in
                    // A long video becomes up to 5 consecutive slides, as everywhere else. Every slide
                    // carries the embed, so the link back works whichever one you're looking at.
                    let parts = await MediaStore.shared.splitStoryVideo(ref)
                    for r in parts {
                        feed.postStory(media: [r],
                                       caption: StoryEmbed.encode(target.embed, caption: caption),
                                       music: track)
                    }
                    storyShare = nil
                }
            } onDone: { storyShare = nil }
        }
        .alert("Edit comment", isPresented: Binding(get: { editCommentId != nil }, set: { if !$0 { editCommentId = nil } })) {
            TextField("Comment", text: $editCommentText)
            Button("Save") { if let id = editCommentId { feed.edit(id, editCommentText, media: editCommentMedia) }; editCommentId = nil }
            Button("Cancel", role: .cancel) { editCommentId = nil }
        }
    }

    /// A shared location is encoded as a synthetic `geo:` ref inside `media` (index 0). It is NOT real
    /// media, so it must be drawn as a map and kept OUT of the photo grid / zoom viewer — otherwise it
    /// degrades to a forever-spinner tile (MediaStore has no file for it).
    /// Media slides the card actually renders. Drops location pins, synthetic markers, and
    /// original companions (those only surface via "Show original").
    private var realMedia: [String] {
        MediaVariants.displayRefs(item.media).filter { SharedLocation.parse($0) == nil }
    }

    /// A full-width media page's height: as tall as the media needs, capped. A page WIDER than the media's
    /// own shape is the point — the exposed strip either side is where the blurred backdrop shows.
    private func pageHeight(_ aspect: CGFloat) -> CGFloat {
        guard mediaWidth > 0 else { return singleMediaMaxHeight }
        return min(singleMediaMaxHeight, mediaWidth / aspect)
    }

    /// The page's ACTUAL aspect once it spans the card — what the letterbox test must compare against.
    private func pageAspect(_ aspect: CGFloat) -> CGFloat {
        guard mediaWidth > 0 else { return aspect }
        return mediaWidth / pageHeight(aspect)
    }

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
                    // containerAspect == the media's own aspect ⇒ the inner per-page gate stays off; the
                    // outer backdrop below covers the whole page, so we don't blur the same thing twice.
                    mediaPage(ref, containerAspect: singleAspect(ref))
                    if video { muteButton(ref) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: pageHeight(singleAspect(ref)))
                .background { blurredBackdrop(ref) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                // Tap-to-zoom only for images. For a video, the player owns the single tap
                // (mute) / hold (pause) / drag (scrub); a zoom tap here would swallow them.
                .modifier(ConditionalTap(enabled: !video) { zoomTarget = ZoomTarget(refs: media, index: 0) })
            } else if (2...10).contains(media.count) {
                // Mixed aspects no longer force the grid — each page fits inside a shared shape and
                // its own blurred backdrop masks the difference, which beats a 2-photo masonry.
                // (A location-only post has NO real media: it must fall through to nothing.)
                mediaCarousel(media)
            } else if !media.isEmpty {
                masonry   // a big set → the staggered grid; tap any to zoom
            }
        }
        // Measure the card's content width — pageHeight/pageAspect need it to span the card. maxWidth
        // resolves from the PARENT's proposal, so reading it back here can't feed itself.
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear.preference(key: MediaWidthKey.self, value: g.size.width)
        })
        .onPreferenceChange(MediaWidthKey.self) { w in
            // Remember it for the NEXT card to be created, so it never has to lay out at zero width first.
            if w > 0 { mediaWidth = w; lastKnownMediaWidth = w }
        }
    }

    /// True when a media set all share (near-)equal aspect ratios — such a set keeps its exact shape
    /// in the carousel (no backdrop needed, since nothing letterboxes).
    private func allSameAspect(_ media: [String]) -> Bool {
        guard let a0 = media.first.map(singleAspect) else { return false }
        return media.allSatisfy { abs(singleAspect($0) - a0) < 0.06 }
    }

    /// The carousel's page shape. A uniform set keeps its exact aspect; a MIXED set takes the TALLEST
    /// item's, so no page is ever cropped — clamped so one 9:16 clip can't squeeze the whole card into
    /// a narrow column (the remaining pages letterbox against their own blurred backdrop instead).
    private func carouselAspect(_ media: [String]) -> CGFloat {
        guard let tallest = media.map(singleAspect).min() else { return 4.0 / 3.0 }
        if allSameAspect(media) { return tallest }
        return min(1.91, max(0.8, tallest))
    }

    /// A full-width swipeable pager. The visible page's video autoplays as you swipe
    /// (playVisibleVideo keys off `currentPage`), matching the single-media behavior.
    @ViewBuilder private func mediaCarousel(_ media: [String]) -> some View {
        let aspect = carouselAspect(media)
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
                        mediaPage(ref, containerAspect: pageAspect(aspect), inCarousel: true,
                                  onScrubbing: { carouselScrubbing = $0 })
                        if isVideo(ref) { muteButton(ref) }
                    }
                    .containerRelativeFrame(.horizontal)   // each page == the carousel's width
                    .modifier(ConditionalTap(enabled: !isVideo(ref)) { zoomTarget = ZoomTarget(refs: media, index: i) })
                    .id(i)
                }
            }
            .scrollTargetLayout()
            #if os(macOS)
            .background(KillHorizontalScroller().frame(width: 0, height: 0))
            #endif
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding<Int?>(get: { currentPage }, set: { currentPage = $0 ?? currentPage }))
        // .never, not .hidden: on macOS .hidden still leaves AppKit's legacy scroller drawing a bar
        // across the bottom of the carousel.
        .scrollIndicators(.never)
        // Pages are containerRelativeFrame'd to this ScrollView — clip to it so a neighbouring page's
        // backdrop can't bleed past the edge mid-swipe.
        .clipped()
        .scrollDisabled(carouselScrubbing)   // while scrubbing a video, don't let a swipe page the carousel
        #if os(macOS)
        // macOS: a horizontal ScrollView only pages on a trackpad two-finger swipe — a plain MOUSE has no
        // horizontal scroll, so a click-drag paging gesture is the mouse equivalent. Simultaneous + onEnded
        // + thresholds so it never steals a tap-to-zoom, a vertical scroll, or a video scrub.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard !carouselScrubbing,
                          abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 40 else { return }
                    if value.translation.width < 0, currentPage < media.count - 1 {
                        withAnimation(.easeOut(duration: 0.22)) { currentPage += 1 }
                    } else if value.translation.width > 0, currentPage > 0 {
                        withAnimation(.easeOut(duration: 0.22)) { currentPage -= 1 }
                    }
                }
        )
        #endif
        // Full-width pages (NOT .aspectRatio(_, .fit), which shrank the whole carousel to a centre column
        // on a wide window) — each page letterboxes inside against its own blurred backdrop.
        .frame(maxWidth: .infinity)
        .frame(height: pageHeight(aspect))
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
        // Use MediaKind(ref:) (a cheap string parse) for the play badge — NOT item(ref), which would
        // generate the video poster on the main thread as each tile scrolls into view (the scroll lag).
        //
        // The tile's WIDTH comes from the persisted pixel size (a dictionary lookup, no decode) and the
        // bitmap decodes off-main via FeedImage. This used to call the synchronous thumbnail(_:), which
        // decoded EVERY tile on the main thread in a single layout pass — on a 10+ photo post that was
        // the scroll jitter. The evicted/not-yet-downloaded cases are checked first so the common path
        // never has to decode anything just to decide what to draw.
        if EvictedMediaStore.shared.contains(ref) {
            // Deliberately evicted — a compact tap-to-download tile (not an endless spinner).
            Button { FeedStore.shared.downloadEvicted(ref) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill))
                    Image(systemName: FeedStore.shared.downloadingMedia.contains(ref) ? "arrow.down.circle" : "arrow.down.circle.fill")
                        .font(.title2).foregroundStyle(HavenTheme.pink)
                }
                .frame(width: height * 1.2, height: height)
            }
            .buttonStyle(.plain)
        } else if MediaStore.shared.hasLocalFile(ref) {
            // Non-blocking aspect: a grid tile's aspect only sets its WIDTH inside a horizontal scroller,
            // so it can safely fill in late rather than stalling layout on a header read per tile.
            let known = MediaStore.shared.pixelSize(ref, allowSyncRead: false)
            let aspect = min(2.4, max(0.6, known.map { $0.width / max($0.height, 1) } ?? 4.0 / 3.0))
            FeedImage(ref: ref, maxDimension: height * 3, contentMode: .fill) {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12))
            }
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

    @ViewBuilder private func mediaPage(_ ref: String, containerAspect: CGFloat,
                                        inCarousel: Bool = false,
                                        onScrubbing: @escaping (Bool) -> Void = { _ in }) -> some View {
        if isVideo(ref) {
            // No contextMenu for videos — the long-press is reserved for the player's
            // hold-to-pause. Save/Share live in the mute control's menu instead.
            mediaPageContent(ref, containerAspect: containerAspect, inCarousel: inCarousel, onScrubbing: onScrubbing)
        } else {
            mediaPageContent(ref, containerAspect: containerAspect)
                .contextMenu {
                    Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    if let url = shareURL(ref) {
                        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                    }
                    keepOnDeviceButton(ref)
                }
        }
    }

    /// The on-disk file to hand to the system share sheet (video file, else the image).
    private func shareURL(_ ref: String) -> URL? {
        guard let m = MediaStore.shared.item(ref) else { return nil }
        return m.kind == .video ? m.videoURL : MediaStore.shared.storagePath(for: ref)
    }

    @ViewBuilder private func mediaPageContent(_ ref: String, containerAspect: CGFloat,
                                               inCarousel: Bool = false,
                                               onScrubbing: @escaping (Bool) -> Void = { _ in }) -> some View {
        // Decide from the REF + a cheap file check, never `item(ref)`: that decodes the bitmap / generates
        // the video poster ON THE MAIN THREAD on a cache miss, and this runs for every page of every media
        // post — a 3-video carousel paid three decodes per layout pass, which is the carousel/grid jitter.
        let dataSaver = SettingsStore.shared.superDataSaver
        let hasVideo = MediaStore.shared.hasLocalFile(ref)
        // Super data saver + video not yet downloaded: show the poster still (if we have one) with a
        // play affordance. Tapping play requests the video bytes and only then builds an AVPlayer.
        if dataSaver, MediaKind(ref: ref) == .video, !hasVideo {
            let poster = MediaVariants.poster(for: ref, in: item.media)
            ZStack {
                if let poster, MediaStore.shared.hasLocalFile(poster) {
                    FeedImage(ref: poster, maxDimension: 1200, contentMode: .fit) { mediaLoadingPlaceholder(ref) }
                } else {
                    mediaLoadingPlaceholder(ref)
                }
                Image(systemName: "play.circle.fill").font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.92)).shadow(radius: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                // Explicit play → download the video (and only the video).
                feed.requestMedia(ref, circleId: feed.activeCircleId)
            }
            .background { pageBackdrop(poster ?? ref, containerAspect: containerAspect) }
        } else if hasVideo {
            if MediaKind(ref: ref) == .video, let url = MediaStore.shared.storagePath(for: ref) {
                // Data saver with local video: still don't autoplay — GestureVideoPlayer starts paused
                // when superDataSaver is on via playVisibleVideo; the user taps to start.
                let player = playerFor(ref, url)
                GestureVideoPlayer(player: player,
                                   onTap: { togglePostMute() },
                                   onDoubleTap: { heartIt() },
                                   inCarousel: inCarousel,
                                   onScrubbing: onScrubbing)
                    .background { pageBackdrop(ref, containerAspect: containerAspect) }
            } else if MediaKind(ref: ref) == .file {
                fileAttachmentPage(ref)
            } else {
                // Non-video → a ~1200px thumbnail (not the 2560px original) via the self-loading `FeedImage`:
                // it decodes OFF the main thread and swaps into only itself, so a fast flick never hitches on
                // a main-thread decode AND a finished decode never triggers a feed-wide refresh (the flash of
                // already-shown media + re-rasterized blurs). Zoom uses full-res. Shows the whole image (fit).
                FeedImage(ref: ref, maxDimension: 1200, contentMode: .fit) { mediaLoadingPlaceholder(ref) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { pageBackdrop(ref, containerAspect: containerAspect) }
            }
        } else {
            // Referenced but not here yet — it's still coming from the sender / mailbox.
            mediaLoadingPlaceholder(ref)
        }
    }

    /// A `file_` zip attachment: document chip with share/save affordance.
    @ViewBuilder private func fileAttachmentPage(_ ref: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.zipper").font(.system(size: 44)).foregroundStyle(HavenTheme.pink)
            Text("File attachment").font(.subheadline.weight(.semibold))
            if let url = MediaStore.shared.storagePath(for: ref) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                ShareLink(item: url) { Label("Share file", systemImage: "square.and.arrow.up") }
                    .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// True when this page's media can't fill a `containerAspect`-shaped page — it letterboxes, exposing
    /// the card's grey behind it. A video whose poster hasn't been generated yet has no known aspect
    /// (singleAspect falls back to 4:3), so assume it letterboxes: that's the tall-clip case exactly.
    private func letterboxes(_ ref: String, in containerAspect: CGFloat) -> Bool {
        guard let sz = MediaStore.shared.pixelSize(ref), sz.height > 0 else { return true }
        return abs(sz.width / sz.height - containerAspect) > 0.02
    }

    /// A blurred, cropped-to-fill copy of the media behind the fitted one — the letterboxed area reads as
    /// the media's own colors instead of the card's grey. A 64px thumbnail is all a heavy blur can show;
    /// for a video that thumbnail is its poster.
    ///
    /// The poster, NOT a second live layer: an AVPlayer only ever feeds ONE AVPlayerLayer, so hanging a
    /// second (fill-gravity) layer off the same player renders nothing — only the most recently associated
    /// layer draws. A blurred still is the honest trade: no second decode, and behind a 24pt blur the
    /// difference between a still and a moving copy isn't visible anyway.
    @ViewBuilder private func blurredBackdrop(_ ref: String) -> some View {
        BlurredMediaBackdrop(ref: ref)
    }

    /// The carousel's per-page backdrop: only pay for it when the page's media actually letterboxes
    /// inside the shared page shape. (Single media gates on the page frame instead — see `mediaView`.)
    @ViewBuilder private func pageBackdrop(_ ref: String, containerAspect: CGFloat) -> some View {
        if letterboxes(ref, in: containerAspect) { blurredBackdrop(ref) }
    }

    /// The measured width of a post's media column, so a page can span the card rather than shrink to the
/// media's own shape. `max` because the reducer sees one value per card.
private struct MediaWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The blurred backdrop itself — SELF-LOADING, which is the whole reason it's a view and not a
/// `@ViewBuilder` helper reading the thumbnail cache inline.
///
/// It used to be exactly that: a cache PEEK evaluated in `PostCard.body`. But nothing ever tells a
/// card that its thumbnail has since landed — `FeedImage` decodes off-main and swaps the bitmap into
/// JUST itself, deliberately WITHOUT nudging a feed refresh (that refresh is what used to flash
/// already-shown media and chop the scroll). So a card whose body ran before its thumbnail was
/// resident saw an empty cache, drew no backdrop, and was never re-evaluated to notice otherwise.
/// It stayed flat for the life of the card.
///
/// That is the "top posts have no blur behind them" report. The cards you scroll DOWN to are built
/// after their decode finishes, so they look right; the ones on screen at launch race it and lose.
/// On a tall Mac window those top cards are also never recycled, so they never got a second chance —
/// which is why it read as a macOS bug even though the race is the same everywhere.
///
/// Holding its own `@State` bitmap keeps the property that made the old design worth having: a
/// finished decode re-renders this one backdrop, never the feed. Loading is awaited via
/// `thumbnailAsync`, which decodes off the main thread (and generates a video's poster off-thread),
/// so the backdrop still never decodes on the scroll hot path.
private struct BlurredMediaBackdrop: View {
    let ref: String
    @State private var img: PlatformImage?
    /// Which ref `img` belongs to — a lazy cell reused for another post must not show the old blur.
    @State private var loadedRef: String?

    var body: some View {
        Group {
            if let img, loadedRef == ref {
                // GeometryReader (not `Color.clear.overlay { … .scaledToFill() }`) so the fill size is
                // COMPUTED and bounded — see `backdropFill`. `scaledToFill` let the layer size run away on a
                // narrow source, and a runaway layer is exactly what made the backdrop vanish.
                GeometryReader { g in
                    let fill = Self.backdropFill(source: img.size, container: g.size)
                    Image(platformImage: img)
                        .resizable()
                        .frame(width: fill.width, height: fill.height)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                        .blur(radius: 24, opaque: true)
                }
                .clipped()
                // Rasterize the blur ONCE instead of re-running it every scroll frame — a 24pt blur
                // re-composited per frame is what made scrolling past a post chop.
                .drawingGroup()
                .allowsHitTesting(false)
            }
        }
        .task(id: ref) {
            if let cached = Self.cachedSource(ref) { img = cached; loadedRef = ref; return }
            img = nil; loadedRef = nil
            // Awaited purely as the completion signal the peek never had. Deliberately the 1200px
            // bucket — the tile in FRONT of this backdrop decodes exactly that, so `thumbnailAsync`'s
            // single-flight makes this the same decode rather than a second one. (Asking for the 64px
            // thumb instead would be a separate cache bucket, i.e. real extra work, and for a video a
            // whole second poster generation.)
            _ = await MediaStore.shared.thumbnailAsync(ref, maxDimension: 1200)
            guard !Task.isCancelled else { return }
            img = Self.cachedSource(ref)
            loadedRef = ref
        }
    }

    /// The bitmap to blur. Falls back through sizes because the 64px thumb ALONE is not dependable: it
    /// lives in an NSCache that evicts under pressure (the backdrop would vanish from a post that had
    /// one a moment ago), and for a video it's nil until the poster finishes generating off-thread.
    /// The 1200px thumb is already resident — it's what the page itself draws — so the fallback is
    /// free in the case that matters. Blurring a bigger bitmap costs nothing extra once rasterized.
    ///
    /// Cache PEEK only — no decode happens here. The decode is awaited in `.task`, off the main thread.
    ///
    /// The 64px thumb is preferred ONLY while it still has pixels to blur. A narrow source collapses its
    /// minor axis at that size (a 40×1600 sliver thumbs to 2×64), and a 2px-wide bitmap carries no color
    /// detail a 24pt blur can show — it bands. The 1200px thumb is the page's own bitmap, already resident,
    /// and holds its shape at any aspect, so it's the better source precisely in the narrow case.
    private static func cachedSource(_ ref: String) -> PlatformImage? {
        if let small = MediaStore.shared.cachedThumbnail(ref, maxDimension: 64),
           min(small.size.width, small.size.height) >= 8 {
            return small
        }
        return MediaStore.shared.cachedThumbnail(ref, maxDimension: 1200)
            ?? MediaStore.shared.cachedThumbnail(ref, maxDimension: 64)
    }

    /// How far past the container a uniform crop-to-fill may spill before we stretch instead.
    private static let maxBackdropOverflow: CGFloat = 4

    /// The size to draw the backdrop bitmap at so it covers `container`.
    ///
    /// Normally that's a uniform crop-to-fill, exactly what `scaledToFill` did. The reason this is
    /// computed by hand is the NARROW case, where `scaledToFill` silently produced no backdrop at all:
    ///
    /// A 64px thumbnail caps the LARGER axis (ImageIO's `kCGImageSourceThumbnailMaxPixelSize`), so a
    /// narrow source comes back with its minor axis rounded down to a few pixels — a 40×1600 sliver
    /// becomes 2×64. Covering a card-sized page from a 2px-wide bitmap means magnifying it ~200×, and
    /// the filtered layer that produces runs to tens of thousands of points. Past the renderer's max
    /// texture size `.drawingGroup()` rasterizes to NOTHING — the post draws with no backdrop, which is
    /// the "too narrow → no blur" report. It's aspect-dependent, so it hit only some posts.
    ///
    /// So past `maxBackdropOverflow` we stretch to the container instead of cropping to it. Behind a
    /// 24pt blur a stretched copy is indistinguishable from a cropped one, and the layer is then exactly
    /// the container's size — it can never explode and never degenerate, for ANY aspect ratio.
    static func backdropFill(source: CGSize, container: CGSize) -> CGSize {
        // `> 0` also rejects NaN, which a zero-byte or malformed decode can hand back.
        guard source.width > 0, source.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = max(container.width / source.width, container.height / source.height)
        let filled = CGSize(width: source.width * scale, height: source.height * scale)
        // `scale` is the max of the two ratios, so one axis lands exactly on the container and the other
        // spills. This is that spill.
        let overflow = max(filled.width / container.width, filled.height / container.height)
        return overflow <= maxBackdropOverflow ? filled : container
    }
}

#if os(macOS)
/// Reaches the enclosing NSScrollView and turns its horizontal scroller off for good.
///
/// SwiftUI can't do this on macOS: with "Show scroll bars: Always" in System Settings, AppKit forces
/// LEGACY (non-overlay) scrollers and neither `showsIndicators: false` nor `.scrollIndicators(.never)`
/// suppresses them — a grey bar draws across the bottom of the carousel. The dots already say which
/// page you're on, so the scroller is pure noise.
private struct KillHorizontalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ v: NSView, context: Context) {
        // async: the view isn't in the hierarchy yet at make time, so there's no scroll view to find.
        DispatchQueue.main.async {
            var node: NSView? = v
            while let cur = node {
                if let sv = cur as? NSScrollView {
                    sv.hasHorizontalScroller = false
                    sv.horizontalScroller = nil
                    sv.scrollerStyle = .overlay
                    return
                }
                node = cur.superview
            }
        }
    }
}
#endif

/// Shown for a media reference whose bytes haven't arrived yet, so the post doesn't look
    /// broken while it's still downloading from the sender, a relay, or the shared mailbox.
    @ViewBuilder private func mediaLoadingPlaceholder(_ ref: String) -> some View {
        MissingMediaPlaceholder(ref: ref, isVideo: MediaKind(ref: ref) == .video,
                                postContext: (circleId: feed.activeCircleId, postId: item.id,
                                              authorShort: item.authorShort))
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

    /// The speaker chip over a video page — plus that page's Save/Share menu.
    @ViewBuilder private func muteButton(_ ref: String) -> some View {
        Button {
            if audio.activePostId != item.id { audio.start(postId: item.id, track: item.music, video: primaryVideoPlayer, muteVideo: item.muteVideo, immediateMusic: true) }
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
        // video itself no longer carries a contextMenu). It acts on THIS page's video — it used to
        // take item.media.first, which is the wrong item on any page but the first (and is the
        // synthetic geo: ref on a post that also pins a location).
        .contextMenu {
            Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
            if let url = shareURL(ref) {
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
            keepOnDeviceButton(ref)
        }
    }

    /// "Keep on this device" toggle — pins/unpins this ref in the device-local retention set so no
    /// cleanup (orphan sweep, age/size limit, or the cleanup screen) ever removes its bytes.
    @ViewBuilder private func keepOnDeviceButton(_ ref: String) -> some View {
        // Through the OBSERVED store, so toggling re-renders the card (and its pin badge) rather
        // than silently recording a pin nothing on screen reflects.
        let isPinned = pinned.isPinned(ref)
        Button { pinned.togglePin([ref]) } label: {
            Label(isPinned ? "Stop keeping on this device" : "Keep on this device",
                  systemImage: isPinned ? "pin.slash.fill" : "pin")
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
            // Super data saver: no autoplay of attached music either — only the poster still loads.
            let track = SettingsStore.shared.superDataSaver ? nil : item.music
            audio.start(postId: item.id, track: track, video: primaryVideoPlayer, muteVideo: item.muteVideo)
            if !SettingsStore.shared.superDataSaver {
                audio.ensureMusicPlaying()   // resume the song if a video had paused it
            }
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
        // Super data saver: never autoplay. The still (poster) is already on screen; the user
        // taps play when they want the bytes + the decode heat.
        if SettingsStore.shared.superDataSaver {
            for (_, player) in players { player.pause() }
            return
        }
        let visibleRef: String? = item.media.isEmpty
            ? nil
            : item.media[min(max(currentPage, 0), item.media.count - 1)]
        #if os(iOS)
        // A post's music plays on the system music player; without mixing, that music takes the audio
        // session and INTERRUPTS the video's AVPlayer, so the (muted) video just froze. Mix so the video
        // plays alongside the music. Safe when the video is unmuted too (it simply mixes its own audio).
        // NB: setCategory/setActive are synchronous and can block the main thread for tens of ms — doing
        // that every time a video scrolled to centre was the scroll "stick then continue". Configure the
        // session once, off the main thread, and skip entirely when it's already set up.
        if let visibleRef, isVideo(visibleRef) { ensureHavenPlaybackSession() }
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
            // Kept on THIS device. Without a mark on the card, "Keep on this device" recorded the pin
            // and showed nothing — the menu closed and the post looked identical, so a working toggle
            // read as a dead button. This is the state, visible where the decision applies.
            if item.media.contains(where: { !MediaStore.isSynthetic($0) && pinned.isPinned($0) }) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(HavenTheme.pink)
                    .accessibilityLabel("Kept on this device")
            }
            // Upload state for your OWN media posts, shown whenever the circle has a relay to back up to
            // (any relay — not just an S3 mailbox this device volunteers, which the old gate required and
            // so hid this for everyone on the default relay-HTTP path). Driven PER-MEDIA off the backup
            // ledger: ✓ once every blob in the post is confirmed on at least one relay, ↑ while it's still
            // uploading. This is the "did my story actually reach a relay?" signal — so the author knows to
            // keep Haven open a moment until it lands, instead of assuming it's broken and bailing.
            if item.isMe && !item.unsent, !item.media.isEmpty,
               !(RelayMailboxStore.shared.relays(forCircle: feed.activeCircleId).isEmpty) {
                // The whole cluster is one tap target: every state below is a partial answer to
                // "where is this?", and the sheet is the full one — including which relays hold
                // nothing, which no icon can express.
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    let blobs = item.media.filter { !MediaStore.isSynthetic($0) }
                    // "Backed up" must mean a relay SOMEONE ELSE can read. Writing to our own
                    // in-process relay is a local file copy that cannot fail, so counting it showed a
                    // confident tick on every post while friends could fetch none of them — the single
                    // biggest reason tonight's delivery failure stayed invisible for hours.
                    let ownRelay = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
                    let backed = !blobs.isEmpty && blobs.allSatisfy {
                        MediaBackupLedger.hasAnyRemote($0, ownRelayHex: ownRelay)
                    }
                    // Reached OUR relay and nowhere else: not an error, not safe either. Says so.
                    let localOnly = !backed && !blobs.isEmpty && blobs.allSatisfy { MediaBackupLedger.hasAny($0) }
                    let progress = MediaUploadProgress.shared.fraction(for: blobs)
                    let stuck = MediaUploadProgress.shared.looksStuck(blobs)
                    if backed {
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.caption2).foregroundStyle(HavenTheme.pink)
                            .help("Backed up to a relay others can read")
                    } else if localOnly {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("Only on this device's own relay — nobody else can fetch it yet")
                    } else if let progress {
                        // A real fraction, because a big video genuinely takes minutes and a motionless
                        // arrow made "slow" and "broken" look identical. Determinate ring + percentage.
                        ZStack {
                            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                            Circle().trim(from: 0, to: max(0.02, progress))
                                .stroke(stuck ? Color.orange : HavenTheme.pink,
                                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 12, height: 12)
                        .help(stuck
                              ? "Still trying to upload — it has restarted several times"
                              : "Uploading to a relay… \(Int(progress * 100))%")
                    } else {
                        // Queued but no window has been written yet (or the blob is small enough to go
                        // in one shot). Orange once it has restarted repeatedly: the queue never gives
                        // up, so without this an upload that can never succeed looks like one about to.
                        Image(systemName: stuck ? "exclamationmark.icloud" : "arrow.up.circle")
                            .font(.caption2)
                            .foregroundStyle(stuck ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.secondary))
                            .help(stuck ? "Still trying to upload — it has restarted several times"
                                        : "Waiting to upload to a relay…")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showBackupDetail = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows which relays hold a copy")
                .sheet(isPresented: $showBackupDetail) {
                    BackupDetailView(refs: item.media.filter { !MediaStore.isSynthetic($0) },
                                     circleId: feed.activeCircleId)
                        .macSheetFrame()
                        #if os(iOS)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        #endif
                }
            }
            Spacer()
            if !item.unsent {
                Menu {
                    // No link for a story (gone by the time anyone taps it) or a DM — a dm: circle
                    // id is literally both members' node ids, so the link would leak the pair to
                    // whoever you sent it to, and nobody outside the DM could ever open it anyway.
                    if !item.story, !feed.activeCircleId.hasPrefix("dm:"),
                       let url = DeepLink.postURL(circleId: feed.activeCircleId, postId: item.id) {
                        ShareLink(item: url) { Label("Share post", systemImage: "square.and.arrow.up") }
                        Button {
                            PlatformPasteboard.string = url.absoluteString
                            linkCopied = true
                            // Unlike the app's other copy buttons this one has to un-stick: the menu
                            // closes on tap, so a reopen a minute later must not still read "Copied".
                            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); linkCopied = false }
                        } label: {
                            Label(linkCopied ? "Copied" : "Copy link",
                                  systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                        }
                        // Reshare the post as a 24h story that links back to it. Deliberately inside the
                        // same guard as the link actions: a story goes to the ACTIVE circle (see
                        // FeedStore.post), and this post is IN the active circle, so everyone who can see
                        // the story can already open the post. That is the whole access story — the embed
                        // carries no key, and we never widen the audience beyond the circle.
                        if !storyableMedia.isEmpty {
                            Button {
                                storyShare = StoryShareTarget(
                                    draft: StoryDraft(refs: storyableMedia),
                                    embed: StoryEmbed.Ref(circleId: feed.activeCircleId,
                                                          postId: item.id, musicStartMs: 0))
                            } label: { Label("Share as story", systemImage: "circle.dashed.inset.filled") }
                        }
                    }
                    // Reply to the AUTHOR privately, the same move a story reply makes: open (or
                    // reuse) the DM with them and carry the post's media so they know which post
                    // you mean. Never available on your own post — that would DM yourself.
                    if !item.isMe, let authorHex = ContactsStore.shared.idHex(forNodePrefix: item.authorShort) {
                        Button {
                            // Stage a draft; do NOT send. Referencing a post is the START of a
                            // message, not one — the point is to ask them something about it, so
                            // the link goes in the composer and the words stay yours. Opens the
                            // real DM thread in Messages rather than switching the circle, which
                            // would drop you into the feed layout instead of the conversation.
                            let dm = feed.startDM(with: authorHex, name: authorName)
                            let ref = DeepLink.postURL(circleId: feed.activeCircleId, postId: item.id)?
                                .absoluteString ?? ""
                            DMDraftStore.shared.stage(circleId: dm, text: ref)
                            DeepLinkRouter.shared.requestedTab = "messages"
                        } label: { Label("Message \(authorName)", systemImage: "bubble.left") }
                    }
                    if item.isMe {
                        Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { onUnsend() } label: { Label("Unsend", systemImage: "arrow.uturn.backward") }
                    }
                    // "Show original" only when the author actually sent an uncompressed companion.
                    // Hidden otherwise so the menu never offers a dead download.
                    let originalRefs = MediaVariants.allOriginals(in: item.media)
                        .filter { !MediaStore.shared.has($0) }
                    if !originalRefs.isEmpty {
                        Button {
                            for r in originalRefs {
                                feed.requestMedia(r, circleId: feed.activeCircleId)
                            }
                        } label: {
                            Label("Show original", systemImage: "arrow.down.circle")
                        }
                    } else if MediaVariants.allOriginals(in: item.media).contains(where: { MediaStore.shared.has($0) }) {
                        // Original already on disk — nothing to download; still surface so the user
                        // knows it's available (opens the zoom viewer on the original if present).
                        Button {
                            // Prefer opening the first available original in the media zoom path.
                            if let first = MediaVariants.allOriginals(in: item.media).first(where: { MediaStore.shared.has($0) }) {
                                // Nudge a refresh so any view observing the store re-reads the item.
                                feed.scheduleRefresh()
                                _ = first
                            }
                        } label: {
                            Label("Original available", systemImage: "checkmark.circle")
                        }
                    }
                    // Keep the post's photos/videos on THIS device so no cleanup (orphan sweep, age/size
                    // limit, or the Manage-media screen) ever removes their bytes. Pins every real media
                    // ref on the post at once — this is the discoverable home for the per-image long-press
                    // "Keep on this device" the storage screen advertises.
                    let keepRefs = item.media.filter { !MediaStore.isSynthetic($0) }
                    if !keepRefs.isEmpty {
                        // `pinned` (observed) rather than the singleton, so flipping this re-renders
                        // the card and its badge — the toggle has to be visible to be believed.
                        let anyPinned = keepRefs.contains { pinned.isPinned($0) }
                        Button { pinned.togglePin(keepRefs) } label: {
                            Label(anyPinned ? "Stop keeping on this device" : "Keep on this device",
                                  systemImage: anyPinned ? "pin.slash.fill" : "pin")
                        }
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
                .menuIndicator(.hidden)
                #if os(macOS)
                .menuStyle(.borderlessButton)   // else macOS paints a rounded-rect bezel behind the glyph
                .fixedSize()
                #endif
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
                // One glass capsule, tinted pink when it's YOUR reaction (the count is pink too) —
                // was a material + hand-rolled ring, i.e. havenGlass's fallback, minus the real glass.
                .havenGlass(in: Capsule(), tint: r.mine ? HavenTheme.pink : nil)
                .contentShape(Capsule())
                .onTapGesture { if r.mine { onUnreact(r.emoji) } else { react(r.emoji) } }
                .onLongPressGesture(minimumDuration: 0.3) { showReactionDetail = true }
                .transition(.scale.combined(with: .opacity))
            }
            if hiddenReactionCount > 0 {
                Text("+\(hiddenReactionCount)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .havenGlass(in: Capsule())
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
            ReactionPicker { e in onReact(e) }
        }
        .sheet(isPresented: $showReactionDetail) {
            ReactionDetailView(reactions: item.reactions, onUnreact: { e in onUnreact(e) })
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
            ReactionPicker { e in feed.react(t.id, e) }
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
                // Flat rows, each reacting on TAP. A ControlGroup here collapsed into a
                // "❤️ 😎 👍 ›" SUBMENU on macOS: it showed the emoji, then made you open a
                // second menu to actually pick one.
                ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                    Button("React \(e)") { EmojiStore.shared.record(e); feed.react(c.id, e) }
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
                    case .file:
                        Image(systemName: "doc.zipper")
                            .frame(width: 56, height: 56)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
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
        }.havenPausesPostAudio()
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
                                    // This friend's profile picture, not their story media (identity chip).
                                    if let s = userStories.last {
                                        if s.isMe {
                                            HavenAvatar(image: ProfileStore.shared.avatar, emoji: ProfileStore.shared.emoji, size: 50)
                                        } else {
                                            PeerAvatar(nodeHex: s.authorShort,
                                                       name: ContactsStore.shared.name(forNodePrefix: s.authorShort) ?? name, size: 50)
                                        }
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
                            // Report center position so a profile post's video AUTO-PLAYS when centered,
                            // exactly like the main feed (the profile list was missing this, so videos here
                            // only ever played on a manual scrub).
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PostCenterKey.self, value: [item.id: geo.frame(in: .global).midY])
                            })
                        }
                    }
                }
                .padding(16)
            }
            .onPreferenceChange(PostCenterKey.self) { centers in
                // The profile post nearest the vertical center becomes active → its video plays + loops.
                let target = PlatformScreen.contentCenterY
                let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                AudioCoordinator.shared.center(nearest?.key)
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
        #if os(macOS)
        // HavenMacSheet, not NavigationStack — a stack inside a macOS sheet paints a grey band above
        // (nav bar) and below (where macOS parks sheet toolbar items). Cancel is the glass X circle.
        HavenMacSheet("New circle") {
            memberColumn
        } footer: {
            Button("Create") { create() }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
        }
        .havenPausesPostAudio()
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                Form {
                    Section("Name") { TextField("Circle name (e.g. Family)", text: $name) }
                    Section("Who's in it") { memberRows }
                }
                .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New circle")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { dismiss() }.havenToolbarPill() }
                ToolbarItem(placement: .havenTrailing) {
                    Button("Create") { create() }
                    .havenToolbarPill(tint: HavenTheme.pink)
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .havenPausesPostAudio()
        #endif
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func create() {
        onCreate(trimmedName, Array(selected))
        dismiss()
    }

    /// macOS column: a Form can't lay out inside HavenMacSheet's ScrollView, so the same rows are
    /// hand-stacked with glass surfaces. Same bindings, same order as the iOS Form.
    @ViewBuilder private var memberColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            TextField("Circle name (e.g. Family)", text: $name).havenPillField()
            Text("Who's in it").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            memberRows
        }
    }

    @ViewBuilder private var memberRows: some View {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                                // Gallery of your own stories → each shows its OWN content thumbnail (matches
                                // the You tab). Off-main, flash-free via FeedImage.
                                if let ref = s.media.first {
                                    FeedImage(ref: ref, maxDimension: 160, contentMode: .fill) { Color.clear }
                                        .frame(width: 56, height: 56).clipShape(Circle())
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
