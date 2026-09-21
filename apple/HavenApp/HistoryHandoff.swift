import Foundation

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
@MainActor
final class HistoryHandoff {
    static let shared = HistoryHandoff()

    /// "Look at the account lane now" — a nudge to my own devices, no payload semantics.
    static let nudgeFrame: UInt8 = 36
    /// Events per page. One page is one engine pass of real crypto (a signature per event), so it
    /// stays well under a second on a phone and doesn't park the UI behind the engine mutex.
    static let pageEvents: UInt32 = 120

    private init() {}

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
        var lastNudgeAt: UInt64 = 0
        /// Consecutive attempts at a page whose circle isn't on this device yet.
        var heldAttempts = 0
    }
    private static let wantKey = "haven.historyHandoff.want.v1"
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
        Task { await announce(force: true) }
    }

    /// Publish (or re-publish) the request and nudge my devices. Throttled: a device that is asleep
    /// sees the relay copy on its own next wake anyway.
    private func announce(force: Bool = false) async {
        guard var w = want else { return }
        let now = HistoryHandoffWire.nowMs()
        guard force || now - w.lastNudgeAt > 10 * 60 * 1000 else { return }
        let me = DeviceKeyStore.deviceNodeHex()
        let req = HistoryHandoffWire.Request(device: me, at: w.at)
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
            w.run = m.run; w.source = m.source; w.nextPage = 0; w.heldAttempts = 0
        }
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
            w.nextPage += 1
            w.heldAttempts = 0
            want = w
            progressed = true
        }
        if m.complete && w.nextPage >= m.pages {
            HavenLog.sync("history handoff: complete — \(w.received) envelopes over \(m.pages) pages")
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
    }
    private static let serveKey = "haven.historyHandoff.serve.v1"
    private var serves: [String: Serve] {
        get {
            guard let d = UserDefaults.standard.data(forKey: Self.serveKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Serve].self, from: d)) ?? [:]
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: Self.serveKey) }
        }
    }

    /// Unfinished work on either side — worth a background wake.
    var hasOutstandingWork: Bool { isWaiting || serves.values.contains { !$0.complete } }

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
        for key in await SelfSyncCoordinator.shared.accountLaneList(HistoryHandoffWire.requestPrefix(acct)) {
            let device = String(key.split(separator: "/").last ?? "").lowercased()
            guard device.count == 64, device != me,
                  let raw = await SelfSyncCoordinator.shared.accountLaneGet(key),
                  let req = try? JSONDecoder().decode(HistoryHandoffWire.Request.self, from: raw), req.done != true else { continue }
            var s = serves[device]
            if s == nil || s!.requestAt != req.at {
                // Another of my devices already answering this ask? Let it finish (unless it went quiet).
                if await anotherSourceIsServing(account: acct, target: device, request: req.at, me: me) { continue }
                // A new ask (or a re-ask after a finished run): start a fresh run, newest circles first.
                s = Serve(device: device, requestAt: req.at, run: String(HistoryHandoffWire.nowMs()),
                          order: FeedStore.shared.circles.map(\.id))
                HavenLog.sync("history handoff: serving \(device.prefix(8)) — \(s!.order.count) circles")
            }
            guard var run = s, !run.complete else { continue }
            if await serveRun(&run, account: acct, source: me, until: deadline) { did = true }
            serves[device] = run
            if Date() >= deadline { break }
        }
        return did
    }
    private var serving = false

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
                let blob = HistoryHandoffWire.encodePage(circleId: cid, envelopes: page.envelopes)
                guard await SelfSyncCoordinator.shared.accountLanePut(
                    HistoryHandoffWire.pageKey(account, run.device, source, run.run, run.pages), blob) else {
                    return did   // no relay took it — resume from this cursor on the next wake
                }
                run.pages += 1
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

    private func putManifest(_ run: Serve, account: String, source: String) async {
        let m = HistoryHandoffWire.Manifest(run: run.run, source: source, forRequest: run.requestAt, pages: run.pages,
                                            complete: run.complete, updatedAt: HistoryHandoffWire.nowMs())
        if let body = try? JSONEncoder().encode(m) {
            _ = await SelfSyncCoordinator.shared.accountLanePut(HistoryHandoffWire.manifestKey(account, run.device, source), body)
        }
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
        UserDefaults.standard.removeObject(forKey: Self.serveKey)
    }
}
