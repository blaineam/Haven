import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Hands a new device of MY OWN account the account's whole history — through the relay, so the old
/// and new device never have to be awake at the same time.
///
/// Before this, a new or restored phone got history three ways, none of which scaled to a large,
/// old account: a single fire-and-forget push of only the posts the old phone authored (at link
/// time), a periodic own-device catch-up that re-sent the same newest 6 envelopes per circle every
/// 5 minutes with no cursor (and skipped when the phone was even slightly warm), and relay mailbox
/// copies sealed under epoch keys the new device never held. So history arrived in small chunks, and
/// only while both phones were open and awake — repeatedly.
///
/// The handoff, all on the account lane (`haven/self/<acct>/…`, readable and writable only by this
/// account's own devices, never swept):
///
///   NEW device (target)                          OLD device (source)
///   ────────────────────                         ───────────────────
///   PUT  history-req/<me>        ──────────▶     sees the request on its next sync — foreground,
///   silent push + frame-36 nudge                 background refresh, a push wake, or overnight
///                                                processing — and exports history newest-first,
///                                                round-robin across circles (friends' posts and DMs
///   GET  history/<me>/manifest   ◀──────────     included), one page per PUT:
///   GET  history/<me>/<run>/<n>  ◀──────────       history/<me>/<run>/<n>, then the manifest
///   ingest, persist, advance                     Resumes where it stopped on the next wake.
///   (resumes where it stopped)
///
/// Each page is self-sufficient (it carries the source's roster + key commit), so the target can
/// open it whenever it arrives. Frame 36 is only a "look now" hint — the relay copy is the request.
/// Pages are sealed exactly like the own-device catch-up, so nothing new is exposed to the relay.
///
/// MEDIA rides the same handoff and the same progress. Each page names the blobs its events carry
/// (photos, videos, and their thumb/preview/poster/original companions). The target asks the source
/// for them DIRECTLY first — the own-device media stream over the mesh and iroh, nothing parked on a
/// server. If that stalls (the source is asleep, or the two can't reach each other), the target
/// leaves a per-page "need" on the lane and the source uploads just that page's media, circle-sealed
/// and chunked; the target downloads, verifies, stores, and blanks the relay copies.
@MainActor
final class HistoryHandoff: ObservableObject {
    static let shared = HistoryHandoff()

    /// What the UI shows: a progress bar in Settings ▸ Devices and a banner over the feed.
    struct Status: Equatable {
        enum Phase: Equatable {
            case idle
            /// Asked; no other device has answered yet (it will on its next wake).
            case waitingForSource
            case receiving
            /// Everything arrived — shown until dismissed or the next launch.
            case received
            /// This device is uploading history for another of my devices.
            case sending
        }
        var phase: Phase = .idle
        /// Events received (target) or sent (source) so far.
        var done = 0
        /// Total events expected; 0 = not known yet.
        var total = 0
        /// Photos/videos (and their companions) received / known so far — the target's media count.
        var mediaDone = 0
        var mediaTotal = 0
        /// One bar for both: posts and media weigh the same per item.
        var fraction: Double? {
            let t = total + mediaTotal
            return t > 0 ? min(1, Double(done + mediaDone) / Double(t)) : nil
        }
    }
    @Published private(set) var status = Status()

    /// "Look at the account lane now" — a nudge to my own devices, no payload semantics.
    static let nudgeFrame: UInt8 = 36
    /// Events per page. One page is one engine pass of real crypto (a signature per event), so it
    /// stays well under a second on a phone and doesn't park the UI behind the engine mutex.
    static let pageEvents: UInt32 = 120

    private init() {
        refreshStatus()
        #if os(iOS)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HistoryHandoff.shared.enteredBackground() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HistoryHandoff.shared.becameActive() }
        }
        #endif
    }

    // MARK: - Keeping a transfer moving

    /// True while a transfer is running in either direction. `CallManager.syncIdleTimer` holds the
    /// screen awake while this is set — derived, never latched, exactly like a call — because a
    /// phone that auto-locks suspends Haven and the transfer with it.
    @Published private(set) var transferActive = false
    /// Last time this device did SOURCE work: a page, a relayed blob, or a direct media serve.
    private var lastSendingAt: UInt64 = 0
    /// Unrelayed needs were seen on the last source pass (more media to upload).
    private var needsPending = false

    /// Device ids this device is currently serving a handoff to. Own-device media streams go to
    /// these over iroh directly — a cached roster can lag the device that just joined.
    var handoffTargets: [String] { Array(serves.keys) }

    /// Called when this device served history work — including a direct media ask from my other
    /// device DURING a handoff (FeedStore's media-request handler).
    func noteSending() {
        guard !serves.isEmpty else { return }   // a normal own-device media ask isn't a handoff
        lastSendingAt = HistoryHandoffWire.nowMs()
        refreshActive()
        startDriver()
    }

    private func refreshActive() {
        let active = hasOutstandingWork
        if active != transferActive {
            transferActive = active
            NearbyTransport.handoffBoost = active
            #if os(iOS)
            CallManager.shared.syncIdleTimer()
            #endif
        }
        refreshStatus()
    }

    /// The loop that actually moves the transfer. It used to ride the mailbox poll, which stretches
    /// to minutes when the app is idle — so each side did ~20s of work every few minutes and a big
    /// library looked stuck. This runs back-to-back while there is work, in the foreground, and for
    /// the background grace iOS allows after the app is switched away.
    private var driver: Task<Void, Never>?
    func startDriver() {
        refreshActive()   // assert the screen hold now, not after the loop's first pass
        guard driver == nil, hasOutstandingWork else { return }
        driver = Task { @MainActor in
            while !Task.isCancelled, HistoryHandoff.shared.hasOutstandingWork {
                #if os(iOS)
                if UIApplication.shared.applicationState == .background, bgTask == .invalid { break }
                #endif
                let moved = await tick(budget: 25)
                refreshActive()
                try? await Task.sleep(nanoseconds: moved ? 1_000_000_000 : 6_000_000_000)
            }
            driver = nil
            refreshActive()
        }
    }

    #if os(iOS)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private func enteredBackground() {
        guard transferActive, bgTask == .invalid else { return }
        // Finish the item in hand (and a bit more) instead of freezing mid-blob.
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "haven.history-handoff") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        startDriver()
    }
    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
    private func becameActive() {
        endBackgroundTask()
        startDriver()
    }
    #endif

    /// Rebuild `status` from the persisted state (both roles).
    private func refreshStatus() {
        var st = Status()
        if let w = want, w.account == AccountStore.currentNodeHex() {
            st.phase = w.run == nil ? .waitingForSource : .receiving
            st.done = w.receivedEvents
            st.total = w.totalEvents
            st.mediaDone = w.mediaDone
            st.mediaTotal = w.mediaTotal
        } else if let s = serves.values.first(where: { !$0.complete }) {
            st.phase = .sending
            st.done = s.servedEvents
            st.total = s.totalEvents
        } else if !serves.isEmpty || needsPending || HistoryHandoffWire.nowMs() &- lastSendingAt < 120_000 {
            st.phase = .sending   // posts are across; media is still going until the target says done
        } else if receivedBanner {
            st.phase = .received
        }
        if st != status { status = st }
    }

    /// The "all your history is here" banner, until dismissed.
    private var receivedBanner = false
    func dismissReceived() { receivedBanner = false; refreshStatus() }

    // MARK: - Target (the new device)

    /// What this device is waiting for. Persisted, so a pull resumes across launches.
    private struct Want: Codable {
        var account: String
        var at: UInt64
        var run: String?
        /// The source device this pull follows (one at a time — see `pickManifest`).
        var source: String?
        var nextPage = 0
        var received = 0
        /// Event envelopes taken in (progress numerator) and the source's announced total.
        var receivedEvents = 0
        var totalEvents = 0
        var lastNudgeAt: UInt64 = 0
        /// Consecutive attempts at a page whose circle isn't on this device yet.
        var heldAttempts = 0
        /// Pages whose posts are in but whose media isn't yet, oldest first.
        var mediaQueue: [MediaTask] = []
        var mediaDone = 0
        var mediaTotal = 0
        var lastNeedNudgeAt: UInt64 = 0
    }

    /// One page's outstanding media on the target.
    private struct MediaTask: Codable {
        var page: Int
        var circle: String
        var pending: [HistoryHandoffWire.MediaItem]
        /// Direct lane: when we first/last asked the source, and when something last landed.
        var firstAskAt: UInt64 = 0
        var lastAskAt: UInt64 = 0
        var lastProgressAt: UInt64 = 0
        /// Relay lane: the "need" is on the lane; attempts at downloading what the source put up.
        var needPut = false
        var relayAttempts = 0
        /// The source has started putting this page's media on the relay (a ready marker exists).
        /// OPTIONAL on purpose: a persisted queue from an older build must still decode — a
        /// non-optional new field would fail the whole record and lose the transfer's place.
        var relayStarted: Bool?
        /// Direct stalled on this page once: leave it on the relay (no flip-flop back to direct).
        var directFailed: Bool?
        /// When the relay need was put — a need the source never starts on is pulled back.
        var needAt: UInt64?
    }
    /// v2: v1 records (rc.1/rc.2) lack the media fields; a stale one is simply re-requested.
    private static let wantKey = "haven.historyHandoff.want.v2"
    private var want: Want? {
        get {
            guard let d = UserDefaults.standard.data(forKey: Self.wantKey) else { return nil }
            return try? JSONDecoder().decode(Want.self, from: d)
        }
        set {
            if let newValue, let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: Self.wantKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.wantKey)
            }
            refreshStatus()
        }
    }

    /// Waiting on history for the current account.
    var isWaiting: Bool {
        guard let w = want else { return false }
        return w.account == AccountStore.currentNodeHex()
    }

    /// Ask my other devices for the whole history. Called when this device joins an account it
    /// didn't create the history on (a link, a restore onto a new phone) — and from Settings.
    func requestHistory(reason: String) {
        let acct = AccountStore.currentNodeHex()
        guard !acct.isEmpty else { return }
        want = Want(account: acct, at: HistoryHandoffWire.nowMs())
        HavenLog.sync("history handoff: requested (\(reason))")
        Task { await announce(force: true); startDriver() }
    }

    /// Publish (or re-publish) the request and nudge my devices. Throttled: a device that is asleep
    /// sees the relay copy on its own next wake anyway.
    private func announce(force: Bool = false) async {
        guard var w = want else { return }
        let now = HistoryHandoffWire.nowMs()
        guard force || now - w.lastNudgeAt > 10 * 60 * 1000 else { return }
        // A link reconfigures the engine right before asking: wait for the new one (the roster below
        // needs it), rather than failing the first ask and waiting a whole tick for the retry.
        for _ in 0..<60 where !FeedStore.shared.engineReady { try? await Task.sleep(nanoseconds: 250_000_000) }
        let me = DeviceKeyStore.deviceNodeHex()
        // The relay must know this device before it accepts the account-lane write, and the source
        // must know it before its pages are sealed to it: publish the roster, and carry it along.
        await FeedStore.shared.publishOwnRosterNow()
        let roster = await FeedStore.shared.ownRosterWire()
        let req = HistoryHandoffWire.Request(device: me, at: w.at, roster: roster?.base64EncodedString())
        guard let body = try? JSONEncoder().encode(req),
              await SelfSyncCoordinator.shared.accountLanePut(HistoryHandoffWire.requestKey(w.account, me), body) else {
            HavenLog.sync("history handoff: request not published yet (no reachable relay)")
            return
        }
        w.lastNudgeAt = now
        want = w
        FeedStore.shared.nudgeMyDevicesForHistory()
        PushManager.shared.wakeMyDevices()
    }

    /// Pull whatever pages are ready, until `deadline`. True if anything was ingested.
    @discardableResult
    func pull(until deadline: Date) async -> Bool {
        guard var w = want, !pulling else { return false }
        guard w.account == AccountStore.currentNodeHex() else { want = nil; return false }   // identity changed
        pulling = true
        defer { pulling = false }
        let me = DeviceKeyStore.deviceNodeHex()
        guard let m = await pickManifest(account: w.account, target: me, want: w) else {
            await announce()   // no answer to THIS request yet — keep the ask alive
            return false
        }
        if w.run != m.run || w.source != m.source {
            w.run = m.run; w.source = m.source; w.nextPage = 0; w.heldAttempts = 0; w.receivedEvents = 0
        }
        w.totalEvents = max(m.totalEvents ?? 0, w.receivedEvents)
        want = w
        var progressed = false
        while w.nextPage < m.pages, Date() < deadline {
            guard let blob = await SelfSyncCoordinator.shared.accountLaneGet(HistoryHandoffWire.pageKey(w.account, me, m.source, m.run, w.nextPage)) else {
                break   // not on any reachable relay yet — the source may still be uploading it
            }
            guard let page = HistoryHandoffWire.decodePage(blob) else {
                HavenLog.sync("history handoff: page \(w.nextPage) unreadable — skipped")
                w.nextPage += 1; want = w
                continue
            }
            guard let applied = await FeedStore.shared.ingestHandoffPage(circleId: page.circleId, envelopes: page.envelopes) else {
                // Its circle hasn't reached this device yet (self-sync delivers the circle list). Wait
                // for it — but a circle that never arrives must not wedge every page behind it.
                w.heldAttempts += 1
                if w.heldAttempts >= 4 {
                    HavenLog.sync("history handoff: page \(w.nextPage) (\(page.circleId.prefix(12))) never found its circle — skipped")
                    w.nextPage += 1; w.heldAttempts = 0
                }
                want = w
                break
            }
            w.received += applied
            w.receivedEvents += HistoryHandoffWire.eventCount(page.envelopes)
            let missing = page.media.filter { !MediaStore.shared.hasLocalFile($0.ref) }
            if !missing.isEmpty {
                w.mediaQueue.append(MediaTask(page: w.nextPage, circle: page.circleId, pending: missing))
                w.mediaTotal += missing.count
            }
            w.nextPage += 1
            w.heldAttempts = 0
            want = w
            progressed = true
        }
        if Date() < deadline, !w.mediaQueue.isEmpty {
            if await pullMedia(&w, account: w.account, me: me, manifest: m, until: deadline) { progressed = true }
            want = w
        }
        if m.complete && w.nextPage >= m.pages && w.mediaQueue.isEmpty {
            HavenLog.sync("history handoff: complete — \(w.received) envelopes over \(m.pages) pages, \(w.mediaDone)/\(w.mediaTotal) media")
            receivedBanner = true
            want = nil
            // Tell the source it can stop considering this ask.
            let done = HistoryHandoffWire.Request(device: me, at: w.at, done: true)
            if let body = try? JSONEncoder().encode(done) {
                _ = await SelfSyncCoordinator.shared.accountLanePut(HistoryHandoffWire.requestKey(w.account, me), body)
            }
        } else if progressed {
            HavenLog.sync("history handoff: page \(w.nextPage)/\(m.pages)\(m.complete ? "" : "+") received")
        }
        return progressed
    }
    private var pulling = false

    /// Direct asks in flight (ref → when asked). In memory: a relaunch simply re-asks. The window is
    /// what keeps the SOURCE alive — asking for 2,000 blobs at once made it try to stream them all
    /// concurrently, and it served a handful before choking.
    private static let directWindow = 12
    private var directAsked: [String: UInt64] = [:]
    private var directWindowSince: UInt64 = 0
    private var lastDirectLandAt: UInt64 = 0
    private var lastChunkProgress = 0
    /// Direct stalled twice this session: stop trying it and go relay-only (rolling pages).
    private var directStalls = 0
    /// Relay pages requested at once while direct isn't an option.
    private static let relayWindow = 3

    /// Work the media queue: count what has landed (direct transfers arrive on their own), keep a
    /// small window of direct asks going while the source is awake, and move pages to the relay when
    /// direct stalls or the source sleeps — a few at a time, never the whole library at once.
    private func pullMedia(_ w: inout Want, account: String, me: String,
                           manifest m: HistoryHandoffWire.Manifest, until deadline: Date) async -> Bool {
        let now = HistoryHandoffWire.nowMs()
        // Live = the source touched its manifest in the last two minutes (it refreshes it while it
        // serves), i.e. it is awake right now and can stream.
        let sourceLive = now &- (m.updatedAt ?? 0) < 120_000
        var progressed = false

        // 1. Count what landed, everywhere.
        var i = 0
        while i < w.mediaQueue.count {
            var t = w.mediaQueue[i]
            let before = t.pending.count
            t.pending.removeAll { item in
                guard MediaStore.shared.hasLocalFile(item.ref) else { return false }
                directAsked[item.ref] = nil
                return true
            }
            if t.pending.count < before {
                w.mediaDone += before - t.pending.count
                t.lastProgressAt = now
                lastDirectLandAt = now
                progressed = true
            }
            if t.pending.isEmpty {
                if t.needPut { await blankRelayMedia(account: account, me: me, manifest: m, page: t.page) }
                w.mediaQueue.remove(at: i); continue
            }
            w.mediaQueue[i] = t
            i += 1
        }
        if directAsked.isEmpty { directWindowSince = 0 }

        // 2. Relay pages already requested: download whatever the source has put up so far.
        for j in w.mediaQueue.indices where w.mediaQueue[j].needPut && Date() < deadline {
            var t = w.mediaQueue[j]
            if await pullRelayMedia(&t, &w, account: account, me: me, manifest: m, until: deadline) { progressed = true }
            w.mediaQueue[j] = t
        }
        for j in w.mediaQueue.indices.reversed() where w.mediaQueue[j].pending.isEmpty {
            let t = w.mediaQueue.remove(at: j)
            await blankRelayMedia(account: account, me: me, manifest: m, page: t.page)
        }

        // 3. Direct window, or relay pages when direct isn't possible.
        // Chunk-level progress counts: a video streaming directly is progress long before it completes.
        let chunks = FeedStore.shared.directChunkProgress(Array(directAsked.keys))
        if chunks > lastChunkProgress { lastDirectLandAt = now }
        lastChunkProgress = chunks
        let directUsable = sourceLive && directStalls < 2
        if directUsable {
            // Pages sent to the relay that the source hasn't started on: while it is awake and
            // streaming works, take them back — direct is far faster than phone → relay → phone
            // (an rc.3 queue had put EVERY page on the relay). Withdraw the need so it doesn't
            // upload them anyway.
            for j in w.mediaQueue.indices where w.mediaQueue[j].needPut && w.mediaQueue[j].relayStarted != true
                && (w.mediaQueue[j].directFailed != true || now &- (w.mediaQueue[j].needAt ?? 0) > 5 * 60_000) {
                let key = HistoryHandoffWire.needKey(account, me, m.source, m.run, w.mediaQueue[j].page)
                if await SelfSyncCoordinator.shared.accountLanePut(key, Data()) {
                    w.mediaQueue[j].needPut = false
                    w.mediaQueue[j].directFailed = nil
                    HavenLog.sync("history handoff: page \(w.mediaQueue[j].page) media back to direct (source awake)")
                }
            }
            let stallClock = max(lastDirectLandAt, directWindowSince)
            if !directAsked.isEmpty, stallClock > 0, now &- stallClock > 90_000 {
                // Nothing landed for 90s with asks outstanding: those pages go to the relay.
                directStalls += 1
                let stuck = Set(directAsked.keys)
                directAsked.removeAll(); directWindowSince = 0
                for j in w.mediaQueue.indices where !w.mediaQueue[j].needPut
                    && w.mediaQueue[j].pending.contains(where: { stuck.contains($0.ref) }) {
                    var t = w.mediaQueue[j]
                    t.directFailed = true
                    await putNeed(&t, &w, account: account, me: me, manifest: m, why: "direct stalled")
                    w.mediaQueue[j] = t
                }
            } else {
                // Re-ask anything outstanding for 45s (dropped on the way), then top the window up —
                // SMALLEST first across all direct pages, so photos land in seconds and the big videos
                // stream after them instead of filling the whole window.
                var ask: [String] = directAsked.filter { now &- $0.value > 45_000 }.map(\.key)
                let candidates = w.mediaQueue.filter { !$0.needPut }.flatMap(\.pending)
                    .filter { directAsked[$0.ref] == nil }.sorted { $0.size < $1.size }
                for item in candidates where directAsked.count + ask.count < Self.directWindow {
                    if !ask.contains(item.ref) { ask.append(item.ref) }
                }
                if !ask.isEmpty {
                    if directAsked.isEmpty { directWindowSince = now }
                    for r in ask { directAsked[r] = now }
                    FeedStore.shared.askMyDevicesForMedia(ask)
                }
            }
        } else {
            // Source asleep (or unreachable directly): keep a few pages on the relay at a time.
            directAsked.removeAll(); directWindowSince = 0
            var onRelay = w.mediaQueue.filter(\.needPut).count
            for j in w.mediaQueue.indices where !w.mediaQueue[j].needPut && onRelay < Self.relayWindow {
                var t = w.mediaQueue[j]
                await putNeed(&t, &w, account: account, me: me, manifest: m,
                              why: sourceLive ? "direct unreachable" : "source asleep")
                w.mediaQueue[j] = t
                if t.needPut { onRelay += 1 }
            }
        }
        return progressed
    }

    private func putNeed(_ t: inout MediaTask, _ w: inout Want, account: String, me: String,
                         manifest m: HistoryHandoffWire.Manifest, why: String) async {
        let key = HistoryHandoffWire.needKey(account, me, m.source, m.run, t.page)
        guard await SelfSyncCoordinator.shared.accountLanePut(key, Data("1".utf8)) else { return }
        t.needPut = true
        t.needAt = HistoryHandoffWire.nowMs()
        HavenLog.sync("history handoff: page \(t.page) media → relay (\(t.pending.count) items, \(why))")
        let now = HistoryHandoffWire.nowMs()
        if now &- w.lastNeedNudgeAt > 60_000 {
            w.lastNeedNudgeAt = now
            FeedStore.shared.nudgeMyDevicesForHistory()
            PushManager.shared.wakeMyDevices()
        }
    }

    /// RELAY lane for one page: once the source has marked it ready, download each blob's chunks to
    /// a file, open + verify + adopt, then blank the relay copy.
    private func pullRelayMedia(_ t: inout MediaTask, _ w: inout Want, account: String, me: String,
                                manifest m: HistoryHandoffWire.Manifest, until deadline: Date) async -> Bool {
        guard let raw = await SelfSyncCoordinator.shared.accountLaneGet(
                HistoryHandoffWire.mediaReadyKey(account, me, m.source, m.run, t.page)),
              let ready = try? JSONDecoder().decode(HistoryHandoffWire.MediaReady.self, from: raw) else {
            return false   // the source hasn't put it up yet
        }
        t.relayStarted = true
        let chunksByRef = Dictionary(ready.items.map { ($0.ref, $0.chunks) }, uniquingKeysWith: { a, _ in a })
        var progressed = false
        for item in t.pending where Date() < deadline {
            guard let chunks = chunksByRef[item.ref] else {
                // Not up yet — unless the source finished this page without it (it no longer holds it).
                if ready.complete != false {   // nil = an rc.3 source, which only wrote it when done
                    t.pending.removeAll { $0.ref == item.ref }
                    w.mediaTotal = max(w.mediaDone, w.mediaTotal - 1)
                }
                continue
            }
            switch await downloadRelayMedia(account: account, me: me, manifest: m, ref: item.ref, chunks: chunks, circle: t.circle) {
            case .stored:
                t.pending.removeAll { $0.ref == item.ref }
                w.mediaDone += 1
                progressed = true
            case .unopenable:
                HavenLog.sync("history handoff: media \(item.ref.prefix(12)) unopenable — skipped")
                t.pending.removeAll { $0.ref == item.ref }
                w.mediaTotal = max(w.mediaDone, w.mediaTotal - 1)
            case .missingChunk:
                t.relayAttempts += 1
                if t.relayAttempts >= 6 {
                    HavenLog.sync("history handoff: page \(t.page) media incomplete on the relay — giving up on \(t.pending.count)")
                    w.mediaTotal = max(w.mediaDone, w.mediaTotal - t.pending.count)
                    t.pending.removeAll()
                }
                return progressed
            }
        }
        return progressed
    }

    private enum RelayMedia { case stored, missingChunk, unopenable }

    /// A page's media is all here: blank every relay copy the source put up for it, however each item
    /// actually arrived (a late direct stream can beat the relay download — then nothing else would).
    private func blankRelayMedia(account: String, me: String, manifest m: HistoryHandoffWire.Manifest, page: Int) async {
        // Withdraw the need first (an empty body), so a source that hasn't uploaded yet never does.
        _ = await SelfSyncCoordinator.shared.accountLanePut(HistoryHandoffWire.needKey(account, me, m.source, m.run, page), Data())
        let readyKey = HistoryHandoffWire.mediaReadyKey(account, me, m.source, m.run, page)
        guard let raw = await SelfSyncCoordinator.shared.accountLaneGet(readyKey),
              let ready = try? JSONDecoder().decode(HistoryHandoffWire.MediaReady.self, from: raw) else { return }
        for item in ready.items {
            for c in 0..<item.chunks {
                _ = await SelfSyncCoordinator.shared.accountLanePut(
                    HistoryHandoffWire.mediaChunkKey(account, me, m.source, m.run, item.ref, c), Data())
            }
        }
        _ = await SelfSyncCoordinator.shared.accountLanePut(readyKey, Data())
    }

    private func downloadRelayMedia(account: String, me: String, manifest m: HistoryHandoffWire.Manifest,
                                    ref: String, chunks: Int, circle: String) async -> RelayMedia {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-in-\(UUID().uuidString).sealed")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let fh = try? FileHandle(forWritingTo: tmp) else { return .missingChunk }
        for c in 0..<chunks {
            guard let d = await SelfSyncCoordinator.shared.accountLaneGet(
                    HistoryHandoffWire.mediaChunkKey(account, me, m.source, m.run, ref, c)), !d.isEmpty else {
                try? fh.close()
                return .missingChunk
            }
            fh.write(d)
        }
        try? fh.close()
        guard await FeedStore.shared.openHandoffMedia(circleId: circle, sealed: tmp, ref: ref) else { return .unopenable }
        // Stored: blank the relay copy (the lane is never swept; don't leave a second library there).
        for c in 0..<chunks {
            _ = await SelfSyncCoordinator.shared.accountLanePut(
                HistoryHandoffWire.mediaChunkKey(account, me, m.source, m.run, ref, c), Data())
        }
        return .stored
    }

    /// The manifest to follow for this request: the source already being followed while it is still
    /// live, otherwise the live one furthest along. (Several of my devices may answer; following one
    /// keeps the page cursor meaningful.)
    private func pickManifest(account: String, target: String, want w: Want) async -> HistoryHandoffWire.Manifest? {
        var found: [HistoryHandoffWire.Manifest] = []
        for key in await SelfSyncCoordinator.shared.accountLaneList(HistoryHandoffWire.manifestPrefix(account, target)) {
            guard let raw = await SelfSyncCoordinator.shared.accountLaneGet(key),
                  let m = try? JSONDecoder().decode(HistoryHandoffWire.Manifest.self, from: raw),
                  m.forRequest >= w.at else { continue }
            found.append(m)
        }
        let now = HistoryHandoffWire.nowMs()
        if let current = found.first(where: { $0.source == w.source && $0.run == w.run }), current.isLive(now: now) {
            return current
        }
        return found.filter { $0.isLive(now: now) }.max { ($0.complete ? 1 : 0, $0.pages) < ($1.complete ? 1 : 0, $1.pages) }
            ?? found.first { $0.source == w.source && $0.run == w.run }
    }

    // MARK: - Source (a device holding the history)

    private struct Serve: Codable {
        var device: String
        var requestAt: UInt64
        var run: String
        var order: [String]
        var cursors: [String: UInt64] = [:]
        var finished: [String] = []
        var pages = 0
        var complete = false
        var totalEvents = 0
        var servedEvents = 0
        /// The kept-stories media page has been sent. Optional: a record from an earlier build must
        /// still decode (and gets the page appended even though its run already finished).
        var keptSent: Bool?
    }
    private static let serveKey = "haven.historyHandoff.serve.v2"

    /// Per-run media bookkeeping on the source — kept in a FILE, not defaults (a big account names
    /// tens of thousands of blobs): which refs each page named, which pages were relayed, and what is
    /// already on the relay.
    private struct RunMedia: Codable {
        var pageMedia: [String: PageMedia] = [:]
        var relayed: [Int] = []
        var uploaded: [String: Int] = [:]
        struct PageMedia: Codable { var circle: String; var refs: [String] }
    }
    private static func runMediaURL(device: String, run: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("haven-handoff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(device.prefix(16))-\(run).json")
    }
    private static func loadRunMedia(device: String, run: String) -> RunMedia {
        guard let d = try? Data(contentsOf: runMediaURL(device: device, run: run)),
              let r = try? JSONDecoder().decode(RunMedia.self, from: d) else { return RunMedia() }
        return r
    }
    private static func saveRunMedia(_ r: RunMedia, device: String, run: String) {
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: runMediaURL(device: device, run: run), options: .atomic) }
    }
    private var serves: [String: Serve] {
        get {
            guard let d = UserDefaults.standard.data(forKey: Self.serveKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Serve].self, from: d)) ?? [:]
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: Self.serveKey) }
            refreshStatus()
        }
    }

    /// Unfinished work on either side — worth a background wake.
    /// A source counts as busy for as long as ANY handoff it served is unfinished (the target hasn't
    /// marked its request done) — not just while it is actively sending. Otherwise, after a relaunch,
    /// it looked idle, stopped refreshing its manifest, and the target read it as asleep and never
    /// asked it directly: each side waiting for the other to move first.
    var hasOutstandingWork: Bool {
        isWaiting || !serves.isEmpty || needsPending
            || HistoryHandoffWire.nowMs() &- lastSendingAt < 120_000
    }

    /// Serve every open request from my other devices, until `deadline`. True if anything was
    /// uploaded. Cheap when there's nothing to do: one LIST of a tiny prefix.
    @discardableResult
    func serve(until deadline: Date) async -> Bool {
        guard !serving, !ThermalPolicy.isSeriousOrWorse else { return false }
        let acct = AccountStore.currentNodeHex()
        guard !acct.isEmpty, SelfSyncCoordinator.shared.hasAccountLane else { return false }
        // Nothing to serve from until the engine is up with its circles — a run started now would
        // "finish" with zero pages.
        guard FeedStore.shared.engineReady, !FeedStore.shared.circles.isEmpty else { return false }
        serving = true
        defer { serving = false }
        let me = DeviceKeyStore.deviceNodeHex().lowercased()
        var did = false
        // An abandoned handoff (the target never finished) must not keep this phone's screen on
        // forever: runs older than three days are dropped.
        let cutoff = HistoryHandoffWire.nowMs() &- 3 * 24 * 3_600_000
        for (dev, r) in serves where (UInt64(r.run) ?? 0) < cutoff {
            try? FileManager.default.removeItem(at: Self.runMediaURL(device: dev, run: r.run))
            serves[dev] = nil
        }
        for key in await SelfSyncCoordinator.shared.accountLaneList(HistoryHandoffWire.requestPrefix(acct)) {
            let device = String(key.split(separator: "/").last ?? "").lowercased()
            guard device.count == 64, device != me,
                  let raw = await SelfSyncCoordinator.shared.accountLaneGet(key),
                  let req = try? JSONDecoder().decode(HistoryHandoffWire.Request.self, from: raw) else { continue }
            if req.done == true {
                // The target has everything: drop this run's bookkeeping.
                if let old = serves[device] {
                    try? FileManager.default.removeItem(at: Self.runMediaURL(device: device, run: old.run))
                    serves[device] = nil
                }
                continue
            }
            var s = serves[device]
            if s == nil || s!.requestAt != req.at {
                // Another of my devices already answering this ask? Let it finish (unless it went quiet).
                if await anotherSourceIsServing(account: acct, target: device, request: req.at, me: me) { continue }
                // Learn the new device first, so the key commit on every page is sealed to it. Only a
                // seed holder can union-merge (and re-sign) its own roster.
                if AccountStore.storedSeed() != nil, let b64 = req.roster, let wire = Data(base64Encoded: b64) {
                    let st = await FeedStore.shared.ingestOwnDeviceRoster(wire)
                    HavenLog.sync("history handoff: \(device.prefix(8))'s roster ingested (\(st))")
                }
                // A new ask (or a re-ask after a finished run): start a fresh run, newest circles first.
                let order = FeedStore.shared.circles.map(\.id)
                s = Serve(device: device, requestAt: req.at, run: String(HistoryHandoffWire.nowMs()), order: order,
                          totalEvents: await FeedStore.shared.historyEventCount(circleIds: order))
                HavenLog.sync("history handoff: serving \(device.prefix(8)) — \(s!.order.count) circles")
            }
            guard var run = s else { continue }
            if !run.complete, await serveRun(&run, account: acct, source: me, until: deadline) { did = true }
            if run.complete, run.keptSent != true, Date() < deadline,
               await serveKeptStories(&run, account: acct, source: me) { did = true }
            // Still streaming media directly after the posts are done: keep the manifest fresh, or
            // the target reads this device as asleep after two minutes and detours via the relay.
            let nowMs = HistoryHandoffWire.nowMs()
            // Heartbeat while this device is up and the handoff unfinished — the target's "is the
            // source awake?" test is this timestamp, and direct streaming depends on it.
            if nowMs &- (lastManifestTouch[device] ?? 0) > 30_000 {
                lastManifestTouch[device] = nowMs
                await putManifest(run, account: acct, source: me)
            }
            serves[device] = run
            // Pages whose media the target couldn't get directly — whether or not paging is finished.
            if Date() < deadline, await serveNeeds(run, account: acct, source: me, until: deadline) { did = true }
            if Date() >= deadline { break }
        }
        return did
    }
    private var serving = false
    private var lastManifestTouch: [String: UInt64] = [:]

    private func anotherSourceIsServing(account: String, target: String, request: UInt64, me: String) async -> Bool {
        let now = HistoryHandoffWire.nowMs()
        for key in await SelfSyncCoordinator.shared.accountLaneList(HistoryHandoffWire.manifestPrefix(account, target)) {
            guard let raw = await SelfSyncCoordinator.shared.accountLaneGet(key),
                  let m = try? JSONDecoder().decode(HistoryHandoffWire.Manifest.self, from: raw),
                  m.source.lowercased() != me, m.forRequest >= request, m.isLive(now: now) else { continue }
            return true
        }
        return false
    }

    /// Round-robin one page per circle per pass, newest first everywhere, so the new device sees
    /// recent content across all circles before it sees any circle's distant past.
    private func serveRun(_ run: inout Serve, account: String, source: String, until deadline: Date) async -> Bool {
        var did = false
        while !run.complete, Date() < deadline {
            let pending = run.order.filter { !run.finished.contains($0) }
            if pending.isEmpty {
                run.complete = true
                await putManifest(run, account: account, source: source)
                HavenLog.sync("history handoff: served \(run.device.prefix(8)) — \(run.pages) pages")
                break
            }
            for cid in pending {
                guard Date() < deadline else { break }
                let before = run.cursors[cid] ?? 0
                guard let page = await FeedStore.shared.exportHistoryPage(circleId: cid, before: before, limit: Self.pageEvents) else {
                    return did   // engine went away (identity switch / teardown)
                }
                if page.events == 0 { run.finished.append(cid); continue }
                // Name the page's media (only what this device actually holds) so the target can ask for it.
                let media: [HistoryHandoffWire.MediaItem] = HistoryHandoffWire.blobRefs(page.mediaRefs).compactMap { ref in
                    guard let url = MediaStore.shared.storagePath(for: ref),
                          let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
                    else { return nil }
                    return HistoryHandoffWire.MediaItem(ref: ref, size: size)
                }
                let blob = HistoryHandoffWire.encodePage(circleId: cid, envelopes: page.envelopes, media: media)
                guard await SelfSyncCoordinator.shared.accountLanePut(
                    HistoryHandoffWire.pageKey(account, run.device, source, run.run, run.pages), blob) else {
                    return did   // no relay took it — resume from this cursor on the next wake
                }
                if !media.isEmpty {
                    var rm = Self.loadRunMedia(device: run.device, run: run.run)
                    rm.pageMedia[String(run.pages)] = RunMedia.PageMedia(circle: cid, refs: media.map(\.ref))
                    Self.saveRunMedia(rm, device: run.device, run: run.run)
                }
                run.pages += 1
                run.servedEvents += Int(page.events)
                lastSendingAt = HistoryHandoffWire.nowMs()
                run.cursors[cid] = page.oldestMs
                serves[run.device] = run
                await putManifest(run, account: account, source: source)
                did = true
                // Air between pages: each export holds the engine for real crypto.
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        return did
    }

    /// Kept stories are held as SNAPSHOTS (KeptStoriesStore) after their 24h event expired, so no
    /// history page names their media. The list itself self-syncs; this sends the blobs, as one extra
    /// media-only page (no events) after the run's last page. Sealed via the personal `default`
    /// circle on the relay lane, which every device of the account holds.
    private func serveKeptStories(_ run: inout Serve, account: String, source: String) async -> Bool {
        let refs = HistoryHandoffWire.blobRefs(KeptStoriesStore.shared.kept.flatMap(\.media))
        let media: [HistoryHandoffWire.MediaItem] = refs.compactMap { ref in
            guard let url = MediaStore.shared.storagePath(for: ref),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return nil }
            return HistoryHandoffWire.MediaItem(ref: ref, size: size)
        }
        guard !media.isEmpty else { run.keptSent = true; return false }
        let cid = "default"
        let blob = HistoryHandoffWire.encodePage(circleId: cid, envelopes: [], media: media)
        guard await SelfSyncCoordinator.shared.accountLanePut(
                HistoryHandoffWire.pageKey(account, run.device, source, run.run, run.pages), blob) else { return false }
        var rm = Self.loadRunMedia(device: run.device, run: run.run)
        rm.pageMedia[String(run.pages)] = RunMedia.PageMedia(circle: cid, refs: media.map(\.ref))
        Self.saveRunMedia(rm, device: run.device, run: run.run)
        run.pages += 1
        run.keptSent = true
        serves[run.device] = run
        lastSendingAt = HistoryHandoffWire.nowMs()
        await putManifest(run, account: account, source: source)
        HavenLog.sync("history handoff: kept stories' media page for \(run.device.prefix(8)) (\(media.count) items)")
        return true
    }

    private func putManifest(_ run: Serve, account: String, source: String) async {
        let m = HistoryHandoffWire.Manifest(run: run.run, source: source, forRequest: run.requestAt, pages: run.pages,
                                            complete: run.complete, updatedAt: HistoryHandoffWire.nowMs(),
                                            totalEvents: run.totalEvents, servedEvents: run.servedEvents)
        if let body = try? JSONEncoder().encode(m) {
            _ = await SelfSyncCoordinator.shared.accountLanePut(HistoryHandoffWire.manifestKey(account, run.device, source), body)
        }
    }

    /// RELAY fallback, source side: upload the media of every page the target asked for, then mark
    /// the page ready. Resumable — what's already up is remembered per run.
    private func serveNeeds(_ run: Serve, account: String, source: String, until deadline: Date) async -> Bool {
        let keys = await SelfSyncCoordinator.shared.accountLaneList(HistoryHandoffWire.needPrefix(account, run.device, source, run.run))
        guard !keys.isEmpty else { return false }
        var rm = Self.loadRunMedia(device: run.device, run: run.run)
        needsPending = keys.contains { k in Int(k.split(separator: "/").last ?? "").map { !rm.relayed.contains($0) } ?? false }
        defer { needsPending = keys.contains { k in Int(k.split(separator: "/").last ?? "").map { !rm.relayed.contains($0) } ?? false } }
        var did = false
        let ordered = keys.sorted { (Int($0.split(separator: "/").last ?? "") ?? .max) < (Int($1.split(separator: "/").last ?? "") ?? .max) }
        for key in ordered {
            guard let n = Int(key.split(separator: "/").last ?? ""), !rm.relayed.contains(n) else { continue }
            // A withdrawn need (empty body): the target got this page's media directly after all.
            if let body = await SelfSyncCoordinator.shared.accountLaneGet(key), body.isEmpty {
                rm.relayed.append(n); Self.saveRunMedia(rm, device: run.device, run: run.run)
                continue
            }
            let pm = rm.pageMedia[String(n)]
            var ready: [HistoryHandoffWire.MediaReady.Ready] = []
            for ref in pm?.refs ?? [] {
                if let c = rm.uploaded[ref] { ready.append(.init(ref: ref, chunks: c)); continue }
                guard Date() < deadline else { Self.saveRunMedia(rm, device: run.device, run: run.run); return did }
                guard MediaStore.shared.hasLocalFile(ref) else { continue }   // evicted since — not ours to send
                guard let chunks = await uploadMedia(ref: ref, circle: pm!.circle, account: account,
                                                     target: run.device, source: source, run: run.run) else {
                    Self.saveRunMedia(rm, device: run.device, run: run.run)
                    return did   // no relay took it — resume on the next wake
                }
                rm.uploaded[ref] = chunks
                ready.append(.init(ref: ref, chunks: chunks))
                Self.saveRunMedia(rm, device: run.device, run: run.run)
                did = true
                noteSending()
                // Progressive: the target starts downloading while the rest of the page goes up.
                if let partial = try? JSONEncoder().encode(HistoryHandoffWire.MediaReady(items: ready, complete: false)) {
                    _ = await SelfSyncCoordinator.shared.accountLanePut(
                        HistoryHandoffWire.mediaReadyKey(account, run.device, source, run.run, n), partial)
                }
            }
            let body = (try? JSONEncoder().encode(HistoryHandoffWire.MediaReady(items: ready, complete: true))) ?? Data()
            guard await SelfSyncCoordinator.shared.accountLanePut(
                    HistoryHandoffWire.mediaReadyKey(account, run.device, source, run.run, n), body) else { break }
            rm.relayed.append(n)
            Self.saveRunMedia(rm, device: run.device, run: run.run)
            HavenLog.sync("history handoff: page \(n) media on the relay for \(run.device.prefix(8)) (\(ready.count) items)")
            did = true
        }
        return did
    }

    /// Seal one blob to a temp file and put it on the lane in fixed chunks — never the whole video in
    /// memory. Returns the chunk count, nil if any chunk failed.
    private func uploadMedia(ref: String, circle: String, account: String, target: String, source: String, run: String) async -> Int? {
        guard let sealed = await FeedStore.shared.sealMediaForHandoff(circleId: circle, ref: ref) else { return nil }
        defer { try? FileManager.default.removeItem(at: sealed) }
        guard let fh = try? FileHandle(forReadingFrom: sealed) else { return nil }
        defer { try? fh.close() }
        var index = 0
        while let chunk = try? fh.read(upToCount: HistoryHandoffWire.mediaChunkBytes), !chunk.isEmpty {
            guard await SelfSyncCoordinator.shared.accountLanePut(
                    HistoryHandoffWire.mediaChunkKey(account, target, source, run, ref, index), chunk) else { return nil }
            index += 1
        }
        return index > 0 ? index : nil
    }

    // MARK: - Driving it

    /// One bounded step of both roles. Safe to call often: each role is a no-op when idle.
    /// True if either role moved data.
    @discardableResult
    func tick(budget: TimeInterval) async -> Bool {
        // Both roles are real crypto per envelope; a hot phone waits (the work resumes where it was).
        guard !ThermalPolicy.isSeriousOrWorse else { return false }
        let deadline = Date().addingTimeInterval(budget)
        var moved = false
        if isWaiting { moved = await pull(until: deadline) }
        if Date() < deadline, await serve(until: deadline) { moved = true }
        return moved
    }

    /// Forget everything (identity switch / factory reset): a run belongs to one account.
    func reset() {
        want = nil
        receivedBanner = false
        UserDefaults.standard.removeObject(forKey: Self.serveKey)
        refreshStatus()
    }
}
