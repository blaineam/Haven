import SwiftUI
import Combine
import AVKit
import AVFoundation
import CoreVideo
import UniformTypeIdentifiers
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Short relative time ("now", "5m", "3h", "2d", "8mo", "2y") from a unix-millis SENT timestamp —
/// so people see when something was sent, not when it reached them.
///
/// Months stop at a year. Counting them forever produced "32mo" for a post from 2023, which is a
/// number nobody converts on sight — the unit has to keep getting coarser or it stops being a
/// glance. Archive imports made this constant rather than a curiosity, since they backdate posts
/// years into the past.
func relativeTimeShort(_ ms: UInt64) -> String {
    let secs = Date().timeIntervalSince1970 - Double(ms) / 1000
    switch secs {
    case ..<5: return "now"
    case ..<60: return "\(Int(secs))s"
    case ..<3600: return "\(Int(secs / 60))m"
    case ..<86_400: return "\(Int(secs / 3600))h"
    case ..<604_800: return "\(Int(secs / 86_400))d"
    case ..<2_592_000: return "\(Int(secs / 604_800))w"
    case ..<31_536_000: return "\(Int(secs / 2_592_000))mo"
    default: return "\(Int(secs / 31_536_000))y"
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
/// Which scroll container a PostCard is rendered inside.
///
/// Three feeds report a centered post into the one AudioCoordinator, and a TabView keeps its tabs
/// alive off screen — so the same post can exist as two live cards that BOTH matched
/// `centeredPostId == item.id`. Both then built a player for the same clip. Pairing the centered id
/// with its container lets a card tell "the centre is mine" from "some other feed reported it".
private struct HavenFeedContainerKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var havenFeedContainer: String {
        get { self[HavenFeedContainerKey.self] }
        set { self[HavenFeedContainerKey.self] = newValue }
    }
}

/// Counts live feed players so a doubled clip is a fact rather than a theory.
@MainActor
enum BodyCensus {
    private static var n = 0
    private static var started = false
    static func tick() {
        n += 1
        if !started {
            started = true
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if n > 0 { HavenLog.sync("PostCard.body evaluated \(n)x in 5s (\(n / 5)/s)"); n = 0 }
                }
            }
        }
    }
}

enum PlayerCensus {
    private static var made: [String: Int] = [:]
    static func note(ref: String, postId: String, container: String, bag: String) {
        let k = "\(ref)|\(postId)"
        made[k, default: 0] += 1
        let n = made[k]!
        HavenLog.sync("player #\(n) ref=\(ref.prefix(12)) post=\(postId.prefix(8)) container=\(container) bag=\(bag)")
    }
}

struct PostCenterKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { a, _ in a }
    }
}

/// Old-lane retry schedule for missing media, PERSISTED across launches (mirror of
/// MediaBackupBackoff's shape, but for the FETCH side): 90s → 5m → 30m → 6h, then parked. The
/// in-memory version reset on every launch, so each app open re-requested the entire backlog of
/// permanently-missing media at the tight cadence — steady open-the-app heat for bytes that were
/// never going to arrive. A landed blob, a tap retry, or a fresh ingest of the ref clears it.
@MainActor
enum MediaFetchBackoff {
    private static let steps: [UInt64] = [90_000, 300_000, 1_800_000, 21_600_000]
    private static let defaultsKey = "haven.media.reqBackoff.v1"
    private struct Entry: Codable { var n: Int; var due: UInt64 }
    private static var map: [String: Entry] = {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let m = try? JSONDecoder().decode([String: Entry].self, from: d) else { return [:] }
        return m
    }()
    private static var savePending = false
    private static func save() {
        guard !savePending else { return }
        savePending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savePending = false
            if let d = try? JSONEncoder().encode(map) { UserDefaults.standard.set(d, forKey: defaultsKey) }
        }
    }
    private static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Whether `ref`'s next attempt is due (an unknown ref is always due).
    static func due(_ ref: String) -> Bool {
        guard let e = map[ref] else { return true }
        return nowMs() >= e.due
    }
    /// True once every round has been spent — the caller moves the ref to `unavailableMedia`.
    ///
    /// `>=`, not `>`. `n` counts attempts MADE, and `recordAttempt` applies `steps[min(n-1, last)]`,
    /// so at `n == steps.count` all four gaps have been used and the ladder is finished — which is
    /// exactly what the schedule above says ("90s → 5m → 30m → 6h, then parked"). `>` demanded a
    /// FIFTH attempt before parking, and that attempt can only happen after the 6h gap elapses. The
    /// effect was a six-hour dead zone per ref: too spent to be due, not spent enough to count as
    /// exhausted, so nothing retried it and nothing offered it the end state either. A stuck video
    /// sat in that window with a fix for it already shipped and unreachable.
    static func exhausted(_ ref: String) -> Bool { (map[ref]?.n ?? 0) >= steps.count }
    /// Record an attempt (grows the gap by one step).
    static func recordAttempt(_ ref: String) {
        let n = (map[ref]?.n ?? 0) + 1
        let gap = steps[min(n - 1, steps.count - 1)]
        map[ref] = Entry(n: n, due: nowMs() + gap)
        if map.count > 4000 { map.removeAll() }   // bound (matches the old throttle map's cap)
        save()
    }
    /// The blob arrived, or the user asked to try again — restart from the top.
    static func clear(_ ref: String) {
        guard map.removeValue(forKey: ref) != nil else { return }
        save()
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
    /// Increments only after a post is successfully sealed and broadcast. This
    /// is the app's completed, valuable outcome — the thing Haven exists to do.
    @Published private(set) var publishedPostCount = 0
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
    /// NOT @Published — measured at 64 of 66 store publishes in a 5-SECOND window.
    ///
    /// sendIroh writes this on every send, and with several targets some succeed and some fail, so
    /// the value genuinely alternates nil -> error -> nil. Each write fired objectWillChange, which
    /// invalidated every view observing FeedStore — the whole feed — dozens of times a second. That
    /// is the churn behind a main thread sitting at 84% framework code (AG::Graph::propagate_dirty,
    /// UpdateStack::update, CA commits) with no hot function of our own, and the reason the phone
    /// stayed warm with the app merely open.
    ///
    /// An equality guard does not help when the value really is flip-flopping. Its ONLY reader is the
    /// Diagnostics screen, which is a debug panel — it reads the current value when it draws, and
    /// does not need waking the instant a send fails.
    private(set) var lastSendError: String?
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
    /// Is the engine actually up? Anything holding the only copy of something the user wants sent
    /// must check this before handing it over — `post`/`sendMessage` return quietly when it's nil,
    /// which reads as success to a caller that isn't looking.
    var isConfigured: Bool { social != nil }
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
    /// Last time we re-announced circle relays (frame 19). Must NOT ride every sync tick —
    /// sealing + fan-out to every member is real radio work and kept phones hot.
    private var lastRelayReannounceMs: UInt64 = 0
    /// Last Multipeer `connected` callback — flaps reconnect every few seconds on BLE and used
    /// to re-arm tight sync + re-export history each time (device log: DTLS broken-pipe storms).
    private var lastNearbyConnectMs: UInt64 = 0
    /// Last Multipeer media push on the sync path (not connect path). Mac→iPhone flood fix.
    private var lastNearbyMediaPushMs: UInt64 = 0
    /// Fabric soft-rebind: DERP URLs the live messaging node was bound with + debounce/guard.
    private var fabricBoundUrls: [String] = []
    private var fabricRebindPending = false
    private var fabricRebindInFlight = false
    /// Base cadences and the idle multipliers. Idle <3min = base; <15min = ×3; else ×6.
    /// Thermal pressure and super data saver stretch further so a warm phone (or one the user
    /// asked to go easy on the radio) isn't also blasting hello+roster at the tight cadence.
    ///
    /// iOS starts stretching sooner (60s / 5min) — field log: hundreds of MB of UDP in minutes
    /// while the app was merely open and "idle" by user perception but still at base cadence.
    private func adaptiveInterval(base: UInt64) -> UInt64 {
        let idle = now() &- lastActivityMs
        var mult: UInt64
        #if os(iOS)
        // Aggressive stretch: phone was still warm with 60s base stretch. After 30s idle
        // slow down; after 2 min crawl; after 10 min almost park the radio.
        if idle < 30_000 { mult = 1 }
        else if idle < 120_000 { mult = 4 }
        else if idle < 600_000 { mult = 10 }
        else { mult = 20 }
        #else
        // Mac linked host / always-on relay: shorter idle windows than the old 3/15 min —
        // sample showed main + dozen utility threads contending the engine mutex while the
        // host kept tight sync even when the user was just scrolling.
        if idle < 60_000 { mult = 1 }
        else if idle < 300_000 { mult = 3 }
        else if idle < 900_000 { mult = 6 }
        else { mult = 12 }
        // Hosting a circle relay multiplies background work (mesh, reannounce, media) —
        // stretch further so UI scroll never queues behind that pile-up.
        if RelayHost.shared.serving { mult = max(mult, mult * 2) }
        #endif
        #if os(iOS)
        mult *= ThermalPolicy.intervalMultiplier   // .fair ×2 / .serious+ ×4 — centralized policy
        #endif
        if SettingsStore.shared.dataSaverActive { mult = mult * 2 }
        return base * max(1, mult)
    }

    /// True while the app is on screen. Set from the scene-phase hook.
    ///
    /// The idle stretch above exists to stop a phone cooking itself, and it should keep doing that.
    /// But it measures INTERACTION, not attention: reading the feed without touching it for 30
    /// seconds is "idle", and someone watching the screen waiting for a reply is the most idle user
    /// there is. See `mailboxPollInterval` for what that costs and why the two cadences now differ.
    ///
    /// **Default from the real application state.** A background LAUNCH (content-available push,
    /// VoIP, BGAppRefresh after the process was killed) never fires a `scenePhase` `onChange` — the
    /// system builds the engine with no UI — so a hard-coded `true` left every timer guard and the
    /// Multipeer boot path believing we were on screen. That is how Settings still showed multi-hour
    /// Background time after the 1.4.1 park: parks only run when `setForeground(false)` is called,
    /// and on a pure background launch it never was. Same trap AudioCoordinator already fixed.
    #if os(iOS)
    private(set) var appIsForeground: Bool = {
        // `UIApplication` is ready by the time FeedStore is first touched (delegate launch /
        // SwiftUI body). `.inactive` (e.g. Control Center over us) still counts as "on screen"
        // for our purposes — only `.background` is pocketed.
        UIApplication.shared.applicationState != .background
    }()
    #else
    private(set) var appIsForeground = true
    #endif

    /// Foreground/background transition. Foregrounding also counts as activity — you just came back
    /// to look at something.
    func setForeground(_ on: Bool) {
        guard appIsForeground != on else { return }
        appIsForeground = on
        if on {
            // Foregrounding is activity — you just came back to look at something.
            bumpActivity()
            #if os(iOS)
            // Background launches never open Multipeer (see bringOnline). Give nearby a short
            // discovery window now that someone is actually looking — same 12s budget as cold start.
            nearby?.nudgeDiscovery(parkAfter: 12)
            // The heartbeats were invalidated on the way out, not merely gated — put them back.
            armHeartbeats()
            #endif
            return
        }
        #if os(iOS)
        // HARD PARK while pocketed. Stretching the idle multipliers was not enough: any wake that
        // holds a UIApplication background-task assertion (media-backup drain, upload flush,
        // content-available push, BGAppRefresh) also keeps the main runloop alive, so the 15s/30s
        // heartbeats keep firing and re-arm hello fan-out + mailbox LIST for the whole assertion
        // window. That is how Settings shows hours of Background activity with zero real messages
        // — the phone was never permitted to suspend.
        //
        // 1.4.6: also drop live Multipeer sessions (discovery park alone left AWDL/BT warm) and
        // kill the 5s fresh-media retry timer (armed by push-hint media requests during a wake).
        // Push + BGAppRefresh call `slimBackgroundSync` / `pollMailboxNow` directly.
        nearby?.disconnectForBackground()
        armFastMediaTimer(false)
        nextPollDueMs = UInt64.max / 2
        nextSyncDueMs = UInt64.max / 2
        // 1.4.7: STOP the heartbeats, don't just gate them. See `armMailboxTimer`.
        disarmHeartbeats()
        #endif
    }

    #if os(iOS)
    /// Invalidate every repeating timer that exists only to serve a visible app. Nothing here is
    /// needed while pocketed: push + `slimBackgroundSync` own background delivery.
    ///
    /// `liveCallTimer` is deliberately NOT touched — a call that continues while the app is
    /// backgrounded still needs its 3s live-frame poll, and `callActivityChanged` already tears
    /// that down the moment the call ends.
    private func disarmHeartbeats() {
        mailboxTimer?.invalidate(); mailboxTimer = nil
        syncTimer?.invalidate(); syncTimer = nil
    }

    /// Put the heartbeats back when we come on screen. No-op before the engine exists (a cold
    /// background launch foregrounded later re-arms from `startMailboxPolling` / `bringOnline`).
    private func armHeartbeats() {
        guard social != nil else { return }
        if mailboxTimer == nil { armMailboxTimer() }
        if syncTimer == nil { startSyncTimer() }
    }
    #endif

    /// Re-read `UIApplication.applicationState` and park if we are pocketed. Call at the top of
    /// every background entry point that can boot the engine without a scenePhase transition
    /// (remote-notification, BGAppRefresh, VoIP launch → configure). Cheap no-op when already parked
    /// or actually frontmost.
    func syncForegroundFromSystem() {
        #if os(iOS)
        let front = UIApplication.shared.applicationState != .background
        setForeground(front)
        #endif
    }

    /// How long until the next MAILBOX poll — deliberately not `adaptiveInterval`.
    ///
    /// Both timers used to share one stretch, and that conflated two very different costs. The SYNC
    /// timer's work is a fan-out: hello + roster sealed to every contact, relay re-announce, mesh
    /// dials. That is the radio traffic that cooked phones, and it should keep stretching hard.
    /// The MAILBOX poll is one LIST of our own mailbox — cheap, and the only thing that makes a post
    /// a relay is already holding actually appear on this device.
    ///
    /// Sharing the stretch meant a foregrounded, visible, merely-not-being-tapped app went to a ×4
    /// multiplier after 30 seconds — a 45s base becoming 180s, and ×10 (7.5 min) after two minutes.
    /// That is the "it takes a few minutes after a relay has a copy before it loads into the app"
    /// report, and it is worst exactly when the user is watching. So: while we are ON SCREEN, cap
    /// the poll's stretch hard. Backgrounded, it keeps the full aggressive stretch, because then
    /// nobody is waiting and pushes are what wake us anyway.
    private func mailboxPollInterval(base: UInt64) -> UInt64 {
        let full = adaptiveInterval(base: base)
        guard appIsForeground else { return full }
        #if os(iOS)
        // Thermal pressure still wins: a hot phone stretches regardless of who is looking at it.
        // (`adaptiveInterval` already folded ThermalPolicy in; this only caps the IDLE component.)
        let thermalFloor = base * UInt64(max(1, ThermalPolicy.intervalMultiplier))
        return max(thermalFloor, min(full, base * 2))
        #else
        return min(full, base * 2)
        #endif
    }

    /// Mark "something is happening" → snap both timers back to their tight base cadence immediately.
    func bumpActivity() {
        lastActivityMs = now()
        nextSyncDueMs = 0
        nextPollDueMs = 0
        // Multipeer discovery is NOT re-opened on every scroll — only forceSync / cold start /
        // peer-left rediscovery. That prevented discovery from staying warm all day.
    }

    // Chunked media reassembly: ref → temp file + which chunk indices we've received.
    // 512KB chunks overflowed MultipeerConnectivity's reliable-send buffer (small frames got through, media
    // chunks were silently dropped), so own-device media never arrived over nearby. 32KB transmits reliably
    // over a slow BLE-only link.
    private static let mediaChunkSize = 32 * 1024
    private struct IncomingMedia { let tempURL: URL; let total: Int; var got: Set<Int> }
    private var incoming: [String: IncomingMedia] = [:]

    /// DIAGNOSTIC: how often does this store tell SwiftUI "something changed"?
    ///
    /// Every objectWillChange invalidates EVERY view observing FeedStore — which is every PostCard on
    /// screen, each a ~1,500-line body. The profile said the main thread was 84% framework
    /// (AttributeGraph propagate_dirty / UpdateStack::update) with only 16% of samples containing any
    /// Haven frame: the signature of something dirtying the graph constantly rather than one slow
    /// function. This turns that inference into a number, and a rate per property.
    private var willChangeCount = 0
    private var willChangeSink: AnyCancellable?
    private var propSinks = Set<AnyCancellable>()
    private var pubBy: [String: Int] = [:]

    private init() {
        #if DEBUG
        willChangeSink = objectWillChange.sink { [weak self] _ in
            self?.willChangeCount += 1
        }
        // PER-PROPERTY attribution: which @Published is actually firing, and how often.
        func watch<T>(_ pub: Published<T>.Publisher, _ name: String) {
            pub.dropFirst().sink { [weak self] _ in self?.pubBy[name, default: 0] += 1 }.store(in: &propSinks)
        }
        watch($items, "items"); watch($lastHeard, "lastHeard"); watch($postTick, "postTick")
        watch($reactionTick, "reactionTick"); watch($online, "online"); watch($circles, "circles")
        watch($internetActive, "internetActive"); watch($nearbyActive, "nearbyActive")
        watch($relayReachable, "relayReachable"); watch($internetReady, "internetReady")
        watch($unseenCircle, "unseenCircle"); watch($unseenMessages, "unseenMessages")
        watch($hiddenInActiveCircle, "hiddenInActive")
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.willChangeCount > 0 else { return }
                let top = self.pubBy.sorted { $0.value > $1.value }.prefix(5)
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                HavenLog.sync("FeedStore published \(self.willChangeCount)x in 5s — \(top)")
                self.willChangeCount = 0; self.pubBy.removeAll()
            }
        }
        #endif
    }

    /// Initialize the real networked store once (idempotent) and bring the P2P node
    /// online. The feed works offline too; the node just enables real delivery.
    /// Re-initialize for a different identity (e.g. after restoring from a transfer code).
    /// Tears down the old engine, networking, and on-disk state, then configures fresh.
    func reconfigure(seed: Data) {
        node = nil
        RelayClients.clearAll()   // cached clients wrap the old node's (now dead) endpoint
        // Stop Multipeer cleanly BEFORE dropping the reference — deinit-time teardown cancels the
        // browser in the same runloop turn it's freed (the Bonjour cancel crash); stop() parks
        // discovery properly and the static retire pool holds the cancelled objects.
        nearby?.stop()
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
        } else {
            // No keychain seed (locked, missing entitlement on unsigned sim builds, or first-run race).
            // Without a configure(), `online` stays false forever and the feed is a dead Offline shell.
            // Prefer a *stable* fallback seed in UserDefaults so restarts don't mint a new identity
            // (which breaks circle crypto / peer contacts under matrix QA). Keychain remains preferred.
            let udKey = "haven.ephemeralSeed.v1"
            let seed: Data
            if let b64 = UserDefaults.standard.string(forKey: udKey),
               let existing = Data(base64Encoded: b64), existing.count == 32 {
                HavenLog.net("configureForCurrentIdentity: no keychain seed — reusing UserDefaults ephemeral seed")
                seed = existing
            } else {
                HavenLog.net("configureForCurrentIdentity: no keychain seed — minting UserDefaults ephemeral seed")
                var bytes = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
                seed = Data(bytes)
                UserDefaults.standard.set(seed.base64EncodedString(), forKey: udKey)
            }
            configure(seed: seed)
        }
    }


    func configure(mode: BootMode) {
        guard social == nil else { return }
        // Background launch never gets scenePhase — pin the flag from the system before any
        // Multipeer / timer / daily-backfill work below can treat a pocket wake as "on screen".
        syncForegroundFromSystem()
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
        // Media-backup drain holds a UIApplication assertion. On a pocket cold launch (push /
        // BGAppRefresh) the wake path already runs one budgeted pass via slimBackgroundSync —
        // starting another here stacks assertions and keeps the process warm for the whole drain.
        // Foreground open: finish mid-flight uploads so the user sees them land.
        if appIsForeground, let social { MediaBackupQueue.shared.drainPersisted(social: social) }
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
        // Daily full-history re-assert is foreground work: on a pocket wake it is a multi-minute
        // seal+upload storm under a background assertion. Push / slimBackgroundSync cover delivery.
        if appIsForeground {
            dailyMailboxRefreshIfDue()
            // Retry posts that didn't reach the mailbox. Pocket boots leave this to the push /
            // BGAppRefresh handler (one flush under its own assertion, then suspend).
            Task { await BackgroundUploader.shared.flush() }
        }
        ScheduledStore.shared.start()   // one-shot arm only if anything is queued; cheap when empty
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

    private var liveCallTimer: Timer?
    private func startMailboxPolling() {
        mailboxTimer?.invalidate()
        liveCallTimer?.invalidate()
        liveCallTimer = nil   // callActivityChanged below re-arms it only while a call exists
        // Linked Mac host recovery: re-queue DM mailbox keys that were stuck "seen" with no peer keys.
        // Also force a self-sync pass so device rosters / circle state from the primary land before
        // we re-open the re-queued commits (linked seedless Mac often needs the primary's roster).
        SharedStore.repairLinkedHostMailboxSeenOnce()
        // Hello-lane recovery: forget hello seen-cursors claimed under the old claim-everything
        // filter, so invites swallowed by the wrong device become claimable again.
        SharedStore.repairHelloSeenOnce()
        SharedStore.repairStormBurnedSeenOnce()
        // Publish every circle's epoch HEAD (my roster + current key commit) on EVERY launch.
        // Heads already ride each post, but a member who hasn't posted since a relay was adopted,
        // recovered, or GC-swept never re-offers the commit — and every event of theirs sealed
        // under that epoch buffers forever on peers polling that relay (the content blackout).
        // Cheap: the commit is cached until the epoch/recipients change, and the per-(relay,key)
        // upload marks make repeat launches a set-lookup no-op.
        if let social {
            for cid in circles.map(\.id) {
                for head in social.exportEpochHead(circleId: cid) {
                    BackgroundUploader.shared.enqueue(circleId: cid, env: head)
                }
            }
        }
        // Foreground cold start: pull immediately so the open feed is not empty. Background launch
        // (push / BGAppRefresh) lets the caller drive a single slimBackgroundSync / pollMailboxNow
        // and then suspend — starting a full self-sync fan-out here re-opens the heat path.
        if appIsForeground {
            forceSelfSyncNextPoll()
            pollMailboxNow()
        } else {
            // Park due-gates so the heartbeats we arm below are pure integer compares until
            // setForeground(true). (They also early-return on !appIsForeground.)
            nextPollDueMs = UInt64.max / 2
            nextSyncDueMs = UInt64.max / 2
        }
        armMailboxTimer()
    }

    /// Arm (or re-arm) the mailbox heartbeat. Split out of `startMailboxPolling` so backgrounding can
    /// **invalidate** the timer outright and foregrounding can put it back, without re-running the
    /// one-shot seen-set repairs and epoch-head publish at the top of `startMailboxPolling`.
    ///
    /// 1.4.7: an early-`return` guard inside the timer body was not enough. A repeating `Timer` on the
    /// main runloop is a scheduled *wakeup*: for as long as any assertion (upload flush, media backup,
    /// push wake, BGAppRefresh grant) keeps the process unsuspended, these fired every 15s/30s and
    /// hopped the main actor just to compare two integers and return. Invalidate them instead — a
    /// pocketed Haven should have nothing at all scheduled.
    func armMailboxTimer() {
        mailboxTimer?.invalidate()
        mailboxTimer = nil
        #if os(iOS)
        // A cold BACKGROUND launch (content-available push, VoIP, BGAppRefresh after a kill) runs
        // `startMailboxPolling` with no scenePhase ever arriving. Arming here would schedule a 15s
        // runloop wakeup for the whole grant window. `setForeground(true)` re-arms when we're seen.
        //
        // The live-call poll is armed BEFORE that guard: a PushKit VoIP launch brings the app up
        // in the background precisely so a call can ring, and it needs its 3s frame poll there.
        guard appIsForeground else {
            callActivityChanged(CallManager.shared.callInProgress)
            return
        }
        #endif
        // 10s heartbeat, but the actual poll only runs when due (30s base, stretching when idle).
        #if os(iOS)
        // 45s base. Push + activity still force a poll immediately; idle LIST is pure heat.
        //
        // The HEARTBEAT is 15s, not 30s: it does nothing but compare two integers and return unless
        // the poll is actually due, so its cost is noise — but at 30s it quantised every due time up
        // by as much as 30 seconds, which is half the interval it was gating. The throttling lives in
        // the due-gate (`mailboxPollInterval`), where it can be reasoned about; the heartbeat only
        // decides how precisely that decision gets honoured.
        let pollHeartbeat: TimeInterval = 15
        let pollBaseMs: UInt64 = 45_000
        #else
        // Host Mac: 45s base while serving — less self-LIST churn against the local mailbox.
        let pollHeartbeat: TimeInterval = RelayHost.shared.serving ? 20 : 15
        let pollBaseMs: UInt64 = RelayHost.shared.serving ? 45_000 : 30_000
        #endif
        mailboxTimer = Timer.scheduledTimer(withTimeInterval: pollHeartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                #if os(iOS)
                // Pocketed → timers are parked. Push / BGAppRefresh own background delivery.
                // (An active call still needs the live-call timer, which is a separate arm.)
                guard self.appIsForeground else { return }
                #endif
                guard self.now() >= self.nextPollDueMs else { return }
                #if os(iOS)
                // When seriously hot, park mailbox LIST entirely until thermal recovers or a push wakes us.
                switch ProcessInfo.processInfo.thermalState {
                case .serious, .critical:
                    self.nextPollDueMs = self.now() + 120_000
                    return
                default: break
                }
                #endif
                // A backlog drain in progress overrides the idle stretch: keep base cadence so
                // 200-per-poll actually finishes (8k keys in ~30 min, not hours).
                self.nextPollDueMs = self.now() + (SharedStore.anyOutstandingBacklog()
                    ? pollBaseMs : self.mailboxPollInterval(base: pollBaseMs))
                self.pollMailboxNow()
                self.dailyMailboxRefreshIfDue()   // long-lived sessions refresh without a relaunch
            }
        }
        // Live-call HTTP poll: ONLY while a call is active (ring/connect/in-call).
        // Field profile 2026-07-22 (Mac host 344, 10.6 GB, 237% CPU; iPhone scorching on open):
        // path-proxy log was ~98% `__live__` LIST — 6–17/sec continuous from idle 12s sweeps of
        // every DM×device hex (and overlapping polls piling up). Invites still land via iroh +
        // APNs/VoIP; HTTP is the fallback lane *during* a call when iroh can't carry SDP/ICE.
        // Armed ONLY while a call exists — CallManager's `active` didSet flips it through
        // callActivityChanged, so the 3s timer no longer wakes the main actor forever just to hit
        // its callInProgress guard. If a call is already up (timer restart mid-call), arm now.
        callActivityChanged(CallManager.shared.callInProgress)
    }

    /// CallManager's call lifecycle hook: arm the live-call HTTP poll on call start, kill it on end.
    func callActivityChanged(_ inProgress: Bool) {
        if inProgress {
            guard liveCallTimer == nil else { return }
            liveCallTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard CallManager.shared.callInProgress else { return }
                    await self.pollLiveCallFramesNow()
                }
            }
            Task { @MainActor in await self.pollLiveCallFramesNow() }   // first poll right away
        } else {
            liveCallTimer?.invalidate()
            liveCallTimer = nil
        }
    }

    private var liveCallPollInFlight = false

    /// Pull HTTP-mailbox live-call frames addressed to this device/account and dispatch as inbound frames.
    @MainActor
    func pollLiveCallFramesNow() async {
        guard social != nil else { return }
        // Hard gate: never LIST __live__ when not in a call. Idle polling was the heat source.
        guard CallManager.shared.callInProgress else { return }
        // One poll at a time — a slow CF LIST of N circles used to stack every 2s tick until the
        // host was doing dozens of concurrent prefix walks (10 GB RSS, main stuck on engine lock).
        guard !liveCallPollInFlight else { return }
        liveCallPollInFlight = true
        defer { liveCallPollInFlight = false }
        var mine = [myNodeHex.lowercased()]
        if let d = social?.myDeviceNodeHex().lowercased(), d.count == 64 { mine.append(d) }
        // Active call only needs the conversation circle(s), not the entire membership graph.
        // Prefer DMs + default (where invites almost always live); cap so a huge roster can't fan out.
        var ids = circles.map(\.id).filter { $0.hasPrefix("dm:") || $0 == "default" }
        if ids.isEmpty { ids = Array(circles.prefix(2).map(\.id)) }
        else if ids.count > 6 { ids = Array(ids.prefix(6)) }
        let frames = await SharedStore.pollLiveCallFrames(circleIds: ids, myHexes: mine)
        for (key, data) in frames {
            guard !data.isEmpty else { continue }
            // Full wire frame: [type][payload] — same shape as iroh inbound.
            handleInbound(data, viaNearby: false, senderDevice: nil)
            SharedStore.markSeenPublic(key)
            HavenLog.call("live-call http-ingest type=\(data[0]) key=\(key.split(separator: "/").last.map(String.init)?.prefix(12) ?? "?")")
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
        // Dedupe by id — DEFENSIVE, not a fix for an observed bug. Nothing downstream tolerates the
        // same circle twice (`for circle in circles` would fan out, poll and backfill once per copy),
        // and the cost of guaranteeing it here is one Set.
        //
        // Honest note, because the first version of this comment claimed a measured 2-4x duplication:
        // that reading was WRONG. The fan-out log truncates ids with `.prefix(20)`, and a DM id is
        // `dm:<a>-<b>`, so several distinct DM circles sharing a first party printed identically. The
        // log has been widened; the duplicates were never real. Keeps first occurrence, so ordering
        // and the active circle are unchanged.
        var seenCircleIds = Set<String>()
        circles = all.filter { !CircleDeletionStore.isDeleted($0.id) && seenCircleIds.insert($0.id).inserted }
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
        for m in memberIds {
            try? social.addExistingToCircle(circleId: id, nodeHex: m)
            forceHelloNextSync(m, circleId: id)   // the grant rides the hello — never warm-skip it
        }
        persist(); refreshCircles()
        activeCircleId = id
        refresh()
        if !memberIds.isEmpty { syncWithContacts(force: true) }   // new members: greet now
        nudgeSelfSyncSoon()   // the new circle reaches my other devices in seconds, not minutes
    }

    /// Lift a member's removal both client-side (the guard set) and in the engine (the authoritative
    /// tombstone) — a DELIBERATE re-add. The add paths refuse a tombstoned member, so this must run
    /// first. Exposed so views outside the store (e.g. ConnectView) can un-ban before re-adding.
    func clearCircleRemovalEverywhere(idHex: String, circleId: String) {
        ConnectionsStore.shared.clearCircleRemoval(idHex, circleId: circleId)
        social?.clearCircleRemoval(circleId: circleId, nodeHex: idHex)
        nudgeSelfSyncSoon()   // the re-add tombstone-lift must beat a sibling's stale removal
    }

    /// Add a known contact to the active circle, then sync so the circle forms on theirs.
    func addContactToActiveCircle(idHex: String) {
        guard let social else { return }
        ConnectionsStore.shared.clearCircleRemoval(idHex, circleId: activeCircleId)  // deliberate re-add un-bans them
        social.clearCircleRemoval(circleId: activeCircleId, nodeHex: idHex)          // …and lift the engine tombstone
        try? social.addExistingToCircle(circleId: activeCircleId, nodeHex: idHex)
        forceHelloNextSync(idHex, circleId: activeCircleId)   // the invite rides the hello — never warm-skip it
        persist(); refreshCircles()
        syncWithContacts()
        nudgeSelfSyncSoon()   // membership change → my other devices
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
        nudgeSelfSyncSoon()   // the removal tombstone reaches my other devices in seconds
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
        if count > 0 { nudgeSelfSyncSoon() }   // fan the tombstones out to my other devices now
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
        nudgeSelfSyncSoon()   // the new name reaches my other devices in seconds
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
        var undialable = [String]()
        for a in social.contactNodeIds(circleId: circleId) {
            add(a)                                              // account id (contact handle; reaches old-build peers)
            let devices = social.deviceNodeIdsFor(accountHex: a)
            for d in devices { add(d) }                         // their device node ids (actual reach)
            let hints = deviceHints(for: a)
            for h in hints { add(h) }                           // invite-link hints (until their roster lands)
            // Nothing but the account id, which is an identity and not an address: this member is
            // unreachable except through a shared relay. Ask the public directory for their devices.
            if hints.isEmpty, devices.allSatisfy({ $0.lowercased() == a.lowercased() }) { undialable.append(a) }
        }
        dialTargetsCache[circleId] = (out, now())
        if !undialable.isEmpty { resolveMissingDeviceIds(for: undialable) }
        return out
    }

    // MARK: - Account device discovery (relay-optional reachability)

    /// Publish my account → device-id mapping to the public directory, so a contact who holds only
    /// my account id can dial one of my devices with NO relay in common. Fire-and-forget; the
    /// publisher re-publishes on its own TTL for as long as the node lives.
    func publishAccountDevices() {
        guard let node, let social else { return }
        Task.detached {
            do {
                let ids = try await node.publishAccountDevices(social: social)
                if !ids.isEmpty { HavenLog.net("discovery published devices=\(ids.count)") }
            } catch {
                HavenLog.net("discovery publish failed: \(error.localizedDescription)")   // additive — never fatal
            }
        }
    }

    /// Accounts we've asked the directory about recently, so a 20s sync tick doesn't re-query a
    /// contact who simply hasn't published (every pre-discovery install — the common case).
    private static let discoveryRetrySecs: UInt64 = 10 * 60 * 1000
    private var discoveryAskedAt: [String: UInt64] = [:]

    /// Look up device ids for contacts we have NO way to dial — no signed roster, no invite hint,
    /// just an account id that isn't a transport address. Without this such a contact is only
    /// reachable through a relay both sides happen to share; with it, two online devices can find
    /// each other and let iroh hole-punch, which is the whole promise of the transport.
    ///
    /// Results land in the same hint store the invite `?d=` ids use — a dial hint, never an
    /// authorization (see `resolve_account_devices`).
    func resolveMissingDeviceIds(for accounts: [String]) {
        guard let node else { return }
        let n = now()
        var ask = [String]()
        for a in accounts {
            let key = a.lowercased()
            if let at = discoveryAskedAt[key], n - at < Self.discoveryRetrySecs { continue }
            discoveryAskedAt[key] = n
            ask.append(a)
        }
        guard !ask.isEmpty else { return }
        Task.detached { [weak self] in
            var learned = false
            for a in ask {
                guard let ids = try? await node.resolveAccountDevices(accountHex: a), !ids.isEmpty else { continue }
                learned = true
                // [weak self] on the INNER closure too: referencing the outer task's captured
                // `self` var from inside another concurrent closure is a Swift 6 error. Re-capturing
                // makes each hop own its reference instead of reaching across.
                await MainActor.run { [weak self] in
                    HavenLog.net("discovery resolved \(a.prefix(8)) devices=\(ids.count)")
                    self?.recordDeviceHints(accountHex: a, deviceIds: ids)
                }
            }
            // A peer we could not reach a moment ago is reachable NOW. Don't make them wait for the
            // next 20s tick and the 45s announce cadence to discover that: sync tight and re-announce
            // our relays immediately, which is the exact thing a peer with no relay in common is
            // missing ("his app refuses to find any of the relays I have enabled").
            if learned {
                await MainActor.run { [weak self] in
                    self?.bumpActivity()
                    self?.reannounceOwnRelay()
                    self?.syncWithContacts()
                }
            }
        }
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
        forceHelloNextSync(idHex, circleId: "default")
        if !ContactsStore.shared.contacts.contains(where: { $0.idHex == idHex }) {
            ContactsStore.shared.add(name: String(idHex.prefix(6)), idHex: idHex)
        }
        persist(); refreshCircles(); syncWithContacts()
        nudgeSelfSyncSoon()   // membership + contact change → my other devices
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
        nudgeSelfSyncSoon()   // the deletion tombstone reaches my other devices in seconds
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
        forceHelloNextSync(idHex, circleId: id)
        persist(); refreshCircles(); syncWithContacts()
        nudgeSelfSyncSoon()   // the (re-)opened DM reaches my other devices in seconds
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
        nudgeSelfSyncSoon()   // the (re-)opened group DM reaches my other devices in seconds
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
    /// Approve a connection request. Adding someone to a circle SHARES THAT CIRCLE'S HISTORY —
    /// there is no longer a "new posts only" option, because there never really was one.
    ///
    /// A circle is keyed by a shared epoch. Joining it hands over the key that opens the circle's
    /// content, and the relay serves that content to any current member. The old prompt could
    /// therefore be honoured in the UI and nowhere else: we withheld our own uploads while the
    /// relay kept serving everything already published, and any other member — or our own earlier
    /// backfills — filled the rest in. Every attempt to close that gap ran into the same wall, that
    /// one epoch key cannot be readable by some members and not others.
    ///
    /// So the honest options were "make it cryptographically real by denying entitled members their
    /// history too" or "stop offering it". This is the second. Membership means access; the dialog
    /// now says so plainly rather than implying a boundary the design does not have.
    func approveConnection(_ req: ConnectionRequest) {
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
        persist(); refreshCircles()
        if let hello = helloPayload(circleId: "default", circleName: "Your circle") {
            sendIroh(0, hello, to: req.idHex); nearbyBroadcast(0, hello)
            let meHex = social.myNodeHex()
            Task { await SharedStore.putHello(circleId: "default", toHex: req.idHex, fromHex: meHex, hello: hello, force: true) }
        }
        // Back-fill your past posts to them (and ensure the shared store has them).
        for env in social.syncEnvelopes(circleId: "default") {
            sendIroh(1, eventPayload("default", env), to: req.idHex)
            Task { await SharedStore.uploadEvent(circleId: "default", env: env) }
        }
        // Make sure the relay also holds the MEDIA for that history, so the new member can pull it
        // from the relay if the direct transfer doesn't reach them — no fragmented posts. This is
        // what makes "all the history except the media" impossible rather than merely unlikely.
        backfillMailboxMedia(circleIds: ["default"])
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

    /// Per-circle feed cache so SwiftUI chat bodies (`ordered`) and badge/notify paths don't
    /// re-run `social.feed` (full decrypt) on every paint. Field beachball: Messages view body
    /// + `notifyNewest` after a mailbox batch each called `messages(in:)` → main waited on the
    /// engine mutex held by concurrent utility workers.
    private var messagesCache: [String: (at: UInt64, items: [FeedItemFfi])] = [:]
    private func invalidateMessagesCache(_ circleId: String? = nil) {
        if let circleId { messagesCache.removeValue(forKey: circleId) }
        else { messagesCache.removeAll(keepingCapacity: true) }
    }
    /// Messages of a circle (for a DM thread) without disturbing the main feed.
    /// Is the social engine up? Lookups answer "no such post" indistinguishably from "engine still
    /// booting", so anything that reports absence to the user has to wait for this first.
    var engineReady: Bool { social != nil }

    /// One post by id, WITHOUT applying viewer retention.
    ///
    /// `messages(in:)` filters by the circle's viewer-retention setting, which is a DISPLAY
    /// preference — "don't show me things older than N days" — not a statement that the post is
    /// gone. The deep-link target used that same lookup, so tapping an old notification reported
    /// "Post unavailable" for a post sitting right there in the feed the moment you dismissed the
    /// sheet. The feed itself reads with `viewerRetentionSecs: nil`; a tap is an explicit request
    /// for one specific post, so it must too.
    ///
    /// An id that names a COMMENT resolves to the post that CARRIES it. Comments are not top-level
    /// feed items — they live inside their parent — so an id pointing at one matched nothing here and
    /// the tap landed on "Post unavailable". That is not a rare corner: the core's `react`/`comment`
    /// work on ANY event id, so reacting to (or replying to) a comment produces an activity row and a
    /// push whose target IS the comment. Resolving it up to the parent is the honest answer to "show
    /// me this" — the comment is right there in the post, which is the context it only makes sense in.
    func post(_ postId: String, in circleId: String) -> FeedItemFfi? {
        let items = social?.feed(circleId: circleId, nowMs: now(), viewerRetentionSecs: nil) ?? []
        return items.first { $0.id == postId }
            ?? items.first { $0.comments.contains { $0.id == postId } }
    }

    func messages(in circleId: String) -> [FeedItemFfi] {
        maybePurgeExpiredMedia(circleId, retention: CircleSettingsStore.shared.retentionSecs(circleId))
        let nowMs = now()
        // Warm cache (2s): chat body re-evaluates often; feed() is 10s–100s of ms under lock.
        if let hit = messagesCache[circleId], nowMs >= hit.at, nowMs &- hit.at < 2_000 {
            guard let cutoff = dmClearedBefore[circleId] else { return hit.items }
            return hit.items.filter { $0.createdAt >= cutoff }
        }
        let retention = CircleSettingsStore.shared.retentionSecs(circleId)
        let all = social?.feed(circleId: circleId, nowMs: nowMs, viewerRetentionSecs: retention) ?? []
        messagesCache[circleId] = (nowMs, all)
        // Bound cache so many DM circles don't pin decoded feeds forever.
        if messagesCache.count > 40 {
            let stale = messagesCache.filter { nowMs &- $0.value.at > 30_000 }.map(\.key)
            for k in stale { messagesCache.removeValue(forKey: k) }
            if messagesCache.count > 40 {
                let oldest = messagesCache.sorted { $0.value.at < $1.value.at }.prefix(messagesCache.count - 32)
                for e in oldest { messagesCache.removeValue(forKey: e.key) }
            }
        }
        guard let cutoff = dmClearedBefore[circleId] else { return all }
        return all.filter { $0.createdAt >= cutoff }   // hide messages exchanged before this DM was cleared
    }

    /// Send a text message into a DM circle + broadcast it.
    func sendMessage(to circleId: String, _ body: String) {
        sendMessage(to: circleId, body, media: [], music: nil)
    }

    /// Send a DM with optional media (photos/videos/audio), a song, and optional
    /// disappearing retention (seconds; the message auto-deletes after that).
    /// Returns whether the message was actually authored. Callers that hold the ONLY copy of a
    /// message — the share-sheet queue does — must not throw it away on a silent failure: this
    /// returns false when the engine isn't configured yet (a share arriving on a cold launch) or
    /// the post throws, so the caller can keep it and retry.
    @discardableResult
    func sendMessage(to circleId: String, _ body: String, media rawMedia: [String], music: TrackRefFfi?, retentionSecs: UInt64? = nil) -> Bool {
        let media = withPreviewMarkers(withThumbMarkers(rawMedia))
        let ts = now()
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: media, music: music, retentionSecs: retentionSecs, story: false, muteVideo: false, createdAt: ts) else { return false }
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        // The engine derives event ids internally (BLAKE3 at author time) — read back the id of the
        // message just created so the sealed banner's `p` deep-link opens THIS thread entry. Best-effort:
        // nil keeps the legacy circle route.
        let postId = social.lastAuthoredEventId(circleId: circleId, createdAt: ts)
        broadcastEvent(circleId, env, banner: .forPost(circleId: circleId, circleName: name, body: body, media: media, story: false, postId: postId))
        postTick += 1
        enqueueAuthoredMedia(media, circleId: circleId, social: social)
        // Heal 403-before-roster: publish device ids, then reannounce relay so the peer learns
        // public media URL immediately (cross-device / friend video DMs).
        if !media.isEmpty {
            Task { await SharedStore.publishDeviceRoster(social: social) }
            if RelayHost.shared.serving { reannounceOwnRelay() }
        }
        #if os(iOS)
        // Sending into a thread is what makes it "recent" — the share sheet's suggestion row is
        // ranked by donation time, so this donation is what keeps that order honest.
        ShareSuggestions.donate(circleId: circleId)
        #endif
        return true
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
        broadcastEvent(circleId, env, banner: .forEdit(circleId: circleId, circleName: name, postId: id)); postTick += 1; refresh()
    }

    /// Delete (retract) one of your own messages in a specific (DM) circle.
    func deleteMessage(in circleId: String, _ id: String) {
        guard let social, let env = try? social.unsend(circleId: circleId, target: id, createdAt: now()) else { return }
        broadcastEvent(circleId, env, banner: .forUnsend(circleId: circleId, postId: id)); postTick += 1; refresh()
    }

    /// Delete a whole DM conversation locally (also clears any old contaminated thread).
    func deleteConversation(_ circleId: String) {
        guard let social, circleId.hasPrefix("dm:") else { return }
        clearDMBefore(circleId)   // watermark so re-syncing (or re-starting) this DM won't restore old messages
        CircleDeletionStore.markDeleted(circleId)   // LWW tombstone so self-sync can't re-create it from a sibling
        social.leaveCircle(id: circleId)
        persist(); refreshCircles(); refresh()
        nudgeSelfSyncSoon()   // the deletion tombstone reaches my other devices in seconds
        #if os(iOS)
        ShareSuggestions.forget(circleId: circleId)   // no tile for a conversation that no longer exists
        #endif
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
            let (purged, inUseFinal): ([String], Set<String>) = await EngineGate.shared.run {
                let purged = social.purgeExpired(circleId: circleId, viewerRetentionSecs: retention, nowMs: nowMs)
                guard !purged.isEmpty else { return (purged, Set<String>()) }
                // Anything a LIVE event anywhere still names keeps its bytes (content addressing means
                // one blob can back many posts). Built AFTER the purge so this circle's dropped events
                // no longer count as users. Device-pinned blobs are held regardless of referencedness.
                var inUse = Self.mediaInUseStems(social: social)
                for r in scheduledRefs { inUse.formUnion(MediaStore.storedStems(for: r)) }
                inUse.formUnion(pinnedStems)
                return (purged, inUse)
            }
            guard !purged.isEmpty else { return }
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
                // AN UNSENT POST DOES NOT KEEP ITS MEDIA ALIVE.
                //
                // `feed()` still returns a withdrawn post — as a tombstone carrying its original ref
                // list — and this walked every item, so those refs counted as IN USE and their bytes
                // could never be swept. Nothing displays them, nothing can restore them, and unsend
                // is not reversible; they are dead weight that the cleanup was structurally unable
                // to see.
                //
                // It showed up the moment the duplicate sweep withdrew 81 posts: Manage media listed
                // their blobs as "Unused — not linked to any post" (that screen skips unsent), beside
                // an identical live copy of the same size and timestamp, while "Clean up unused
                // media" answered "Nothing to clean up". Two code paths, two answers, and the one
                // that could free the space was wrong.
                if item.unsent { continue }
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
    /// `grace` protects bytes that may belong to work in progress — a video mid-export, a download
    /// mid-reassembly, media staged in a composer that has not been posted yet.
    ///
    /// The WEEKLY sweep keeps 48 hours, which is right for something that runs unasked. Tapping
    /// "Clean up unused media" is not that: it is a person asking now, about blobs the app has
    /// already decided nothing references. Your orphans were three hours old, so a 48h grace skipped
    /// every one of them and reported "Nothing to clean up" over 11 GB — twice, because the message
    /// is identical whether the sweep found nothing or never looked.
    ///
    /// An hour still covers an export or a download in flight, and it is the same judgement
    /// `sweepStaleScratch` already makes about what counts as live work.
    func cleanupUnusedMedia(grace: TimeInterval = 3600) async -> (bytes: Int64, files: Int) {
        guard let social, !DemoEnv.isDemo else { return (0, 0) }
        let scheduledRefs = ScheduledStore.shared.items.flatMap(\.media)
        let pinnedStems = PinnedMediaStore.shared.inUseStems()   // device-pinned blobs are cleanup-exempt
        let result = await Task.detached(priority: .utility) { () -> (Int64, Int) in
            let inUse: Set<String> = await EngineGate.shared.run {
                var inUse = Self.mediaInUseStems(social: social)
                for r in scheduledRefs { inUse.formUnion(MediaStore.storedStems(for: r)) }
                inUse.formUnion(pinnedStems)
                return inUse
            }
            return MediaStore.performOrphanSweep(inUse: inUse, graceSeconds: grace)
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
            _ = await self.cleanupUnusedMedia(grace: 48 * 3600)   // unasked: keep the long grace
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
    /// Relays were reachable and NONE holds the blob — we're waiting on the SENDER's device to
    /// upload it. Drives the placeholder's honest "Waiting for sender…" state.
    @Published var waitingForSenderMedia: Set<String> = []
    /// Chunk progress for large chunked relay restores (ref → done/total) — the placeholder's i/n.
    @Published var mediaRestoreProgress: [String: (done: Int, total: Int)] = [:]
    /// Present-but-undecryptable blobs (bytes fetched, every circle failed to open them). SESSION
    /// scoped, Android/desktop parity: without it the missing-media sweep re-downloaded the same
    /// bad blob every cycle forever. A tap-retry (downloadEvicted) or relaunch clears it — by then
    /// the author's forced re-seal may have replaced the stored copy.
    var unopenableMedia: Set<String> = []

    func noteMediaMissingOnRelays(_ ref: String) {
        guard !MediaStore.shared.has(ref) else { return }
        waitingForSenderMedia.insert(ref)
    }
    func noteUnopenableMedia(_ ref: String) { unopenableMedia.insert(ref) }
    func noteRestoreProgress(_ ref: String, done: Int, total: Int) {
        mediaRestoreProgress[ref] = (done, total)
        downloadingMedia.insert(ref)   // a chunked pull IS a download — say so
    }
    func clearRestoreProgress(_ ref: String) {
        mediaRestoreProgress.removeValue(forKey: ref)
    }
    /// The bytes for `ref` just landed — clear every transient placeholder state it held.
    private func mediaArrived(_ ref: String) {
        // If someone reacted or replied to this post while this blob was still missing, tell them
        // it is here now (docs/PREVIEW-TIER-DESIGN.md §4.4). No-op unless they actually engaged.
        IncompleteInterestStore.shared.mediaArrived(ref)
        downloadingMedia.remove(ref)
        waitingForSenderMedia.remove(ref)
        unavailableMedia.remove(ref)
        unopenableMedia.remove(ref)
        mediaRestoreProgress.removeValue(forKey: ref)
    }

    /// User tapped "Download" on a placeholder for a blob we deliberately evicted: clear the eviction
    /// (so the normal missing-media path may fetch it), request it now, and surface a spinner. If it
    /// hasn't arrived in ~45s, mark it unavailable (the relay/peers don't have it either).
    func downloadEvicted(_ ref: String) {
        EvictedMediaStore.shared.clear(ref)
        unavailableMedia.remove(ref)
        // A tap retry restarts every lane from the top: backoff schedule, session-unopenable mark
        // (the author may have re-sealed the stored copy since), and the waiting state.
        MediaFetchBackoff.clear(ref)
        unopenableMedia.remove(ref)
        waitingForSenderMedia.remove(ref)
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
        // Re-entry (identity adoption paths call this again): stop the previous transport before
        // building a fresh one — overwriting `nearby` frees the old browser in the same runloop
        // turn as its cancel otherwise (the Bonjour cancel crash).
        nearby?.stop()
        // Nearby Bluetooth / Wi-Fi mesh — works even with no internet at all.
        if let social {
            // Matrix QA stub is a pure relay host. Multipeer Bonjour discovery on the stub was
            // crashing CFNetwork (`_BrowserCancel` / `_CFAssertMismatchedTypeID`) under matrix
            // bounce load and is not needed for HTTP mailbox QA.
            let isQaStub = Bundle.main.bundleIdentifier?.contains("qa.stub") == true
            if !isQaStub {
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
                // iOS + Mac: start Multipeer for a bounded discovery window, then park advertise/browse
                // if nobody connects. Live sessions keep working; send path is rate-limited so neither
                // side can flood (Mac→iPhone history dump was the field heat source).
                #if os(iOS)
                // Pocketed cold launch (push / BGAppRefresh / VoIP): do NOT open Multipeer at all.
                // A 12s discovery window under a background-task assertion is pure heat with nobody
                // looking, and is exactly the "hours of Background with zero activity" symptom when
                // combined with timers that still thought we were foreground (see appIsForeground).
                // Foregrounding nudges discovery; forceSync / peer-left still re-open a short window.
                if appIsForeground {
                    // Very short discovery — if Mac isn't nearby in 12s, park Bonjour. Continuous
                    // Multipeer advertise/browse on launch was a top field heat source (phone scorch).
                    switch ProcessInfo.processInfo.thermalState {
                    case .fair, .serious, .critical:
                        // Already warm: don't even start discovery; internet + mailbox cover delivery.
                        nt.start(parkAfter: 1)
                        nt.parkDiscovery()
                    default:
                        nt.start(parkAfter: 12)
                    }
                } else {
                    HavenLog.net("nearby: skipped discovery — background launch")
                }
                #else
                // Host Mac: shorter window than 120s — Multipeer + CF tunnel + engine lock was
                // the 10 GB / beachball field sample.
                nt.start(parkAfter: RelayHost.shared.serving ? 20 : 60)
                #endif
                nearby = nt
            } else {
                nearby = nil
                HavenLog.net("qa.stub: Multipeer discovery disabled (relay-only host)")
            }
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
                // iroh-trace.debug logging is **off by default** — full `iroh=debug` tracing
                // writes continuously during path discovery and was a real heat/battery source
                // on daily-driver phones (unbounded append + CPU). Opt-in only:
                // UserDefaults `haven.debug.irohTrace` = true (or set in a debug menu later).
                #if DEBUG
                let wantIrohTrace = UserDefaults.standard.object(forKey: "haven.debug.irohTrace") as? Bool ?? false
                #else
                let wantIrohTrace = UserDefaults.standard.bool(forKey: "haven.debug.irohTrace")
                #endif
                if wantIrohTrace,
                   let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    initLogging(dir: dir.path)
                }
                let deviceSeed = DeviceKeyStore.deviceAccount().secretSeed()
                // Fabric before bind: prefs/UserDefaults may already know circle DERP from a prior
                // session. apply_derp_urls is process-wide and only affects this HavenNode if set
                // before start (iroh RelayMap is construct-time).
                RelayMailboxStore.refreshHavenFabric()
                let n = try await HavenNode.start(accountSeed: deviceSeed, listener: bridge)
                RelayClients.clearAll()   // never inherit clients bound to a previous endpoint
                self.node = n
                self.fabricBoundUrls = RelayMailboxStore.shared.allDerpUrls()
                self.internetReady = true
                self.online = true
                HavenLog.net("node started id=\(n.nodeIdHex().prefix(10)) account=\(social?.myNodeHex().prefix(10) ?? "?")")
                self.publishAccountDevices()   // account id → my device ids, so contacts can dial me relay-free
                // Matrix QA: dump public identity bundle so Scripts/qa-exchange-bundles.sh can seed
                // the Android peer when HELLO cannot dial (HTTP-mailbox-only stub path).
                if let b = social?.myBundle(), !b.isEmpty {
                    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    if let url = dir?.appendingPathComponent("qa-my-bundle.bin") {
                        try? b.write(to: url, options: .atomic)
                        let name = ProfileStore.shared.displayName.isEmpty ? "SimPeer" : ProfileStore.shared.displayName
                        try? Data(name.utf8).write(to: dir!.appendingPathComponent("qa-my-name.txt"), options: .atomic)
                        HavenLog.net("qa-my-bundle written bytes=\(b.count) name=\(name)")
                    }
                }
                // Dump account seed for linked-device Tauri (haven-seed:…). Keychain-only stores were
                // unreadable to Scripts/qa-link-tauri-to-ios.sh under the sim.
                #if DEBUG
                if let seed = AccountStore.storedSeed(), seed.count == 32,
                   let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    let line = "haven-seed:" + seed.base64EncodedString()
                    try? line.write(to: dir.appendingPathComponent("qa-account-seed.txt"), atomically: true, encoding: .utf8)
                    try? (social?.myNodeHex() ?? "").write(
                        to: dir.appendingPathComponent("qa-account-hex.txt"), atomically: true, encoding: .utf8)
                    // HTTP mailbox auth is the DEVICE transport id — stub must authorize this too.
                    try? n.nodeIdHex().write(
                        to: dir.appendingPathComponent("qa-device-hex.txt"), atomically: true, encoding: .utf8)
                    let ss = UserDefaults.standard.string(forKey: "haven.selfsync.deviceId") ?? ""
                    if !ss.isEmpty {
                        try? ss.write(to: dir.appendingPathComponent("qa-selfsync-device-hex.txt"),
                                      atomically: true, encoding: .utf8)
                    }
                    HavenLog.net("qa-account-seed written account=\(social?.myNodeHex().prefix(12) ?? "?") device=\(n.nodeIdHex().prefix(12))")
                }
                #endif
                // Ingest staged Android peer bundle (driver copies qa-peer-bundle.bin into App Support).
                self.ingestQaPeerBundle()
                // One delayed ticket snapshot for diagnostics — not a multi-probe heat loop.
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    let t = (try? await n.ticket()) ?? ""
                    HavenLog.net(t.isEmpty ? "node TICKET = EMPTY (no reachable path)" : "node TICKET len=\(t.count)")
                }
                self.startSyncTimer()
                // One boot sync after discovery settles — not three stacked fan-outs at 1/4/10s.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.syncWithContacts()
                }
            } catch {
                self.nodeError = error.localizedDescription
            }
        }
    }

    /// Called when circle DERP URLs change (frame 19 / adopt / host). If the messaging node is
    /// already live on a different map, debounce and soft-rebind (iroh RelayMap is bind-time).
    func noteFabricUrlsChanged(_ urls: [String]) {
        let target = urls.sorted()
        guard node != nil, !target.isEmpty, target != fabricBoundUrls,
              !fabricRebindInFlight, !fabricRebindPending else { return }
        // Schedule-ONCE debounce. The old generation-bump pattern cancelled the pending rebind on
        // every call, so a caller stream (e.g. re-ingested __relay__ frames during a mailbox storm)
        // both starved the rebind forever AND logged "scheduled" dozens of times a second. The
        // pending task recomputes the target from RelayMailboxStore at fire time, so coalescing
        // later calls into it loses nothing.
        fabricRebindPending = true
        HavenLog.net("fabric rebind scheduled (urls=\(target.count))")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            fabricRebindPending = false
            await rebindTransportForFabric()
        }
    }

    /// Stop messaging node cleanly, re-apply fabric, start again, re-attach relay host if needed.
    private func rebindTransportForFabric() async {
        guard !fabricRebindInFlight else { return }
        let target = RelayMailboxStore.shared.allDerpUrls().sorted()
        guard !target.isEmpty, target != fabricBoundUrls else { return }
        fabricRebindInFlight = true
        defer { fabricRebindInFlight = false }
        HavenLog.net("fabric rebind starting…")
        let wasHosting = RelayHost.shared.serving || RelayHost.shared.enabled
        let hostingWasLive = RelayHost.shared.serving
        if hostingWasLive {
            RelayHost.shared.detachForFabricRebind()
        }
        if let old = node {
            await old.shutdown()
            node = nil
            // The cached RelayClients wrap BlobClients bound to the endpoint we just closed. Left
            // in place they fail every op with "endpoint stopping" for the rest of the process.
            RelayClients.clearAll()
            internetReady = false
            // Let OS / accept loop finish teardown before same-seed spawn.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let bridge = listener else {
            HavenLog.net("fabric rebind aborted — no inbound listener")
            return
        }
        do {
            RelayMailboxStore.refreshHavenFabric()
            let deviceSeed = DeviceKeyStore.deviceAccount().secretSeed()
            let n = try await HavenNode.start(accountSeed: deviceSeed, listener: bridge)
            node = n
            fabricBoundUrls = RelayMailboxStore.shared.allDerpUrls().sorted()
            internetReady = true
            online = true
            HavenLog.net("fabric rebind ok id=\(n.nodeIdHex().prefix(10)) urls=\(fabricBoundUrls.count)")
            publishAccountDevices()   // the record is per-endpoint — re-publish on the new node
            if wasHosting {
                RelayHost.shared.reattachAfterFabricRebind()
            }
            reannounceOwnRelay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.syncWithContacts()
            }
            // Catch learns that arrived during rebind.
            noteFabricUrlsChanged(RelayMailboxStore.shared.allDerpUrls())
        } catch {
            nodeError = error.localizedDescription
            HavenLog.net("fabric rebind failed: \(error.localizedDescription)")
            // Detach left the host in enabled-but-not-serving ("Starting…") with no node.
            // Bring the messaging node back (best effort) and re-attach the relay so a failed
            // fabric rebind can't permanently brick hosting until app restart.
            if node == nil, let bridge = listener {
                do {
                    let deviceSeed = DeviceKeyStore.deviceAccount().secretSeed()
                    let n = try await HavenNode.start(accountSeed: deviceSeed, listener: bridge)
                    node = n
                    internetReady = true
                    online = true
                    HavenLog.net("fabric rebind recovery node ok id=\(n.nodeIdHex().prefix(10))")
                } catch {
                    HavenLog.net("fabric rebind recovery node failed: \(error.localizedDescription)")
                }
            }
            if wasHosting {
                RelayHost.shared.reattachAfterFabricRebind()
            }
        }
    }

    // Diagnostics accessors.
    var myNodeIdShort: String { social.map { String($0.myNodeHex().prefix(16)) } ?? "—" }
    var myNodeHex: String { social?.myNodeHex() ?? "" }
    /// This DEVICE's node id (distinct from the ACCOUNT id above). Anything deciding "is this me?"
    /// against a participant list needs both — a device-transport peer is named by this one.
    var myDeviceNodeHex: String { social?.myDeviceNodeHex() ?? "" }
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

    /// Prefix-tolerant "heard within window" check for keep-alive skip. `lastHeard` keys may be
    /// full device ids, account ids, or short prefixes depending on the inbound path.
    private func recentlyHeard(_ nodeHex: String, withinMs: UInt64, nowMs: UInt64) -> Bool {
        let needle = nodeHex.lowercased()
        guard !needle.isEmpty else { return false }
        for (k, date) in lastHeard {
            let key = k.lowercased()
            guard key.hasPrefix(needle) || needle.hasPrefix(key) else { continue }
            let heardMs = UInt64(max(0, date.timeIntervalSince1970) * 1000)
            if nowMs >= heardMs, nowMs &- heardMs < withinMs { return true }
        }
        return false
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
    func forceSync() {
        bumpActivity()
        // Open a short Multipeer discovery window when the user asks to sync (needed local mesh).
        nearby?.nudgeDiscovery(parkAfter: 45)
        ingestPushInbox()
        syncWithContacts()
        forceSelfSyncNextPoll()
        pollMailboxNow()
        pullActivity()
    }

    /// Refresh the in-app activity list from the engine (bell icon / ActivityView). Off-main via
    /// EngineGate inside ActivityStore; deduped by event id, so calling liberally is cheap.
    func pullActivity() {
        guard let social else { return }
        ActivityStore.shared.pull(social: social)
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
        #if os(iOS)
        // Same trap as `armMailboxTimer`: a pocketed cold launch must schedule nothing.
        guard appIsForeground else {
            #if DEBUG
            startMatrixQaPoller()
            #endif
            return
        }
        #endif
        // 10s heartbeat, but the expensive fan-out (hello+roster to every contact, relay re-announce,
        // mesh dials) only runs when due — 20s base, stretching to 60s/120s as the app sits idle. This
        // is the primary device-heat fix: an open-but-idle phone no longer blasts the radio every 20s.
        // Heartbeat: 15s on iOS (was 10) so idle phones wake the main actor less often; due-gate
        // still decides when expensive work runs (base 30s on iOS, 20s elsewhere).
        #if os(iOS)
        // 30s heartbeat / 60s base — launch heat sample: phone back scorching within seconds of open.
        let syncHeartbeat: TimeInterval = 30
        let syncBaseMs: UInt64 = 60_000
        #else
        // Mac hosting a circle relay: prefer longer gaps so mesh/media work doesn't pin the UI.
        // (Field sample: host Mac at 10.6 GB with continuous Multipeer + __live__ + engine lock.)
        let syncHeartbeat: TimeInterval = RelayHost.shared.serving ? 30 : 15
        let syncBaseMs: UInt64 = RelayHost.shared.serving ? 90_000 : 30_000
        #endif
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncHeartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                #if os(iOS)
                // Pocketed → no hello fan-out, no media backfill sweep, no Multipeer. Those are
                // foreground work; background delivery is push + slimBackgroundSync only.
                guard self.appIsForeground else { return }
                #endif
                guard self.now() >= self.nextSyncDueMs else { return }
                // Re-read host state: user may have toggled relay after timer start.
                #if os(macOS)
                let base = RelayHost.shared.serving ? UInt64(90_000) : UInt64(30_000)
                #else
                let base = syncBaseMs
                #endif
                self.nextSyncDueMs = self.now() + self.adaptiveInterval(base: base)
                #if os(iOS)
                // Serious heat: stop Multipeer discovery and skip the expensive contact fan-out.
                // Push + mailbox recover traffic; cooking the SoC helps nobody.
                switch ProcessInfo.processInfo.thermalState {
                case .serious, .critical:
                    // Park discovery only — don't tear down live Multipeer sessions mid-transfer.
                    self.nearby?.parkDiscovery()
                    self.nextSyncDueMs = self.now() + 180_000
                    return
                case .fair:
                    // Don't re-open Multipeer discovery while already warm.
                    break
                default: break
                }
                #endif
                // requestMissingMedia runs inside syncWithContacts (already throttled) — do not
                // call it again here or every tick doubles the media-scan + restore Tasks.
                self.syncWithContacts()
                // Mesh tick only when we host a relay (avoid empty work every cycle on phones).
                // Internally throttled to ≥5 min for the expensive pull (see RelayHost.meshSyncTick).
                if RelayHost.shared.serving {
                    RelayHost.shared.meshSyncTick()
                }
                RelayMailboxStore.shared.purgeStale()   // GC relays inactive + unseen > 7 days
                self.maybeWeeklyMediaSweep()      // orphaned media blobs (at most once a week)
                self.enforceLocalLimits()         // device-local age/size caps (throttled ~10 min; no-op if off)
            }
        }
        #if DEBUG
        startMatrixQaPoller()
        #endif
    }

    #if DEBUG
    /// Matrix multi-device QA: poll Application Support for `qa-cmd.json` and honor
    /// `haven://qa?...` deep links (post / story / dm / call) without camera or picker automation.
    ///
    /// Drop file shape (deleted after one consume) — two dialects:
    /// - legacy v1: `{"post":"…","story":"…","dm_to":"<64hex>","dm":"…","call_to":"<64hex>"}`
    /// - qa-cmd v2 (docs/QA.md): `{"op":"post|story|dm|react|comment|profile|circle_create|
    ///   circle_invite|file|music_post|mark_read|dump", …}` — every op answers with a fresh
    ///   `qa-dump.json` next to the drop file.
    private var matrixQaTimer: Timer?
    private func startMatrixQaPoller() {
        matrixQaTimer?.invalidate()
        matrixQaTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.processMatrixQaDropFile() }
        }
        // Also honor one-shot launch env (relaunch-driven automation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.processMatrixQaEnvironment()
        }
    }

    /// Handle `haven://qa?post=&story=&dm_to=&dm=&call_to=` from `onOpenURL`.
    /// A bare poke (`haven://qa?x=1`) consumes any waiting drop file immediately, so the
    /// v2 driver doesn't have to wait out the 1.5s poll tick.
    @discardableResult
    func handleMatrixQaURL(_ url: URL) -> Bool {
        guard url.scheme == "haven", url.host == "qa" else { return false }
        processMatrixQaDropFile()
        var items: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .forEach { if let v = $0.value, !v.isEmpty { items[$0.name] = v } }
        applyMatrixQa(items)
        return true
    }

    private func processMatrixQaDropFile() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("qa-cmd.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            HavenLog.net("matrix-qa drop: invalid JSON")
            return
        }
        // qa-cmd v2 dialect: an explicit {"op": …} routes through the full driver contract.
        if obj["op"] is String {
            applyMatrixQaV2(obj)
            return
        }
        var items: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String, !s.isEmpty { items[k] = s }
        }
        applyMatrixQa(items)
    }

    private func processMatrixQaEnvironment() {
        let e = ProcessInfo.processInfo.environment
        var items: [String: String] = [:]
        if let v = e["HAVEN_QA_POST"], !v.isEmpty { items["post"] = v }
        if let v = e["HAVEN_QA_STORY"], !v.isEmpty { items["story"] = v }
        if let v = e["HAVEN_QA_DM"], !v.isEmpty { items["dm"] = v }
        if let v = e["HAVEN_QA_DM_TO"], !v.isEmpty { items["dm_to"] = v }
        if let v = e["HAVEN_QA_CALL_TO"], !v.isEmpty { items["call_to"] = v }
        guard !items.isEmpty else { return }
        applyMatrixQa(items)
    }

    private func applyMatrixQa(_ items: [String: String]) {
        guard social != nil else {
            HavenLog.net("matrix-qa deferred — social not ready")
            return
        }
        // Media attach: `media=photo|video` and/or `photo_path` / `video_path` (absolute file).
        // Text-only when media is absent. Video prepare is async so those paths hop a Task.
        let mediaKind = (items["media"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let photoPath = (items["photo_path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let videoPath = (items["video_path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsMedia = mediaKind == "photo" || mediaKind == "video"
            || !photoPath.isEmpty || !videoPath.isEmpty

        let publish: ([String]) -> Void = { [weak self] refs in
            guard let self else { return }
            if let body = items["post"], !body.isEmpty {
                self.post(body, media: refs)
                HavenLog.net("matrix-qa post body=\(body.prefix(40)) media=\(refs.map { $0.prefix(12) }.joined(separator: ","))")
            }
            if let body = items["story"], !body.isEmpty {
                if refs.isEmpty {
                    self.post(body, media: [], music: nil, retentionSecs: 86_400, story: true)
                } else {
                    self.postStory(media: refs, caption: body)
                }
                HavenLog.net("matrix-qa story body=\(body.prefix(40)) media=\(refs.map { $0.prefix(12) }.joined(separator: ","))")
            }
            let dmTo = (items["dm_to"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let dmBody = items["dm"] ?? ""
            if dmTo.count == 64, !dmBody.isEmpty {
                self.qaSendDM(to: dmTo, body: dmBody, refs: refs)
            }
            self.qaWriteDump()   // v2 contract: every qa op refreshes qa-dump.json
        }

        if wantsMedia {
            Task { @MainActor in
                let refs = await Self.qaBuildMediaRefs(photoPath: photoPath, videoPath: videoPath, kind: mediaKind)
                if refs.isEmpty {
                    HavenLog.net("matrix-qa media FAILED — no refs from kind=\(mediaKind) photo=\(photoPath.prefix(40)) video=\(videoPath.prefix(40))")
                }
                publish(refs)
            }
        } else {
            publish([])
        }

        let callTo = (items["call_to"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if callTo.count == 64 {
            let name = ContactsStore.shared.name(forNodePrefix: callTo) ?? "Friend"
            CallManager.shared.startCall(peerHex: callTo, name: name)
            HavenLog.net("matrix-qa call to=\(callTo.prefix(8))")
        }
        if items["call_accept"] == "1" || (items["call_accept"] ?? "").lowercased() == "true" {
            CallManager.shared.accept()
            HavenLog.net("matrix-qa call_accept")
        }
        if items["call_hangup"] == "1" || (items["call_hangup"] ?? "").lowercased() == "true" {
            CallManager.shared.endCall()
            HavenLog.net("matrix-qa call_hangup")
        }
    }

    /// Build media refs for matrix QA from paths and/or synthetic fixtures (no camera/picker).
    private static func qaBuildMediaRefs(photoPath: String, videoPath: String, kind: String) async -> [String] {
        var refs: [String] = []
        if !photoPath.isEmpty, let img = PlatformImage(contentsOfFile: photoPath) {
            refs.append(MediaStore.shared.addImage(img))
            HavenLog.net("matrix-qa photo_path → \(refs.last?.prefix(16) ?? "?")")
        } else if kind == "photo" {
            #if os(iOS)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
            let img = renderer.image { ctx in
                UIColor(red: 0.12, green: 0.56, blue: 1.0, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                let s = "HavenQA" as NSString
                s.draw(at: CGPoint(x: 200, y: 220), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 48),
                    .foregroundColor: UIColor.white,
                ])
            }
            refs.append(MediaStore.shared.addImage(img))
            #else
            let img = NSImage(size: NSSize(width: 640, height: 480))
            img.lockFocus()
            NSColor(calibratedRed: 0.12, green: 0.56, blue: 1.0, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 480)).fill()
            img.unlockFocus()
            refs.append(MediaStore.shared.addImage(img))
            #endif
            HavenLog.net("matrix-qa synthetic photo → \(refs.last?.prefix(16) ?? "?")")
        }
        if !videoPath.isEmpty {
            let url = URL(fileURLWithPath: videoPath)
            if FileManager.default.fileExists(atPath: url.path) {
                let bundle = await MediaStore.shared.prepareVideo(url: url)
                if !bundle.isEmpty {
                    refs.append(contentsOf: bundle.mediaRefs)
                    HavenLog.net("matrix-qa video_path → \(bundle.videoRef.prefix(16)) media=\(bundle.mediaRefs.count)")
                } else {
                    HavenLog.net("matrix-qa video_path prepare FAILED \(videoPath.prefix(60))")
                }
            } else {
                HavenLog.net("matrix-qa video_path missing \(videoPath.prefix(60))")
            }
        } else if kind == "video" {
            // Tiny solid-color MP4 written to temp via AVAssetWriter if no fixture path.
            if let url = await Self.qaSyntheticVideoURL() {
                let bundle = await MediaStore.shared.prepareVideo(url: url)
                if !bundle.isEmpty {
                    refs.append(contentsOf: bundle.mediaRefs)
                    HavenLog.net("matrix-qa synthetic video → \(bundle.videoRef.prefix(16))")
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
        return refs
    }

    /// 1s solid-color H.264 clip for matrix video attach when no fixture is staged.
    private static func qaSyntheticVideoURL() async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-qa-\(UUID().uuidString).mp4")
        let size = CGSize(width: 320, height: 240)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        let fps: Int32 = 10
        let frames = 12
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let shade = Int32(0x40 + min(i * 8, 0x80))
                memset(base, shade, CVPixelBufferGetDataSize(buf))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            let t = CMTime(value: CMTimeValue(i), timescale: fps)
            adaptor.append(buf, withPresentationTime: t)
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }

    // MARK: qa-cmd v2 (docs/QA.md) — {"op": …} dispatch + qa-dump.json answer

    /// Full v2 driver contract. Each op rides the SAME code path the UI uses (post/react/…),
    /// then refreshes `qa-dump.json` so the orchestrator can assert on the resulting state.
    private func applyMatrixQaV2(_ obj: [String: Any]) {
        guard let social else {
            HavenLog.net("matrix-qa v2 deferred — social not ready")
            return
        }
        func str(_ k: String) -> String {
            ((obj[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let op = str("op").lowercased()
        let body = str("body")
        HavenLog.net("matrix-qa v2 op=\(op)")

        // Content ops honor an explicit "circle_id": switch the active circle through the same
        // store call the UI's circle picker uses, then author normally. Nothing is restored —
        // the QA fleet doesn't care which circle stays selected. A missing or unknown id keeps
        // current behavior (author into whatever circle is active).
        if ["post", "story", "file", "music_post"].contains(op) {
            let target = str("circle_id")
            if !target.isEmpty {
                if social.circles().contains(where: { $0.id == target }) {
                    setActiveCircle(target)
                } else {
                    HavenLog.net("matrix-qa v2 unknown circle_id=\(target.prefix(24)) — authoring into active")
                }
            }
        }

        switch op {
        #if DEBUG
        case "approve_connections":
            // QA: approve every pending connection request.
            //
            // Nothing in the driver could do this, so a fleet where B reached A's OTHER devices as
            // a stranger simply stopped: Android and desktop sat on an un-approvable "Matrix Stub
            // Host" request forever, and every assertion about B's content on those legs failed for
            // a reason that had nothing to do with the product. An automated suite cannot depend on
            // somebody tapping Approve.
            let reqs = ConnectionsStore.shared.pending
            for r in reqs { approveConnection(r) }
            HavenLog.net("matrix-qa v2 approve_connections: approved \(reqs.count)")
            qaWriteDump()
            return
        case "link_constraint":
            // QA: force the link constraint so the satellite path can be exercised off a satellite.
            // `Ultra` is otherwise unreachable in a simulator — see LowDataMonitor.debugForce.
            let level = str("level").lowercased()
            let forced: LinkConstraint? = level == "ultra" ? .ultra
                : level == "low" ? .low
                : level == "normal" ? .normal
                : nil     // anything else (or "auto") hands control back to the real path monitor
            LowDataMonitor.shared.debugForce(forced)
            qaWriteDump()
            return
        #endif
        case "post", "story", "dm":
            // Media-carrying ops share the async ref build (photo sync, video prepare hops a Task).
            let mediaKind = str("media").lowercased()
            let photoPath = str("photo_path")
            let videoPath = str("video_path")
            let wantsMedia = mediaKind == "photo" || mediaKind == "video"
                || !photoPath.isEmpty || !videoPath.isEmpty
            let finish: ([String]) -> Void = { [weak self] refs in
                guard let self else { return }
                switch op {
                case "post":
                    self.post(body, media: refs)
                case "story":
                    let caption = str("caption").isEmpty ? body : str("caption")
                    if refs.isEmpty {
                        self.post(caption, media: [], music: nil, retentionSecs: 86_400, story: true)
                    } else {
                        self.postStory(media: refs, caption: caption)
                    }
                case "dm":
                    self.qaSendDM(to: str("dm_to").lowercased(), body: body, refs: refs)
                default: break
                }
                self.qaMarkUserActive(mutating: true)
                self.qaWriteDump()
            }
            if wantsMedia {
                Task { @MainActor in
                    let refs = await Self.qaBuildMediaRefs(photoPath: photoPath, videoPath: videoPath, kind: mediaKind)
                    if refs.isEmpty {
                        HavenLog.net("matrix-qa v2 media FAILED — no refs from kind=\(mediaKind)")
                    }
                    finish(refs)
                }
            } else {
                finish([])
            }
            return   // dump written by `finish`

        case "react":
            let target = str("target_id"), emoji = str("emoji")
            if !target.isEmpty, !emoji.isEmpty, let cid = qaFindCircleId(ofEvent: target) {
                reactMessage(in: cid, target, emoji)   // the same reaction path the UI uses
            } else {
                HavenLog.net("matrix-qa v2 react: target not found id=\(target.prefix(16))")
            }

        case "comment":
            let target = str("target_id")
            if !target.isEmpty, !body.isEmpty, let cid = qaFindCircleId(ofEvent: target) {
                commentMessage(in: cid, target, body)
            } else {
                HavenLog.net("matrix-qa v2 comment: target not found id=\(target.prefix(16))")
            }

        case "profile":
            let name = str("name")
            if !name.isEmpty {
                // The real settings path: the didSet persists + stamps the LWW timestamp
                // (self-sync carries it to my other devices), then push my card to contacts.
                ProfileStore.shared.displayName = name
                rebroadcastProfile()
            }

        case "circle_create":
            let name = str("name")
            if !name.isEmpty { createCircle(name: name) }   // same engine call the UI uses

        case "circle_invite":
            let cid = str("circle_id"), hex = str("dm_to").lowercased()
            if !cid.isEmpty, hex.count == 64 {
                // Mirror addContactToActiveCircle for a specific circle: deliberate add lifts
                // any removal tombstone, then greet + back-fill so the circle forms on theirs.
                ConnectionsStore.shared.clearCircleRemoval(hex, circleId: cid)
                social.clearCircleRemoval(circleId: cid, nodeHex: hex)
                try? social.addExistingToCircle(circleId: cid, nodeHex: hex)
                forceHelloNextSync(hex, circleId: cid)   // invite rides the hello — never warm-skip
                persist(); refreshCircles()
                syncWithContacts()
            } else {
                HavenLog.net("matrix-qa v2 circle_invite: bad args circle=\(cid.prefix(24)) hex=\(hex.prefix(8))")
            }

        case "file":
            let path = str("file_path")
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                // Same path the share/file picker takes: zip → `file_` ref → regular post.
                let ref = MediaStore.shared.addFile(url: URL(fileURLWithPath: path))
                if ref.isEmpty { HavenLog.net("matrix-qa v2 file: addFile failed \(path.suffix(40))") }
                else { post(body, media: [ref]) }
            } else {
                HavenLog.net("matrix-qa v2 file: missing \(path.suffix(60))")
            }

        case "music_post":
            let music = obj["music"] as? [String: Any]
            let title = (music?["title"] as? String) ?? ""
            let artist = (music?["artist"] as? String) ?? ""
            // Song-card post path (composer + song picker) — a synthetic catalog id like DemoSeed's.
            post(body, media: [], music: TrackRefFfi(catalogId: "qa-\(title)", title: title, artist: artist,
                                                     artworkUrl: "", durationMs: 0))

        case "mark_read":
            let cid = str("circle_id")
            if !cid.isEmpty {
                DMReadStore.shared.markRead(cid)
            } else {
                for c in social.circles() where c.id.hasPrefix("dm:") { DMReadStore.shared.markRead(c.id) }
            }

        // Call ops. Calls were the one field failure the suite could not reproduce, because it had
        // no way to place or answer one — so "connects but carries no media" shipped twice.
        case "call":
            let peer = str("dm_to").lowercased()
            if peer.count == 64 {
                let name = ContactsStore.shared.name(forNodePrefix: peer) ?? "Friend"
                CallManager.shared.startCall(peerHex: peer, name: name)
            } else {
                HavenLog.net("matrix-qa call: bad dm_to")
            }

        case "call_accept":
            CallManager.shared.accept()

        case "call_end":
            CallManager.shared.endCall()

        case "call_video":
            // Idempotent for QA: only toggle when the current state differs from what was asked.
            let want = str("on") != "false"
            if CallManager.shared.videoOn != want { CallManager.shared.toggleVideo() }

        case "dump":
            break   // the shared dump write below is the whole op

        default:
            HavenLog.net("matrix-qa v2 unknown op=\(op)")
            qaWriteDump()
            return   // not a user action — leave the sync cadence untouched
        }
        // Every recognized op models a user actively using the app; `dump` is the one
        // non-mutating op — it marks activity but must NOT force a poll (see qaMarkUserActive).
        qaMarkUserActive(mutating: op != "dump")
        qaWriteDump()
    }

    /// qa-cmd v2 cadence contract: a qa op represents a user ACTIVELY using the app, so every op
    /// resets the adaptive idle multiplier exactly like the real user-activity/foreground hook
    /// (`bumpActivity`). Mutating ops additionally nudge an immediate mailbox poll — the slim
    /// `pollMailboxNow` path, NOT the full Multipeer `forceSync` — so freshly authored content
    /// uploads now. `dump` deliberately skips the poll: receivers must converge at their real
    /// active-cadence poll, keeping measured convergence latency honest.
    private func qaMarkUserActive(mutating: Bool) {
        bumpActivity()
        if mutating { pollMailboxNow() }
    }

    /// Author a DM (used by both the legacy `dm_to`+`dm` keys and the v2 `dm` op).
    private func qaSendDM(to dmTo: String, body: String, refs: [String]) {
        guard dmTo.count == 64, !body.isEmpty else { return }
        let name = ContactsStore.shared.name(forNodePrefix: dmTo) ?? "Friend"
        let cid = startDM(with: dmTo, name: name)
        // Author into the DM circle only (not the active feed circle).
        if let social,
           let env = try? social.post(circleId: cid, body: body, media: refs, music: nil,
                                      retentionSecs: nil, story: false, muteVideo: false, createdAt: now()) {
            broadcastEvent(cid, env)
            for r in refs { MediaBackupQueue.shared.enqueue(r, circleId: cid, social: social) }
            persist(); refresh()
        }
        HavenLog.net("matrix-qa dm to=\(dmTo.prefix(8)) circle=\(cid.prefix(24)) body=\(body.prefix(40)) media=\(refs.count)")
    }

    /// Which circle holds this post (or comment) id? QA-only scan across every circle's feed —
    /// react/comment targets arrive as bare event ids from another device's dump.
    private func qaFindCircleId(ofEvent target: String) -> String? {
        guard let social, !target.isEmpty else { return nil }
        let nowMs = now()
        for c in social.circles() {
            for item in social.feed(circleId: c.id, nowMs: nowMs, viewerRetentionSecs: nil)
            where item.id == target || item.comments.contains(where: { $0.id == target }) {
                return c.id
            }
        }
        return nil
    }

    /// One circle's worth of dump state, snapshotted off-main via the engine gate.
    private struct QaCircleSnapshot {
        let circle: CircleInfoFfi
        let items: [FeedItemFfi]
        let members: [String]
    }

    /// Stale-write guard: only the newest dump request may land (ops fire back-to-back).
    private var qaDumpGeneration: UInt64 = 0

    /// Write `qa-dump.json` next to the drop file — the v2 contract's answer after every op.
    /// Engine reads (feed() decodes every envelope) happen off-main like `refresh`; the
    /// MainActor-bound bits (MediaStore.has, ProfileStore) assemble + write on main.
    private func qaWriteDump() {
        guard let social else { return }
        qaDumpGeneration &+= 1
        let gen = qaDumpGeneration
        let nowMs = now()
        Task.detached(priority: .utility) { [weak self] in
            let snapshot: [QaCircleSnapshot] = await EngineGate.shared.run {
                social.circles().map { c in
                    QaCircleSnapshot(circle: c,
                                     items: social.feed(circleId: c.id, nowMs: nowMs, viewerRetentionSecs: nil),
                                     members: social.contactNodeIds(circleId: c.id))
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.qaDumpGeneration == gen else { return }
                self.qaWriteDumpFile(snapshot, accountHex: social.myNodeHex(), tsMs: nowMs,
                                     delivery: social.diagDeliveryJson())
            }
        }
    }

    private func qaWriteDumpFile(_ snapshot: [QaCircleSnapshot], accountHex: String, tsMs: UInt64,
                                 delivery: String) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        #if os(iOS)
        let device = "ios"
        #else
        let device = Bundle.main.bundleIdentifier?.contains("qa.stub") == true ? "mac-stub" : "mac"
        #endif
        let me = myNodeHex
        var posts: [(ts: UInt64, row: [String: Any])] = []
        var dms: [String: [[String: Any]]] = [:]
        var circles: [[String: Any]] = []
        for snap in snapshot {
            circles.append(["id": snap.circle.id, "name": snap.circle.name, "members": snap.members])
            if snap.circle.id.hasPrefix("dm:") {
                // DM threads keyed by the peer's full account hex (group DMs fall back to the id body).
                let peer = snap.members.first(where: { $0 != me }) ?? String(snap.circle.id.dropFirst(3))
                var rows = dms[peer] ?? []
                for item in snap.items where !item.unsent {
                    // Fetchable blobs only — `poster:`/`thumb:` markers aren't bytes and must not
                    // be able to fail the orchestrator's media-blob gate (Android realRefs /
                    // desktop media_present already skip them; the stub runs THIS file).
                    let real = item.media.filter { !MediaStore.isSynthetic($0) }
                    rows.append(["id": item.id, "body": item.body,
                                 "media_present": real.map { MediaStore.shared.has($0) }])
                }
                dms[peer] = rows
            } else {
                for item in snap.items where !item.unsent {
                    // Same synthetic-marker filter as the DM rows above: a `poster:`/`thumb:`
                    // marker can never be present, and mapping `has()` over it pinned a video
                    // post's media_present at [true, false, true] forever — the E2E video-blob
                    // gate failed even after the blob demonstrably landed on the relay.
                    let real = item.media.filter { !MediaStore.isSynthetic($0) }
                    posts.append((item.createdAt, [
                        "id": item.id,
                        "body": item.body,
                        "circle": snap.circle.id,
                        "story": item.story,
                        "caption": item.story ? item.body : NSNull(),
                        "media_refs": real,
                        "media_present": real.map { MediaStore.shared.has($0) },
                        // Companion MARKERS (`preview:`/`thumb:`/`poster:`/`orig:`) and whether the
                        // blobs they name are here.
                        //
                        // `real` above deliberately drops synthetic refs, and the bare companion ref
                        // is never listed in a post's media either — so without this a preview is
                        // invisible to QA even when it exists, is stored, and is on the wire. The
                        // satellite assertions were checking for something the dump could not
                        // report, which is a test that cannot pass rather than a product that
                        // cannot work.
                        "media_markers": item.media.filter { MediaStore.isSynthetic($0) },
                        "companions_present": Dictionary(
                            uniqueKeysWithValues: item.media.compactMap { m -> (String, Bool)? in
                                let companion = MediaVariants.parsePreview(m)?.preview
                                    ?? MediaVariants.parseThumb(m)?.thumb
                                    ?? MediaVariants.parsePoster(m)?.poster
                                    ?? MediaVariants.parseOriginal(m)?.original
                                guard let companion else { return nil }
                                return (companion, MediaStore.shared.has(companion))
                            }),
                        "reactions": Dictionary(item.reactions.map { ($0.emoji, Int($0.count)) }, uniquingKeysWith: +),
                        "comments": item.comments.filter { !$0.unsent }.map { ["id": $0.id, "body": $0.body] },
                    ]))
                }
            }
        }
        let dump: [String: Any] = [
            "device": device,
            "account_hex": accountHex,
            "ts_ms": tsMs,
            "posts": posts.sorted { $0.ts > $1.ts }.prefix(100).map { $0.row },   // newest 100
            "dms": dms,
            "profile": ["name": ProfileStore.shared.displayName],
            "circles": circles,
            // Call state, including inbound RTP byte counters. "connected" is NOT evidence a call
            // works — the field failure was both sides connected with zero audio either way — so QA
            // asserts on bytes actually received (CallManager.qaMediaSnapshot, refreshed per dump).
            "call": CallManager.shared.qaSnapshot(),
            // What the engine is HOLDING BACK: parked (received-but-unopenable) envelopes per
            // circle, plus the rosters we know. A short feed alone cannot tell "never arrived" from
            // "arrived and could not be opened", and the two have opposite fixes.
            "delivery": (try? JSONSerialization.jsonObject(with: Data(delivery.utf8))) ?? [:],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dump, options: [.sortedKeys]) else {
            HavenLog.net("matrix-qa dump: JSON encode failed")
            return
        }
        try? data.write(to: dir.appendingPathComponent("qa-dump.json"), options: .atomic)
        HavenLog.net("matrix-qa dump written posts=\(min(posts.count, 100)) dms=\(dms.count) circles=\(circles.count)")
    }
    #endif

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// Matrix QA: ingest `qa-peer-bundle.bin` from Application Support (Android peer staged by driver).
    private func ingestQaPeerBundle() {
        #if DEBUG
        guard let social else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url = dir?.appendingPathComponent("qa-peer-bundle.bin"),
              let bundle = try? Data(contentsOf: url), !bundle.isEmpty else { return }
        let name = (try? String(contentsOf: dir!.appendingPathComponent("qa-peer-name.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "EmuPeer"
        do {
            let hex = try social.addContactBundle(circleId: "default", bundle: bundle)
            HavenLog.net("qa-peer-bundle ingested hex=\(hex.prefix(12)) name=\(name)")
            try? FileManager.default.removeItem(at: url)
            Task { await SharedStore.publishDeviceRoster(social: social) }
            scheduleRefresh()
        } catch {
            HavenLog.net("qa-peer-bundle ingest FAILED \(error.localizedDescription)")
        }
        #endif
    }

    /// Stale-result guard for the off-main feed rebuild: only the newest refresh may publish.
    private var refreshGeneration: UInt64 = 0
    func refresh() {
        guard let social else { items = []; return }
        // While a bulk import runs, rebuild SLOWLY — but do rebuild.
        //
        // This used to return outright, which was wrong in the worst way: on a fresh account the
        // feed starts empty, so "freeze the list" meant the Circle and You tabs stayed blank for
        // the entire import and the app looked broken. Never seeing your posts arrive is worse
        // than the list moving occasionally.
        //
        // The floor is now about CPU, not about jumping. `refresh()` re-opens every envelope in the
        // circle, so doing it per imported post is genuinely expensive — but it was never what moved
        // the content under the reader. That was cards CHANGING HEIGHT as their media arrived (see
        // MediaAspectStore and postSingleAspect), which throttling could only make less frequent,
        // never fix. With heights stable, this can be tight enough that posts appear as they land.
        if InstagramImporter.shared.isRunning {
            let now = Date().timeIntervalSince1970
            guard now - lastImportRefreshAt > 2 else { return }
            lastImportRefreshAt = now
        }
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
            // One feed rebuild at a time (and not concurrent with mailbox receive / exportState).
            let (raw, members): ([FeedItemFfi], [String]) = await EngineGate.shared.run {
                let r = social.feed(circleId: circleId, nowMs: nowMs, viewerRetentionSecs: retention)
                let m = social.contactNodeIds(circleId: circleId)
                return (r, m)
            }
            // Hide posts from blocked people and from anyone no longer in this circle (removed
            // members), so a removal actually clears their content. My own posts always stay.
            // Prefix-matching because a feed item carries the author's short id.
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
                // Warm the messages cache for the active circle so chat/feed siblings skip a cold feed().
                self.messagesCache[circleId] = (self.now(), raw)
                // Only republish when the content ACTUALLY changed. A refresh triggered incidentally during
                // a scroll (media backfill, a poster landing, a periodic tick) usually produces an identical
                // list; assigning it anyway re-diffs the LazyVStack and nudged the scroll offset — the
                // "position jumps around before settling" on fast flings.
                // DEDUPE BY ID before publishing.
                //
                // The feed's ForEach is keyed `id: \.id`. A duplicate id makes SwiftUI build the row
                // TWICE, and two live PostCards for one post each own their own `players` dict — so
                // the same clip gets two AVPlayers, two hardware decode sessions, audio playing over
                // itself slightly offset (the "static sounding" doubling), and a mute toggle that can
                // only ever reach one of them. It also doubles that post's layout and image decode,
                // which is heat with no CPU hotspot — matching a phone that stays warm in AIRPLANE
                // MODE.
                //
                // Logged when it fires, because a duplicate id coming out of the engine's feed() is
                // itself a bug worth chasing upstream; this keeps the UI honest meanwhile.
                var seenPostIds = Set<String>()
                let deduped = filtered.filter { seenPostIds.insert($0.id).inserted }
                if deduped.count != filtered.count {
                    HavenLog.sync("feed: DROPPED \(filtered.count - deduped.count) duplicate post id(s) of \(filtered.count)")
                }
                if self.items != deduped { self.items = deduped }
                if self.hiddenInActiveCircle != hiddenHere { self.hiddenInActiveCircle = hiddenHere }
                // First refresh that produced anything: repair an account that was imported into
                // twice, without being asked. Guarded to once per launch, and a no-op when there is
                // nothing duplicated — see `sweepDuplicateImports`.
                self.sweepDuplicateImportsOnce()
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
    /// Last feed rebuild performed while an import was running — see the throttle in `refresh`.
    private var lastImportRefreshAt: TimeInterval = 0
    /// Id of the most recent imported post, so a deferred song credit can be attached to it.
    private(set) var lastImportedPostId: String?

    /// The final rebuild once an import stops writing, with everything in place.
    func importFinished() {
        refreshPending = false
        lastImportRefreshAt = 0   // the throttle must not swallow the last one
        refresh()
        sweepDuplicateImports()
    }

    /// Whether this launch has already swept — the duplicates are historical, so once is enough.
    private var sweptDuplicates = false

    /// Unsend posts this device authored more than once, keeping one of each.
    ///
    /// The importer is idempotent NOW — it records every archive item it publishes and skips what it
    /// has already done — but that arrived after an archive had already been imported twice, and
    /// nothing about the ledger removes the copies already sitting in the feed. Asking someone to
    /// delete two hundred posts by hand is not a fix.
    ///
    /// THE KEY IS CAPTURE TIME + CAPTION + HOW MANY ITEMS, **NOT MEDIA REFS**.
    ///
    /// My first attempt keyed on the media refs, reasoning that a ref is a sha-256 of the bytes so
    /// two posts sharing one carry the identical picture. That is true and it is useless here: the
    /// importer RE-ENCODES everything it stages (`forceOptimize`), and re-encoding is not
    /// reproducible. A video goes through AVAssetExportSession, which stamps its own timestamps, and
    /// every clip gets a freshly generated poster still. The second import therefore mints DIFFERENT
    /// refs for the same photo, the signatures never matched, and the sweep quietly found nothing —
    /// it "ran" perfectly and did nothing at all.
    ///
    /// What survives re-import unchanged is what came out of the ARCHIVE: the capture time, which is
    /// backdated from the export and identical on every run, and the caption, which is copied
    /// verbatim. Item count separates a single photo from a carousel that happens to share a second.
    ///
    /// Captions are compared after normalising whitespace and case — the same text through two
    /// import runs is byte-identical, so this is not fuzzy matching, just insensitivity to the ways
    /// the same string can be spelled. Deliberately NOT a similarity score: two posts from the same
    /// day with similar captions are two posts, and a threshold that merges them destroys content.
    ///
    /// Residual risk, stated plainly: Instagram exports capture times in SECONDS, so two genuinely
    /// different posts made in the same second, with the same caption, carrying the same number of
    /// items, would be treated as one. Text-only posts are excluded for the same reason — with no
    /// media the key is weakest exactly where a repeat is most likely deliberate ("gm" twice).
    ///
    /// Unsend, not a local hide: the duplicates went out to the circle, so they have to be withdrawn
    /// from it. That is what `unsend` is for, and members already handle the event.
    @discardableResult
    func sweepDuplicateImports() -> Int {
        // Oldest first, so the copy that has been in the circle longest is the one that stays and
        // the later re-import is what gets withdrawn.
        let candidates = items
            .filter { $0.isMe && !$0.unsent && !$0.story }
            .sorted { $0.createdAt < $1.createdAt }
            .map { item -> PostDedupe.Candidate in
                let refs = MediaVariants.displayRefs(item.media)
                // The 64px thumbnail, PEEKED only — never decoded here. A dHash is computed from a
                // 9x8 downsample, so the tiniest cached bitmap is already more detail than it needs,
                // and forcing a decode per post would put hundreds of them on the main thread at the
                // exact moment the feed is being built. A miss simply leaves the hash unknown and the
                // caption decides, which is the pre-visual behaviour.
                //
                // EVERY ref is tried, not just the first, and a video's POSTER stands in for it.
                // Looking only at `refs.first` meant a reel — whose first display ref is the clip,
                // which has no thumbnail of its own — never got a hash at all, so exactly the posts
                // an Instagram archive is full of fell back to comparing captions, and imported
                // captions are frequently empty. The poster is a real image sitting in the same
                // cache; ask for it.
                let hash = refs.lazy.compactMap { ref -> UInt64? in
                    let imageRef = MediaVariants.poster(for: ref, in: item.media) ?? ref
                    return MediaStore.shared.cachedThumbnail(imageRef, maxDimension: 64)
                        .flatMap { $0.cgImage }
                        .flatMap { PerceptualHash.dHash($0) }
                }.first
                return PostDedupe.Candidate(id: item.id, createdAt: item.createdAt, body: item.body,
                                            mediaCount: refs.count, mediaHash: hash)
            }
        let doomed = PostDedupe.duplicates(candidates)
        guard !doomed.isEmpty else {
            HavenLog.sync("dedupe: nothing duplicated across \(candidates.count) of my posts")
            return 0
        }
        HavenLog.sync("dedupe: withdrawing \(doomed.count) duplicate posts of \(candidates.count)")
        for id in doomed { unsend(id) }
        refresh()
        return doomed.count
    }

    /// Once per launch, after the feed actually has something to look at. Cheap when there is
    /// nothing to do — one pass over the items already in memory — so it costs a normal launch
    /// nothing and repairs an account that was imported into twice without being asked.
    func sweepDuplicateImportsOnce() {
        guard !sweptDuplicates, !items.isEmpty else { return }
        sweptDuplicates = true
        sweepDuplicateImports()
    }

    func scheduleRefresh(after seconds: Double = 0.25) {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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

    /// Expand a compose-time media list with `thumb:` pairing markers for photos whose tiny
    /// companion was minted at attach time (MediaStore.addImage). The marker joins the SIGNED
    /// list — same pattern as `poster:` — so old clients simply ignore it. The bare thumb ref is
    /// deliberately NOT listed: receivers learn it from the marker, so a legacy carousel never
    /// shows a duplicate tiny slide.
    private func withThumbMarkers(_ media: [String]) -> [String] {
        var out = media
        for ref in media where ref.hasPrefix("img_") {
            guard MediaVariants.thumb(for: ref, in: media) == nil,
                  let t = MediaStore.shared.thumbCompanion(ref), MediaStore.shared.has(t) else { continue }
            out.append(MediaVariants.thumbMarker(content: ref, thumb: t))
        }
        return out
    }

    /// Expand a compose-time media list with `preview:` markers for photos whose 512px AVIF was
    /// minted at attach time (`MediaStore.mintPreviewCompanion`).
    ///
    /// Same shape and the same reasoning as `withThumbMarkers`: the marker joins the SIGNED list so
    /// old clients ignore it, and the bare preview ref is deliberately NOT listed so a legacy
    /// carousel never shows a duplicate slide. This is what makes a photo sendable off-grid at all
    /// (`docs/PREVIEW-TIER-DESIGN.md` §4.1) — without the marker there is nothing small enough to
    /// cross, and the post arrives as text with a placeholder.
    private func withPreviewMarkers(_ media: [String]) -> [String] {
        var out = media
        for ref in media where ref.hasPrefix("img_") {
            guard MediaVariants.preview(for: ref, in: media) == nil,
                  let p = MediaStore.shared.previewCompanion(ref), MediaStore.shared.has(p) else { continue }
            out.append(MediaVariants.previewMarker(content: ref, preview: p))
        }
        return out
    }

    /// Queue a just-authored event's media for relay backup: PRIORITY lane (ahead of any backfill
    /// backlog), thumbs first, then posters, then content — so the placeholder-feeding bytes land
    /// before the big blobs start.
    private func enqueueAuthoredMedia(_ media: [String], circleId: String, social: HavenSocial) {
        // PREVIEWS FIRST, and explicitly — `uploadOrder` can only rank refs that are IN `media`, and
        // the bare preview ref never is: a post lists the `preview:` MARKER and not the companion.
        // So the preview was never enqueued for upload at all, and the one blob that must cross a
        // satellite link was the one blob that never left. Android enqueues them explicitly for the
        // same reason; iOS did not, which is exactly why android→ delivered a preview and ios→ did
        // not, to the same stub.
        for ref in MediaVariants.allPreviews(in: media) + MediaVariants.allThumbs(in: media)
            + MediaVariants.uploadOrder(media) {
            MediaBackupQueue.shared.enqueue(ref, circleId: circleId, social: social, priority: true)
        }
    }

    func post(_ body: String, media rawMedia: [String] = [], music: TrackRefFfi? = nil, retentionSecs: UInt64? = nil, story: Bool = false, muteVideo: Bool = false) {
        let media = withPreviewMarkers(withThumbMarkers(rawMedia))
        let ts = now()
        guard let social, let env = try? social.post(circleId: activeCircleId, body: body, media: media, music: music, retentionSecs: retentionSecs, story: story, muteVideo: muteVideo, createdAt: ts) else { return }
        let cid = activeCircleId
        let name = circles.first(where: { $0.id == cid })?.name ?? "your circle"
        // Read back the engine-derived id of the post just authored so the sealed banner carries `p`
        // (exact tap route on the recipient). Best-effort — nil keeps the legacy circle route.
        let postId = social.lastAuthoredEventId(circleId: cid, createdAt: ts)
        broadcastEvent(cid, env, banner: .forPost(circleId: cid, circleName: name, body: body, media: media, story: story, postId: postId))
        postTick += 1; publishedPostCount += 1; refresh()
        enqueueAuthoredMedia(media, circleId: cid, social: social)
        if !media.isEmpty {
            Task { await SharedStore.publishDeviceRoster(social: social) }
            if RelayHost.shared.serving { reannounceOwnRelay() }
        }
    }

    /// Attach an identified song CREDIT to a post that already published.
    ///
    /// Identification is slow and frequently refused, so a credit often arrives long after the post
    /// did. Re-emitting the post as an edit is how it catches up — the same mechanism the
    /// re-optimize pass uses, and silent for the same reason: re-pointing an existing post at a
    /// song nobody wrote is not news.
    func attachSongCredit(postId: String, circleId: String, track: TrackRefFfi) {
        guard let social, let item = items.first(where: { $0.id == postId }) else { return }
        guard item.music == nil else { return }   // don't stomp a song already there
        guard let env = try? social.edit(circleId: circleId, target: postId, body: item.body,
                                         media: item.media, music: track,
                                         muteVideo: item.muteVideo, createdAt: now()) else { return }
        broadcastEvent(circleId, env, silent: true)
        scheduleRefresh()
    }

    /// Author a post that came from an ARCHIVE IMPORT (Instagram et al) — silent by construction.
    ///
    /// An import republishes a whole back-catalogue at once: a 900-post Instagram archive would fire
    /// 900 lock-screen banners at every member of the circle. That is the one case where the content
    /// is genuinely not news — the member is not being told something happened just now, the owner is
    /// backfilling history that is often years old. So this takes NO `banner` and goes out over
    /// `broadcastEvent(silent:)`: the event still delivers, still syncs, still reaches offline members
    /// through the mailbox — only the banner is suppressed (see `broadcastEvent`).
    ///
    /// Deliberately a SEPARATE entry point rather than a `silent:` flag on `post`: silence is a
    /// property of importing, not a mode the user can leave switched on. No normal authoring path can
    /// reach it, so there is no way to accidentally publish real news without notifying anyone.
    ///
    /// `createdAt` is the ORIGINAL capture time in ms (Instagram exports seconds — multiply). The feed
    /// orders by it, so backdating is what makes an imported archive slot into history instead of
    /// landing in a heap at today's date.
    func postImported(circleId: String, body: String, media rawMedia: [String],
                      music: TrackRefFfi? = nil, story: Bool = false, createdAt: UInt64) {
        let media = withPreviewMarkers(withThumbMarkers(rawMedia))
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: media,
                                                     music: music, retentionSecs: nil, story: story,
                                                     muteVideo: false, createdAt: createdAt) else { return }
        // The engine derives ids at author time; read it back so a deferred song credit can find
        // this exact post later (see ShazamRetryQueue).
        lastImportedPostId = social.lastAuthoredEventId(circleId: circleId, createdAt: createdAt)
        broadcastEvent(circleId, env, silent: true)
        postTick += 1; publishedPostCount += 1
        // Deliberately does NOT schedule a refresh. The slow floor in `refresh()` governs how
        // often the feed rebuilds during an import; asking per post is what made it thrash.
        //
        // Coalescing this to every few seconds was still wrong. Any rebuild replaces the whole
        // items array and re-diffs the list, and a LazyVStack re-measuring rows it had recycled
        // shifts the scroll offset — so the page kept lurching under the reader no matter how
        // rarely it happened. There is also nothing to be gained by streaming them in: these are
        // backdated history posts landing at the BOTTOM of a newest-first feed, where nobody is
        // watching them arrive.
        //
        // The banner reports progress; the feed updates once, when the import finishes.
        enqueueAuthoredMedia(media, circleId: circleId, social: social)
        if !media.isEmpty {
            Task { await SharedStore.publishDeviceRoster(social: social) }
            if RelayHost.shared.serving { reannounceOwnRelay() }
        }
    }

    /// Post to a SPECIFIC circle (used by the scheduler when a queued post fires — the target
    /// circle may not be the active one). Same seal → broadcast → mailbox-backup path as `post`.
    func postScheduled(circleId: String, body: String, media rawMedia: [String]) {
        let media = withPreviewMarkers(withThumbMarkers(rawMedia))
        let ts = now()
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: media, music: nil, retentionSecs: nil, story: false, muteVideo: false, createdAt: ts) else { return }
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        let postId = social.lastAuthoredEventId(circleId: circleId, createdAt: ts)   // best-effort `p` tag (see `post`)
        broadcastEvent(circleId, env, banner: .forPost(circleId: circleId, circleName: name, body: body, media: media, story: false, postId: postId))
        postTick += 1
        if circleId == activeCircleId { refresh() }
        enqueueAuthoredMedia(media, circleId: circleId, social: social)
    }

    /// Post text to a specific circle (used by App Intents with a circle filter).
    func post(_ body: String, toCircle circleId: String) {
        let ts = now()
        guard let social, let env = try? social.post(circleId: circleId, body: body, media: [], music: nil, retentionSecs: nil, story: false, muteVideo: false, createdAt: ts) else { return }
        let name = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        let postId = social.lastAuthoredEventId(circleId: circleId, createdAt: ts)   // best-effort `p` tag (see `post`)
        broadcastEvent(circleId, env, banner: .forPost(circleId: circleId, circleName: name, body: body, media: [], story: false, postId: postId))
        postTick += 1; refresh()
    }

    /// Post a full-screen story to the active circle — auto-expires after 24h (retention).
    /// Stories can carry a caption (the post body) and a song (played in the viewer).
    ///
    /// A VIDEO story must ship its poster still, exactly like video anywhere else. The story picker
    /// hands us one playable ref (StoryDraft's refs are separate CLIPS, each its own story), so the
    /// companions have to be re-attached HERE or the published event is a bare video ref:
    ///
    ///   * the receiver has nothing to draw until the ENTIRE clip lands — a "Downloading story…"
    ///     spinner where a still should be, for as long as the transfer takes;
    ///   * `enqueueAuthoredMedia` uploads thumbs and posters ahead of big blobs precisely so the
    ///     placeholder-feeding bytes arrive first, and with no poster there are none;
    ///   * `dataSaverPrefetchRefs` skips full videos by contract and falls back to the declared
    ///     poster — with neither, super data saver prefetches NOTHING for that story.
    ///
    /// `withPosterCompanions` is the same helper the camera path uses, and it is idempotent: a ref
    /// that already declares a poster passes through untouched, and non-video refs are left alone.
    func postStory(media: [String], caption: String = "", music: TrackRefFfi? = nil) {
        post(caption, media: CameraView.withPosterCompanions(media), music: music,
             retentionSecs: 86_400, story: true)
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
    /// Media on `postId` that has NOT arrived on this device yet, excluding the companions that are
    /// not meant to be shown on their own. Used to decide whether an interaction happened against an
    /// incomplete post.
    private func missingMediaFor(_ postId: String) -> [String] {
        guard let item = items.first(where: { $0.id == postId }) else { return [] }
        return MediaVariants.displayRefs(item.media).filter { ref in
            !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref)
        }
    }

    /// Record that this device engaged with a post whose pictures had not all arrived, so it can be
    /// told when they do.
    private func noteInterestIfIncomplete(_ postId: String) {
        let missing = missingMediaFor(postId)
        guard !missing.isEmpty else { return }
        let cid = activeCircleId
        let name = circles.first(where: { $0.id == cid })?.name ?? "your circle"
        IncompleteInterestStore.shared.note(missing: missing, postId: postId, circleId: cid, circleName: name)
    }

    func comment(_ id: String, _ body: String, _ media: [String] = []) {
        guard let social, let env = try? social.comment(circleId: activeCircleId, target: id, body: body, media: media, createdAt: now()) else { return }
        let cid = activeCircleId
        let name = circles.first(where: { $0.id == cid })?.name ?? "your circle"
        broadcastEvent(cid, env, banner: .forComment(body: body, circleId: cid, circleName: name, postId: id))
        noteInterestIfIncomplete(id)
        refresh()
    }
    func react(_ id: String, _ emoji: String) {
        guard let social, let env = try? social.react(circleId: activeCircleId, target: id, emoji: emoji, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env, banner: .forReaction(emoji: emoji, circleId: activeCircleId, postId: id))
        noteInterestIfIncomplete(id)
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
        broadcastEvent(circleId, env, banner: .forReaction(emoji: emoji, circleId: circleId, postId: id))
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
        broadcastEvent(circleId, env, banner: .forComment(body: body, circleId: circleId, circleName: name, postId: id)); refresh()
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
    func edit(_ id: String, _ body: String, media rawMedia: [String] = [], music: TrackRefFfi? = nil, muteVideo: Bool = false) {
        let media = withPreviewMarkers(withThumbMarkers(rawMedia))
        guard let social, let env = try? social.edit(circleId: activeCircleId, target: id, body: body, media: media, music: music, muteVideo: muteVideo, createdAt: now()) else { return }
        let cid = activeCircleId
        let name = circles.first(where: { $0.id == cid })?.name ?? "your circle"
        broadcastEvent(cid, env, banner: .forEdit(circleId: cid, circleName: name, postId: id)); refresh()
        enqueueAuthoredMedia(media, circleId: cid, social: social)
    }
    func unsend(_ id: String) {
        guard let social, let env = try? social.unsend(circleId: activeCircleId, target: id, createdAt: now()) else { return }
        broadcastEvent(activeCircleId, env, banner: .forUnsend(circleId: activeCircleId, postId: id)); refresh()
    }

    // MARK: - Wire protocol  [type][payload]: 0 Hello, 1 Event, 3 MediaReq, 5 MediaChunk
    //   Hello payload = [LP circleId][LP circleName][LP bundle][signed profile]
    //   Event payload = [LP circleId][sealed envelope]

    /// On add / online / timer: for every circle, send each member our Hello + that
    /// circle's posts, so the circle forms on their side and back-fills.
    private var lastHistoryResendMs: UInt64 = 0
    private var lastMediaBackfillMs: UInt64 = 0
    /// Sealed full-history bundles per circle. The periodic re-send re-seals EVERY event
    /// (`syncEnvelopes` — real crypto per envelope), yet between re-sends most circles haven't
    /// changed at all. Keyed by a per-circle change GENERATION bumped on every authored event,
    /// ingest, and key commit — the app-visible proxy for (epoch, eventCount, headId) — so an
    /// unchanged circle re-sends its cached bytes instead of re-sealing its whole history.
    private var syncBundleCache: [String: (gen: UInt64, envs: [Data])] = [:]
    private var syncBundleGen: [String: UInt64] = [:]
    /// Something changed in `circleId` (post/edit/unsend, ingested envelope, epoch commit) — the
    /// next history re-send must re-seal it.
    private func invalidateSyncBundle(_ circleId: String) {
        syncBundleGen[circleId, default: 0] += 1
        syncBundleCache.removeValue(forKey: circleId)
    }
    /// Generation each target last got a circle's FULL history blast at ("cid|nodehex" → gen), and
    /// the generation each circle's bundle was last mailbox-uploaded at. The b344 gen-cache made an
    /// unchanged circle cheap to RE-SEAL — but the bytes still went out every cycle, and every
    /// RECEIVER paid a full unseal-to-dedupe pass per envelope every few minutes, forever (the
    /// standing all-devices CPU/heat storm; the receiver-side hash skip in `receive` is the other
    /// half of this fix). Send the blast only when the circle changed since THAT target last got
    /// it, or when a target is new this session. Session-scoped: a restart re-blasts once, and
    /// offline/gappy peers were never served by this path anyway — the mailbox covers them.
    private var historyBlastGen: [String: UInt64] = [:]
    private var historyUploadGen: [String: UInt64] = [:]
    /// Last own-device catch-up sweep. Throttled hard (5 min): it re-seals every envelope it sends,
    /// so it must not ride the 20s sync tick. See the sweep for why it exists.
    private var lastOwnDeviceCatchupMs: UInt64 = 0
    /// Last seen-set wipe per circle (the key-commit re-open). One wipe per circle per 10 min —
    /// the backstop that keeps any future "receive reported a change" bug from turning the poll
    /// loop into an unbounded re-ingest storm (the 16.8 GB Mac incident).
    private var lastSeenWipeMs: [String: UInt64] = [:]
    /// Circles owed a re-open seen-wipe once their mailbox backlog finishes draining (a wipe
    /// mid-drain resets the drain — see the guard in pullMailbox's unlockedCircles block).
    private var pendingReopenCircles: Set<String> = []
    /// Coalesce window for the contact fan-out. The 30s heartbeat + 60s due-gate in startSyncTimer
    /// were the "primary device-heat fix", but they only govern the TIMER — and syncWithContacts has
    /// a dozen event-driven callers (a relay learned, a fabric rebind, a member change) that call it
    /// directly and bypass the gate entirely.
    ///
    /// Measured on a real iPhone, steady state, 60s window: 36 fan-outs for a single DM circle (one
    /// every 1.7s), ~180 putHello calls that dropped as "no due relays", and 289 of 300 log lines
    /// were this one subsystem. Each run walks EVERY circle and every account in it, so one trigger
    /// costs a burst — and the phone was warm doing nothing else. Whatever re-arms the callers, the
    /// fan-out itself must not run at that rate.
    ///
    /// A floor here fixes it wherever the trigger lives. User-visible work still passes force: an
    /// invite, an accepted request, or a new member greets immediately; the forced hello also rides
    /// `pendingForcedHellos`, which survives a coalesced call and ships on the next run.
    #if os(iOS)
    private static let syncContactsFloorMs: UInt64 = 20_000
    #else
    private static let syncContactsFloorMs: UInt64 = 10_000
    #endif
    private var lastSyncContactsMs: UInt64 = 0

    func syncWithContacts(force: Bool = false) {
        #if os(iOS)
        // Pocketed: never fan hello/roster. Event-driven callers (relay learned, fabric rebind,
        // member change) used to bypass the timer gate and keep the radio warm under a leftover
        // background assertion — same battery symptom as the timer heartbeats. User-forced
        // (force: true from Connect UI) is only reachable while frontmost.
        if !appIsForeground && !force { return }
        #endif
        let nowMsFloor = now()
        if !force, lastSyncContactsMs != 0,
           nowMsFloor &- lastSyncContactsMs < Self.syncContactsFloorMs {
            return   // coalesced — a caller fired again inside the floor
        }
        lastSyncContactsMs = nowMsFloor
        syncWithContactsNow()
    }

    private func syncWithContactsNow() {
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
        // ~3 min at the tight cadence, stretching with the SAME idle/thermal multiplier as the
        // sync base — an idle phone re-sealing + re-blasting full history every flat 3 min was a
        // straight heat source with nobody new to catch up.
        let resendHistory = nowMs - lastHistoryResendMs > adaptiveInterval(base: 180_000)
        // When the app is open but quiet, skip keep-alive hello/roster to peers we heard from
        // recently. Real posts still go out via broadcastEvent; mailbox/poll covers the offline case.
        // Without this, every sync tick redials every warm peer (iroh path discovery / radio heat).
        // 30s idle (was 60s): warm peers don't need hello storms while you're just reading the feed.
        let skipWarmKeepalives = (nowMs &- lastActivityMs) > 30_000
        // syncEnvelopes RE-SEALS every one of my events — expensive. Used to run on main for every
        // circle on the 3-min resend path and beachball the Mac host under concurrent mailbox work.
        // Snapshot circle ids; seal off-main; hop back only to send.
        if resendHistory {
            lastHistoryResendMs = nowMs
            let circleSnap = circles.map { ($0.id, $0.name) }
            // Re-seal ONLY circles whose change generation moved since their last seal; the rest
            // re-send their cached bundle bytes (siblings dedupe, so identical bytes are fine).
            var cachedBundles: [(String, [Data])] = []
            var toSeal: [(cid: String, gen: UInt64)] = []
            var genSnap: [String: UInt64] = [:]
            for (cid, _) in circleSnap {
                let gen = syncBundleGen[cid] ?? 0
                genSnap[cid] = gen
                if let hit = syncBundleCache[cid], hit.gen == gen {
                    cachedBundles.append((cid, hit.envs))
                } else {
                    toSeal.append((cid: cid, gen: gen))
                }
            }
            Task.detached(priority: .utility) { [weak self, social] in
                let freshSealed: [(cid: String, gen: UInt64, envs: [Data])] = await EngineGate.shared.run {
                    toSeal.map { ($0.cid, $0.gen, social.syncEnvelopes(circleId: $0.cid)) }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for s in freshSealed {
                        // Cache only if the circle didn't change while sealing, and keep it bounded
                        // (history envelopes are small event JSON, but a huge circle stays uncached).
                        let bytes = s.envs.reduce(0) { $0 + $1.count }
                        if (self.syncBundleGen[s.cid] ?? 0) == s.gen, bytes < 8 * 1024 * 1024 {
                            self.syncBundleCache[s.cid] = (gen: s.gen, envs: s.envs)
                        }
                    }
                    let sealed = freshSealed.map { ($0.cid, $0.gen, $0.envs) }
                        + cachedBundles.map { ($0.0, genSnap[$0.0] ?? 0, $0.1) }
                    for (cid, gen, envs) in sealed where !envs.isEmpty {
                        var targets = Set(self.dialTargets(cid))
                        if cid == "default" {
                            for c in ContactsStore.shared.contacts { targets.insert(c.idHex) }
                        }
                        // Circle history goes to the circle's mailbox, unconditionally. The
                        // per-recipient consent gate that used to stand here is gone with the
                        // choice that fed it (see `approveConnection`): one shared mailbox holds a
                        // single copy that every current member's epoch key opens, so it could
                        // never express a per-contact decision — it only ever withheld backfill
                        // from members who were entitled to it, while the relay went on serving
                        // everything already published to everyone.
                        if self.historyUploadGen[cid] != gen {
                            self.historyUploadGen[cid] = gen
                            for env in envs {
                                Task { await SharedStore.uploadEvent(circleId: cid, env: env) }
                            }
                        }
                        for nodeHex in targets {
                            // Unchanged since this target's last blast → nothing to teach them.
                            let blastKey = cid + "|" + nodeHex.lowercased()
                            guard self.historyBlastGen[blastKey] != gen else { continue }
                            self.historyBlastGen[blastKey] = gen
                            for env in envs {
                                self.sendIroh(1, self.eventPayload(cid, env), to: nodeHex)
                            }
                        }
                    }
                }
            }
        }
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            // The default circle bootstraps with ALL QR contacts (newly-added ones aren't
            // members yet — this is how we get their bundle). Other circles target members.
            var targets = Set(dialTargets(circle.id))   // account id (handle) + device ids (actual reach)
            if circle.id == "default" {
                for c in ContactsStore.shared.contacts { targets.insert(c.idHex) }
            }
            let meHex = social.myNodeHex()
            for nodeHex in targets {
                if skipWarmKeepalives, recentlyHeard(nodeHex, withinMs: 120_000, nowMs: nowMs) {
                    continue
                }
                sendIroh(0, hello, to: nodeHex)
                if !rosterWire.isEmpty { sendIroh(27, rosterWire, to: nodeHex) }   // announce my device roster
            }
            // HTTP mailbox HELLO when iroh cannot dial (matrix stub / cross-NAT) — addressed by the
            // member's ACCOUNT hex ONLY, never a dial target. A device id in the slot pins the
            // hello to whatever transport id we happened to hold; a stale/rotated one is a dead
            // slot nobody ever claims, and the circle invite riding the hello silently vanishes
            // (the lost-invite bug). Device ids stay exactly what they are: iroh DIAL targets
            // (the loop above). The account hex is the stable handle every fleet claims.
            var helloAccounts = Set(social.contactNodeIds(circleId: circle.id).map { $0.lowercased() })
            if circle.id == "default" {
                for c in ContactsStore.shared.contacts { helloAccounts.insert(c.idHex.lowercased()) }
            }
            helloAccounts.remove(meHex.lowercased())
            if !helloAccounts.isEmpty {
                // Full id: `prefix(20)` truncated DM ids (`dm:<a>-<b>`) to exactly the shared first party,
                // so distinct circles printed identically and a log read as duplicated work that was not.
                HavenLog.net("hello fan-out circle=\(circle.id) accounts=\(helloAccounts.count) forced=\(pendingForcedHellos.count)")
            }
            for acct in helloAccounts {
                // A just-invited member must get the hello NOW — it carries the circle grant,
                // and a member who greeted us seconds ago stays "warm" for as long as they
                // keep talking, so the warm skip alone can defer an invite indefinitely
                // (relay-only peers have no other lane).
                let forcedKey = "\(acct)|\(circle.id)"
                let forced = pendingForcedHellos.contains(forcedKey)
                if !forced, skipWarmKeepalives, recentlyHeard(acct, withinMs: 120_000, nowMs: nowMs) {
                    continue   // warm skip; a cold putHello is cheap anyway (per-relay seen marks)
                }
                if forced { pendingForcedHellos.remove(forcedKey) }
                Task { await SharedStore.putHello(circleId: circle.id, toHex: acct, fromHex: meHex, hello: hello, force: forced) }
            }
            // Bootstrap the device-id exchange over the RELAY. When a friend flips to the per-device
            // transport their ACCOUNT id stops resolving, so a direct send can't reach them to deliver my
            // roster — but their relay node (== their device messaging endpoint, one-endpoint design) IS
            // reachable. Push my roster there so the relay-hosting friend learns + authorizes my device id
            // (that's what lets me then read their mailbox). Skip my own hosted relay.
            // When idle, skip warm relays too — re-publishing every sync tick was pure dial heat.
            if !rosterWire.isEmpty, !skipWarmKeepalives {
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
                // Teach the relay this circle's MEMBERS while we're here. Publishing our own roster
                // (above) only says "these are MY devices" — it cannot say "this new person is one
                // of us", so a contact invited after the operator pasted the relay link was refused
                // by that relay forever. Every op they tried (media GET/PUT, mailbox put, devroster
                // read) came back forbidden, which reads as "media never loads and my DMs don't
                // send" rather than as a membership gap.
                //
                // The relay has always been able to accept this (`RelayAuth::learn`, additive, and
                // it re-checks that we are already served and that we name ourselves); the verb just
                // had no caller on any platform until now.
                enrollMembers(circleId: circle.id)
            }
            // Only the OPEN default circle broadcasts its handshake to nearby. Custom + DM
            // circles must NOT — a broadcast Hello let any nearby contact handshake their way
            // into a circle they were never added to (membership contamination).
            // Skip when idle with no connected peers (radio heat for nobody).
            if circle.id == "default", !skipWarmKeepalives || (nearby?.hasConnectedPeers == true) {
                nearbyBroadcast(0, hello)
            }
            // (Own-device nearby catch-up of events moved below — every cycle, off-main.)
            // Mesh: let a relay carry our handshake to members we can't reach directly.
            // When idle, only mesh-originate to cold targets (same filter as the iroh keep-alives).
            let meshDests: [String] = skipWarmKeepalives
                ? targets.filter { !recentlyHeard($0, withinMs: 120_000, nowMs: nowMs) }
                : Array(targets)
            if !meshDests.isEmpty {
                originateRelay(dests: meshDests, inner: frame(0, hello))
            }
        }
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
        // Own-device nearby catch-up of history belongs on **connect** (`nearbyPeerConnected`), NOT
        // every sync tick. Mac used to re-export 50 envelopes × every circle over Multipeer every
        // ~20s while the iPhone was connected — field log: continuous IncomingPacket / 32KB frames
        // and a hot phone. Internet own-device catch-up below covers multi-device when not nearby.
        // (Intentionally no periodic Multipeer history dump here.)
        // Own-device catch-up over the INTERNET. The nearby sweep above only runs when a sibling is
        // physically connected — so two devices on different networks never reconciled, and anything
        // that reached only ONE of them stayed there. That is the "a DM landed on my Mac and never on
        // my iPhone" case, and fixing the receive-time fan-out alone would not have repaired the
        // messages already sitting on one device.
        //
        // BOUNDED, deliberately: only when I actually have other devices, at most 50 events per
        // circle, and no more than every 5 minutes — this re-seals per envelope, so it is real CPU
        // and must not ride the 20s tick. Siblings dedupe, so a repeat sweep is harmless.
        // Linked-device catch-up. Mac host: 2 min. iPhone: 5 min and much smaller — exporting
        // 24 envs × every circle + liveDeliver + APNs syncSelf every 90–180s cooked open phones.
        #if os(iOS)
        let catchupEvery: UInt64 = 300_000
        let catchupLimit = 6
        let syncSelfCap = 2
        // Skip entirely when the phone is already warm/hot — mailbox + push cover delivery.
        let thermalBlocksCatchup: Bool = {
            switch ProcessInfo.processInfo.thermalState {
            case .fair, .serious, .critical: return true
            default: return false
            }
        }()
        #else
        // Hosting Mac: 3 min (was 2) — exportRecent holds the engine mutex for every circle and
        // was piling concurrent utility workers on top of mailbox receive (beachball sample).
        let catchupEvery: UInt64 = RelayHost.shared.serving ? 180_000 : 300_000
        let catchupLimit = RelayHost.shared.serving ? 10 : 16
        let syncSelfCap = 4
        let thermalBlocksCatchup = false
        #endif
        if !thermalBlocksCatchup,
           nowMs - lastOwnDeviceCatchupMs > catchupEvery,
           !myOtherDeviceTargets().isEmpty {
            lastOwnDeviceCatchupMs = nowMs
            // Cover ALL circles via a persisted round-robin. The old "DMs + default + first 2"
            // shape meant a custom circle past the first two NEVER reconciled between own devices
            // (a steady source of the linked-device divergence reports). Budgeted slice per sweep
            // (the per-sweep cost stays what it was); the persisted index advances so successive
            // sweeps walk the whole list — and it survives relaunches, so short sessions don't
            // forever re-sweep the same head. A cold device (no index yet) does one full pass so
            // a fresh link converges without waiting out the rotation.
            let rrKey = "haven.selfCatchup.rrIndex"
            let allCids = circles.map(\.id)
            let circleBudget = 6
            let cidsForDevices: [String]
            if UserDefaults.standard.object(forKey: rrKey) == nil {
                cidsForDevices = allCids
                UserDefaults.standard.set(0, forKey: rrKey)
            } else if allCids.count <= circleBudget {
                cidsForDevices = allCids
            } else {
                let start = UserDefaults.standard.integer(forKey: rrKey) % allCids.count
                cidsForDevices = (0..<circleBudget).map { allCids[(start + $0) % allCids.count] }
                UserDefaults.standard.set((start + circleBudget) % allCids.count, forKey: rrKey)
            }
            Task.detached(priority: .utility) { [weak self, social] in
                let workFinal: [(String, [Data])] = await EngineGate.shared.run {
                    var work: [(String, [Data])] = []
                    for cid in cidsForDevices {
                        let envs = social.exportRecentEnvelopes(circleId: cid, limit: UInt32(catchupLimit))
                        if !envs.isEmpty { work.append((cid, envs)) }
                    }
                    return work
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    var pushed = 0
                    for (cid, envs) in workFinal {
                        self.liveDeliverManyToMyDevices(1, envs.suffix(catchupLimit).map { self.eventPayload(cid, $0) })
                        for env in envs.suffix(3) where env.count < 3_500 && pushed < syncSelfCap {
                            PushManager.shared.syncSelf(event: env.base64EncodedString())
                            pushed += 1
                        }
                    }
                }
            }
        }
        // Frame-19 re-announce: throttle hard. Every sync tick used to seal + fan-out relay ids to
        // every member (iroh + nearby + mesh), which kept the radio warm even when nothing changed.
        // Hosting: 45s. iPhone non-host: 10 min (was 3) — each reannounce seals + fans out + may
        // HTTP-PUT durable __relay__ keys; doing that often on a phone was pure heat.
        #if os(iOS)
        let reannounceEvery: UInt64 = RelayHost.shared.serving ? 60_000 : 600_000
        #else
        // Host Mac: 90s (was 45) — seal+fan-out is engine-lock heavy; less often = fewer beachballs.
        let reannounceEvery: UInt64 = RelayHost.shared.serving ? 90_000 : 180_000
        #endif
        if nowMs &- lastRelayReannounceMs > reannounceEvery {
            lastRelayReannounceMs = nowMs
            reannounceOwnRelay()
        }
        // Push MY media up to every circle relay periodically. Throttled harder on iOS when idle —
        // 60s forever made an open phone re-scan/upload constantly even with nothing new.
        #if os(iOS)
        let mediaEvery: UInt64 = (nowMs &- lastActivityMs) > 60_000 ? 300_000 : 120_000
        #else
        // Host Mac used to re-scan/upload media every 60s forever — CPU + engine lock under load.
        let mediaEvery: UInt64 = RelayHost.shared.serving
            ? ((nowMs &- lastActivityMs) > 120_000 ? 600_000 : 180_000)
            : 120_000
        #endif
        if nowMs - lastMediaBackfillMs > mediaEvery {
            lastMediaBackfillMs = nowMs
            #if os(iOS)
            // Don't thrash media backup while the SoC is already warm.
            let hot: Bool = {
                switch ProcessInfo.processInfo.thermalState {
                case .fair, .serious, .critical: return true
                default: return false
                }
            }()
            if !hot {
                backfillMailboxMedia(circleIds: circles.map { $0.id })
            }
            #else
            backfillMailboxMedia(circleIds: circles.map { $0.id })
            #endif
            // Re-publish our account-signed device roster to every known relay, so a HEADLESS relay
            // (which only knows account ids from its link) authorizes THIS device's id and stops
            // ERR-forbidding our mailbox ops — the "my own NAS relay rejects my phone" fix.
            Task { await SharedStore.publishDeviceRoster(social: social) }
        }
        // Multipeer media: at most every 5 min on the sync path (connect still pushes once).
        // Every-tick pushOwnMediaNearby from Mac was a major iPhone heat source.
        if nearby?.hasConnectedPeers == true, nowMs &- lastNearbyMediaPushMs > 300_000 {
            lastNearbyMediaPushMs = nowMs
            pushOwnMediaNearby()
        }
        requestMissingMedia()
    }

    /// Re-emit EVERY relay this device knows for each circle (nearby + direct + mesh), WITHOUT
    /// adoptRelayNode's heavy backfill. frame 19 used to fire only once (relay start / adopt), so a
    /// sibling/friend that wasn't reachable at that instant never learned the relay — which is why
    /// the iPhone "sees the Mac nearby but won't show its relay", and why an adopted EXTERNAL relay
    /// (NAS docker daemon) never reached circle members at all: only the self-hosted relay was ever
    /// re-announced. Android already re-announces all circle relays per hello — this is that parity.
    ///
    /// Callers: host start / nearby connect / adopt may fire immediately; the periodic sync path
    /// must throttle via `lastRelayReannounceMs` (not every tick — each call fans out sealed
    /// frame-19 to every member over iroh and re-arms dials to unreachable ids).
    func reannounceOwnRelay() {
        guard let social else { return }
        // Snapshot membership + announce plaintext on main (cheap), seal OFF main through
        // EngineGate — sealCircleMedia is real crypto and used to run for every circle×relay
        // on the main actor during the 45s host reannounce tick (beachball under concurrent receive).
        struct SealJob {
            let circleId: String
            let hex: String
            let members: [String]
            let plain: Data
        }
        var jobs: [SealJob] = []
        for ci in circles {
            // Active relays for the circle (adopted external + all-circles default) plus the relay
            // THIS device hosts. Skip s3: pseudo-relays — those share via the S3-config frame, and
            // handleRelayNode expects a 64-hex node id.
            // Prefer proven-alive relays, BUT also re-announce any with a public HTTPS media URL.
            // Free trycloudflare flaps made provenAlive false on the phone while the Mac host was
            // fine — then nobody re-announced, and friends (iroh-unreachable) never learned the
            // relay at all ("I'm not connected to any relays" while the owner sees them all on).
            var hexes = RelayMailboxStore.shared.relays(forCircle: ci.id).filter { hex in
                guard !hex.hasPrefix("s3:") else { return false }
                if RelayHealth.shared.provenAlive(hex, withinMs: 300_000) { return true }
                let urls = RelayMailboxStore.shared.httpInterface(hex)?.urls ?? []
                return urls.contains { $0.hasPrefix("https://") && RelayMailboxStore.urlReachableByOthers($0) }
            }
            if RelayHost.shared.serving, RelayHost.shared.nodeId.count == 64,
               !hexes.contains(RelayHost.shared.nodeId) {
                hexes.append(RelayHost.shared.nodeId)
            }
            guard !hexes.isEmpty else { continue }
            let members = dialTargets(ci.id)
            for hex in hexes where hex.count == 64 {
                jobs.append(SealJob(circleId: ci.id, hex: hex, members: members,
                                    plain: relayAnnounceData(hex)))
            }
        }
        guard !jobs.isEmpty else { return }
        let hosting = RelayHost.shared.serving
        Task.detached(priority: .utility) { [weak self] in
            struct SealedFrame {
                let circleId: String
                let hex: String
                let members: [String]
                let payload: Data
            }
            let sealed: [SealedFrame] = await EngineGate.shared.run {
                var out: [SealedFrame] = []
                for j in jobs {
                    guard let sealed = try? social.sealCircleMedia(circleId: j.circleId, data: j.plain) else { continue }
                    var p = Data()
                    let idBytes = Data(j.circleId.utf8)
                    let n = UInt16(idBytes.count)
                    p.append(UInt8(n & 0xff)); p.append(UInt8(n >> 8)); p.append(idBytes)
                    p.append(sealed)
                    out.append(SealedFrame(circleId: j.circleId, hex: j.hex, members: j.members, payload: p))
                }
                return out
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for f in sealed {
                    self.nearbyBroadcast(19, f.payload)
                    for m in f.members { self.sendIroh(19, f.payload, to: m) }
                    self.originateRelay(dests: f.members, inner: self.frame(19, f.payload))
                    // Durable path: friends who miss live iroh still LIST the mailbox over HTTP and
                    // learn the relay. Only the HOST (or Mac) should PUT these — every phone doing it
                    // each reannounce cycle was continuous HTTP put heat.
                    if hosting {
                        Task { await SharedStore.putRelayAnnounce(circleId: f.circleId, nodeHex: f.hex, payload: f.payload) }
                    }
                }
            }
        }
    }

    /// The frame-19 announce body for one relay: bare 64-hex, or JSON with media/DERP/TURN.
    private func relayAnnounceData(_ hex: String) -> Data {
        // Always carry the relay's adoption timestamp so receivers can LWW a stale tombstone. Use the
        // JSON form whenever we have EITHER an HTTP interface or a non-zero adoption stamp; a legacy
        // receiver ignores JSON it can't parse as a bare hex (wrong length), so this stays compatible.
        let addedAt = RelayMailboxStore.shared.addedAtMs(hex)
        let http = RelayMailboxStore.shared.httpInterface(hex)
        let entry = RelayMailboxStore.shared.entries[hex.lowercased()]
            ?? RelayMailboxStore.shared.entries[hex]
        let derp = entry?.derpUrl
        let turnUrls = entry?.turnUrls ?? []
        let turnUser = entry?.turnUser ?? ""
        let turnPass = entry?.turnPass ?? ""
        if http != nil || addedAt > 0 || (derp?.isEmpty == false) || !turnUrls.isEmpty {
            var obj: [String: Any] = ["node": hex, "addedAt": addedAt]
            if let http { obj["urls"] = http.urls; obj["token"] = http.token }
            if let derp, !derp.isEmpty { obj["derp"] = derp }
            if !turnUrls.isEmpty {
                obj["turn"] = turnUrls
                if !turnUser.isEmpty { obj["turnUser"] = turnUser }
                if !turnPass.isEmpty { obj["turnPass"] = turnPass }
            }
            if let json = try? JSONSerialization.data(withJSONObject: obj) { return json }
        }
        return Data(hex.utf8)
    }

    /// A nearby peer just connected over Bluetooth/Wi-Fi — say hello + back-fill (all circles).
    private func nearbyPeerConnected() {
        guard let social else { return }
        nearbyActive = true
        // Multipeer flaps (connect → broken-pipe → reconnect) were observed live on device: each
        // transition re-armed tight sync cadence + re-exported 150 envelopes/circle + re-announced
        // relays. Debounce the heavy catch-up to once per 45s; light enroll still retries.
        let nowMs = now()
        let flap = lastNearbyConnectMs > 0 && (nowMs &- lastNearbyConnectMs) < 45_000
        lastNearbyConnectMs = nowMs
        if pendingEnrollTicket != nil { sendEnrollRequest() }
        if flap { return }
        bumpActivity()   // a peer just appeared → sync tight for the catch-up burst
        reannounceOwnRelay()   // a freshly-connected sibling/friend immediately learns this host's relay
        // FIRST: offer this device's sealed self-sync slot to nearby peers. ONLY our own devices (same
        // seed) can open it — it's how a linked Mac/phone bootstraps circles + profile + posts LOCALLY,
        // with no relay or S3 at all (the local "handshake" sync). Sent before the post events below so
        // the receiver learns the circles before their posts arrive.
        if let slot = SelfSyncCoordinator.shared.sealedLocalSlot(social: social) {
            nearbyBroadcast(23, slot, class: .control)
        }
        // Bounded catch-up — rate-limited bulk path; never 150×circles flood (Mac→iPhone heat).
        #if os(iOS)
        let nearbyCatchupLimit: UInt32 = 40
        #else
        let nearbyCatchupLimit: UInt32 = 80
        #endif
        for circle in circles {
            guard let hello = helloPayload(circleId: circle.id, circleName: circle.name) else { continue }
            if circle.id == "default" { nearbyBroadcast(0, hello, class: .control) }
            // DMs + RECEIVED events — sealed; non-members drop. Rate limiter paces bulk sends.
            for env in social.exportRecentEnvelopes(circleId: circle.id, limit: nearbyCatchupLimit) {
                nearbyBroadcast(1, eventPayload(circle.id, env), class: .bulk)
            }
        }
        pushOwnMediaNearby(freshPeer: true)   // paced bulk media via rate limiter
        refresh()
        // Keep the Multipeer **session** for live nearby delivery; discovery is already parked
        // on connect. Do not disconnect — that forced internet-only and broke local mesh UX.
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
        invalidateMessagesCache(circleId)   // own send must not sit behind a 2s feed cache
        invalidateSyncBundle(circleId)      // the cached history bundle no longer has this event
        let payload = eventPayload(circleId, env)
        let members = social?.contactNodeIds(circleId: circleId) ?? []
        // Build the push banner once: title = my name, body keyed to the KIND of event. We seal it
        // *per recipient* below so the relay only ever forwards ciphertext.
        let myName = ProfileStore.shared.displayName.isEmpty ? "Someone" : ProfileStore.shared.displayName
        let isDM = circleId.hasPrefix("dm:")
        let circleName = circles.first(where: { $0.id == circleId })?.name ?? "your circle"
        let resolved = banner ?? .generic(isDM: isDM, circleName: circleName,
                                          isGroupDM: PushBanner.isGroupDM(circleId))
        // `c` lets the recipient's NSE redact the banner if *they've* locked this circle.
        // `k`/`e` let a modern NSE group and format; older NSEs ignore unknown keys.
        // `mk` (the deterministic mailbox key this envelope uploads under, below) + `p`/`mr` from
        // the banner ride INSIDE the sealed blob — the recipient's NSE fetches the content the
        // moment the banner lands, and the relay never learns what was announced.
        let notifJSON = (try? JSONSerialization.data(
            withJSONObject: resolved.jsonObject(title: myName, circleId: circleId,
                                                mailboxKey: SharedStore.mailboxKeyHint(circleId: circleId, env: env)))) ?? Data()
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
    // pullMailbox single-flight (see its doc comment): overlap stacks duplicate ingest batches.
    private var pullMailboxInFlight = false
    private var pullMailboxQueued = false
    /// Set by explicit user actions (device link, force-sync, foreground pull): the next self-sync
    /// pass runs FORCED — past the thermal gate and the step-3/5 skip caches.
    private var selfSyncForced = false
    /// Force the next poll to run self-sync even if inside the throttle window (device link, foreground).
    func forceSelfSyncNextPoll() { lastSelfSyncMs = 0; selfSyncForced = true }

    /// Debounced "self-sync now" nudge — called by every LOCAL mutation of self-sync-carried state
    /// (profile fields, synced settings, DM pins, read watermarks, circle create/membership/rename/
    /// delete). One ~4s timer coalesces a burst of edits (typing a bio, bulk member adds) into a
    /// SINGLE forced pass, so the user's other devices converge in seconds instead of waiting out
    /// the 2-minute periodic gate. Fires ONLY on a mutation — an idle app schedules nothing (the
    /// heat fixes stand, and the periodic cadence is untouched). Thermal: a deliberate user edit
    /// pushes through .fair (the pass runs `force: true`, past `skipSelfSync`), but .serious+ stays
    /// respected — only the forced flag is set, and the parked poll runs it once the SoC recovers.
    private var selfSyncNudgeTask: Task<Void, Never>?
    func nudgeSelfSyncSoon() {
        selfSyncNudgeTask?.cancel()
        selfSyncNudgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.selfSyncNudgeTask = nil
            self.forceSelfSyncNextPoll()
            guard !ThermalPolicy.isSeriousOrWorse else { return }
            // Live-push my sealed slot to my OWN devices (frame 23, mesh + iroh) so an ONLINE
            // sibling applies the edit immediately — its own periodic gate/idle stretch would
            // otherwise hold the published slot for minutes. One seal + two sends, mutation-only.
            if let slot = SelfSyncCoordinator.shared.sealedLocalSlot(social: self.social) {
                self.sendToMyDevices(23, slot)
            }
            self.pollMailboxNow()
        }
    }

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
        // Hints first, OUTSIDE the throttle: they're targeted single GETs (cheap by construction)
        // and immediacy is their entire point — the banner already told the user something exists.
        consumePushHints()
        let nowMs = now()
        guard nowMs - lastPushPollMs > 10_000 else { return }
        lastPushPollMs = nowMs
        pollMailboxNow()
    }

    /// Drain `SharedPushHints` (written into the app group as pushes arrive) and act on them AHEAD
    /// of the general sweep: targeted-GET each hinted mailbox key (single GET, no LIST), pull the
    /// hinted circles first, and request the hinted media refs bypassing the fetch throttles —
    /// closing the "banner beat the content" gap. Tolerant of the drop not existing yet.
    private func consumePushHints() {
        guard social != nil else { return }
        let hints = SharedPushHints.drain()
        guard !hints.isEmpty else { return }
        let known = Set(circles.map(\.id))
        let hintedCids = Array(Set(hints.map(\.c)).intersection(known))
        HavenLog.sync("push hints: \(hints.count) hint(s), \(hintedCids.count) known circle(s)")
        Task { @MainActor in
            // 1. Targeted single GETs for the exact keys the pushes announced.
            var fetched: [(cid: String, key: String, env: Data)] = []
            for h in hints.prefix(32) {
                guard known.contains(h.c), let mk = h.mk, !mk.isEmpty else { continue }
                if let data = await SharedStore.fetchMailboxKey(circleId: h.c, key: mk) {
                    fetched.append((cid: h.c, key: mk, env: data))
                }
            }
            if !fetched.isEmpty { await self.ingestHintedEnvelopes(fetched) }
            // 2. Hinted circles ahead of the caller's (throttled) general sweep.
            if !hintedCids.isEmpty { await self.pullMailbox(circleIds: hintedCids) }
        }
        // 3. Media the push named: request NOW, bypassing the lane throttles/backoff.
        for h in hints {
            for ref in (h.mr ?? []).prefix(8)
                where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref) {
                MediaFetchBackoff.clear(ref)
                fastReq[ref] = nil
                requestMedia(ref, circleId: known.contains(h.c) ? h.c : nil)
            }
        }
    }

    /// Targeted prefetch for the macOS silent-push handler (full engine in-process — no NSE
    /// limits): GET the exact mailbox key the push named + kick the named media fetches, BEFORE
    /// its banner posts, so clicking the notification opens content that is already there.
    /// Envelope path mirrors `consumePushHints` step 1; the caller bounds how long it waits.
    func prefetchPush(circleId: String, mailboxKey: String?, mediaRefs: [String]) async {
        guard social != nil, circles.contains(where: { $0.id == circleId }) else { return }
        if let mk = mailboxKey, !mk.isEmpty,
           let data = await SharedStore.fetchMailboxKey(circleId: circleId, key: mk) {
            await ingestHintedEnvelopes([(cid: circleId, key: mk, env: data)])
        }
        for ref in mediaRefs.prefix(8)
            where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref) {
            MediaFetchBackoff.clear(ref)
            fastReq[ref] = nil
            requestMedia(ref, circleId: circleId)
        }
    }

    /// Adopt sealed media the NSE prefetched into the App Group scratch while we were away: open
    /// each blob against its hinted circle (falling back to every circle) and store it, so the
    /// post's image is already on screen when the feed renders. One attempt per blob — the normal
    /// media fetch lanes stay the backstop.
    private func adoptPushMediaScratch() {
        guard let social else { return }
        let items = SharedPushMediaScratch.drain()
        guard !items.isEmpty else { return }
        let known = circles.map(\.id)
        Task { @MainActor in
            var adopted = false
            for item in items where !MediaStore.shared.has(item.ref) {
                var cids = [item.circleId]
                cids.append(contentsOf: known.filter { $0 != item.circleId })
                let opened: Data? = await Task.detached(priority: .utility) {
                    await EngineGate.shared.run {
                        for cid in cids {
                            if let d = social.openCircleMedia(circleId: cid, sealed: item.sealed) { return d }
                        }
                        return nil
                    }
                }.value
                guard let opened else { continue }
                MediaStore.shared.store(item.ref, opened)
                mediaArrived(item.ref)
                MediaFetchBackoff.clear(item.ref)
                adopted = true
            }
            if adopted { scheduleRefresh() }
        }
    }

    /// Ingest envelopes fetched via targeted hint GETs — same receive/mark-seen/side-effect
    /// contract as pullMailbox's content path, for a tiny batch.
    private func ingestHintedEnvelopes(_ batch: [(cid: String, key: String, env: Data)]) async {
        guard let social else { return }
        let ingested: [(String, Data)] = await Task.detached(priority: .utility) {
            await EngineGate.shared.run {
                var out: [(String, Data)] = []
                for item in batch where (try? social.receive(circleId: item.cid, envelope: item.env)) == true {
                    SharedStore.markSeenPublic(item.key)
                    out.append((item.cid, item.env))
                }
                return out
            }
        }.value
        guard !ingested.isEmpty else { return }
        persist()
        bumpActivity()
        for (cid, env) in ingested {
            invalidateMessagesCache(cid)
            invalidateSyncBundle(cid)
            liveDeliverToMyDevices(1, eventPayload(cid, env))
            scheduleCircleSideEffects(cid)
        }
        refresh(); requestMissingMedia()
    }

    /// SLIM background sync for BG-refresh and content-available push wakes: push-inbox drain +
    /// a mailbox-only pull + one upload-queue pass. Deliberately NO Multipeer nudge and NO
    /// hello/roster fan-out — those are foreground work that just cooked the SoC in a pocket wake.
    /// Returns whether anything new arrived so the caller can end the window early on an empty poll
    /// (the common case with zero activity is a quick no-op).
    @discardableResult
    /// `allowMailboxPull`: whether this wake may LIST every circle's mailbox. Push wakes pass `true`
    /// (a banner-only push carries no key, so the LIST is the only way to find what arrived).
    /// BGAppRefresh passes `false` unless it has a known backlog or the 6h safety sweep is due —
    /// listing every circle to discover nothing was the bulk of an idle wake's radio time.
    /// Push HINTS are still fetched in both cases: those are targeted single-key GETs.
    func slimBackgroundSync(allowMailboxPull: Bool = true) async -> Bool {
        // Re-pin the park at the start of every wake. A concurrent scenePhase blip or an
        // earlier configure that raced us must not leave Multipeer / media timers warm.
        #if os(iOS)
        syncForegroundFromSystem()
        #endif
        ingestPushInbox()
        // Hints: process in THIS task. The general `consumePushHints` spawns fire-and-forget work
        // that can outlive setTaskCompleted / fetchCompletionHandler and keep the process warm
        // after we told iOS we were done — the opposite of a quick no-op wake.
        let hints = SharedPushHints.drain()
        let known = Set(circles.map(\.id))
        let hintedCids = Array(Set(hints.map(\.c)).intersection(known))
        var gotFromHints = 0
        if !hints.isEmpty {
            var fetched: [(cid: String, key: String, env: Data)] = []
            for h in hints.prefix(32) {
                guard known.contains(h.c), let mk = h.mk, !mk.isEmpty else { continue }
                if let data = await SharedStore.fetchMailboxKey(circleId: h.c, key: mk) {
                    fetched.append((cid: h.c, key: mk, env: data))
                }
            }
            if !fetched.isEmpty {
                await ingestHintedEnvelopes(fetched)
                gotFromHints = fetched.count
            }
            // Media: do NOT call requestMedia here. That kicks peer mesh asks + a 5s fast-lane
            // timer that outlives fetchCompletionHandler and holds the process warm for minutes.
            // NSE may already have prefetched sealed blobs into the app group; the rest loads
            // when the user opens the app. Envelope text is enough for the banner.
        }
        guard social != nil else { return gotFromHints > 0 }
        // One media-backup pass only — drain itself refuses to re-arm while backgrounded. Runs even
        // on a no-LIST wake: finishing an owed upload is exactly why such a wake was requested.
        defer { if let social { MediaBackupQueue.shared.drainPersisted(social: social) } }
        guard allowMailboxPull else { return gotFromHints > 0 }
        // Prefer hinted circles first, then a full sweep so a banner-only push (no mk) still lands.
        let all = circles.map(\.id)
        let ordered = hintedCids + all.filter { !hintedCids.contains($0) }
        let got = await pullMailbox(circleIds: ordered.isEmpty ? all : ordered)
        return got > 0 || gotFromHints > 0
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
        let force = selfSyncForced
        selfSyncForced = false
        Task { @MainActor in
            if await SelfSyncCoordinator.shared.sync(social: self.social, force: force) {
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
    /// Returns how many envelopes actually ingested (the BG-refresh slim sync ends its window
    /// early on 0).
    ///
    /// SINGLE-FLIGHT. Keys are marked seen when the ingest BATCH runs (inside the EngineGate
    /// queue), but the fetch-time filter reads the seen-set immediately — so two overlapping
    /// pulls fetch the SAME unmarked keys and stack duplicate 200-envelope batches. With many
    /// pollMailboxNow() triggers (timer, push, relay-announce ingest tails) and a big backlog,
    /// polls outran the batches and the EngineGate queue grew without bound: 55 GB and a jetsam
    /// kill in 8 minutes on the relay-hosting Mac, `+7747 next poll` frozen across polls being
    /// the fingerprint. A pull that arrives while one is running coalesces into ONE follow-up
    /// sweep of all circles after the current pass (and its marks) complete.
    @discardableResult
    @MainActor func pullMailbox(circleIds ids: [String]) async -> Int {
        guard let social, ids.contains(where: { SharedStore.hasMailbox($0) }) else { return 0 }
        if pullMailboxInFlight {
            pullMailboxQueued = true
            return 0
        }
        pullMailboxInFlight = true
        defer {
            pullMailboxInFlight = false
            if pullMailboxQueued {
                pullMailboxQueued = false
                Task { @MainActor in
                    await self.pullMailbox(circleIds: self.circles.map { $0.id })
                }
            }
        }
        let msgs = await SharedStore.pollMailbox(circleIds: ids)
        guard !msgs.isEmpty else { return 0 }
        let me = social.myNodeHex().lowercased()
        // Control plane first: HELLOs, durable relay announces (__relay__), key commits / rosters,
        // then content. LIST order is a filesystem walk — without this sort a linked host buffers
        // hundreds of events before the commit that opens them.
        var helloIngested = false
        var relayIngested = false
        func controlRank(_ key: String, _ data: Data) -> Int {
            if key.contains("/__hello__/") { return 0 }
            if key.contains("/__relay__/") { return 1 }
            switch data.first {
            case 0x03, 0x04: return 2   // key commit / device roster
            default: return 3
            }
        }
        let sorted = msgs.sorted { a, b in
            controlRank(a.1, a.2) < controlRank(b.1, b.2)
        }
        // Claim ONLY hellos addressed to one of MY ids: my account hex (the canonical slot) or my
        // CURRENT transport device id (transition senders addressed per dial target). A hello
        // addressed to any OTHER id — another member, a sibling device, a STALE id of mine — is
        // not ours to touch. The old `else { markSeen }` consumed those slots forever on whichever
        // device polled first, which is exactly how circle invites vanished; leave them for their
        // owners (or the relay TTL). pollMailbox already skips fetching them — this is the
        // belt-and-suspenders for envelopes that arrived through an older fetch path.
        var myIds: Set<String> = [me]
        let tdev = transportNodeHex.lowercased()
        if !tdev.isEmpty { myIds.insert(tdev) }
        let mdev = social.myDeviceNodeHex().lowercased()
        if !mdev.isEmpty { myIds.insert(mdev) }
        var heldHelloCircles = Set<String>()
        for (cid, key, data) in sorted where key.contains("/__hello__/") {
            let parts = key.split(separator: "/").map(String.init)
            var toShort = "?", fromShort = "?"
            if let i = parts.firstIndex(of: "__hello__"), parts.count > i + 1 {
                let to = parts[i + 1].lowercased()
                toShort = String(to.prefix(8))
                if parts.count > i + 2 { fromShort = String(parts[i + 2].prefix(8)) }
                guard myIds.contains(to) else {
                    // The claim decision, visible: this slot belongs to another id — untouched.
                    HavenLog.net("hello claim SKIPPED (addressed to \(toShort), not me) from=\(fromShort) circle=\(cid.prefix(12))")
                    continue
                }
            }
            let outcome = handleHello(data, viaNearby: false, senderDevice: nil)
            // Mark seen ONLY when the hello was applied or deliberately dropped. A HELD hello
            // (approval gate, verification hold, engine hiccup) keeps its mailbox slot so the
            // next poll retries — marking it here is how a circle grant riding a hello from a
            // not-yet-approved contact evaporated forever (E2E stub / hosting-Mac symptom).
            if outcome.consumed {
                SharedStore.markSeenPublic(key)
                helloIngested = true
            } else {
                heldHelloCircles.insert(cid)
            }
            HavenLog.net("hello claim \(outcome.consumed ? "CONSUMED" : "HELD") (\(outcome.why)) from=\(fromShort) to=\(toShort) circle=\(cid.prefix(12))")
        }
        // A held hello stays unclaimed, but the HTTP delta-LIST digest was already committed at
        // fetch time — a 204 next poll would hide the slot and stall the retry. Re-list in full.
        for cid in heldHelloCircles { SharedStore.invalidateMailboxListDigests(circleId: cid) }
        // Durable frame-19: friends who can't iroh-dial the host still learn the relay + public
        // media URL from the mailbox ("no available relays" while the owner sees them all on).
        for (_, key, data) in sorted where key.contains("/__relay__/") {
            handleRelayNode(data)
            SharedStore.markSeenPublic(key)
            relayIngested = true
        }
        // `/__live__/` keys are call frames claimed by the in-call 2s poll — never content. An
        // unclaimed one (another device's lane, or a call long over) fed to receive() fails every
        // single poll forever; keep them out of the batch entirely.
        let content = sorted.filter {
            !$0.1.contains("/__hello__/") && !$0.1.contains("/__relay__/") && !$0.1.contains("/__live__/")
        }
        // receive() does real crypto per envelope; a backlog drain used to run the whole loop on
        // the main actor and freeze the UI for the duration. Ingest the batch off-main, then hop
        // back once with the circles that changed. Keep the NEW envelopes so we can fan them out
        // to my other linked devices (handleEvent already does this for live/iroh delivery — mailbox
        // was the hole: a friend's post landed on whichever of my devices polled first and never
        // reached the rest when their mailbox auth/relay set differed).
        let batch: (ingested: [(circleId: String, envelope: Data)],
                    controlKeys: [String: [String]],
                    unlockedCircles: Set<String>,
                    processedKeys: [String]) = await Task.detached(priority: .utility) {
            await EngineGate.shared.run {
                var changed: [(String, Data)] = []
                var controlKeys: [String: [String]] = [:]
                var unlocked = Set<String>()
                var processed: [String] = []
                for (cid, key, env) in content {
                    let applied = (try? social.receive(circleId: cid, envelope: env)) == true
                    // Every processed envelope is marked seen — `false` means "duplicate" or
                    // "buffered until its key/roster arrives" and the pending buffer is durable,
                    // so the mailbox copy is redundant either way (marking only on `true` melted
                    // the Mac: honest no-op duplicates re-fetched forever). BUT the marks are
                    // COLLECTED here and written only AFTER persist() lands the engine state:
                    // marking inside this loop put the seen-save (2s debounce, independent file)
                    // AHEAD of the engine save, and a process kill in that gap burned the batch —
                    // keys durably seen, events (including friends' KEY COMMITS) never in the
                    // engine. A day of storm-kills did exactly that fleet-wide: pushes flowed,
                    // every layer of content underneath went dark.
                    processed.append(key)
                    if applied {
                        changed.append((cid, env))
                        // Key commit (0x03) or roster (0x04) that actually changed state — peer keys
                        // may now open events that were previously marked seen while unopenable.
                        if let tag = env.first, tag == 0x03 || tag == 0x04 {
                            controlKeys[cid, default: []].append(key)
                            if tag == 0x03 { unlocked.insert(cid) }
                        }
                    }
                }
                return (changed, controlKeys, unlocked, processed)
            }
        }.value
        let ingested = batch.ingested
        // After a NEW key commit lands, re-queue that circle's mailbox content (except the control
        // keys we just applied). Older builds / mark-at-fetch races left epoch events "seen" with
        // no peer_epoch_keys — classic linked-Mac-host symptom: iPhone has mom's DMs, Mac store
        // holds hundreds of sealed blobs, feed stays empty.
        if !batch.unlockedCircles.isEmpty {
            // DAMPER: one seen-wipe per circle per 10 minutes, no matter what receive() reports.
            // The 16.8 GB Mac storm was this block firing on EVERY poll: competing key commits
            // flip-flopped the engine's epoch slot (fixed in core by deterministic convergence),
            // each flip reported "changed", and each report wiped the circle's seen-set — so every
            // poll re-fetched and re-ingested the whole mailbox, fanning out pushes per envelope.
            // The core fix ends the flip; this throttle guarantees no future "changed" bug can
            // escalate a poll loop into an unbounded re-ingest storm again. A genuinely-new commit
            // still re-opens immediately (its circle won't have wiped recently).
            let nowMs = now()
            var reopened = 0
            for cid in batch.unlockedCircles {
                if let last = lastSeenWipeMs[cid], nowMs &- last < 21_600_000 { continue }
                // NEVER wipe mid-drain: the wipe's purpose (re-open events marked seen while
                // unopenable) is served just as well AFTER the current backlog finishes, and
                // wiping while thousands of keys are still deferred resets the drain to zero —
                // the wipe cadence beat the ~30-minute drain time and the backlog never shrank
                // (the 351/352 "deferred frozen at ~8k" treadmill). Park the request; the
                // post-drain check below performs it once the circle's backlog reaches zero.
                guard SharedStore.readyForReopen(cid) else {
                    pendingReopenCircles.insert(cid)
                    continue
                }
                lastSeenWipeMs[cid] = nowMs
                reopened += 1
                SharedStore.forgetSeenPrefix("haven/mailbox/\(cid)/")
                // The relay's key SET didn't change, so its LIST digest didn't either — drop ours
                // or the next poll 204s and the re-queued keys never re-GET.
                SharedStore.invalidateMailboxListDigests(circleId: cid)
                for k in batch.controlKeys[cid] ?? [] { SharedStore.markSeenPublic(k) }
            }
            if reopened > 0 {
                HavenLog.relay("mailbox: re-open \(reopened) circle(s) after key commit")
            }
        }
        // Parked re-opens: perform each one exactly when its circle's drain completes. Runs every
        // pass because the completing poll is usually a later one than the pass that parked it.
        if !pendingReopenCircles.isEmpty {
            let nowMs = now()
            for cid in pendingReopenCircles where SharedStore.readyForReopen(cid) {
                pendingReopenCircles.remove(cid)
                if let last = lastSeenWipeMs[cid], nowMs &- last < 21_600_000 { continue }
                lastSeenWipeMs[cid] = nowMs
                SharedStore.forgetSeenPrefix("haven/mailbox/\(cid)/")
                SharedStore.invalidateMailboxListDigests(circleId: cid)
                HavenLog.relay("mailbox: parked re-open of \(cid.prefix(12)) after drain")
            }
        }
        // Persist whenever we ran ANY receive: an envelope that only BUFFERED (event arrived before
        // its key commit / the sender's roster) mutated the now-durable pending_epoch buffer — if we
        // don't save the engine state here, a kill before the key arrives loses the buffered event.
        persist()
        // Seen-marks STRICTLY AFTER the engine state that contains their events is on disk. Kill
        // before persist(): nothing marked, everything re-fetched, receive() is idempotent. Kill
        // after persist() before marks: events safe, keys re-fetched once and marked as duplicates.
        // Either way nothing is ever both "seen" and absent from the engine — the invariant whose
        // violation blacked out all content while pushes kept arriving.
        for k in batch.processedKeys { SharedStore.markSeenPublic(k) }
        if helloIngested { refresh(); syncWithContacts() }
        if relayIngested { objectWillChange.send() }   // Storage / circle relay chips re-read the store
        guard !ingested.isEmpty else {
            // Key-commit-only pass: still refresh so a recovering linked host paints newly unlocked
            // history as the next poll drains re-queued events.
            if !batch.unlockedCircles.isEmpty { refresh() }
            return 0
        }
        bumpActivity()   // a message arrived → keep sync tight while the conversation is live
        // Drop stale feed reads before badge/notify — a cold messages() per envelope was the
        // beachball: N × feed() on main while utility workers still held the engine mutex.
        for cid in Set(ingested.map(\.circleId)) { invalidateMessagesCache(cid); invalidateSyncBundle(cid) }
        // Batch fan-out: one Task for many envelopes (same shape as own-device catch-up).
        liveDeliverManyToMyDevices(1, ingested.map { eventPayload($0.circleId, $0.envelope) })
        // Multipeer siblings that share no good internet path still need a hop — sealed, so only
        // members (and my other devices with the seed) open it.
        for item in ingested {
            nearbyBroadcast(1, eventPayload(item.circleId, item.envelope), class: .bulk)
        }
        // APNs silent self-sync for LINKED devices. Own-authored events already call syncSelf in
        // broadcastEvent; mailbox ingest was the hole: host Mac polled the friend's DM first and
        // liveDelivered over iroh, but a sleeping/cellular iPhone that missed iroh never got a
        // push with the inline event — so Mac showed the DM and iPhone stayed empty until a
        // successful HTTP mailbox poll (often blocked by free-CF DNS flaps).
        // CAPPED at the newest 3 per circle per pass: a catch-up burst (or any re-ingest bug) used
        // to fire one APNs push PER envelope — the Mac storm pushed dozens a second at the iPhone
        // (heat + battery). The push's job is waking the device and painting the newest message;
        // the woken device drains the rest from the mailbox itself.
        var syncSelfSent: [String: Int] = [:]
        for item in ingested.reversed() where syncSelfSent[item.circleId, default: 0] < 3 {
            syncSelfSent[item.circleId, default: 0] += 1
            PushManager.shared.syncSelf(event: item.envelope.base64EncodedString())
        }
        for item in ingested {
            // Coalesced: one off-main feed read per circle, not notifyNewest→messages() per env.
            // DM media fetch runs inside runCircleSideEffects after the cache is warm (do NOT call
            // requestMissingDMMedia here — that would cold-call feed() on main right after invalidate).
            scheduleCircleSideEffects(item.circleId)
        }
        refresh(); requestMissingMedia()
        return ingested.count
    }

    /// Fetch media the NEWEST messages in a DM circle reference and we don't hold.
    ///
    /// Bounded hard, because this runs off an ingest and a peer decides when that happens: newest
    /// messages only, a handful of refs, and `requestMedia` no-ops for anything already held. It
    /// deliberately does not walk the whole conversation — history fills in when you open the thread.
    @MainActor func requestMissingDMMedia(_ circleId: String) {
        let recent = messages(in: circleId).sorted { $0.createdAt > $1.createdAt }.prefix(8)
        var budget = 4
        let dataSaver = SettingsStore.shared.dataSaverActive
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
        adoptPushMediaScratch()   // NSE-prefetched sealed media → open + store before the feed renders
        let envs = SharedInbox.drain()
        guard !envs.isEmpty else { return }
        let ids = circles.map { $0.id }
        // Trying every circle per envelope multiplies the receive() crypto — run the whole batch
        // off-main and apply the result in one main-actor hop (same shape as pullMailbox).
        Task.detached(priority: .utility) { [weak self] in
            let ingestedFinal: [(circleId: String, envelope: Data)] = await EngineGate.shared.run {
                var ingested: [(circleId: String, envelope: Data)] = []
                for env in envs {
                    for cid in ids where (try? social.receive(circleId: cid, envelope: env)) == true {
                        ingested.append((cid, env)); break
                    }
                }
                return ingested
            }
            let failedOpen = ingestedFinal.isEmpty && !envs.isEmpty
            await MainActor.run { [weak self] in
                guard let self else { return }
                if failedOpen {
                    // Banner fired but every inline envelope failed to open (wrong circle state,
                    // missing epoch, seedless lag). Do NOT drop the only recovery path — always
                    // pull the mailbox so posts/stories/DMs still land.
                    HavenLog.sync("push inbox: \(envs.count) env(s) failed to open — polling mailbox")
                    self.syncBecauseOfPush()
                    return
                }
                guard !ingestedFinal.isEmpty else { return }
                for (cid, env) in ingestedFinal {
                    self.invalidateMessagesCache(cid)
                    self.invalidateSyncBundle(cid)
                    self.scheduleCircleSideEffects(cid)  // notify + badge + DM media (off-main feed)
                    // Fan out to my other online devices — same contract as handleEvent. The push
                    // worker delivers to every device token, but the *event body* only rides the
                    // push when it fits under ~3900 bytes; larger DMs notify every device and only
                    // inline on none of them. Live-delivering the sealed envelope we just opened
                    // is what makes "I got the banner on my phone AND my Mac shows the message"
                    // true when both are awake. Mailbox poll still covers the asleep case.
                    self.liveDeliverToMyDevices(1, self.eventPayload(cid, env))
                }
                self.persist(); self.refresh(); self.requestMissingMedia()
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
            // ONLY WRITE ON CHANGE. @Published fires objectWillChange on EVERY assignment — even
            // nil over nil — and this runs on every iroh send: hellos, call frames, event fan-out.
            // Each write invalidated every view observing FeedStore, which is every PostCard on
            // screen, so ordinary network traffic was driving whole-feed SwiftUI invalidation.
            //
            // It fits the profile exactly: the main thread was 84% framework (AttributeGraph
            // propagate_dirty / UpdateStack::update / CA commits) with only 16% of samples containing
            // ANY Haven frame — the signature of something dirtying the graph rather than one slow
            // function.
            await MainActor.run {
                let v = anyOk ? nil : lastErr
                if self?.lastSendError != v { self?.lastSendError = v }
            }
        }
    }
    /// My OWN other devices' transport ids — the live-delivery fan-out set (D16 Phase 4b).
    /// Excludes this device (dialing our own id loops iroh's path discovery unboundedly — the
    /// self-connect leak) and the account id (a contact handle that resolves to NO endpoint under
    /// per-device transport seeds, so dialing it is a guaranteed ~30s timeout, not a sibling).
    /// Invite/device hints for MY account are included too: until self-sync merges the signed
    /// own-roster, a freshly-linked sibling is otherwise invisible to fan-out and never gets
    /// contact events that only this device received.
    private func myOtherDeviceTargets() -> [String] {
        guard let social else { return [] }
        let mineAcct = social.myNodeHex().lowercased()
        let mineDev = social.myDeviceNodeHex().lowercased()
        var out = [String]()
        var seen = Set<String>()
        func add(_ h: String) {
            let l = h.lowercased()
            guard l.count == 64, l != mineAcct, l != mineDev, seen.insert(l).inserted else { return }
            out.append(l)
        }
        for d in social.deviceNodeIdsFor(accountHex: social.myNodeHex()) { add(d) }
        for h in deviceHints(for: mineAcct) { add(h) }
        return out
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

    /// Multipeer fan-out with rate class. Control = hello/announce/signals; bulk = history/media.
    private func nearbyBroadcast(_ type: UInt8, _ payload: Data, class sendClass: NearbyTransport.SendClass = .control) {
        // Large frames (media chunks / fat envelopes) are bulk by default if caller left default.
        let cls: NearbyTransport.SendClass = {
            if sendClass != .control { return sendClass }
            // Heuristic: frames > 2 KB are bulk even if tagged control (defensive).
            if payload.count > 2048 { return .bulk }
            // Explicit bulk types: event history (1) can be large; media (5) always bulk.
            if type == 5 { return .bulk }
            return sendClass
        }()
        nearby?.broadcast(frame(type, payload), class: cls)
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
        let payload = Data(data.dropFirst())
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
            //
            // The unseal + roster resolution are ENGINE calls; frames 30/31/32 ride this path and
            // burst during media sweeps, and opening each on the main actor parked the UI on the
            // engine mutex for as long as any storm held it (beachball sample, b349). Hop through
            // EngineGate for the crypto, back to the main actor to dispatch. Consecutive frames
            // enqueue in arrival order; the rare cross-frame reorder this could allow is harmless
            // to the handlers (SDP/ICE tolerate it, invite/accept/hangup key on call ids).
            Task { [weak self] in
                guard let self else { return }
                let social = self.social
                struct OpenedFrame {
                    let plaintext: Data
                    let verified: String
                    let resolved: String?
                    let transportAcct: String?
                }
                let opened: OpenedFrame? = await EngineGate.shared.run {
                    guard let social else {
                        HavenLog.call("call frame type=\(type) DROPPED — no social")
                        return nil
                    }
                    guard let o = social.openCallFrame(frameType: type, blob: payload) else {
                        // "seal/signature did not verify" collapsed two opposite causes into one
                        // line. Ask which: a decrypt failure means the frame wasn't sealed to a key
                        // we hold, while a signature failure means it WAS addressed to us and the
                        // signature is checked against the wrong id of ours. Diagnostics only.
                        let why = social.diagnoseCallFrame(frameType: type, blob: payload)
                        HavenLog.call("call frame type=\(type) DROPPED — \(why)")
                        return nil
                    }
                    let verified = o.senderHex.lowercased()
                    return OpenedFrame(
                        plaintext: Data(o.data),
                        verified: verified,
                        // The signer's ACCOUNT. A SEEDLESS sender (S4, D9) signs call/notification
                        // frames with its DEVICE key and carries the device bundle, so `verified`
                        // is a device id — resolve it to the account that authorized it (a seeded
                        // sender signs with the account key, where the account resolves to itself).
                        // This is the receive-side half of accepting device-signed frames.
                        resolved: social.accountForDevice(deviceHex: verified)?.lowercased(),
                        transportAcct: (senderDevice?.count == 64)
                            ? senderDevice.flatMap { social.accountForDevice(deviceHex: $0)?.lowercased() }
                            : nil
                    )
                }
                guard let opened else { return }
                let declared = String(data: opened.plaintext.prefix(64), encoding: .utf8)?.lowercased() ?? ""
                let signerAccount = opened.resolved ?? opened.verified
                guard opened.verified.count == 64, declared == signerAccount else {   // proven signer's account == self-declared
                    // If `resolved` is nil the sender signed as a DEVICE we can't map to an account —
                    // i.e. we don't hold their device roster — so a perfectly genuine frame from a
                    // seedless/linked device fails this check. That is a roster-propagation problem
                    // wearing a signature-mismatch costume; it is NOT a forgery.
                    HavenLog.call("call frame type=\(type) DROPPED — declared=\(declared.prefix(8)) != signerAccount=\(signerAccount.prefix(8)) (signer device=\(opened.verified.prefix(8)), device→account \(opened.resolved == nil ? "UNRESOLVED — we lack their roster" : "resolved"))")
                    return
                }
                // Defense in depth: when the transport gave us a verified device id, it must resolve
                // to the SAME account as the signer (nil on the relay path, where the signature
                // already did the work).
                if let acct = opened.transportAcct, acct != signerAccount {
                    HavenLog.call("call frame type=\(type) DROPPED — transport device \(senderDevice?.prefix(8) ?? "") maps to \(acct.prefix(8)), signer is \(signerAccount.prefix(8))")
                    return
                }
                if ConnectionsStore.shared.isBlocked(opened.verified) {
                    HavenLog.call("call frame type=\(type) DROPPED — sender \(opened.verified.prefix(8)) is blocked")
                    return
                }
                HavenLog.call("call frame type=\(type) accepted from \(signerAccount.prefix(8))")
                self.dispatchInboundFrame(type, opened.plaintext, viaNearby: viaNearby, senderDevice: senderDevice)
            }
            return
        }
        if [3, 13, 15, 33].contains(type) {
            // Remaining sender-prefixed frames (media req + resume req + call audio/video
            // placeholders): drop if blocked (audit F4). These are not call SIGNALING and keep the
            // plaintext-prefix check. 33 sits here rather than in the sealed set above because it asks
            // for a SUBSET of what frame 3 already asks for in the clear — see handleMediaResumeRequest.
            let head = String(data: payload.prefix(64), encoding: .utf8) ?? ""
            if head.count == 64, ConnectionsStore.shared.isBlocked(head) { return }
        }
        dispatchInboundFrame(type, payload, viaNearby: viaNearby, senderDevice: senderDevice)
    }

    /// Route one authenticated inbound frame to its handler. Call-signaling frames arrive here
    /// AFTER the sealed-open + signer checks in `handleInbound` (with `payload` already the opened
    /// plaintext); everything else arrives as it came off the wire.
    private func dispatchInboundFrame(_ type: UInt8, _ payload: Data, viaNearby: Bool, senderDevice: String?) {
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
        case 35: CallManager.shared.handleEndedElsewhere(payload)   // my account ENDED this call elsewhere
        case 34: handleHistoryRequest(payload)                       // "send me the page of your history before X"
        default: break
        }
    }

    // MARK: - Lazy history (wire 34)
    //
    // Adding someone used to hand them EVERYTHING. `sync_envelopes` re-seals my whole history — real
    // cryptography per event — and every envelope goes out, gets unsealed on their side, and drags
    // its media behind it. On an account carrying an imported archive that is hundreds of envelopes
    // and a gigabyte of media, delivered before the new member has looked at a single post.
    //
    // The first screenful is what they need. The rest is a backlog they may never scroll to — so it
    // is fetched the way media already is: when they get there.
    //
    // The reply is ordinary Event frames (type 1), NOT a new response type, so the receiving path is
    // the one that already ingests and dedupes envelopes. Only the ASK is new.
    //
    // The periodic full re-send stays exactly as it was and remains the backstop: paging can drop a
    // page, be answered by nobody, or stop early, and history still reconciles on its own. Nothing
    // here can strand a peer — the worst case is that they wait for the backstop instead of getting
    // it on demand.

    /// Events a new member is given up front, and the size of each page fetched afterwards. Sized to
    /// comfortably overfill a screen so the common case never needs a second round trip.
    static let historyPageSize: UInt32 = 60

    /// The cursor last asked for per circle — scrolling past the end repeatedly must not re-ask.
    private var historyAskedBefore: [String: UInt64] = [:]

    /// Ask this circle's members for the page of history older than the oldest post we hold.
    ///
    /// Idempotent per cursor: asking again only happens once an older page has actually arrived and
    /// moved the cursor. If nobody answers, the cursor stays put and the periodic full re-send
    /// eventually delivers it anyway.
    func requestOlderHistory(circleId: String? = nil) {
        let cid = circleId ?? activeCircleId
        guard let social else { return }
        guard let oldest = items.map(\.createdAt).min(), oldest > 0 else { return }
        guard historyAskedBefore[cid] != oldest else { return }
        historyAskedBefore[cid] = oldest
        var payload = Data(social.myNodeHex().utf8)
        withUnsafeBytes(of: oldest.littleEndian) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: Array(cid.utf8))
        for contact in ContactsStore.shared.contacts { sendIroh(34, payload, to: contact.idHex) }
        HavenLog.sync("history: asked for the page before \(oldest) in \(cid)")
    }

    /// Someone asked for the page of MY history older than their cursor. Answer with events only —
    /// authorship is unchanged, because `sync_envelopes_page` re-seals only what I authored.
    private func handleHistoryRequest(_ payload: Data) {
        guard payload.count > 72, let social else { return }
        guard let requesterHex = String(data: payload.prefix(64), encoding: .utf8),
              requesterHex.count == 64,
              let cid = String(data: payload.dropFirst(72), encoding: .utf8), !cid.isEmpty,
              circles.contains(where: { $0.id == cid }) else { return }
        // Only a member of that circle may page through it. Everything below re-seals to the
        // circle's epoch anyway, so a stranger could not open it — but there is no reason to spend
        // the sealing on them, and an unbounded stranger-triggered re-seal is a free CPU drain.
        guard ContactsStore.shared.contacts.contains(where: { $0.idHex == requesterHex }) else { return }
        var before: UInt64 = 0
        for (i, byte) in payload.dropFirst(64).prefix(8).enumerated() { before |= UInt64(byte) << (8 * i) }
        let page = social.syncEnvelopesPage(circleId: cid, beforeMs: before, limit: Self.historyPageSize)
        HavenLog.sync("history: serving \(page.count) envelopes before \(before) in \(cid) to \(requesterHex.prefix(8))")
        for env in page { sendIroh(1, eventPayload(cid, env), to: requesterHex) }
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
        // MY OWN posts are exempt from the auto-delete window. That window exists so a member's disk
        // is not filled by OTHER people's history — my own feed is my archive, and aging it out is
        // data loss rather than a storage policy. The core has always honoured this in
        // `purge_expired`, and documents the app as owning the toggle, but no platform ever called
        // it, so it was false everywhere. Apple only escaped the consequence because its retention
        // is per-circle and defaults to off; desktop applies one global window and silently ate an
        // entire backdated Instagram import.
        social.setKeepOwnPosts(on: true)
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
            // Forced: a rotation is an explicit user action and MUST publish under the new epoch
            // now — never deferred by the thermal gate or the unchanged-state publish skip.
            _ = await SelfSyncCoordinator.shared.sync(social: social, force: true)
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
        ActivityStore.shared.note(id: "seedless-enroll-\(request.deviceHex)", kind: "device",
                                  snippet: "“\(request.name)” is now a secure linked device")
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
        nearby?.stop()   // clean Multipeer teardown before the reference drops (Bonjour cancel crash)
        node = nil; nearby = nil; social = nil; items.removeAll(); circles.removeAll()
        RelayClients.clearAll()
        configure(mode: .seedless(accountBundle: grant.accountBundle, deviceSeed: deviceSeed))
        // 4. Ask the primary to push full state now (profile/circles/posts) → it answers with the
        //    type-23 slot that seeds our base, plus the circle events.
        sendToMyDevices(26, Data(DeviceKeyStore.deviceNodeHex().utf8))
        NotificationManager.shared.notify(title: "Device linked",
                                          body: "This device is now linked — syncing your circles…",
                                          dedupeKey: "seedless-grant", persist: false)
        ActivityStore.shared.note(id: "seedless-grant-\(now())", kind: "device",
                                  snippet: "This device is now linked to your account")
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
    /// `haven-relay` (`{"node","urls","token","derp","turn",…}`) so media + fabric + TURN are
    /// learned in one paste and re-announced to the circle (frame 19).
    func adoptRelayNode(_ nodeHex: String, circleIds: [String], setDefault: Bool) {
        var hex = nodeHex.trimmingCharacters(in: .whitespacesAndNewlines)
        var announcedUrls: [String] = []
        var announcedToken = ""
        var announcedDerp: String?
        var announcedTurn: [String] = []
        var announcedTurnUser = ""
        var announcedTurnPass = ""
        if hex.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: Data(hex.utf8)) as? [String: Any] {
            announcedUrls = (obj["urls"] as? [String] ?? []).filter { $0.hasPrefix("http") }
            announcedToken = obj["token"] as? String ?? ""
            if let d = obj["derp"] as? String, d.hasPrefix("http") {
                announcedDerp = d.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if let arr = obj["turn"] as? [String] {
                announcedTurn = arr.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
            } else if let s = obj["turn"] as? String, s.hasPrefix("turn:") || s.hasPrefix("turns:") {
                announcedTurn = [s]
            }
            announcedTurnUser = obj["turnUser"] as? String ?? ""
            announcedTurnPass = obj["turnPass"] as? String ?? ""
            if announcedTurnUser.isEmpty, !announcedTurn.isEmpty { announcedTurnUser = "haven" }
            if announcedTurnPass.isEmpty, !announcedTurn.isEmpty, !announcedToken.isEmpty {
                announcedTurnPass = announcedToken
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
        if !announcedTurn.isEmpty {
            RelayMailboxStore.shared.setTurn(hex, urls: announcedTurn, user: announcedTurnUser, pass: announcedTurnPass)
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

    /// Bring a DELETED relay back. Restoring is a deliberate re-adoption, so it goes through the same
    /// path as adding a relay by node id — clear the suppression + LWW tombstone, re-associate the
    /// circles, re-announce it to those circles' members, and backfill what they missed. Anything
    /// less produced an entry that existed but served nothing.
    ///
    /// A relay deleted BEFORE the archive existed has only its tombstone, so there are no circles to
    /// put it back into: it re-adopts into every circle, exactly like adding it fresh would.
    func restoreDeletedRelay(_ nodeHex: String) {
        let store = RelayMailboxStore.shared
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.lowercased()
        let rec = store.erasedRelays.first { $0.entry.hex == hex }
        let targets = (rec?.circles.isEmpty == false) ? rec!.circles : circles.map(\.id)
        adoptRelayNode(hex, circleIds: targets, setDefault: rec?.wasDefault ?? false)
        store.dropErased(hex)
        HavenLog.relay("restored deleted relay \(hex.prefix(8)) into \(targets.count) circle(s)")
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

    /// Last member-enroll per circle — the set changes rarely, so once per 10 min is plenty.
    private var lastEnrollMs: [String: UInt64] = [:]

    /// Tell every relay serving `circleId` who its members are, so a peer the operator never listed
    /// in the relay link is still served. Best-effort: a relay that refuses (we aren't served there
    /// ourselves) or predates the verb simply keeps its existing set.
    func enrollMembers(circleId: String) {
        guard let social else { return }
        let nowMs = now()
        if let last = lastEnrollMs[circleId], nowMs &- last < 600_000 { return }
        let relays = RelayMailboxStore.shared.relays(forCircle: circleId)
            .filter { !$0.hasPrefix("s3:") && $0.count == 64 }
        guard !relays.isEmpty else { return }
        // Rule (2) of `learn`: we must name OURSELVES or the relay declines outright.
        var members = Set(dialTargets(circleId).map { $0.lowercased() })
        members.insert(social.myNodeHex().lowercased())
        members.insert(social.myDeviceNodeHex().lowercased())
        guard members.count > 1 else { return }
        lastEnrollMs[circleId] = nowMs
        let list = Array(members)
        Task.detached {
            for hex in relays {
                guard let c = await RelayClients.client(hex) else { continue }
                let ok = await c.enrollMembers(circleId: circleId, members: list)
                if ok { HavenLog.relay("enrolled \(list.count) members of \(circleId) at \(hex.prefix(8))") }
            }
        }
    }

    /// Push every media blob I hold for a circle to its relay/mailbox, so a member pulling EVENTS
    /// from the relay can also pull the MEDIA (instead of receiving fragmented posts). No-op without
    /// a mailbox. Used when sharing history with a new member and when a new relay is adopted.
    func backfillMailboxMedia(circleIds: [String]) {
        guard let social else { return }
        // Host Macs with large libraries: enqueue a bounded newest-first slice per pass so the
        // 2‑min tick can't dump thousands of seal jobs onto MediaBackupQueue at once.
        let perCircleCap = RelayHost.shared.serving ? 40 : 200
        for cid in circleIds where SharedStore.hasMailbox(cid) {
            let feed = social.feed(circleId: cid, nowMs: now(),
                                   viewerRetentionSecs: CircleSettingsStore.shared.retentionSecs(cid))
            var refs: [String] = []
            var seen = Set<String>()
            // Newest posts first (feed is reverse-chronological).
            for item in feed {
                for r in item.media where seen.insert(r).inserted { refs.append(r) }
                for c in item.comments {
                    for r in c.media where seen.insert(r).inserted { refs.append(r) }
                }
            }
            var enqueued = 0
            let ownRelay = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
            for ref in refs {
                guard enqueued < perCircleCap else { break }
                guard MediaStore.shared.has(ref), !MediaBackupBackoff.shouldSkip(ref) else { continue }
                // Skip only when EVERY relay this circle publishes to already holds it. The old
                // test was "any relay a DIFFERENT DEVICE can read" — one remote copy stopped the
                // mirroring forever, so a blob that landed on the NAS never reached this Mac's
                // relay (and vice versa), and any relay adopted, recovered, or GC-swept afterwards
                // stayed empty for good. Redundancy across relays is the entire point of having
                // several: a peer polls the relays IT knows, not the one that happened to win the
                // race here. Exactly the per-(relay,key) shape the EVENT upload path needed.
                let wanted = RelayMailboxStore.shared.relays(forCircle: cid)
                if wanted.isEmpty {
                    // No explicit relay set for this circle — fall back to the old remote test.
                    if MediaBackupLedger.hasAnyRemote(ref, ownRelayHex: ownRelay) { continue }
                } else {
                    let held = Set(MediaBackupLedger.destinations(for: ref))
                    if wanted.allSatisfy({ held.contains($0) }) { continue }
                }
                MediaBackupQueue.shared.enqueue(ref, circleId: cid, social: social)
                enqueued += 1
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
        var announcedTurn: [String] = []
        var announcedTurnUser = ""
        var announcedTurnPass = ""
        if nodeHex.hasPrefix("{"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            announcedUrls = (obj["urls"] as? [String] ?? []).filter { $0.hasPrefix("http") }
            announcedToken = obj["token"] as? String ?? ""
            announcedAddedAt = (obj["addedAt"] as? NSNumber)?.uint64Value ?? 0
            if let d = obj["derp"] as? String, d.hasPrefix("http") { announcedDerp = d }
            if let arr = obj["turn"] as? [String] {
                announcedTurn = arr.filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
            } else if let s = obj["turn"] as? String, s.hasPrefix("turn:") || s.hasPrefix("turns:") {
                announcedTurn = [s]
            }
            announcedTurnUser = obj["turnUser"] as? String ?? ""
            announcedTurnPass = obj["turnPass"] as? String ?? ""
            if announcedTurnUser.isEmpty, !announcedTurn.isEmpty { announcedTurnUser = "haven" }
            if announcedTurnPass.isEmpty, !announcedTurn.isEmpty, !announcedToken.isEmpty {
                announcedTurnPass = announcedToken
            }
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
        // NEVER let an announce tell us about our OWN running relay. The live front door is
        // authoritative; an announce blob is only ever a stale photograph of it.
        //
        // Announces are content-addressed over a randomized seal, so each one is a distinct mailbox
        // key and they accumulate — and `forgetSeenPrefix` (the re-open after a key commit) un-sees
        // the whole circle prefix, re-offering WEEKS of our own older announces, each naming
        // whichever free trycloudflare hostname was live that day. Adopting one overwrote our
        // httpUrls/derpUrl with a dead hostname, and changing the fabric triggers a full transport
        // rebind — which detached the relay, minted a NEW tunnel hostname, and published yet another
        // announce for the next pass to adopt. That is the relay "cycling", the ever-rotating URL
        // the iPhone could never resolve, and (via the rebind) the dead relay-client cache that
        // stopped media and DMs from crossing at all.
        if RelayHost.shared.enabled, !RelayHost.shared.nodeId.isEmpty,
           lower == RelayHost.shared.nodeId.lowercased() {
            return
        }
        // A contact advertised their circle relay → ADD it to our redundant set for this circle, so
        // members automatically pool relays (more redundancy, no manual setup) — desktop parity.
        let wasNew = !RelayMailboxStore.shared.relays(forCircle: circleId).contains(lower)
        // Propagate the announced adoption stamp (not now()) so the freshest legit re-add flows across
        // the circle without any echo fabricating a new timestamp.
        RelayMailboxStore.shared.add(circleId: circleId, nodeHex: nodeHex, adoptedAtMs: announcedAddedAt)
        // Record the relay's announced HTTP media interface (the reliable cross-NAT path).
        let hadPublicHttp: Bool = {
            let prev = RelayMailboxStore.shared.httpInterface(lower)?.urls ?? []
            return prev.contains { $0.hasPrefix("https://") }
        }()
        if !announcedUrls.isEmpty, !announcedToken.isEmpty {
            RelayMailboxStore.shared.setHttpInterface(lower, urls: announcedUrls, token: announcedToken)
            // New/rotated free CF hostname — stop skipping the old cool-down window.
            for u in announcedUrls { SharedStore.clearHttpUrlBad(u) }
        }
        let nowPublicHttp = announcedUrls.contains { $0.hasPrefix("https://") }
        // Haven fabric: DERP URL so peers prefer this box over n0 for live NAT.
        if let announcedDerp {
            RelayMailboxStore.shared.setDerpUrl(lower, url: announcedDerp)
        }
        if !announcedTurn.isEmpty {
            RelayMailboxStore.shared.setTurn(lower, urls: announcedTurn, user: announcedTurnUser, pass: announcedTurnPass)
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
        // New relay OR first time we learn a public HTTPS media URL (LAN-only → trycloudflare
        // after host fix): push past posts+media so "previously shared content" finally lands.
        if wasNew || (!hadPublicHttp && nowPublicHttp) {
            backfillMailbox(circleIds: [circleId])
            backfillMailboxMedia(circleIds: [circleId])
        }
        Task { await BackgroundUploader.shared.flush() }   // deliver posts we couldn't send before
        pollMailboxNow()
    }

    // MARK: - Relay interface self-heal (rotated/never-learned HTTP front doors)

    /// Last fetch attempt per relay, so a media-miss storm can't hammer the same relay.
    private var relayInterfaceRefreshMs: [String: UInt64] = [:]

    /// Fetch a relay's SELF-PUBLISHED interface (`haven/relay/__interface__` — its current public
    /// HTTP URLs + token + DERP/TURN, written by the relay process at startup) over the iroh
    /// channel that still works, and adopt it exactly like a frame-19 announce. This is the
    /// self-heal for the failure that stranded media while posts flowed: a CLI relay restart
    /// rotates its free-tunnel URL, every client keeps polling the mailbox over iroh (fine) and
    /// fetching media over a front door that no longer exists (dead) — and the paste-wire flow
    /// only ever ran once at adopt time. After adopting we re-announce, so members with no iroh
    /// reach — including builds older than this one — learn the URL from the mailbox.
    func refreshRelayInterfaceIfNeeded(_ nodeHex: String, force: Bool = false) {
        let lower = nodeHex.lowercased()
        // Only when we hold no HTTP interface, or every URL we hold is in its bad window — OR a
        // caller has just WATCHED the front door fail (`force`).
        //
        // Holding a URL is not evidence it works. A rotated free-tunnel hostname stays a perfectly
        // well-formed https URL forever, and `httpUrlBad` only marks it during a short cooldown
        // after a request fails — so this guard almost always early-returned and the device stayed
        // pinned to a front door that no longer exists. The one mechanism that can learn the new
        // hostname over iroh was therefore unreachable exactly when it was needed. Android had the
        // identical bug and the identical fix; this side was missed.
        if !force, let http = RelayMailboxStore.shared.httpInterface(lower),
           http.urls.contains(where: { !SharedStore.httpUrlBad($0) }) { return }
        let nowMs = now()
        if let last = relayInterfaceRefreshMs[lower], nowMs &- last < 300_000 { return }
        relayInterfaceRefreshMs[lower] = nowMs
        Task { @MainActor in
            guard let c = await RelayClients.client(lower) else { return }
            guard let data = await c.get(key: "haven/relay/__interface__"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  // A relay may only describe ITSELF — the key is served from its own store, but
                  // never adopt a doc whose node field disagrees with who we asked.
                  (obj["node"] as? String)?.lowercased() == lower,
                  let urls = obj["urls"] as? [String], !urls.isEmpty,
                  let token = obj["token"] as? String, !token.isEmpty
            else { return }
            HavenLog.relay("relay interface \(lower.prefix(10)): learned \(urls.count) url(s) over iroh — adopting + re-announcing")
            RelayMailboxStore.shared.setHttpInterface(lower, urls: urls, token: token)
            for u in urls { SharedStore.clearHttpUrlBad(u) }
            if let derp = obj["derp"] as? String, !derp.isEmpty {
                RelayMailboxStore.shared.setDerpUrl(lower, url: derp)
            }
            if let turn = obj["turn"] as? [String], !turn.isEmpty {
                RelayMailboxStore.shared.setTurn(lower, urls: turn,
                                                 user: obj["turnUser"] as? String ?? "",
                                                 pass: obj["turnPass"] as? String ?? "")
            }
            // React like a frame-19 that taught us a public URL: pull what we were missing and
            // push what the circle was missing, then re-announce so everyone else learns it too.
            let circles = RelayMailboxStore.shared.relaysByCircle
                .filter { $0.value.contains(lower) }.map(\.key)
            if !circles.isEmpty {
                backfillMailbox(circleIds: circles)
                backfillMailboxMedia(circleIds: circles)
            }
            pollMailboxNow()
            reannounceOwnRelay()
        }
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
    /// Refs already proven openable, and refs already asked about — so a probe runs once per ref
    /// per launch and an author is asked at most once per ref per launch.
    private static var mediaProbed = Set<String>()
    private static var mediaAskedForReseal = Set<String>()

    /// HELD is not the same as READABLE, and only one of those is what a user sees.
    ///
    /// A blob we hold but cannot open is excluded from the missing sweep — the bytes ARE on disk —
    /// so nothing notices and nothing repairs it. Media is sealed once to a fixed recipient list and
    /// never re-sealed, so a member who joined after a post can never open its media: the bytes
    /// arrive perfectly and decrypt to nothing, forever, while the post's text renders fine. Android
    /// hit exactly this and sat at "0 missing" with 23 broken tiles.
    ///
    /// So actually TEST a few held refs per pass and ask the author to re-seal the failures. Bounded
    /// per pass (an open attempt is real crypto over real bytes) and once per ref per launch, so the
    /// total cost is the size of the library rather than a rate.
    func verifyHeldMedia(limit: Int = 6) {
        guard let social else { return }
        var tested = 0
        for c in circles {
            if tested >= limit { break }
            for item in social.feed(circleId: c.id, nowMs: now(), viewerRetentionSecs: nil) {
                if tested >= limit { break }
                for ref in item.media {
                    if tested >= limit { break }
                    if MediaStore.isSynthetic(ref) || Self.mediaProbed.contains(ref) { continue }
                    guard MediaStore.shared.has(ref), let sealed = MediaStore.shared.rawBytes(ref) else { continue }
                    Self.mediaProbed.insert(ref)
                    tested += 1
                    if social.openCircleMedia(circleId: c.id, sealed: sealed) != nil { continue }
                    guard !Self.mediaAskedForReseal.contains(ref) else { continue }
                    Self.mediaAskedForReseal.insert(ref)
                    HavenLog.sync("held-but-unreadable \(ref.prefix(10)) — asking \(item.authorShort.prefix(8)) to re-seal")
                    requestMediaWhenAvailable(ref: ref, circleId: c.id, postId: item.id,
                                              authorShort: item.authorShort)
                }
            }
        }
    }

    /// `manual` = a PERSON tapped "Notify me when it's back". The held-but-unreadable sweep calls
    /// this too, constantly and on its own, and those asks must stay silent — see MediaWantedStore.
    func requestMediaWhenAvailable(ref: String, circleId: String, postId: String, authorShort: String,
                                   manual: Bool = false) {
        // MY OWN MEDIA NEEDS NOBODY'S PERMISSION.
        //
        // A held-but-unreadable blob I authored used to end here: ContactsStore cannot resolve ME —
        // I am not my own contact — so it logged "author not resolvable" and gave up, every launch,
        // forever. Observed on device: four refs authored by this account, all bailing, while
        // friend-authored refs in the same sweep sent their asks fine.
        //
        // There is nothing to ask for. If I still hold the plaintext I can re-seal it locally to the
        // CURRENT recipient set, which is exactly what the request would have asked a peer to do.
        if authorShort.isEmpty || myNodeHex.lowercased().hasPrefix(authorShort.lowercased()) {
            guard let social, MediaStore.shared.has(ref) else {
                // NO PLAINTEXT ON *THIS* DEVICE — which on a multi-device account is not the same as
                // "there is nothing to ask for". It means asking the device that does have it.
                //
                // This used to log and give up, on the reasoning above that my own media needs
                // nobody's permission. True of the ACCOUNT, false of the DEVICE: a post made on the
                // phone leaves the Mac holding no bytes at all, so every ask for it died right here —
                // including the one behind "Notify me when it's back", which therefore did nothing
                // whatsoever on the one platform where the media was actually missing. The ask is the
                // ordinary frame-3 media request, which now reaches my own devices (see askForMedia)
                // and, on arrival, also prompts them to re-check the relay copy
                // (`reverifyBackupAfterDirectAsk`) — so a stored copy that went bad gets repaired at
                // the source rather than just streamed peer-to-peer this once.
                HavenLog.sync("media-wanted \(ref.prefix(10)): MINE but no plaintext here — asking my other devices")
                MediaWantedStore.shared.add(ref, manual: manual)
                mediaReqCircle[ref] = circleId
                var ask = Data(myNodeHex.utf8); ask.append(Data(ref.utf8))
                liveDeliverToMyDevices(3, ask)
                nearbyBroadcast(3, ask)
                return
            }
            HavenLog.sync("media-wanted \(ref.prefix(10)): MINE — re-sealing locally, no peer needed")
            MediaBackupQueue.shared.enqueue(ref, circleId: circleId, social: social, priority: true)
            return
        }
        guard let authorHex = ContactsStore.shared.idHex(forNodePrefix: authorShort) else {
            HavenLog.sync("media-wanted \(ref.prefix(10)): author not resolvable — cannot ask")
            return
        }
        MediaWantedStore.shared.add(ref, manual: manual)
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
        // Holding the SEALED blob is not enough to repair it. An asker who cannot open a blob is,
        // almost always, not one of its recipients — media is sealed once to a fixed list and never
        // re-sealed, so anyone who joined later is permanently excluded. Fixing that needs a FRESH
        // seal, which needs the PLAINTEXT. Re-uploading a sealed copy someone else produced puts the
        // very same recipient list back and then answers "it's back" — true, and useless: the asker
        // re-fetches identical bytes, fails identically, and asks again forever. Only the device that
        // still holds the original can repair this; stay quiet so the ask reaches one that can.
        guard MediaStore.shared.hasLocalFile(ref) else {
            HavenLog.sync("media-wanted \(ref.prefix(10)) from \(from.prefix(8)) — I hold only a SEALED copy, not the plaintext; cannot re-seal, not answering")
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
        // A repeat ask is answered from the earlier upload — but ONLY once this ref has actually
        // been RE-SEALED at least once in this session. The 10-minute timer alone could swallow the
        // very first repair: a peer that could not open a blob asked, we had served that ref minutes
        // earlier for an unrelated reason, and we replied "it's back" without re-sealing. Nothing
        // changed, they re-fetched identical bytes, failed identically, and asked again — so whether
        // a photo ever got repaired depended on where its ask landed in the window, which reads as
        // "some media loads, some doesn't, at random". A ref we HAVE re-sealed is genuinely as good
        // as it will get until the circle changes, so caching that answer is honest and bounded.
        if !mediaResealedThisSession.contains(ref) {
            HavenLog.sync("media-wanted \(ref.prefix(10)): never re-sealed this session — repairing rather than answering from cache")
        } else if let at = mediaWantedServedAt[ref], Date().timeIntervalSince(at) < 600 {
            HavenLog.sync("media-wanted \(ref.prefix(10)): served recently — answering \(from.prefix(8)) without re-uploading")
            sendMediaAvailable(ref: ref, circleId: circleId, postId: postId, to: from)
            return
        }
        HavenLog.sync("media-wanted \(ref.prefix(10)) from \(from.prefix(8)) — re-uploading to a shared relay")
        mediaWantedInFlight.insert(ref)
        Task { @MainActor in
            defer { self.mediaWantedInFlight.remove(ref) }
            // reseal: a peer asking means THEY cannot open it. Re-uploading the cached seal would
            // put back bytes addressed to the same recipients that already excluded them.
            let ok = await SharedStore.backup(ref: ref, circleId: circleId, social: social, force: true, reseal: true)
            guard ok else {
                HavenLog.sync("media-wanted \(ref.prefix(10)): re-upload failed — they'll re-ask")
                return
            }
            self.mediaWantedServedAt[ref] = Date()
            self.mediaResealedThisSession.insert(ref)
            if self.mediaWantedServedAt.count > 500 { self.mediaWantedServedAt.removeAll() }
            if self.mediaResealedThisSession.count > 1000 { self.mediaResealedThisSession.removeAll() }
            self.sendMediaAvailable(ref: ref, circleId: circleId, postId: postId, to: from)
            HavenLog.sync("media-wanted \(ref.prefix(10)): back on a relay, told \(from.prefix(8))")
        }
    }

    /// Refs genuinely RE-SEALED since launch. The serve cache may only answer for these: a ref we
    /// have never re-sealed has nothing to answer WITH, and saying "it's back" about bytes we did
    /// not touch is what let a broken photo stay broken while both sides reported success.
    private var mediaResealedThisSession = Set<String>()

    /// Refs currently being re-uploaded, and when each was last served — see the bounding note above.
    private func sendMediaAvailable(ref: String, circleId: String, postId: String, to peer: String) {
        var f = Data(myNodeHex.utf8)
        lpAppend(&f, Data(ref.utf8))
        lpAppend(&f, Data(circleId.utf8))
        lpAppend(&f, Data(postId.utf8))
        sendCallFrame(32, f, to: peer)
    }

    /// Author-side push-ahead: a FRESH post's blob just reached a relay (MediaBackupQueue priority
    /// lane) — proactively tell the whole circle with the SAME frame-32 shape as the ask-back
    /// reply (sendCallFrame covers iroh + the frame-9 relay forward + the HTTP live lane), plus a
    /// silent push so a backgrounded member wakes and prefetches. This is what makes media drop in
    /// WITH the post instead of on the recipient's next 90s sweep. postId is best-effort (a
    /// deep-link nicety); the receiver keys on the ref.
    func announceMediaLanded(ref: String, circleId: String) {
        guard social != nil else { return }
        let postId = messages(in: circleId).first(where: { item in
            item.isMe && (item.media.contains(ref)
                          || MediaVariants.allThumbs(in: item.media).contains(ref)
                          || MediaVariants.allPosters(in: item.media).contains(ref))
        })?.id ?? ""
        var f = Data(myNodeHex.utf8)
        lpAppend(&f, Data(ref.utf8))
        lpAppend(&f, Data(circleId.utf8))
        lpAppend(&f, Data(postId.utf8))
        for member in memberHexes(circleId: circleId) {
            sendCallFrame(32, f, to: member)
            PushManager.shared.wake(member, ciphertext: nil, event: nil, silent: true)
        }
        HavenLog.sync("media-landed \(ref.prefix(10)) announced to circle \(circleId.prefix(12))")
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
        guard MediaWantedStore.shared.isWanted(ref) else {
            // Not something we asked for → an author's push-ahead announce (their fresh post's
            // media just landed on a relay). Prefetch it anyway — bounded, deduped, and
            // data-saver aware (videos stay tap-to-play under super data saver). No notification:
            // the POST's banner is the news; this is just its media arriving on time.
            guard !MediaStore.isSynthetic(ref), !MediaStore.shared.has(ref),
                  !EvictedMediaStore.shared.contains(ref) else { return }
            if SettingsStore.shared.dataSaverActive,
               !(ref.hasPrefix("img_") || ref.hasPrefix("i:") || ref.hasPrefix("aud_")
                 || ref.hasPrefix("a:") || ref.hasPrefix("file_")) { return }
            let nowMs = now()
            if let last = announcedMediaAt[ref], nowMs &- last < 60_000 { return }
            announcedMediaAt[ref] = nowMs
            if announcedMediaAt.count > 500 { announcedMediaAt.removeAll() }
            MediaFetchBackoff.clear(ref)   // it's on a relay NOW — restart any parked schedule
            waitingForSenderMedia.remove(ref)
            requestMedia(ref, circleId: circles.contains(where: { $0.id == circleId }) ? circleId : nil)
            HavenLog.sync("media-available \(ref.prefix(10)): announced by \(from.prefix(8)) — prefetching")
            return
        }
        // Take the manual flag BEFORE clear() drops it.
        let personAsked = MediaWantedStore.shared.takeManual(ref)
        MediaWantedStore.shared.clear(ref)
        unavailableMedia.remove(ref)
        waitingForSenderMedia.remove(ref)
        MediaFetchBackoff.clear(ref)
        EvictedMediaStore.shared.clear(ref)
        requestMedia(ref)   // pull it now, while we know it's there
        // Silent unless the user personally asked. The held-but-unreadable sweep asks on its own,
        // for media the user has never heard of — a night of automatic repair arriving as a stack of
        // "X put back the media you asked for" is the report this fixes. The fetch above still runs;
        // what a user wants is the picture to appear, which it does either way.
        guard personAsked else {
            HavenLog.sync("media-wanted \(ref.prefix(10)): author says it's back — fetching (automatic, no notification)")
            return
        }
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
        // SEALING RUNS OFF THE MAIN ACTOR. This is per-frame crypto, and ICE emits a candidate
        // frame per candidate — dozens during setup, each one previously sealing on the main
        // thread while the user was tapping mute/video/flip. Combined with the AVCaptureSession
        // work (now also off-main, see WebRTCCall.captureQueue) that is what made in-call controls
        // feel dead. The hop back for delivery keeps send ordering on one actor as before.
        guard let social else { return }
        Task.detached(priority: .userInitiated) {
            let sealedOpt = await EngineGate.shared.run {
                try? social.sealCallFrame(recipientNodeHex: nodeHex, frameType: type, data: payload)
            }
            guard let sealed = sealedOpt, !sealed.isEmpty else {
                let known = await EngineGate.shared.run { social.deviceNodeIdsFor(accountHex: nodeHex).count }
                HavenLog.call("call frame type=\(type) NOT SENT to \(nodeHex.prefix(8)) — seal failed (recipient unresolvable: \(known) known device id(s), \(sealedOpt == nil ? "threw" : "empty"))")
                return
            }
            await MainActor.run { FeedStore.shared.deliverSealedCallFrame(type, sealed, to: nodeHex) }
        }
    }

    /// Fan a SEALED call frame out over every transport. Split from `sendCallFrame` so the crypto
    /// can happen off the main actor while delivery stays serialized here.
    fileprivate func deliverSealedCallFrame(_ type: UInt8, _ sealed: Data, to nodeHex: String) {
        let wire = frame(type, sealed)
        sendIroh(type, sealed, to: nodeHex)
        // Cross-NAT fallback: hop the same SEALED frame LIVE through the circle relays (frame 9 — the
        // relay host unwraps + sends it onward over its own connections). The nearby originateRelay
        // flood never leaves the room, so a callee whose direct dial back to the caller failed had
        // NO way to deliver the ACCEPT — the push rang her, but the answer died in the NAT. The relay
        // only ever handles the sealed blob; it cannot read or alter the signaling.
        var dests = social?.deviceNodeIdsFor(accountHex: nodeHex) ?? []
        if !dests.contains(where: { $0.lowercased() == nodeHex.lowercased() }) { dests.append(nodeHex) }
        if dests.count <= 1 {
            for h in deviceHints(for: nodeHex) where !dests.contains(where: { $0.lowercased() == h }) {
                dests.append(h)
                if dests.count >= 3 { break }
            }
        }
        originateRelayInternet(dests: dests, inner: wire)
        // HTTP live-lane: account + roster devices only (avoid flooding every historical hint).
        let liveDests = dests
        // ONLY circles the destination is actually in.
        //
        // This passed EVERY circle, and uploadLiveCallFrames loops circles x dests x relays — so one
        // sealed call frame became ~60 HTTP PUTs on a device in 10 circles with 6 destinations.
        // Measured as a 110-line burst of `live-call http-put OK` in an otherwise quiet minute, and
        // it is the largest remaining radio user after the fan-out floor landed.
        //
        // A PUT into a circle the destination is not a member of is waste BY DEFINITION: they cannot
        // read that circle's mailbox, so the frame can never be ingested from it. This narrows the
        // work without narrowing reachability — every circle that could actually carry the frame is
        // still used, which is what makes the cross-NAT ACCEPT fallback work.
        //
        // Falls back to every circle if membership cannot be resolved, so an unknown roster degrades
        // to the old behaviour rather than dropping the call's answer.
        let me = nodeHex.lowercased()
        let member = self.circles.map(\.id).filter { cid in
            (social?.contactNodeIds(circleId: cid) ?? []).contains { $0.lowercased() == me }
        }
        let cids = member.isEmpty ? self.circles.map(\.id) : member
        Task { await SharedStore.uploadLiveCallFrames(circleIds: cids, dests: liveDests, frame: wire) }
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
        nearby?.broadcast(frame(9, p), class: .control)
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
        #if os(iOS)
        // Pocketed: refuse. Peer mesh ask + URLSession restore outlive the wake completion and
        // are what still racked multi-hour Background after the 1.4.1/1.4.2 parks. Media lands
        // when the user opens the app (or via NSE app-group prefetch).
        guard appIsForeground else { return }
        #endif
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
                MediaStore.shared.store(ref, data); mediaArrived(ref); MediaFetchBackoff.clear(ref)
                autoSaveReceived(ref); scheduleRefresh()
            }
        }
    }

    // MARK: - Missing-media fetch lanes (fresh vs old)
    //
    // FRESH lane: refs referenced by events created < 5 min ago retry on a fast bounded backoff
    // (5s → 10s → 20s → 45s → 90s, then park) on their OWN 5s timer — so a post's media drops in
    // seconds after the author's upload lands, instead of waiting out a flat 90s throttle. The
    // fresh state is in-memory: freshness itself expires in minutes.
    //
    // OLD lane: everything else grows 90s → 5m → 30m → 6h (mirror of MediaBackupBackoff), with
    // the schedule PERSISTED so a relaunch doesn't snap a long-dead ref back to the tight cadence
    // — that reset was a steady heat source on every open. After the last round the ref moves to
    // `unavailableMedia` (the placeholder's Retry / Ask-for-it-back state); a tap retry or a fresh
    // ingest of the same ref restarts the schedule.
    private static let freshEventMs: UInt64 = 5 * 60_000
    /// Older than this and a newly-ingested post is BACKFILL (archive import / history sync), not
    /// news — its full-size media prefetch becomes lazy. See the `backfill` gate in `scan`.
    /// A week is comfortably past anything the live feed treats as recent, so normal posting and
    /// normal catch-up after a few days offline are untouched.
    private static let backfillLazyMs: UInt64 = 7 * 24 * 60 * 60 * 1000
    private static let fastSteps: [UInt64] = [5_000, 10_000, 20_000, 45_000, 90_000]
    private var fastReq: [String: (n: Int, due: UInt64)] = [:]
    private var fastMediaTimer: Timer?
    /// Refs whose spent backoff has already been given its one free attempt this launch, and how many
    /// such attempts are left overall — see the `exhausted` branch in `requestMissingMedia`.
    private var retriedExhaustedThisLaunch: Set<String> = []
    private var exhaustedRetryBudget = 24
    /// Last resume ask per ref with a live, growing partial — the heartbeat that keeps a peer transfer
    /// moving once the sender's one-pass serve ends. See the in-flight branch in `requestMissingMedia`.
    private var resumeAskAt: [String: UInt64] = [:]
    private var thumbReqAt: [String: UInt64] = [:]   // thumbs: plain 90s throttle, no lanes
    private var lastMediaScanMs: UInt64 = 0
    /// Rotating pointer over non-active circles — one extra circle scanned per pass (bounded),
    /// covering them all across successive passes.
    private var otherCircleScanIdx = 0

    /// Keep the fresh-lane 5s timer armed exactly while fresh refs are still retrying.
    private func armFastMediaTimer(_ active: Bool) {
        if active {
            #if os(iOS)
            // Never arm while pocketed — a 5s media retry loop under a wake assertion is the
            // residual that still showed multi-hour Background after 1.4.1/1.4.2.
            guard appIsForeground else { return }
            #endif
            guard fastMediaTimer == nil else { return }
            fastMediaTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    #if os(iOS)
                    guard self.appIsForeground else {
                        self.armFastMediaTimer(false)
                        return
                    }
                    #endif
                    self.lastMediaScanMs = 0   // the fresh lane bypasses the 2s scan gate
                    self.requestMissingMedia()
                }
            }
        } else {
            fastMediaTimer?.invalidate()
            fastMediaTimer = nil
        }
    }

    /// Run a media-prefetch pass now, because the network just got better.
    ///
    /// Low-data mode suppresses media prefetch on a constrained link (`docs/SATELLITE-DESIGN.md` §5).
    /// Without this, the bytes that were held back wait for whatever happens to refresh the feed
    /// next — which, for someone who put their phone away off-grid and pulled it out again in
    /// coverage, can be a long time. This is the moment the deferred half of a satellite post
    /// completes itself, so it fires on the transition rather than on a timer.
    ///
    /// Cheap and idempotent: `requestMissingMedia` already skips refs that are present, in flight,
    /// or deliberately evicted.
    func nudgeMediaPrefetchNow() {
        requestMissingMedia()
        // Both halves of a deferred post complete here. Receiving is `requestMissingMedia` above;
        // SENDING is the backup queue, which holds everything but the preview while the link is
        // ultra-constrained (`MediaBackupQueue.drain`). Without this kick the queue waits for its
        // own next pass, and the photo someone sent from a dead zone stays half-delivered after
        // they are plainly back on Wi-Fi.
        if let social { MediaBackupQueue.shared.drainPersisted(social: social) }
    }

    private func requestMissingMedia() {
        #if os(iOS)
        // Pocketed: no media scan, no peer asks, no restore Tasks. slimBackgroundSync owns
        // envelopes only; media loads on the next open. Without this, ingest side-effects of a
        // push wake re-arm the 5s lane and keep the radio warm past completionHandler.
        guard appIsForeground else { return }
        #endif
        verifyHeldMedia()   // held != readable — a blob we hold but cannot open is invisible here
        guard let social, node != nil || nearby != nil else { return }
        // The scan below is O(items × media) with a stat() per ref (MediaStore.has) — cap it to
        // once per 2s on the main actor; per-ref request throttles below stay unchanged.
        let nowMs = now()
        guard nowMs - lastMediaScanMs > 2_000 else { return }
        lastMediaScanMs = nowMs
        let myHex = social.myNodeHex()
        // Skip synthetic refs (geo: location pins): they carry no fetchable bytes, so counting them
        // keeps nbMediaPending pinned above 0 forever and fires a doomed restore each sweep.
        // Skip refs the user DELIBERATELY evicted (cleanup screen / local-limit sweep). Auto-refetching
        // them would silently undo the space the user just freed — they re-download only on an explicit
        // "Download" tap (downloadEvicted clears the eviction first). Still fetch media never seen yet.
        // Skip session-unopenable refs: the bytes ARE on a relay and can't be decrypted — re-pulling
        // the same bad blob every sweep repaired nothing and cost a full download each time.
        let dataSaver = SettingsStore.shared.dataSaverActive
        var missing: [String: (circleId: String, fresh: Bool)] = [:]
        var thumbs: [String: String] = [:]   // thumb image ref → circle (prefetched unconditionally)
        func scan(_ item: FeedItemFfi, circleId: String) {
            let fresh = nowMs >= item.createdAt && nowMs &- item.createdAt < Self.freshEventMs
            // BACKFILL IS LAZY. A post whose creation date is far older than now did not just
            // happen — it arrived from an archive import or a history sync. Prefetching those
            // eagerly is how one member importing a back-catalogue turns into every other member
            // silently downloading gigabytes: an Instagram archive is ~370 posts / 1100 files / 1.2 GB,
            // and a viewer on the DEFAULT retention (0 = forever) expires none of it, so every last
            // byte would land on their phone the moment they opened the circle.
            //
            // Thumbs and posters below are deliberately still prefetched — they are ≤32 KB by
            // contract and are what makes the feed look right — so backfilled history renders
            // immediately as browsable tiles and the full photo/video downloads when it is actually
            // opened (`requestMedia` on tap). Fresh posts are unaffected: real news still arrives
            // eagerly, which is what makes media feel instant in a live circle.
            let backfill = nowMs >= item.createdAt && nowMs &- item.createdAt > Self.backfillLazyMs
            // Super data saver: only prefetch posters/images/audio/files — never full videos or
            // original companions. Videos download when the user taps play; originals via the menu.
            let candidates: [String] = backfill ? []
                : dataSaver ? MediaVariants.dataSaverPrefetchRefs(item.media)
                : item.media
            // NOTE: `unopenableMedia` is deliberately NOT a gate here — it gates the RELAY half of
            // `fetch` instead. The flag means "the stored copy we downloaded could not be decrypted",
            // which is a statement about a relay blob and nothing else. Excluding the ref from the
            // scan also silenced the PEER ask, which travels a different lane under a different key
            // (the account-derived own-media key) and is frequently the one that works — so a relay
            // copy sealed to a recipient set we're not in would kill an own-device transfer that was
            // actively succeeding, mid-flight, and nothing ever re-asked. Observed exactly that: a
            // peer transfer died at 823/1231 chunks the moment a relay copy failed to open.
            for ref in candidates where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref)
                && !EvictedMediaStore.shared.contains(ref) {
                if missing[ref] == nil || fresh { missing[ref] = (circleId, fresh) }
            }
            // Thumb companions prefetch for EVERY post regardless of lane/data saver — ≤32KB by
            // contract, and they're what makes the loading placeholder look like the photo.
            for t in MediaVariants.allThumbs(in: item.media)
                where !MediaStore.shared.has(t) && !unopenableMedia.contains(t) {
                thumbs[t] = circleId
            }
            // PREVIEWS ride the same priority lane, and must: a preview ref is named only INSIDE its
            // marker and never listed in `item.media`, so nothing else ever asks for it. Without
            // this a satellite post arrives with a `preview:` marker pointing at bytes the receiver
            // never requests — observed exactly that, with the 8 KB preview absent while the 500 KB
            // original had been served instead.
            for v in MediaVariants.allPreviews(in: item.media)
                where !MediaStore.shared.has(v) && !unopenableMedia.contains(v) {
                thumbs[v] = circleId
            }
            // POSTERS ride the same priority lane, for the same reason: a poster is a small still,
            // not a video. It used to queue in `missing` behind the full-size clips — so the tile
            // had no poster for as long as the video backlog took, and fell back to generating one
            // locally from the received file. That is the wrong fix twice over: it is expensive
            // (every attempt costs a VideoToolbox decode session, and exhausting them is what
            // produces `-11800 / -12433 … not retrying this file`), and it is unnecessary, because
            // the sender already cut a poster and shipped it — we simply had not fetched it yet.
            // Prefetching it means the tile is right on arrival and no decode session is spent.
            for p in MediaVariants.allPosters(in: item.media)
                where !MediaStore.shared.has(p) && !unopenableMedia.contains(p) {
                thumbs[p] = circleId
            }
            for c in item.comments {
                // Same lazy rule as the post itself — a backfilled thread's attachments load on tap.
                let cands: [String] = backfill ? []
                    : dataSaver ? MediaVariants.dataSaverPrefetchRefs(c.media) : c.media
                for ref in cands where !MediaStore.isSynthetic(ref) && !MediaStore.shared.has(ref)
                    && !EvictedMediaStore.shared.contains(ref) && !unopenableMedia.contains(ref) {
                    if missing[ref] == nil || fresh { missing[ref] = (circleId, fresh) }
                }
                for t in MediaVariants.allThumbs(in: c.media) + MediaVariants.allPosters(in: c.media)
                    where !MediaStore.shared.has(t) && !unopenableMedia.contains(t) {
                    thumbs[t] = circleId
                }
            }
        }
        for item in items { scan(item, circleId: activeCircleId) }
        // ALL circles, newest-first, budget-bounded: rotate one NON-active circle per pass so its
        // posts prefetch too — media used to download only for the circle you were LOOKING at, so
        // switching circles always meant a wall of placeholders. DMs keep their own dedicated path
        // (requestMissingDMMedia, driven off ingest).
        let others = circles.map(\.id).filter { $0 != activeCircleId && !$0.hasPrefix("dm:") }
        if !others.isEmpty {
            otherCircleScanIdx = (otherCircleScanIdx + 1) % others.count
            let cid = others[otherCircleScanIdx]
            for item in messages(in: cid).sorted(by: { $0.createdAt > $1.createdAt }).prefix(12) {
                scan(item, circleId: cid)
            }
        }
        let circleIds = circles.map { $0.id }
        SyncMetrics.shared.nbMediaPending = missing.count
        let hasMailbox = circleIds.contains(where: { SharedStore.hasMailbox($0) })

        // One fetch attempt for `ref` — relay-first, then the peer ask (shared tail of both lanes).
        // RELAY-FIRST: pull the stored copy from the circle's mailbox (own hosted store → relay
        // HTTP :8674 → S3 → iroh blob, in that order inside restore). Only if there is NO mailbox,
        // or the stored copy can't be fetched, fall back to asking an online author/peer directly.
        func fetch(_ ref: String, circleId: String) {
            mediaReqCircle[ref] = circleId
            var payload = Data(myHex.utf8)          // 64-byte requester id
            payload.append(Data(ref.utf8))
            let directAsk = { self.askForMedia(ref: ref, myHex: myHex, plain: payload) }
            // The relay's copy is present and undecryptable: re-pulling it repairs nothing and costs a
            // full download every sweep — that is what this flag is for. It bounds the RELAY half
            // only. The peer ask still goes out, because it carries different bytes under a different
            // key and is exactly the lane that can still succeed here.
            if unopenableMedia.contains(ref) {
                directAsk()
                return
            }
            if hasMailbox {
                downloadingMedia.insert(ref)   // honest placeholder: an AUTO restore IS a download
                Task { @MainActor in
                    defer { if !MediaStore.shared.has(ref) { self.downloadingMedia.remove(ref) } }
                    if let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                        HavenLog.relay("MEDIA-FETCH ok ref=\(ref.prefix(10)) bytes=\(data.count) via=relay")
                        MediaStore.shared.store(ref, data); self.mediaArrived(ref)
                        MediaFetchBackoff.clear(ref); self.fastReq[ref] = nil
                        self.autoSaveReceived(ref); self.scheduleRefresh()
                    // A relay REFUSED us rather than lacking the blob: publish our device roster to it
                    // and try once more. Without this the fetch degrades to a peer ask that only works
                    // while the author happens to be online — which is exactly how media a few days old
                    // became permanently unreachable while fresh media (author still around) looked fine.
                    } else if await SharedStore.healForbiddenRelays(social: social),
                              let data = await SharedStore.restore(ref: ref, circleIds: circleIds, social: social) {
                        HavenLog.relay("MEDIA-FETCH ok ref=\(ref.prefix(10)) bytes=\(data.count) via=relay (after roster publish)")
                        MediaStore.shared.store(ref, data); self.mediaArrived(ref)
                        MediaFetchBackoff.clear(ref); self.fastReq[ref] = nil
                        self.autoSaveReceived(ref); self.scheduleRefresh()
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

        // FRESH lane: 5s/10s/20s/45s/90s, then park (the ref ages into the old lane naturally).
        var fastActive = false
        var fastBudget = ThermalPolicy.mediaBudget(8)
        for (ref, info) in missing where info.fresh {
            let st = fastReq[ref] ?? (n: 0, due: 0)
            guard st.n < Self.fastSteps.count else { continue }   // fast rounds spent — parked
            fastActive = true
            guard nowMs >= st.due, fastBudget > 0 else { continue }
            fastBudget -= 1
            fastReq[ref] = (n: st.n + 1, due: nowMs + Self.fastSteps[st.n])
            fetch(ref, circleId: info.circleId)
        }
        if fastReq.count > 500 { fastReq = fastReq.filter { missing[$0.key] != nil } }
        armFastMediaTimer(fastActive)

        // OLD lane: parked entirely at .serious+ (thermal), halved budget at .fair.
        if !ThermalPolicy.parkMediaRetries {
            var budget = ThermalPolicy.mediaBudget(12)
            for (ref, info) in missing where !info.fresh {
                guard budget > 0 else { break }
                // AN ACTIVE PEER TRANSFER OUTRANKS THE RELAY BACKOFF.
                //
                // The ladder below is about RELAY fetches — how long to wait before re-asking a store
                // that hasn't got the bytes. A partial that is still GROWING is the opposite case: the
                // bytes are arriving. But a serve is one pass over the file and then it ends, so the
                // remainder only moves if we send another resume ask — and the backoff (or the
                // one-attempt-per-launch rule below it) silences exactly that. Observed: an own-device
                // transfer climbed 823 → 889 → 1101 of 1231 chunks and then stopped dead, with the
                // sender online and holding the rest, because nothing was left to ask again.
                //
                // Throttled per ref so this is a heartbeat, not a flood; `askForMedia` sends frame 33
                // with our bitmap, so each ask costs the sender only the windows we still lack.
                if let partial = incoming[ref], !partial.got.isEmpty, partial.got.count < partial.total {
                    let last = resumeAskAt[ref] ?? 0
                    guard nowMs &- last >= 10_000 else { continue }
                    resumeAskAt[ref] = nowMs
                    if resumeAskAt.count > 500 { resumeAskAt = resumeAskAt.filter { missing[$0.key] != nil } }
                    budget -= 1
                    // It is visibly arriving — don't leave the card claiming it never will.
                    unavailableMedia.remove(ref)
                    HavenLog.net("media resume ref=\(ref.prefix(10)): \(partial.got.count)/\(partial.total) held — re-asking for the rest")
                    var payload = Data(myHex.utf8); payload.append(Data(ref.utf8))
                    askForMedia(ref: ref, myHex: myHex, plain: payload)
                    continue
                }
                if MediaFetchBackoff.exhausted(ref) {
                    // Every round spent → the honest end state (placeholder offers Retry and
                    // Ask-for-it-back; a tap or fresh ingest clears the backoff and starts over).
                    //
                    // ONE FRESH ATTEMPT PER LAUNCH before parking it again. The schedule is persisted
                    // on purpose — resetting it on every open was a steady heat source — but the
                    // consequence was that a ref which spent its rounds was never tried again by
                    // ANYTHING: not a new app version, not a relay coming back, not a different
                    // network, not the author re-uploading. "It will never load" was literally true,
                    // and only a manual tap could change it. That is also how a bug fixed in the code
                    // stays invisible in the field: the repaired fetch path is gated shut upstream and
                    // never runs. (Found exactly that way — a stuck video sat at n=4 while the fix for
                    // it shipped underneath, untouched.)
                    //
                    // Bounded twice over: once per ref per launch (the set), and a small per-launch
                    // budget so a library full of long-dead refs can't turn a cold start into a fetch
                    // storm. The persisted schedule is deliberately NOT cleared — this is one extra
                    // attempt, not a restart of the ladder.
                    guard exhaustedRetryBudget > 0, retriedExhaustedThisLaunch.insert(ref).inserted else {
                        unavailableMedia.insert(ref)
                        continue
                    }
                    exhaustedRetryBudget -= 1
                    budget -= 1
                    HavenLog.relay("MEDIA-FETCH ref=\(ref.prefix(10)): rounds spent — one fresh attempt for this launch")
                    // `unavailableMedia` is left alone: if this attempt works `mediaArrived` clears it,
                    // and if it doesn't the placeholder never flickered out of its honest state.
                    fetch(ref, circleId: info.circleId)
                    continue
                }
                guard MediaFetchBackoff.due(ref) else { continue }
                budget -= 1
                MediaFetchBackoff.recordAttempt(ref)
                fetch(ref, circleId: info.circleId)
            }
        }

        // Thumbs: no lanes, no data-saver gate, no thermal budget — a plain 90s per-ref throttle.
        for (t, cid) in thumbs {
            if let at = thumbReqAt[t], nowMs &- at < 90_000 { continue }
            thumbReqAt[t] = nowMs
            fetch(t, circleId: cid)
        }
        if thumbReqAt.count > 2000 { thumbReqAt.removeAll() }
    }

    private func handleMediaRequest(_ payload: Data) {
        guard payload.count > 64 else { return }
        let requesterHex = String(data: payload.prefix(64), encoding: .utf8) ?? ""
        let ref = String(data: payload.dropFirst(64), encoding: .utf8) ?? ""
        guard requesterHex.count == 64, !ref.isEmpty else { return }
        let haveLocal = MediaStore.shared.storagePath(for: ref).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        HavenLog.net("media REQ ref=\(ref.prefix(12)) have=\(haveLocal) from=\(requesterHex.prefix(8))")
        // ULTRA-CONSTRAINED LINK: serve only what may cross it.
        //
        // The upload gate covered MediaBackupQueue — pushing blobs to relays — and nothing else. A
        // peer that simply ASKS for media went through this path, which served whatever was on disk
        // regardless of the link. On a forced satellite link the far side ended up with the 500 KB
        // original and NOT the 8 KB preview: exactly the two things reversed. Refusing here is safe
        // — the requester re-asks, and once the constraint clears the full copy goes as normal.
        if LowDataMonitor.shared.effective == .ultra,
           !MediaStore.shared.maySendOnUltraConstrained(ref) {
            HavenLog.net("media REQ ref=\(ref.prefix(12)) — refused, link is ultra-constrained")
            return
        }
        if let url = MediaStore.shared.storagePath(for: ref), FileManager.default.fileExists(atPath: url.path) {
            // They had to come to US for bytes we already backed up — so a relay didn't serve them.
            // That is a signal about our own backup, not just a request to answer. See below.
            reverifyBackupAfterDirectAsk(ref)
            if servingNow.contains("\(ref)|\(requesterHex)") {
                HavenLog.net("media REQ ref=\(ref.prefix(12)) — already streaming to \(requesterHex.prefix(8)), ignoring")
            } else if shouldServeNearby(ref, requester: requesterHex) {
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

    /// Refs whose relay backup a direct ask has already prompted us to re-check.
    private var backupReverifiedAt: [String: UInt64] = [:]
    /// Once an hour per ref. A peer that still can't fetch re-asks on a timer, and a re-verify must
    /// never be allowed to become a re-upload storm.
    private static let backupReverifyIntervalMs: UInt64 = 3_600_000

    /// A peer asked us DIRECTLY for a blob we hold — meaning they could not fetch it from any relay
    /// we share. That is the only signal in the system that a STORED copy has gone bad, and until now
    /// nothing listened to it.
    ///
    /// `MediaBackupLedger` is write-once: a ref confirmed on a relay is never probed again. Right
    /// while a stored blob is immutable and complete; wrong the moment one isn't. A relay copy that
    /// is missing chunks stays missing forever — every reader stalls on the same absent window, and
    /// this device goes on showing the post with a confident "backed up" tick. Re-probing on a direct
    /// ask closes that loop with a signal that is cheap, rare, and exactly correlated with the failure.
    ///
    /// Deliberately NOT `force`: this is a probe. It re-uploads only the windows a destination turns
    /// out to actually lack (see `holdsCompleteBlob`), and does nothing when every copy checks out.
    @MainActor private func reverifyBackupAfterDirectAsk(_ ref: String) {
        guard let social, !MediaStore.isSynthetic(ref) else { return }
        let nowMs = now()
        if let at = backupReverifiedAt[ref], nowMs &- at < Self.backupReverifyIntervalMs { return }
        backupReverifiedAt[ref] = nowMs
        if backupReverifiedAt.count > 2000 { backupReverifiedAt.removeAll() }
        guard let cid = circleId(holding: ref) else { return }
        MediaBackupLedger.forget(ref)   // the verdict we're re-testing
        HavenLog.sync("media REQ \(ref.prefix(10)): asked directly for media we backed up — re-probing its relay copies")
        Task { @MainActor in _ = await SharedStore.backup(ref: ref, circleId: cid, social: social) }
    }

    /// The circle whose feed references `ref` — the one whose relays are supposed to hold its bytes.
    /// Only ever reached behind the hourly throttle above, so the feed walk is not a hot path.
    private func circleId(holding ref: String) -> String? {
        if let cid = mediaReqCircle[ref] { return cid }
        guard let social else { return nil }
        for c in circles {
            for item in social.feed(circleId: c.id, nowMs: now(), viewerRetentionSecs: nil) {
                if item.media.contains(ref) { return c.id }
                if item.comments.contains(where: { $0.media.contains(ref) }) { return c.id }
            }
        }
        return nil
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
        } else if shouldServeNearby(ref, requester: requesterHex, isResume: true) {
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
    ///
    /// MY OWN DEVICES GET THE ASK TOO. This used to fan out over iroh to `ContactsStore.contacts`
    /// and nothing else — and your own phone is not a contact, it lives in the account's device
    /// roster. So the only lane that ever carried an own-device media ask was the nearby (Multipeer)
    /// mesh, which needs both devices on the same LAN and actually peered. When it isn't, a video
    /// your phone is holding right there is unreachable from your Mac for as long as both sit open,
    /// with no diagnosis anywhere: the fetch just kept "asking peers" that could never answer.
    @MainActor private func askForMedia(ref: String, myHex: String, plain: Data) {
        guard let resume = resumeAsk(ref: ref, myHex: myHex) else {
            nearbyBroadcast(3, plain)
            for contact in ContactsStore.shared.contacts { sendIroh(3, plain, to: contact.idHex) }
            liveDeliverToMyDevices(3, plain)
            return
        }
        nearbyBroadcast(33, resume)
        for contact in ContactsStore.shared.contacts { sendIroh(33, resume, to: contact.idHex) }
        liveDeliverToMyDevices(33, resume)
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
            self.liveDeliverToMyDevices(3, plain)
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
    /// MultipeerConnectivity's serial send queue so NOTHING actually drained to the peer. One serve per
    /// ref+requester per 25s lets the queue clear and the chunks really deliver.
    ///
    /// **Resume is exempt** (short 3s floor only): a rate-limit abort used to stamp `servedAt` and then
    /// reject frame-33 resumes for 25s, so partial videos never refilled holes.
    private func shouldServeNearby(_ ref: String, requester: String? = nil, isResume: Bool = false) -> Bool {
        let nowMs = now()
        let key = requester.map { "\(ref)|\($0.prefix(16))" } ?? ref
        let window: UInt64 = isResume ? 3_000 : 25_000
        if let last = servedAt[key], nowMs - last < window { return false }
        servedAt[key] = nowMs
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
            guard shouldServeNearby(ref, requester: me) else { continue }
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
            // MY OWN DEVICES ALSO GET THE BYTES OVER IROH. This serve was nearby-ONLY while the
            // friend path below has always mirrored each chunk to `node.sendToNode` — so own-device
            // media had exactly one transport, the local Multipeer mesh, and off that LAN there was
            // no way at all for one of your devices to hand a blob to another. Combined with the ask
            // never reaching a sibling over iroh (see `askForMedia`), your own media between your own
            // devices was strictly LAN-only, which is not how any other frame in this app behaves.
            let ownTargets = myOtherDeviceTargets()
            // BOUNDED in-flight iroh sends. This loop runs on a plain dispatch queue and cannot await,
            // so each chunk's send is a detached Task — and without a gate a 1,231-chunk video spawns
            // 1,231 of them as fast as the file reads, with no backpressure whatsoever. The link then
            // drops what it can't keep up with, `try?` swallows every failure, and the transfer simply
            // stops partway with nothing logged. (Observed: a serve that died at 823/1,231.) The
            // semaphore turns the loop's own pace into the link's pace: it blocks once four sends are
            // outstanding, which is the backpressure the nearby lane already gets from
            // `broadcastWaiting`.
            let irohGate = DispatchSemaphore(value: 4)
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
                    let out = Data([5]) + frame
                    // Every sibling, over iroh, alongside the mesh broadcast. The chunk is sealed with
                    // the ACCOUNT-derived key, so only this user's own devices can open it however it
                    // travelled — the two lanes carry identical bytes and whichever arrives first wins
                    // at reassembly (chunks are content-addressed and idempotent).
                    if let node, !ownTargets.isEmpty {
                        irohGate.wait()
                        Task.detached {
                            defer { irohGate.signal() }
                            for t in ownTargets { try? await node.sendToNode(nodeIdHex: t, payload: out) }
                        }
                    }
                    // Wait for rate tokens — do NOT abort mid-video after one miss (photos fit the
                    // burst; multi‑MB videos did not and left partial reassemblies).
                    //
                    // A mesh give-up no longer ends the serve when iroh is carrying it too: with no
                    // peer on the nearby mesh at all, `broadcastWaiting` fails on chunk 0 and the old
                    // `break` abandoned the whole transfer — including the iroh copy that was working.
                    if mesh?.broadcastWaiting(out, class: .bulk, maxWaitMs: 8_000) != true {
                        HavenLog.net("media serve ref=\(ref.prefix(12)): nearby rate-limit at chunk \(index)/\(total)")
                        if ownTargets.isEmpty { break }
                    }
                    // Soft backpressure: pause if Multipeer backlog is high, but keep going.
                    if mesh?.sendBacklogHigh == true {
                        Thread.sleep(forTimeInterval: 0.20)
                    }
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
                // Same wait-for-tokens path as own-device serve — friend videos must not abort early.
                let sent: Bool = await Task.detached {
                    nearby?.broadcastWaiting(out, class: .bulk, maxWaitMs: 8_000) ?? false
                }.value
                if !sent {
                    HavenLog.net("media serve ref=\(ref.prefix(12)) → \(requesterHex.prefix(8)): rate-limit give-up at chunk \(index)/\(total)")
                    break
                }
                if let node { Task.detached { try? await node.sendToNode(nodeIdHex: requesterHex, payload: out) } }
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

    /// Ingest one HELLO. Returns `consumed`: true when the hello was APPLIED or deliberately
    /// dropped — safe for a mailbox caller to mark its slot seen. False means NOT applied
    /// (engine not ready, held for connection approval, verification hold, transient engine
    /// failure): the mailbox slot must stay UNCLAIMED so a later poll retries — once the gate
    /// clears (user approves, contacts sync converges) the SAME slot re-processes and the
    /// circle grant riding it finally applies. Marking held hellos seen is exactly how the
    /// E2E stub's circle invite evaporated: claimed at fetch, quarantined at the approval
    /// gate, seen forever. `why` feeds the one-line claim diag in pullMailbox.
    @discardableResult
    private func handleHello(_ payload: Data, viaNearby: Bool = false, senderDevice: String? = nil) -> (consumed: Bool, why: String) {
        guard let social else { return (false, "engine-not-ready") }
        // [LP circleId][LP circleName][LP bundle][signed profile]
        var off = 0
        guard let circleIdData = lpRead(payload, &off),
              let circleNameData = lpRead(payload, &off),
              let bundle = lpRead(payload, &off), bundle.count >= 32 else { return (true, "malformed") }
        let circleId = String(data: circleIdData, encoding: .utf8) ?? ""
        let circleName = String(data: circleNameData, encoding: .utf8) ?? "Circle"
        guard !circleId.isEmpty else { return (true, "malformed") }
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
            return (true, "self-device")
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
            return (true, "known-device")
        }
        // Blocked people get dropped entirely — no add, no re-add.
        if ConnectionsStore.shared.isBlocked(idHex) { return (true, "blocked") }
        // Someone new reaching us through our invite → hold for approval (don't auto-add).
        // One person scans; the other gets asked, with safety words to verify.
        if !isContact(idHex) {
            // ENGINE-KNOWN MEMBER: the ENGINE already lists this account in one of my circles —
            // an established relationship (I invited or approved them, possibly on a linked
            // device before ContactsStore converged, or ContactsStore lagged a restore). They
            // are not "someone new": re-gating them as a stranger strands every hello they
            // send — on a hosting Mac the circle grant riding the hello was quarantined as a
            // pending request nobody could see, and the circle never formed. Same principle
            // as the device-of-known-account rule above, at account level. Adopt the contact
            // record and continue the normal handshake. A contact the user explicitly REMOVED
            // (LWW tombstone) still takes the approval path.
            let engineKnows = !ContactsStore.shared.isContactRemoved(idHex) && social.circles().contains { c in
                social.contactNodeIds(circleId: c.id).contains { $0.lowercased() == idHex.lowercased() }
            }
            if engineKnows {
                let name = social.verifyProfile(bundle: bundle, blob: profileBlob) ?? "Someone"
                let vhex = try? social.bundleVerificationHex(bundle: bundle)
                ContactsStore.shared.add(name: name.isEmpty ? "Someone" : name, idHex: idHex, verificationHex: vhex)
                HavenLog.sync("hello from \(idHex.prefix(8)) is an engine-known circle member — adopted as contact, handshake continues")
            } else {
                // BUT: a non-contact Hello that arrived over the NEARBY mesh is just proximity — another
                // Haven user happened to be in Bluetooth/Wi-Fi range. That must NOT pop a connection request
                // (it did, repeatedly, for everyone nearby). Real new connections come from scanning an
                // invite, which sends a TARGETED Hello over iroh/relay (viaNearby == false) — those still ask.
                if viaNearby { return (true, "nearby-stranger") }
                let name = social.verifyProfile(bundle: bundle, blob: profileBlob) ?? "Someone"
                let vhex = (try? social.bundleVerificationHex(bundle: bundle)) ?? ""
                let display = name.isEmpty ? "Someone" : name
                ConnectionsStore.shared.addPending(ConnectionRequest(
                    idHex: idHex, name: display, bundle: bundle,
                    safetyWords: SafetyWords.words(fromHex: vhex)))
                NotificationManager.shared.notify(title: "New connection",
                                                  body: "\(display) wants to connect",
                                                  dedupeKey: "req-\(idHex)")
                ActivityStore.shared.note(id: "req-\(idHex)", kind: "connect",
                                          actorHex: idHex, actorShort: String(idHex.prefix(8)),
                                          snippet: "\(display) wants to connect")
                // NOT consumed: the grant this hello carries must survive until the user decides.
                // Approval re-processes the same mailbox slot on the next poll and applies it.
                return (false, "held-for-approval")
            }
        }
        if let expected = ContactsStore.shared.verification(forNodePrefix: idHex),
           let actual = try? social.bundleVerificationHex(bundle: bundle),
           expected != actual {
            // NOT consumed: the local expectation may be stale (self-sync lag / re-verify) —
            // keep the slot until it clears or the mailbox TTL expires. Same body → same key,
            // so a permanently-wrong hello is bounded by the TTL, not retried forever.
            return (false, "verification-mismatch")
        }
        // A DM circle is strictly its two encoded parties — never let a third party (e.g. a
        // contact who picked up a broadcast Hello) handshake their way into someone else's DM.
        if circleId.hasPrefix("dm:") && !dmCircleAllows(circleId, idHex) { return (true, "dm-third-party") }
        // A member you explicitly removed from this circle must NOT auto-rejoin on their handshake —
        // but silently DROPPING it made a removal permanent AND mutual. The tombstone only ever
        // clears on YOUR side when YOU re-add them, so once two people had removed each other
        // neither could reconnect by any route: their deliberate request died on your tombstone,
        // yours died on theirs, and both sides just saw "waiting" forever. Ask instead of dropping —
        // consent is still required, nothing auto-rejoins, and approving clears the tombstone.
        // Proximity and DM hellos keep dropping: neither is a deliberate request.
        if ConnectionsStore.shared.isRemovedFromCircle(idHex, circleId: circleId) {
            if viaNearby || circleId.hasPrefix("dm:") { return (true, "removed-from-circle") }
            let name = social.verifyProfile(bundle: bundle, blob: profileBlob) ?? "Someone"
            let vhex = (try? social.bundleVerificationHex(bundle: bundle)) ?? ""
            let display = name.isEmpty ? "Someone" : name
            ConnectionsStore.shared.addPending(ConnectionRequest(
                idHex: idHex, name: display, bundle: bundle,
                safetyWords: SafetyWords.words(fromHex: vhex)))
            NotificationManager.shared.notify(title: "New connection",
                                              body: "\(display) wants to connect",
                                              dedupeKey: "req-\(idHex)")
            ActivityStore.shared.note(id: "req-\(idHex)", kind: "connect",
                                      actorHex: idHex, actorShort: String(idHex.prefix(8)),
                                      snippet: "\(display) wants to connect")
            // NOT consumed — the grant must survive until the user decides (stranger parity).
            return (false, "removed-needs-approval")
        }
        // A circle/DM the user DELETED must not be re-created by a bare handshake (LWW) — respect the
        // deletion. The user re-opens it explicitly (startDM/createCircle) if they want it back.
        if circleId != "default", CircleDeletionStore.isDeleted(circleId) { return (true, "circle-deleted") }
        // Ensure the circle exists on our side, then add the sender to it.
        let isNewCircle = circleId != "default" && !circles.contains { $0.id == circleId }
        social.createCircle(id: circleId, name: circleName)
        if isNewCircle {
            let who = ContactsStore.shared.name(forNodePrefix: idHex) ?? "Someone"
            NotificationManager.shared.notify(title: "Added to a circle",
                                              body: "\(who) added you to “\(circleName)”",
                                              dedupeKey: "circle-\(circleId)")
            ActivityStore.shared.note(id: "circle-\(circleId)", kind: "circle", circleId: circleId,
                                      actorHex: idHex, actorShort: String(idHex.prefix(8)),
                                      snippet: "\(who) added you to “\(circleName)”")
        }
        guard (try? social.addContactBundle(circleId: circleId, bundle: bundle)) != nil else {
            return (false, "engine-add-failed")   // transient — leave the slot for the next poll
        }
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
            refresh()
            return (true, "applied")   // already handshaked this peer/circle very recently — don't echo back
        }
        lastHelloReply[replyKey] = now
        let isDM = circleId.hasPrefix("dm:")
        if let hello = helloPayload(circleId: circleId, circleName: circleName) {
            sendIroh(0, hello, to: idHex)
            if circleId == "default" { nearbyBroadcast(0, hello) }
            let meHex = social.myNodeHex()
            Task { await SharedStore.putHello(circleId: circleId, toHex: idHex, fromHex: meHex, hello: hello, force: true) }
        }
        // A PAGE, not the whole history — see "Lazy history (wire 34)".
        //
        // This is the moment someone is added, and it used to re-seal and ship every event I have
        // ever authored to the circle. For an account carrying an imported archive that is hundreds
        // of envelopes and the entire media backlog behind them, before the new member has looked at
        // anything. They get the newest screenful now and ask for older pages as they scroll, the
        // same way media is fetched only when a tile appears.
        //
        // DMs are exempt: a conversation is read from the beginning and is small enough that paging
        // it would cost a round trip to save nothing.
        let firstPage = isDM
            ? social.syncEnvelopes(circleId: circleId)
            : social.syncEnvelopesPage(circleId: circleId, beforeMs: 0, limit: Self.historyPageSize)
        for env in firstPage {
            sendIroh(1, eventPayload(circleId, env), to: idHex)
            if !isDM { nearbyBroadcast(1, eventPayload(circleId, env)) }
            Task { await SharedStore.uploadEvent(circleId: circleId, env: env) }
        }
        refresh()
        return (true, "applied")
    }
    /// Cooldown to break handshake ping-pong (see handleHello). Keyed by "<peerHex>|<circleId>".
    private var lastHelloReply: [String: Date] = [:]

    /// "<acctHex>|<circleId>" keys whose next fan-out hello must NOT be warm-skipped —
    /// populated at invite time so the circle grant always ships immediately.
    private var pendingForcedHellos: Set<String> = []
    func forceHelloNextSync(_ idHex: String, circleId: String) {
        pendingForcedHellos.insert("\(idHex.lowercased())|\(circleId)")
    }

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
        // Did this come from one of MY devices? Those already have it; re-sharing would only waste
        // radio. Do NOT treat `viaNearby` as own-device: Multipeer also carries CONTACT content when
        // a friend is in the room, and suppressing fan-out there left my other linked devices
        // (off-mesh / different network) without the event until a slow catch-up — or never, if
        // their mailbox path was unauthorized. Loop safety is `receive` returning true only for NEW
        // events (siblings that already hold it stop here).
        // Snapshot own-device ids OFF the hot path's main-thread lock chain: mine set is small and
        // changes only on link/revoke — cache for a few seconds so burst receives don't call
        // deviceNodeIdsFor on main while utility workers hold the engine.
        let fromOwnDevice = senderDevice.map { self.isOwnDeviceHex($0) } ?? false
        // receive() verifies + decrypts — real CPU per frame, and event frames arrive in BURSTS
        // during a sync. Do the crypto off-main; hop back only for the (already-coalesced) applies.
        Task.detached(priority: .utility) { [weak self] in
            let ok = await EngineGate.shared.run {
                (try? social.receive(circleId: circleId, envelope: envelope)) == true
            }
            guard ok else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // FAN OUT to my other devices. A sender dials the device ids its copy of my roster
                // resolves — often just one — so a DM delivered straight to my Mac never reached my
                // iPhone, which was left waiting on a mailbox poll (and got nothing at all if the
                // relay refused it). The send path has always done this for my OWN posts via
                // liveDeliverToMyDevices; the receive path must for CONTACT posts too.
                if !fromOwnDevice {
                    self.liveDeliverToMyDevices(1, payload)
                    // Internet/relay path only: Multipeer already flooded the local mesh, so
                    // re-broadcasting nearby would amplify. Off-mesh siblings still need iroh above.
                    if !viaNearby {
                        self.nearbyBroadcast(1, payload, class: .bulk)
                    }
                    // Linked-device push path: iroh live-deliver reaches an awake Mac, but a Mac that
                    // is only hosting in the background (or whose APNs silent path is flaky) still
                    // needs the sealed event inline on a content-available push. Mailbox poll already
                    // does this; live contact delivery was the remaining hole for
                    // "iPhone got mom's notification, linked Mac stayed empty".
                    PushManager.shared.syncSelf(event: envelope.base64EncodedString())
                }
                // Hearing a message is proof of life — refresh "last seen" for a DM's partner.
                if circleId.hasPrefix("dm:"), let partner = self.dmPartnerHex(circleId) { self.recordHeard(partner) }
                self.invalidateMessagesCache(circleId)
                self.invalidateSyncBundle(circleId)
                self.schedulePersist()             // coalesced — a sync burst writes once, not per event
                self.scheduleRefresh()             // coalesced feed rebuild
                self.scheduleRequestMissingMedia() // coalesced media pull (scans the whole feed)
                self.scheduleCircleSideEffects(circleId)  // notify + badge + DM media, coalesced off-main
            }
        }
    }

    /// Cached set of my account + device hexes for own-device fan-out gating (handleEvent hot path).
    private var ownDeviceHexCache: (at: UInt64, set: Set<String>) = (0, [])
    private func isOwnDeviceHex(_ hex: String) -> Bool {
        let nowMs = now()
        if nowMs &- ownDeviceHexCache.at > 15_000 || ownDeviceHexCache.set.isEmpty {
            guard let social else { return false }
            var s = Set(social.deviceNodeIdsFor(accountHex: social.myNodeHex()).map { $0.lowercased() })
            s.insert(social.myNodeHex().lowercased())
            s.insert(social.myDeviceNodeHex().lowercased())
            ownDeviceHexCache = (nowMs, s)
        }
        return ownDeviceHexCache.set.contains(hex.lowercased())
    }

    /// Coalesce notify/badge/DM-media side effects after ingest. A mailbox batch used to call
    /// `notifyNewest` → `messages(in:)` → full `feed()` **per envelope on the main actor**, which
    /// is the Mac beachball under concurrent export/receive.
    private var pendingSideEffectCircles = Set<String>()
    private var sideEffectsPending = false
    private func scheduleCircleSideEffects(_ circleId: String) {
        pendingSideEffectCircles.insert(circleId)
        guard !sideEffectsPending else { return }
        sideEffectsPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            let cids = self.pendingSideEffectCircles
            self.pendingSideEffectCircles.removeAll(keepingCapacity: true)
            self.sideEffectsPending = false
            await self.runCircleSideEffects(cids)
        }
    }
    @MainActor
    private func runCircleSideEffects(_ cids: Set<String>) async {
        guard let social, !cids.isEmpty else { return }
        let retentionByCid = Dictionary(uniqueKeysWithValues: cids.map {
            ($0, CircleSettingsStore.shared.retentionSecs($0))
        })
        let nowMs = now()
        // One feed() per touched circle, serialized with other engine work — never on main.
        let feeds: [String: [FeedItemFfi]] = await Task.detached(priority: .utility) {
            await EngineGate.shared.run {
                var out: [String: [FeedItemFfi]] = [:]
                for cid in cids {
                    out[cid] = social.feed(circleId: cid, nowMs: nowMs,
                                           viewerRetentionSecs: retentionByCid[cid] ?? nil)
                }
                return out
            }
        }.value
        var anyDM = false
        for cid in cids {
            let raw = feeds[cid] ?? []
            messagesCache[cid] = (now(), raw)
            let cutoff = dmClearedBefore[cid]
            let items = cutoff.map { c in raw.filter { $0.createdAt >= c } } ?? raw
            applyNotifyFromItems(items, circleId: cid)
            if cid.hasPrefix("dm:") {
                anyDM = true
                requestMissingDMMedia(cid)
            } else {
                bumpUnseenFromItems(items, circleId: cid)
            }
        }
        if anyDM { recomputeUnreadDMs() }
        // Refresh the in-app activity list off this same coalesced pass (its own EngineGate hop,
        // deduped by event id — an ingest burst pulls once).
        ActivityStore.shared.pull(social: social)
    }

    /// Same rules as `notifyNewest` but with a pre-fetched feed (no engine lock on main).
    private func applyNotifyFromItems(_ items: [FeedItemFfi], circleId: String) {
        let inbound = items.filter { !$0.isMe && !$0.unsent }
        guard let newest = inbound.max(by: { $0.createdAt < $1.createdAt }) else { return }
        guard now() &- newest.createdAt < 10 * 60 * 1000 else { return }
        // Mirror into the in-app activity list — the list must be complete even when the banner
        // is suppressed (foreground, deduped, unauthorized). Same event id as the engine pull.
        ActivityStore.shared.noteFeedItem(newest, circleId: circleId)
        let name = ContactsStore.shared.name(forNodePrefix: newest.authorShort) ?? "Someone"
        if CircleSettingsStore.shared.biometricRequired(circleId) {
            NotificationManager.shared.notify(title: "Haven", body: "New activity", dedupeKey: newest.id,
                                              deepLink: DeepLink.interactionLink(circleId: circleId, postId: newest.id))
            return
        }
        let body = newest.story ? "shared a story" : (newest.body.isEmpty ? "sent you media" : newest.body)
        let title = circleId.hasPrefix("dm:") ? name : "\(name) in your circle"
        NotificationManager.shared.notify(title: title, body: body, dedupeKey: newest.id,
                                          deepLink: DeepLink.interactionLink(circleId: circleId, postId: newest.id))
    }

    /// Same rules as `bumpUnseen` with a pre-fetched feed.
    private func bumpUnseenFromItems(_ items: [FeedItemFfi], circleId: String) {
        if circleId.hasPrefix("dm:") { return }   // watermark path via recomputeUnreadDMs
        let inbound = items.filter { !$0.isMe && !$0.unsent }
        guard let newest = inbound.max(by: { $0.createdAt < $1.createdAt }) else { return }
        guard now() &- newest.createdAt < 5 * 60 * 1000 else { return }
        guard lastCountedUnseen[circleId] != newest.id else { return }
        lastCountedUnseen[circleId] = newest.id
        if lastCountedUnseen.count > 500 { lastCountedUnseen.removeAll() }
        unseenCircle += 1
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
    /// Per-ref throttle for acting on unsolicited frame-32 announces (the author push-ahead).
    private var announcedMediaAt: [String: UInt64] = [:]

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
        ActivityStore.shared.noteFeedItem(newest, circleId: circleId)   // list stays complete (see applyNotifyFromItems)
        let name = ContactsStore.shared.name(forNodePrefix: newest.authorShort) ?? "Someone"
        // A biometric-locked circle must not spill its content (or even who/where) onto the lock
        // screen — mirror the NSE's redaction for this in-process notification path too.
        if CircleSettingsStore.shared.biometricRequired(circleId) {
            NotificationManager.shared.notify(title: "Haven", body: "New activity", dedupeKey: newest.id,
                                              deepLink: DeepLink.interactionLink(circleId: circleId, postId: newest.id))
            return
        }
        let body = newest.story ? "shared a story" : (newest.body.isEmpty ? "sent you media" : newest.body)
        let title = circleId.hasPrefix("dm:") ? name : "\(name) in your circle"
        NotificationManager.shared.notify(title: title, body: body, dedupeKey: newest.id,
                                          deepLink: DeepLink.interactionLink(circleId: circleId, postId: newest.id))
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
    @State private var showAudioRecorder = false
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
    @State private var showActivity = false
    @ObservedObject private var activity = ActivityStore.shared
    @ObservedObject private var connections = ConnectionsStore.shared
    @FocusState private var composeFocused: Bool
    @State private var commentingActive = false   // a post's comment field is focused → hide composer
    /// The post currently at the top edge — see `.scrollPosition` below. Nil while the header is on
    /// screen, which is what lets new posts appear normally when you are already at the top.
    @State private var anchoredPostId: String?
    @ObservedObject private var importer = InstagramImporter.shared
    /// Posts are arriving in bulk (an archive import) rather than one at a time — suppress the
    /// arrival animation so the feed stays still enough to read while it fills in behind you.
    private var bulkArriving: Bool { importer.isRunning }

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

    #if os(iOS)
    /// Load a share routed to "Share as Post" into THIS composer — the one that owns the circle
    /// switcher, the song picker, the location toggle and scheduling. Appended, never assigned, so
    /// it can't discard something half-typed.
    ///
    /// Deliberately a PULL (`takePostDraft`), and deliberately never called straight from the
    /// publisher — see that method for why clearing during the publish silently put the draft back.
    /// Refs are de-duplicated because both entry points (the publisher and `onAppear`) can fire for
    /// one share, which is what attached the same photo twice.
    private func applySharedPostDraft() {
        guard let draft = ShareRouter.shared.takePostDraft() else { return }
        if !draft.text.isEmpty {
            compose = compose.isEmpty ? draft.text : compose + "\n" + draft.text
        }
        attachedMedia.append(contentsOf: draft.refs.filter { !attachedMedia.contains($0) })
    }
    #endif

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
                            // Skip the whole 1,507-line body when this row's item is unchanged.
                            // FeedStore.items republishes on every feed rebuild (a mailbox pull, a
                            // poster landing, a periodic tick) and re-initialises every visible card;
                            // without this each republish re-evaluates all of them.
                            .equatable()
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PostCenterKey.self,
                                                       value: [item.id: geo.frame(in: .global).midY])
                            })
                            // Reaching the oldest post we hold is the cue to ask its author for the
                            // page before it — history arrives as it is looked at, not all at once
                            // when someone is added. No-op once we've asked for this cursor.
                            .onAppear {
                                if item.id == store.feedItems.last?.id { store.requestOlderHistory() }
                            }
                            // A bulk import writes hundreds of posts, and animating each arrival
                            // means the whole stack springs on every one of them — the page visibly
                            // bounces, and because the moving layout changes which post is nearest
                            // the centre, the video you were watching keeps restarting. A single
                            // post arriving is news worth animating; three hundred is not.
                            .transition(bulkArriving ? .identity : .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                                removal: .opacity))
                        }
                    }
                    .scrollTargetLayout()
                    .animation(bulkArriving ? nil : HavenTheme.bouncy, value: store.items.count)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 130)
                }
                // KEEP THE READER'S PLACE when posts arrive.
                //
                // The feed is newest-first, so anything new — a peer's post, a mailbox pull landing
                // a batch, an archive import writing 300 of them — is INSERTED ABOVE whatever is
                // being read. A plain ScrollView holds its content offset, not its content, so
                // every insertion shoved the page down and the reader lost their spot. An import
                // made that constant.
                //
                // Binding the scroll position to the post at the top edge pins that post instead of
                // the offset: content grows above it and the reader does not move. The binding is
                // nil while the header/stories tray is on screen, which is exactly right — at the
                // top of the feed new posts SHOULD appear in front of you.
                .scrollPosition(id: $anchoredPostId, anchor: .top)
                .scrollDismissesKeyboard(.immediately)
                .onPreferenceChange(PostCenterKey.self) { centers in
                    // The post nearest the vertical center of the screen becomes active.
                    let target = PlatformScreen.contentCenterY
                    let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                    AudioCoordinator.shared.center(nearest?.key, container: "circle")
                }
                .environment(\.havenFeedContainer, "circle")
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
                // Activity bell: everything that happened across your circles, with an unread
                // badge cleared fleet-wide on open (seenAt syncs via SelfSync). Both platforms.
                ToolbarItem(placement: .havenTrailing) {
                    Button { showActivity = true } label: {
                        // The toolbar's glass capsule CLIPS whatever overflows the label's bounds,
                        // so a badge nudged outward with .offset always loses its top-right corner
                        // — every previous attempt here was just tuning how much got cut. Instead
                        // give the label uniform padding: the capsule grows to include it, the
                        // glyph stays centred (asymmetric padding is what shoved it off-centre
                        // before), and the badge lives INSIDE that padded corner where nothing
                        // clips it. No offset at all.
                        Image(systemName: "bell.fill")
                            .padding(5)
                            .overlay(alignment: .topTrailing) {
                                if activity.unread > 0 {
                                    Text(activity.unread > 99 ? "99+" : "\(activity.unread)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.red))
                                        .fixedSize()
                                }
                            }
                    }
                    .buttonStyle(HavenGlassIcon())
                    .accessibilityLabel("Activity")
                }
                // Manage this circle (members, invite, settings) — lives on the circle, not You.
                ToolbarItem(placement: .havenTrailing) {
                    Button { showCircle = true } label: { Image(systemName: "person.2.fill") }
                        .buttonStyle(HavenGlassIcon())
                        .accessibilityLabel("Manage circle")
                }
            }
            .sheet(isPresented: $showActivity) {
                ActivityView().macSheetFrame()
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
            // Something shared in from another app, routed to "Share as Post" — load it into THIS
            // composer rather than a lesser copy of it, so the circle switcher, song picker,
            // location toggle and schedule all still apply. Appended, never assigned: re-entering
            // the tab must not discard something half-typed.
            #if os(iOS)
            // Next runloop turn, NOT inline: this fires from `@Published`'s willSet, and taking the
            // draft there writes into the middle of the very assignment that published it.
            .onReceive(ShareRouter.shared.$postDraft) { _ in
                DispatchQueue.main.async { applySharedPostDraft() }
            }
            #endif
            .onAppear {
                #if os(iOS)
                // A draft that arrived BEFORE this view existed.
                //
                // TabView builds a tab's content the first time that tab is shown, so a share
                // routed to "Share as Post" while the Circle tab had never been opened published
                // `postDraft` to nobody — `onReceive` needs a live subscriber. The draft is
                // durable, so also look for one on the way in. Both paths are safe to run: the
                // take is atomic and the refs de-duplicate.
                applySharedPostDraft()
                #endif
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
                SongPicker(onPick: { track in attachedTrack = track },
                           suggestFor: (media: attachedMedia, caption: compose)).macSheetFrame()
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
                    attachmentChip(ref)
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

    /// One tile in the composer's attachment tray. See `ComposerAttachmentTile` for why every
    /// attachment draws one whether or not it has a picture to show.
    @ViewBuilder private func attachmentChip(_ ref: String) -> some View {
        if SharedLocation.parse(ref) != nil {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 2) {
                    Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(HavenTheme.pink)
                    Text("Location").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                removeChip { attachedMedia.removeAll { $0 == ref } }
            }
        } else {
            ZStack(alignment: .topTrailing) {
                ComposerAttachmentTile(ref: ref, media: attachedMedia)
                    .overlay(alignment: .bottomLeading) {
                        // Trim/mute stay reachable from the tile even when the tile is a glyph — the
                        // clip is attached either way, so its controls apply either way.
                        if MediaKind(ref: ref) == .video { videoEditMenu(ref) }
                    }
                removeChip { removeAttachment(ref) }
            }
        }
    }

    /// Drop an attachment AND every companion tied to it — a poster or original left behind would
    /// ride along on the next post with no playable ref to belong to.
    private func removeAttachment(_ ref: String) {
        attachedMedia.removeAll { r in
            if r == ref { return true }
            if let p = MediaVariants.parsePoster(r), p.video == ref || p.poster == ref { return true }
            if let o = MediaVariants.parseOriginal(r), o.optimized == ref || o.original == ref { return true }
            if let t = MediaVariants.parseThumb(r), t.content == ref || t.thumb == ref { return true }
            if MediaVariants.poster(for: ref, in: attachedMedia) == r { return true }
            if MediaVariants.original(for: ref, in: attachedMedia) == r { return true }
            if MediaVariants.thumb(for: ref, in: attachedMedia) == r { return true }
            return false
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
nonisolated(unsafe) var lastKnownMediaWidth: CGFloat = 0

/// EQUATABLE so SwiftUI can SKIP a row whose content did not change.
///
/// `FeedStore.items` republishes on every feed rebuild — a mailbox pull, a poster landing, a
/// periodic tick — and each republish re-initialises every PostCard in the list, re-evaluating a
/// 1,507-line body per visible row. A Time Profiler trace of a warm phone is 83% main thread with no
/// single hot leaf: AG::Graph::propagate_dirty marking subtrees, swift_getGenericMetadata and
/// LockingConcurrentMap re-instantiating deeply nested generic view types, ARC churn. That is rows
/// rebuilding wholesale, and it is why deleting expensive calls from inside `body` (storageDir,
/// shareURL) measurably helped and did not fix it.
///
/// With `.equatable()` at the call site, a republish carrying an IDENTICAL item skips the body
/// entirely. The closures are deliberately NOT compared — they are recreated on every parent render
/// and capture only the store plus `item.id`, so two cards with an equal `item` have behaviourally
/// identical callbacks. Comparing them is impossible anyway (functions are not Equatable), and
/// treating them as significant would defeat the whole optimisation.
///
/// This does NOT stop the card's own @ObservedObject stores from invalidating it — that is the next
/// step, pushing `feed`/`audio`/`pinned`/`profile` down into the leaf views that read them.
/// My own avatar, as its OWN view so it — and not its 1,507-line host — is what a ProfileStore
/// publish invalidates.
///
/// PostCard observed ProfileStore for exactly these two call sites. Because @ObservedObject
/// subscribes the WHOLE view, changing an avatar re-evaluated every visible card's entire body. A
/// trace after making rows Equatable showed generic-metadata instantiation down 36% but
/// AG::Graph::UpdateStack::update FLAT — parent-driven rebuilds were being skipped while the card's
/// own store subscriptions kept dirtying it directly. This is the first of those four moved down.
struct MyAvatar: View {
    let size: CGFloat
    @ObservedObject private var profile = ProfileStore.shared
    var body: some View { HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: size) }
}

extension PostCard: Equatable {
    static func == (a: PostCard, b: PostCard) -> Bool {
        a.item == b.item
            && a.friendName == b.friendName
            && a.expandAllComments == b.expandAllComments
    }
}

/// A post's reaction chips + quick-react buttons.
///
/// Extracted from PostCard, which was a single ~1,600-line `body`. SwiftUI instantiates that whole
/// generic tree every time a row appears, which is the cost that remains once invalidation churn is
/// gone: measured at 21-34 body evaluations per second while scrolling. Smaller views are cheaper to
/// build, are re-evaluated only when THEIR inputs change, and are far easier to read than a nested
/// block four levels inside another view.
///
/// It owns its own sheet state — `showPicker`/`showDetail` were @State on PostCard used nowhere but
/// here, so presenting a picker re-evaluated the entire card.
struct PostReactionsRow: View {
    let reactions: [ReactionFfi]
    let onReact: (String) -> Void
    let onUnreact: (String) -> Void
    @State private var showPicker = false
    @State private var showDetail = false

    private var visible: [ReactionFfi] { PostCard.cappedReactions(reactions, cap: 4) }
    private var hiddenCount: Int { max(0, reactions.count - visible.count) }
    private func react(_ e: String) { EmojiStore.shared.record(e); onReact(e) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(visible, id: \.emoji) { r in
                // Tap a chip to toggle your own reaction; press-and-hold to see who reacted.
                HStack(spacing: 3) {
                    Text(r.emoji).font(.caption)
                    Text("\(r.count)").font(.caption2.weight(.semibold).monospacedDigit())
                        // PINK COUNT ON A PINK CAPSULE IS INVISIBLE.
                        //
                        // Both the chip tint and the count read "this one is yours", so the count was
                        // drawn in the same pink as the capsule behind it and the number disappeared
                        // into its own background. The capsule already carries that meaning; the
                        // number's job is to be READ. `.primary` keeps it legible over the tinted
                        // glass in both light and dark, and the chip is still obviously yours.
                        .foregroundStyle(r.mine ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                // One glass capsule, tinted pink when it's YOUR reaction.
                .havenGlass(in: Capsule(), tint: r.mine ? HavenTheme.pink : nil)
                .contentShape(Capsule())
                .onTapGesture { if r.mine { onUnreact(r.emoji) } else { react(r.emoji) } }
                .onLongPressGesture(minimumDuration: 0.3) { showDetail = true }
                .transition(.scale.combined(with: .opacity))
            }
            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .havenGlass(in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { showDetail = true }
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer(minLength: 8)
            ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                Button(e) { react(e) }.font(.body).buttonStyle(PressableStyle())
            }
            Button { showPicker = true } label: {
                Image(systemName: "plus.circle").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .animation(HavenTheme.bouncy, value: reactions.count)
        .sheet(isPresented: $showPicker) { ReactionPicker { e in onReact(e) } }
        .sheet(isPresented: $showDetail) {
            ReactionDetailView(reactions: reactions, onUnreact: { e in onUnreact(e) })
        }
    }
}

/// The "Add a reply…" composer for one post: attachments, text field, send.
///
/// Extracted from PostCard. It owns everything it needs — draft text, staged attachments, the two
/// sheet flags and the focus state — none of which any other part of the card read. As @State on a
/// ~1,600-line view, TYPING A CHARACTER re-evaluated the whole card body; now it re-evaluates a text
/// field. The keyboard-avoidance callback still reports upward, because the feed (not the card) owns
/// the scroll proxy that lifts the post.
struct PostCommentField: View {
    let onSubmit: (String, [String]) -> Void
    var onFocus: ((Bool) -> Void)?

    @State private var text = ""
    @State private var media: [String] = []
    @State private var showMediaPicker = false
    @State private var showAudioRecorder = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if !media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(media, id: \.self) { attachChip($0) } }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    Button { showMediaPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                    Button { showAudioRecorder = true } label: { Label("Audio reply", systemImage: "mic") }
                } label: { Image(systemName: "paperclip").foregroundStyle(.secondary) }
                .menuIndicator(.hidden)   // no macOS disclosure chevron next to the paperclip
                #if os(macOS)
                .menuStyle(.borderlessButton).fixedSize()
                #endif
                TextField("Add a reply…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)   // drop the macOS system focus ring — matches iOS
                    .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .focused($focused)
                    // Report focus up so the feed lifts this post above the keyboard AND hides the
                    // "Share something" composer (which otherwise floats over the comment).
                    .onChange(of: focused) { _, f in onFocus?(f) }
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large).foregroundStyle(HavenTheme.pink)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .sheet(isPresented: $showMediaPicker) { MediaPicker { refs in media.append(contentsOf: refs) }.macSheetFrame() }
        .sheet(isPresented: $showAudioRecorder) { AudioRecorderView { ref in media.append(ref) }.macSheetFrame() }
    }

    private func attachChip(_ ref: String) -> some View {
        let m = MediaStore.shared.item(ref)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let img = m?.image { Image(platformImage: img).resizable().scaledToFill() }
                else { Image(systemName: "waveform").frame(maxWidth: .infinity, maxHeight: .infinity).background(HavenTheme.brandHorizontal.opacity(0.25)) }
            }
            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            Button { media.removeAll { $0 == ref } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.white).background(Circle().fill(.black.opacity(0.5)))
            }
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !media.isEmpty else { return }
        onSubmit(t, media)
        text = ""; media = []
    }
}

/// A post's header: avatar, author, timestamp, backup state and the overflow menu.
///
/// 265 lines lifted out of PostCard — the single largest block in it. It observes PinnedMediaStore
/// itself, so a pin toggle invalidates a header rather than a whole card, and it owns
/// showBackupDetail (nothing else read it). The sheets it OPENS stay on the card, because the card
/// is what presents them, so those arrive as bindings.
struct PostHeader: View {
    let item: FeedItemFfi
    let friendName: String
    let authorName: String
    let storyableMedia: [String]
    let onUnsend: () -> Void
    @Binding var showEdit: Bool
    @Binding var showReport: Bool
    @Binding var storyShare: StoryShareTarget?
    @ObservedObject private var pinned = PinnedMediaStore.shared
    @State private var showBackupDetail = false
    @State private var linkCopied = false

    @ViewBuilder private var avatar: some View {
        if item.isMe { MyAvatar(size: 34) }
        else { PeerAvatar(nodeHex: item.authorShort, name: authorName, size: 34) }
    }

    var body: some View {
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
            // Upload state for YOUR OWN media posts — ALWAYS shown when there is media, even if this
            // device knows zero relays. Gating on "has a relay" hid the indicator entirely when a
            // friend never learned frame-19 (or only had LAN media URLs), so "not syncing" looked
            // identical to "nothing to show" and previously shared content appeared fine while no
            // relay ever got a copy. Driven PER-MEDIA off the backup ledger + queue.
            if item.isMe && !item.unsent, !item.media.isEmpty {
                // The whole cluster is one tap target: every state below is a partial answer to
                // "where is this?", and the sheet is the full one — including which relays hold
                // nothing, which no icon can express.
                // TICK ONLY WHILE SOMETHING CAN CHANGE.
                //
                // This cluster re-rendered every second for every one of YOUR OWN media posts on
                // screen — forever, including posts uploaded months ago where the answer is fixed.
                // On the You feed every cell is yours, so the app never stopped recomputing upload
                // state on the main thread: a warm phone sitting idle, and a feed that stutters
                // while scrolling because each frame competes with this work.
                //
                // A post confirmed on a relay someone else can read is DONE — content-addressed
                // blobs never change, so that verdict cannot be revoked. Those fall back to an
                // hourly tick (a timer that effectively never fires) instead of a per-second one.
                // Anything still in flight keeps the 1s cadence, which is the case the ring and the
                // percentage were built for.
                let settledOwnRelay = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
                let settledBlobs = item.media.filter { !MediaStore.isSynthetic($0) }
                let settled = !settledBlobs.isEmpty && settledBlobs.allSatisfy {
                    MediaBackupLedger.hasAnyRemote($0, ownRelayHex: settledOwnRelay)
                }
                // TICK ONLY WHILE AN UPLOAD IS GENUINELY IN FLIGHT.
                //
                // A Time Profiler trace of a warm phone (47s, iPhone 17 Pro Max) is ~half
                // AG::Graph::UpdateStack::update / update_attribute / input_value_ref_slow with
                // CA::Layer::commit_if_needed and LayoutEngineBox.sizeThatFits behind them: SwiftUI's
                // attribute graph being dirtied over and over and re-running layout. Not media
                // decode, not networking — the earlier fixes in this release were all treating
                // network symptoms of a RENDERING problem.
                //
                // Each of these timers dirties its subtree, and a subtree invalidation drags a layout
                // pass across the list. Gating on `settled` alone was not enough: a post that is not
                // backed up AND has nothing queued (no relay known, upload long since abandoned) also
                // ticked every second while its answer was every bit as fixed.
                //
                // So the 1s cadence — which exists for the progress ring and percentage — now applies
                // ONLY when the queue actually holds one of this post's blobs. hasPending is O(1)
                // now, so asking is free. Everything else falls to an hourly tick that effectively
                // never fires, and re-renders when its own state publishes instead.
                let inFlight = !settled && settledBlobs.contains { MediaBackupQueue.shared.hasPending($0) }
                TimelineView(.periodic(from: .now, by: inFlight ? 1.0 : 3600)) { _ in
                    let blobs = item.media.filter { !MediaStore.isSynthetic($0) }
                    let circleId = FeedStore.shared.activeCircleId
                    let hasRelay = !RelayMailboxStore.shared.relays(forCircle: circleId).isEmpty
                        || SharedStore.hasMailbox(circleId)
                    // "Backed up" must mean a relay SOMEONE ELSE can read. Writing to our own
                    // in-process relay is a local file copy that cannot fail, so counting it showed a
                    // confident tick on every post while friends could fetch none of them.
                    let ownRelay = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
                    let backed = !blobs.isEmpty && blobs.allSatisfy {
                        MediaBackupLedger.hasAnyRemote($0, ownRelayHex: ownRelay)
                    }
                    // Reached OUR relay and nowhere else: not an error, not safe either. Says so.
                    let localOnly = !backed && !blobs.isEmpty && blobs.allSatisfy { MediaBackupLedger.hasAny($0) }
                    let pending = blobs.contains { MediaBackupQueue.shared.hasPending($0) }
                    let progress = MediaUploadProgress.shared.fraction(for: blobs)
                    let stuck = MediaUploadProgress.shared.looksStuck(blobs)
                        || (!backed && !hasRelay)
                        || (!backed && !pending && !localOnly && !blobs.isEmpty)
                    if backed {
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.caption2).foregroundStyle(HavenTheme.pink)
                            .help("Backed up to a relay others can read")
                    } else if !hasRelay {
                        // The invisible case: no known mailbox → never showed an icon before.
                        Image(systemName: "exclamationmark.icloud")
                            .font(.caption2).foregroundStyle(.orange)
                            .help("No relay known for this circle — media stays on this device only. Open Relays or wait for a member who hosts one.")
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
                            .help(stuck
                                  ? (hasRelay
                                     ? "Upload not reaching a relay yet — tap for detail; keep Haven open"
                                     : "No relay available — media only on this device")
                                  : "Waiting to upload to a relay…")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showBackupDetail = true }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows which relays hold a copy")
                .sheet(isPresented: $showBackupDetail) {
                    BackupDetailView(refs: item.media.filter { !MediaStore.isSynthetic($0) },
                                     circleId: FeedStore.shared.activeCircleId)
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
                    if !item.story, !FeedStore.shared.activeCircleId.hasPrefix("dm:"),
                       let url = DeepLink.postURL(circleId: FeedStore.shared.activeCircleId, postId: item.id) {
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
                                    embed: StoryEmbed.Ref(circleId: FeedStore.shared.activeCircleId,
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
                            let dm = FeedStore.shared.startDM(with: authorHex, name: authorName)
                            let ref = DeepLink.postURL(circleId: FeedStore.shared.activeCircleId, postId: item.id)?
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
                                FeedStore.shared.requestMedia(r, circleId: FeedStore.shared.activeCircleId)
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
                                FeedStore.shared.scheduleRefresh()
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
                        FeedStore.shared.refresh()
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
}

/// A post's inline comments: rows, per-comment reactions, attachments and the "show all" sheet.
///
/// The last big block out of PostCard. It owns showAllComments and commentReactTarget — @State that
/// nothing outside the comment list read, so opening a reaction picker used to re-evaluate the whole
/// card. Editing still belongs to the card (it presents the alert), so that arrives as a callback
/// rather than three bindings.
struct PostCommentsList: View {
    let item: FeedItemFfi
    let friendName: String
    let expandAllComments: Bool
    /// The comment a deep link named (see `PostCard.highlightCommentId`) — tinted, never hidden
    /// behind "show all".
    var highlightCommentId: String? = nil
    let onReact: (String) -> Void
    let onUnreact: (String) -> Void
    let onComment: (String, [String]) -> Void
    let onEdit: (String) -> Void
    let onUnsend: () -> Void
    let onEditComment: (FeedCommentFfi) -> Void

    @State private var showAllComments = false
    @State private var commentReactTarget: PostCard.CommentReactTarget?


    private func commentAuthorName(_ c: FeedCommentFfi) -> String {
        if c.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: c.authorShort) ?? friendName
    }

    var body: some View {
        // Inline we show at most 3; the "show all" sheet shows every comment. A comment the caller
        // opened this post FOR is always among them — landing on the post but not the comment the
        // notification named would be its own small failure.
        var shown = expandAllComments ? item.comments : Array(item.comments.prefix(3))
        if let h = highlightCommentId, !shown.contains(where: { $0.id == h }),
           let linked = item.comments.first(where: { $0.id == h }) {
            shown.append(linked)
        }
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
            ReactionPicker { e in FeedStore.shared.react(t.id, e) }
        }
    }

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
        .padding(highlightCommentId == c.id ? 6 : 0)
        .background {
            if highlightCommentId == c.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(HavenTheme.pink.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(HavenTheme.pink.opacity(0.35)))
            }
        }
        .contextMenu {
            if !c.unsent {
                // Flat rows, each reacting on TAP. A ControlGroup here collapsed into a
                // "❤️ 😎 👍 ›" SUBMENU on macOS: it showed the emoji, then made you open a
                // second menu to actually pick one.
                ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                    Button("React \(e)") { EmojiStore.shared.record(e); FeedStore.shared.react(c.id, e) }
                }
                Button { commentReactTarget = PostCard.CommentReactTarget(id: c.id) } label: { Label("More reactions…", systemImage: "face.smiling") }
                if c.isMe {
                    if !c.body.isEmpty {
                        Button { onEditComment(c) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    Button(role: .destructive) { FeedStore.shared.unsend(c.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    @ViewBuilder private func commentReactionsRow(_ c: FeedCommentFfi) -> some View {
        // Cap the chips (most-reacted first, always keep mine) so a comment can't flood its row.
        let visible = PostCard.cappedReactions(c.reactions, cap: 5)
        let hidden = max(0, c.reactions.count - visible.count)
        HStack(spacing: 4) {
            ForEach(visible, id: \.emoji) { r in
                Text("\(r.emoji)\(r.count > 1 ? " \(r.count)" : "")")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(r.mine ? AnyShapeStyle(HavenTheme.brandHorizontal.opacity(0.22)) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Capsule())
                    .overlay(Capsule().strokeBorder(r.mine ? HavenTheme.pink.opacity(0.5) : .clear))
                    .contentShape(Capsule())
                    .onTapGesture {
                        if r.mine { FeedStore.shared.unreact(c.id, r.emoji) }
                        else { EmojiStore.shared.record(r.emoji); FeedStore.shared.react(c.id, r.emoji) }
                    }
            }
            if hidden > 0 {
                Text("+\(hidden)").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: Capsule()).foregroundStyle(.secondary)
            }
            Button { commentReactTarget = PostCard.CommentReactTarget(id: c.id) } label: {
                Image(systemName: "face.smiling").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(PressableStyle())
        }
        .animation(HavenTheme.bouncy, value: c.reactions.count)
    }

    @ViewBuilder private func commentAvatar(_ c: FeedCommentFfi) -> some View {
        if c.isMe {
            MyAvatar(size: 24)
        } else {
            PeerAvatar(nodeHex: c.authorShort, name: commentAuthorName(c), size: 24)
        }
    }

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
}

/// Grid tile for a multi-image post — one slot of the masonry layout.
///
/// A leaf renderer with three inputs, lifted out of PostCard so a tile redraws without the card.
struct PostMasonryTile: View {
    let item: FeedItemFfi
    let media: [String]
    let ref: String
    let height: CGFloat
    @Binding var zoomTarget: ZoomTarget?

    var body: some View { tile(ref, height: height) }

    @ViewBuilder private func tile(_ ref: String, height: CGFloat) -> some View {
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
                    let media = media
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
}

/// Placeholder shown while a media ref has not landed yet (or cannot be fetched).
struct PostMediaPlaceholder: View {
    let item: FeedItemFfi
    let ref: String

    var body: some View { placeholder(ref) }

    @ViewBuilder func placeholder(_ ref: String) -> some View {
        MissingMediaPlaceholder(ref: ref, isVideo: MediaKind(ref: ref) == .video,
                                postContext: (circleId: FeedStore.shared.activeCircleId, postId: item.id,
                                              authorShort: item.authorShort),
                                mediaList: item.media)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// The carousel's page dots.
struct PostCarouselDots: View {
    let count: Int
    let currentPage: Int

    var body: some View { body(count) }

    func body(_ count: Int) -> some View {
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
}

// MARK: - Post media geometry helpers
//
// Free functions, not view methods: they read MediaStore and their arguments and nothing else, so
// living on PostCard only made a 1,600-line view longer. Pulling them out also makes it obvious that
// shareURL must never call item(ref) — see its comment; that was a main-thread bitmap decode per ref
// per layout pass, and it cost real scroll performance until this release.

@MainActor func postShareURL(_ ref: String) -> URL? {
    // NEVER `item(ref)` here — the rule mediaPageContent states two functions below, which this
    // was quietly breaking: item() DECODES THE BITMAP / generates the video poster ON THE MAIN
    // THREAD on a cache miss. shareURL is called from `body` for every media ref, so a scroll
    // paid a decode per ref per layout pass. In a Time Profiler trace of a warm phone this shows
    // as PostCard.shareURL at 957 samples with MediaStore.item at 964 and downsampled at 384,
    // all under PostCard.body.getter — the choppy scrolling and the heat.
    //
    // The on-disk path is derivable from the ref alone: storagePath builds <dir>/<ref>.<ext>
    // from MediaKind(ref:), which is pure string work and cannot decode anything. Video and
    // image resolve to the same file either way — `videoURL` was the same path for a video.
    MediaStore.shared.storagePath(for: ref)
    }

@MainActor func postLetterboxes(_ ref: String, in containerAspect: CGFloat) -> Bool {
    guard let sz = MediaStore.shared.pixelSize(ref), sz.height > 0 else { return true }
    return abs(sz.width / sz.height - containerAspect) > 0.02
    }

@MainActor func postSingleAspect(_ ref: String, in media: [String]) -> CGFloat {
    // Read pixel dimensions from the file header (ImageIO) — NOT item()?.image.size, which decoded the
    // whole bitmap on the main thread just to get an aspect ratio (a scroll hitch per single-media post).
    if let sz = MediaStore.shared.pixelSize(ref), sz.width > 0, sz.height > 0 {
        MediaAspectStore.shared.record(ref, aspect: sz.width / sz.height)
        return sz.width / sz.height
    }
    // Full bytes not here yet, but the tiny thumb companion may be — same aspect as the
    // original, so the placeholder reserves the REAL shape and the layout doesn't jump when
    // the full-size media lands.
    if let t = MediaVariants.thumb(for: ref, in: media),
       let sz = MediaStore.shared.pixelSize(t), sz.width > 0, sz.height > 0 {
        MediaAspectStore.shared.record(ref, aspect: sz.width / sz.height)
        return sz.width / sz.height
    }
    // REMEMBERED shape, before the 4:3 guess.
    //
    // This function decides a card's HEIGHT, and it used to answer differently over time for the
    // same post: 4:3 while nothing was on disk, then the true shape once a thumb landed. A card
    // that changes height is a card that shoves everything below it — and while media is arriving
    // (an import, a mailbox pull, a fresh join) that is happening constantly, ABOVE the reader as
    // well as below. That is the feed "jumping around", and no amount of throttling refreshes
    // addresses it, because the rebuild was never the thing moving the content.
    //
    // So once a ref's real shape is known it is remembered, and every later render agrees with the
    // first one — including after the blob is evicted, which used to snap the card back to 4:3.
    if let remembered = MediaAspectStore.shared.aspect(ref) { return remembered }
    return 4.0 / 3.0
    }

/// The "Keep on this device" pin toggle, as its own view.
///
/// It observes PinnedMediaStore ITSELF. PostCard used to, for these two lines alone — so pinning any
/// media anywhere invalidated every visible card, re-evaluating a ~1,600-line body to redraw one
/// menu label. The original comment ("through the OBSERVED store, so toggling re-renders the card")
/// had the right instinct and the wrong scope: what must re-render is the BUTTON.
struct KeepOnDeviceButton: View {
    let ref: String
    @ObservedObject private var pinned = PinnedMediaStore.shared

    var body: some View {
        let isPinned = pinned.isPinned(ref)
        Button { pinned.togglePin([ref]) } label: {
            Label(isPinned ? "Stop keeping on this device" : "Keep on this device",
                  systemImage: isPinned ? "pin.slash.fill" : "pin")
        }
    }
}

/// The speaker chip over a video page, plus that page's Save/Share menu.
///
/// This could not leave PostCard until an hour ago: it activated the post's audio by handing
/// `primaryVideoPlayer` to the coordinator, so it needed the card's player cache. Now that
/// AudioCoordinator resolves a post's player from its own registry, the chip only needs the item and
/// the ref — and it observes the coordinator itself, so toggling sound redraws a chip rather than a
/// whole card.
struct PostMuteButton: View {
    let item: FeedItemFfi
    let ref: String
    @ObservedObject var audio = AudioCoordinator.shared

    var body: some View {
        Button {
            if audio.activePostId != item.id {
                audio.start(postId: item.id, track: item.music, video: nil,
                            muteVideo: item.muteVideo, immediateMusic: true)
            }
            audio.toggleVideoAudio()
        } label: {
            Image(systemName: audio.activePostId == item.id && audio.videoUnmuted
                  ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .foregroundStyle(.white)
        }
        // A glass circle chip and nothing else — the default button style painted its own
        // rounded-rect bezel BEHIND the circle on macOS (the doubled-background look).
        .buttonStyle(GlassIconButtonStyle(tint: .white))
        .padding(10)
        // Save/Share lives here for videos (the player's long-press is hold-to-pause, so the video
        // itself no longer carries a contextMenu). It acts on THIS page's video — it used to take
        // item.media.first, which is the wrong item on any page but the first (and is the synthetic
        // geo: ref on a post that also pins a location).
        .contextMenu {
            Button { MediaSaver.save(ref) } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
            if let url = postShareURL(ref) {
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
            KeepOnDeviceButton(ref: ref)
        }
    }
}

/// A media page for a `file_` attachment: icon, size, and a share button.
///
/// Self-contained — it reads its ref and MediaStore and nothing else — so it had no reason to be a
/// method on a 1,000-line view. Part of taking the media block out of PostCard one member at a time,
/// after three attempts to move the whole cluster by script left the file's braces unbalanced.
struct PostFileAttachmentPage: View {
    let ref: String

    var body: some View {
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
}

struct PostCard: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    var isPortraitPhone: Bool { hSizeClass == .compact }
    #else
    var isPortraitPhone: Bool { false }
    #endif
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
    /// A comment this card was opened FOR — a notification/activity row about a reaction or reply on
    /// it. Tinted so the thing that was announced is findable in a long thread.
    var highlightCommentId: String? = nil
    /// Called when the "Add a reply…" field gains focus so the enclosing scroll view (which owns
    /// the ScrollViewReader proxy) can lift this post above the keyboard.
    var onCommentFocus: ((Bool) -> Void)? = nil

    @Environment(\.havenFeedContainer) var feedContainer
    @ObservedObject var audio = AudioCoordinator.shared
    /// NOT @ObservedObject — deliberately.
    ///
    /// FeedStore publishes up to 40 TIMES PER SECOND on device (measured: "FeedStore published 204x
    /// in 5s"), because ordinary traffic writes its @Published properties — and @Published fires on
    /// every assignment, equal or not. Observing it here turned each of those into an invalidation of
    /// EVERY PostCard on screen, re-evaluating a ~1,500-line body per card: measured at up to 21 body
    /// evaluations per second while the app sat there.
    ///
    /// That is what the Time Profiler kept describing without naming: the main thread 84% framework
    /// (AG::Graph::propagate_dirty, UpdateStack::update, CA commits) with only 16% of samples
    /// containing any Haven frame — a graph being dirtied, not a slow function.
    ///
    /// This view does not NEED the reactivity. Of its 22 uses, all but one are actions (react, edit,
    /// requestMedia, refresh, postStory, unsend) or reads of activeCircleId, which changes rarely.
    /// Post CONTENT arrives through `item`, handed down by the feed — which does observe the store —
    /// so a changed post still re-renders, now via the value rather than a global notification.
    var feed: FeedStore { FeedStore.shared }
    /// Observed so "Keep on this device" visibly changes state. Reading the store WITHOUT observing
    /// it meant the pin was recorded but nothing on screen moved — the menu closed and the post
    /// looked identical, so a working toggle read as a dead button.
    /// A single photo/video sizes to fill the WIDTH on a portrait phone (a tall shot fills the column
    /// instead of shrinking to a narrow sliver), but fits the WHOLE image within a shorter cap on wider
    /// layouts (iPad / landscape / macOS) so you can see all of it at once.
    @State private var showEdit = false
    @State private var showReport = false
    @State private var linkCopied = false
    /// Set when the backup indicator is tapped — "which relays actually hold this?"
    @State private var showBackupDetail = false
    @State var zoomTarget: ZoomTarget?
    /// A REFERENCE-TYPE cache, deliberately — this is the fix for videos playing twice.
    ///
    /// These were `@State` dictionaries, and `playerFor` writes to them. But `playerFor` is called
    /// FROM `body` (the media page needs a player to hand to GestureVideoPlayer), so that write was a
    /// @State mutation DURING view evaluation. SwiftUI does not honour it for the pass in flight, so
    /// the next evaluation still saw an empty dict, missed the cache, and built a SECOND AVPlayer for
    /// the same clip. The first stayed alive — its loop observer retains it — and kept decoding.
    ///
    /// Measured, not deduced: an instrumented run logged `player #1` and `player #2` for EVERY video,
    /// identical ref, identical post, identical container. Two hardware decode sessions per clip,
    /// audio playing over itself slightly offset (the "static sounding" doubling), and a mute toggle
    /// that could only ever reach the one the coordinator knew about. It is also 2x decode on every
    /// video in the feed — heat with no CPU hotspot, and heat that survives AIRPLANE MODE.
    ///
    /// Mutating a class's contents is not a @State write, so the cache now actually caches.
    @State private var editCommentId: String?
    @State private var editCommentText = ""
    @State private var editCommentMedia: [String] = []

    struct CommentReactTarget: Identifiable { let id: String }
    /// The card's content width, measured. The media page spans it EDGE TO EDGE: sizing the page to the
    /// media's own aspect (the old `.aspectRatio(_, .fit)`) parked a tall clip in a narrow centre column
    /// with the card's grey either side on any wide window — the page must own the width, and the media
    /// letterboxes INSIDE it against its own blurred copy.
    @State private var showHeart = false
    /// A "share this post as a story" composer session (nil = not sharing).
    @State private var storyShare: StoryShareTarget?
    /// Super data saver: video refs the user explicitly tapped play for. We pull those bytes and
    /// auto-start once they land (normal data-saver mode never autoplays).

    /// The centre must have been reported BY THIS CARD'S OWN FEED. Without the container check a
    /// post living in two live containers (your own video is in both the circle feed and your
    /// profile) had both copies claim to be active, and both built an AVPlayer for the same clip —
    /// two decode sessions playing over each other, only one of them known to the coordinator.
    var isActive: Bool {
        audio.centeredPostId == item.id && audio.centeredContainer == feedContainer
    }

    /// The post's real media, minus synthetic refs (a `geo:` location pin has no bytes). A story needs
    /// something to show, so this is what gates the "Share as story" action.
    var storyableMedia: [String] { realMedia.filter { !MediaStore.isSynthetic($0) } }

    /// Display name for the post's author — resolved from your contacts by node id.
    private var authorName: String {
        if item.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: item.authorShort) ?? friendName
    }
    private func commentAuthorName(_ c: FeedCommentFfi) -> String {
        if c.isMe { return "You" }
        return ContactsStore.shared.name(forNodePrefix: c.authorShort) ?? friendName
    }

    /// A post that is exactly one video — the GestureVideoPlayer owns all of its gestures.
    /// Kind from the REF (a cheap string parse — refs encode img_/vid_/aud_), never `item(ref)`. `item(_:)`
    /// decodes the bitmap / generates the video poster on the main thread on a cache miss, and this is
    /// called per media ref all over layout and scrolling (mediaView, isSingleVideoPost, primaryVideoPlayer,
    /// playVisibleVideo). On a carousel or photo-grid post that was several decodes per layout pass — the
    /// same trap the masonry tile already documents.

    private func react(_ e: String) { EmojiStore.shared.record(e); onReact(e) }

    /// Double-tap a post to ❤️ it (with an Instagram-style heart pop).
    func heartIt() {
        react("❤️")
        withAnimation(HavenTheme.bouncy) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(HavenTheme.smooth) { showHeart = false }
        }
    }

    /// Single-tap a post's media to mute/unmute its sound (video audio or its song).
    func togglePostMute() {
        let hasVideo = item.media.contains(where: isVideo)
        // Make sure this post is the active audio source first, so the toggle acts on it.
        if (hasVideo || item.music != nil), audio.activePostId != item.id {
            audio.start(postId: item.id, track: item.music, video: nil, muteVideo: item.muteVideo, immediateMusic: true)
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
        #if DEBUG
        let _ = BodyCensus.tick()
        #endif

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
                        postMedia
                            .overlay { if showHeart { heartBurst } }
                    } else {
                        postMedia
                            .overlay { if showHeart { heartBurst } }
                            .onTapGesture(count: 2) { heartIt() }       // double-tap to heart
                            .onTapGesture(count: 1) { togglePostMute() } // tap to mute/unmute
                    }
                }
                if let track = item.music { NowPlayingPill(track: track, animating: true) }
                reactionsRow
                if !item.comments.isEmpty {
                    PostCommentsList(item: item, friendName: friendName,
                                     expandAllComments: expandAllComments,
                                     highlightCommentId: highlightCommentId,
                                     onReact: onReact, onUnreact: onUnreact, onComment: onComment,
                                     onEdit: onEdit, onUnsend: onUnsend,
                                     onEditComment: { c in
                                         editCommentId = c.id
                                         editCommentText = c.body
                                         editCommentMedia = c.media
                                     })
                }
                commentField
            }
        }
        .havenCard()
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

    /// A full-width media page's height: as tall as the media needs, capped. A page WIDER than the media's
    /// own shape is the point — the exposed strip either side is where the blurred backdrop shows.

    /// The page's ACTUAL aspect once it spans the card — what the letterbox test must compare against.


    /// True when a media set all share (near-)equal aspect ratios — such a set keeps its exact shape
    /// in the carousel (no backdrop needed, since nothing letterboxes).

    /// The carousel's page shape. A uniform set keeps its exact aspect; a MIXED set takes the TALLEST
    /// item's, so no page is ever cropped — clamped so one 9:16 clip can't squeeze the whole card into
    /// a narrow column (the remaining pages letterbox against their own blurred backdrop instead).

    /// A full-width swipeable pager. The visible page's video autoplays as you swipe
    /// (playVisibleVideo keys off `currentPage`), matching the single-media behavior.


    /// Horizontally-scrolling staggered gallery: items flow across two fixed-height rows and
    /// you swipe sideways through them. Each tile keeps its natural aspect (width = row · aspect).



    /// The on-disk file to hand to the system share sheet (video file, else the image).


    /// Super data saver (and normal) single-tap on an inline video.
    /// Under data saver a paused clip's first tap means "play" — mute alone left posters dead after
    /// download because `playVisibleVideo` never auto-starts in that mode.


    /// A `file_` zip attachment: document chip with share/save affordance.
    func fileAttachmentPage(_ ref: String) -> some View { PostFileAttachmentPage(ref: ref) }

    /// True when this page's media can't fill a `containerAspect`-shaped page — it letterboxes, exposing
    /// the card's grey behind it. A video whose poster hasn't been generated yet has no known aspect
    /// (singleAspect falls back to 4:3), so assume it letterboxes: that's the tall-clip case exactly.

    /// A blurred, cropped-to-fill copy of the media behind the fitted one — the letterboxed area reads as
    /// the media's own colors instead of the card's grey. A 64px thumbnail is all a heavy blur can show;
    /// for a video that thumbnail is its poster.
    ///
    /// The poster, NOT a second live layer: an AVPlayer only ever feeds ONE AVPlayerLayer, so hanging a
    /// second (fill-gravity) layer off the same player renders nothing — only the most recently associated
    /// layer draws. A blurred still is the honest trade: no second decode, and behind a 24pt blur the
    /// difference between a still and a moving copy isn't visible anyway.

    /// The carousel's per-page backdrop.
    ///
    /// This used to be gated on `letterboxes(ref, in: containerAspect)` as a perf tweak — "only pay
    /// for the blur when the page's media doesn't fill the page shape". That test is unsound, and it
    /// silently removed the backdrop from entire carousels:
    ///
    ///  • `containerAspect` is `pageAspect(carouselAspect)`, and `pageAspect` falls back to the RAW
    ///    aspect whenever `mediaWidth` is still 0 — which it is on the first layout pass, before the
    ///    preference reports the card's width. Comparing a photo's aspect against the shared aspect
    ///    *derived from that same photo* then matches, so the page that DEFINES the carousel shape
    ///    never got a backdrop.
    ///  • On any wide layout (iPad, landscape, macOS) `pageHeight` is capped at `singleMediaMaxHeight`,
    ///    so the page is far wider than the fitted image no matter what the aspects say. Every page
    ///    letterboxes; the comparison just couldn't see it.
    ///
    /// Single media never had this problem because it draws its backdrop unconditionally. Do the same
    /// here. The cost is one 200px bitmap blurred once per visible page (`.drawingGroup` rasterizes
    /// it), and carousel pages are lazy — which is a much better trade than a flat grey letterbox.




/// Shown for a media reference whose bytes haven't arrived yet, so the post doesn't look
    /// broken while it's still downloading from the sender, a relay, or the shared mailbox.

    /// The single-media tile's aspect ratio, taken from the image (or a video's thumbnail).

    /// The speaker chip over a video page — plus that page's Save/Share menu.
    func muteButton(_ ref: String) -> some View { PostMuteButton(item: item, ref: ref) }

    /// "Keep on this device" toggle — pins/unpins this ref in the device-local retention set so no
    /// cleanup (orphan sweep, age/size limit, or the cleanup screen) ever removes its bytes.


    /// Drive this card's media from whether it's the centered post: the active post
    /// plays its song + the visible carousel video; an inactive post pauses everything.


    /// Fully release this card's video players when it scrolls off-screen — pause, replace each item with
    /// nothing (frees the decode pipeline), remove the loop observers, and drop the dicts. Without this an
    /// off-screen card kept buffering video forever; combined with the leaked observers it ran to ~100 GB.


    @ViewBuilder private var avatar: some View {
        if item.isMe {
            MyAvatar(size: 34)
        } else {
            PeerAvatar(nodeHex: item.authorShort, name: authorName, size: 34)
        }
    }


    func singleAspect(_ ref: String) -> CGFloat { postSingleAspect(ref, in: item.media) }
    func letterboxes(_ ref: String, in containerAspect: CGFloat) -> Bool {
        postLetterboxes(ref, in: containerAspect)
    }
    func shareURL(_ ref: String) -> URL? { postShareURL(ref) }

    func keepOnDeviceButton(_ ref: String) -> some View { KeepOnDeviceButton(ref: ref) }

    /// Kept on the card: the single-video gesture branch and storyableMedia read them, and both are
    /// pure functions of item.media — no player state involved.
    var realMedia: [String] {
        MediaVariants.displayRefs(item.media).filter { SharedLocation.parse($0) == nil }
    }
    func isVideo(_ r: String) -> Bool { MediaKind(ref: r) == .video }
    var isSingleVideoPost: Bool {
        let m = realMedia
        return m.count == 1 && m.first.map(isVideo) == true
    }

    /// The media, as a CHILD VIEW.
    ///
    /// This is the last step of breaking PostCard up, and the one with a measurable point: the media
    /// owns its own state now (player cache, carousel page, measured width, data-saver taps), so
    /// paging a carousel or a width measurement landing re-renders the MEDIA — not the header,
    /// reactions and comments along with it. The playback lifecycle hooks moved with it, because they
    /// belong to the thing that owns the players.
    private var postMedia: some View {
        PostMediaView(item: item, isActive: isActive, onHeart: { heartIt() },
                      onToggleMute: { togglePostMute() }, zoomTarget: $zoomTarget)
    }

    private var header: some View {
        PostHeader(item: item, friendName: friendName, authorName: authorName,
                   storyableMedia: storyableMedia, onUnsend: onUnsend,
                   showEdit: $showEdit, showReport: $showReport, storyShare: $storyShare)
    }

    // Show only the most-reacted few chips so a post with many distinct emoji can't flood the row and
    // break the layout; the rest collapse into a "+N" chip that opens the full who-reacted sheet. A chip
    // the user owns is always kept visible (so they can untap it), even if it's not in the top counts.

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
        PostReactionsRow(reactions: item.reactions, onReact: onReact, onUnreact: onUnreact)
    }


    /// One comment: tappable avatar + name (→ profile), time, body, media, reactions.

    /// Reactions under a comment: existing reaction chips (tap to toggle your own, like the
    /// post-level row) plus a small react button that opens the emoji picker. The core
    /// `react`/`unreact` work on ANY event id, so a comment id is targeted exactly like a post.

    /// A commenter's avatar — mine is my real photo/emoji; others use their synced photo/emoji.

    /// Wrap a commenter's avatar/name so tapping opens their profile (no link for yourself).


    private var commentField: some View {
        PostCommentField(onSubmit: onComment, onFocus: onCommentFocus)
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
    /// Post at the top edge — pinned so arriving posts don't shove the page (see `.scrollPosition`).
    @State private var anchoredPostId: String?

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
                // Lazy — see the note on ProfileView. A member who imported their own archive has as
                // many posts on this screen as you have on yours, and this list built all of them.
                LazyVStack(spacing: 16) {
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
                            .equatable()
                            // Report center position so a profile post's video AUTO-PLAYS when centered,
                            // exactly like the main feed (the profile list was missing this, so videos here
                            // only ever played on a manual scrub).
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: PostCenterKey.self, value: [item.id: geo.frame(in: .global).midY])
                            })
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(16)
            }
            // Hold the reader's place when posts arrive — same reasoning as the main feed: this
            // list is newest-first, so anything new is inserted ABOVE what is being read, and a
            // plain ScrollView keeps its offset rather than its content. Pinning the post at the
            // top edge means the page grows above it instead of under the reader.
            .scrollPosition(id: $anchoredPostId, anchor: .top)
            .onPreferenceChange(PostCenterKey.self) { centers in
                // The profile post nearest the vertical center becomes active → its video plays + loops.
                let target = PlatformScreen.contentCenterY
                let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                AudioCoordinator.shared.center(nearest?.key, container: "profile")
            }
                .environment(\.havenFeedContainer, "profile")
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
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var store = FeedStore.shared
    let friendName: String
    @State private var showStories = false
    @State private var storyIndex = 0

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                // LAZY, and on this screen that is the difference between working and being killed.
                //
                // This was a plain VStack, so opening the You tab BUILT EVERY POST AT ONCE — each
                // with its media, its blurred backdrop bitmap and its own view graph. With a handful
                // of posts nobody noticed. After an Instagram import there are hundreds, and the tab
                // spent ~59% CPU for two and a half minutes (a cpu_resource report whose samples are
                // 254 SwiftUICore / 160 UIKitCore / 103 QuartzCore / 43 AttributeGraph against 33 in
                // Haven's own code — a view graph being built, not work being done) and then the app
                // was killed for memory shortly after the tab appeared.
                //
                // The circle feed has been lazy all along; these two profile lists were simply never
                // given the same treatment, and no ordinary account had enough posts to expose it.
                LazyVStack(spacing: 16) {
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
                            // Same reason the circle feed does it: FeedStore republishes constantly,
                            // and without this every republish re-evaluates a ~1,500-line body for
                            // every card on screen.
                            .equatable()
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Your posts")
        .havenInlineNavTitle()
        // DEBUG-only trace, because this screen is the one that gets the app killed and a memory
        // kill leaves nothing behind to read. Says what it is holding and how much headroom is
        // left, twice a second, so the last line before the process disappears is the evidence.
        .memoryTrace { "you-tab \(store.myPosts.count) posts / \(store.myStories.count) stories" }
        .havenFullScreenCover(isPresented: $showStories) {
            StoryViewer(stories: store.myStories, index: storyIndex, friendName: friendName)
        }
    }

    private var storiesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your stories").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy for the same reason as the list below it: an import that brought stories over
                // as kept stories can leave dozens here, and an eager HStack decodes a thumbnail for
                // every one of them the moment the tab opens — off-screen ones included.
                LazyHStack(spacing: 12) {
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
