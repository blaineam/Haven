import Foundation

/// Per-item media keys, sending side (docs/DECISIONS.md D27; core `mediakeys.rs` is the same job on
/// the desktop, and the browser's receiving side).
///
/// A linked browser never holds the account key, and the circle keys that open older media are
/// deleted everywhere after a few rotations. This device holds the account key, so it can unwrap
/// one blob's own content key from the blob's last few kilobytes. It does that once for every blob
/// the account's posts name, newest first, and sends the keys signed by the account and sealed to
/// that browser alone. Nothing is uploaded again; the browser then loads from the relay as the
/// reader scrolls. Anything posted after the link is sealed to the browser's own key and needs
/// none of this.
@MainActor
final class MediaKeysSender {
    static let shared = MediaKeysSender()

    private struct Job: Codable {
        var device: String
        var requestAt: UInt64
        var run: String
        /// Not looked up yet, in reverse: the next one is at the end.
        var left: [Item]
        /// Set aside because something that may hold them did not answer, longest-waiting retry
        /// first. Optional, as is `touched`: jobs saved by an earlier build have neither.
        var later: [Item]?
        /// The last pass that saw this job's request still open.
        var touched: UInt64?
        var total: Int
        var missing = 0
        var batches = 0
        var complete = false
        struct Item: Codable {
            var circle: String
            var ref: String
            /// When it was first set aside.
            var since: UInt64?
        }

        var waiting: Int { left.count + (later?.count ?? 0) }
    }

    private static let abandonedMs: UInt64 = 3 * 24 * 3_600_000
    /// A blob nobody could be asked about for this long is counted as having no key.
    static let giveUpAfterMs: UInt64 = 3 * 24 * 3_600_000
    /// A batch still looking after this long sends what it has: the rest stay for the next one.
    private static let batchBudget: TimeInterval = 45
    /// Batches worked through per pass, and blobs looked up at once within one.
    private static let batchesPerPass = 5
    private static let parallel = 4

    private var serving = false
    /// Requests the person stopped here ("device|at"): never served again.
    private var declined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "haven.mediaKeys.declined.v1") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "haven.mediaKeys.declined.v1") }
    }

    /// A file, not UserDefaults: a large library's list of refs is hundreds of kilobytes.
    private static var jobsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("haven-handoff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("media-keys.json")
    }
    private lazy var jobs: [String: Job] = (try? Data(contentsOf: Self.jobsURL))
        .flatMap { try? JSONDecoder().decode([String: Job].self, from: $0) } ?? [:]
    private func save() {
        if jobs.isEmpty {
            try? FileManager.default.removeItem(at: Self.jobsURL)
        } else if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: Self.jobsURL, options: .atomic)
        }
    }

    /// Any job not yet marked done by the device that asked.
    var hasJobs: Bool { jobs.values.contains { !$0.complete } }

    /// How far the unfinished job is, for the transfer banner.
    var progress: (done: Int, total: Int)? {
        jobs.values.first { !$0.complete }.map { ($0.total - $0.waiting, $0.total) }
    }

    /// "Cancel transfer": stop, and don't take these requests up again.
    func cancel() {
        var stopped = declined
        for job in jobs.values where !job.complete { stopped.insert("\(job.device)|\(job.requestAt)") }
        declined = stopped
        jobs.removeAll()
        save()
    }

    /// Identity switch / factory reset: a job belongs to one account.
    func reset() {
        jobs.removeAll()
        save()
        declined = []
    }

    /// Answer open requests from my other devices until `deadline`. True if anything was sent.
    @discardableResult
    func serve(until deadline: Date) async -> Bool {
        // Only a device holding the account key can: it opens a recipient entry and signs a batch.
        guard !serving, !ThermalPolicy.suspendHeavyIO, AccountStore.storedSeed() != nil else { return false }
        let acct = AccountStore.currentNodeHex()
        guard !acct.isEmpty, SelfSyncCoordinator.shared.hasAccountLane,
              FeedStore.shared.engineReady, !FeedStore.shared.circles.isEmpty else { return false }
        serving = true
        defer { serving = false }
        let me = DeviceKeyStore.deviceNodeHex().lowercased()
        var did = false
        for key in await SelfSyncCoordinator.shared.accountLaneList(HistoryHandoffWire.keysRequestPrefix(acct)) {
            guard Date() < deadline else { break }
            let device = String(key.split(separator: "/").last ?? "").lowercased()
            guard device.count == 64, device != me,
                  let raw = await SelfSyncCoordinator.shared.accountLaneGet(key),
                  let req = try? JSONDecoder().decode(HistoryHandoffWire.KeysRequest.self, from: raw) else { continue }
            if req.done == true {
                if jobs[device] != nil { jobs[device] = nil; save() }
                continue
            }
            if declined.contains("\(device)|\(req.at)") { continue }
            var job = jobs[device]
            if job == nil || job!.requestAt != req.at {
                if await anotherSourceSends(account: acct, target: device, request: req.at, me: me) { continue }
                let refs = await FeedStore.shared.historyMediaRefs()
                var items = refs.map { Job.Item(circle: $0.circleId, ref: $0.reference) }
                // Kept stories outlive their 24-hour post, so no post names their media any more.
                let named = Set(items.map(\.ref))
                items += HistoryHandoffWire.blobRefs(KeptStoriesStore.shared.kept.flatMap(\.media))
                    .filter { !named.contains($0) }
                    .map { Job.Item(circle: "default", ref: $0) }
                job = Job(device: device, requestAt: req.at, run: String(HistoryHandoffWire.nowMs()),
                          left: items.reversed(), total: items.count)
                jobs[device] = job
                save()
                HavenLog.sync("media keys: \(device.prefix(8)) asked — \(items.count) blobs")
            }
            guard var current = job else { continue }
            current.touched = HistoryHandoffWire.nowMs()
            jobs[device] = current
            save()
            if current.complete { continue }
            if await run(current, account: acct, source: me, until: deadline) { did = true }
        }
        dropAbandoned()
        return did
    }

    /// Jobs whose request no pass has seen for days: the asking device is gone. A job still being
    /// asked for is kept however old it is, so it is never worked through a second time.
    private func dropAbandoned() {
        let cutoff = HistoryHandoffWire.nowMs() &- Self.abandonedMs
        let abandoned = jobs.filter { ($0.value.touched ?? UInt64($0.value.run) ?? 0) < cutoff }.map(\.key)
        if !abandoned.isEmpty {
            for device in abandoned { jobs[device] = nil }
            save()
        }
    }

    private func anotherSourceSends(account: String, target: String, request: UInt64, me: String) async -> Bool {
        let now = HistoryHandoffWire.nowMs()
        for key in await SelfSyncCoordinator.shared.accountLaneList(HistoryHandoffWire.keysManifestPrefix(account, target)) {
            guard let raw = await SelfSyncCoordinator.shared.accountLaneGet(key),
                  let m = try? JSONDecoder().decode(HistoryHandoffWire.KeysManifest.self, from: raw),
                  m.source.lowercased() != me, m.forRequest >= request else { continue }
            if m.isLive(now: now) { return true }
        }
        return false
    }

    /// Still this job: not cancelled or reset while a lookup was waiting on the network.
    private func isCurrent(_ job: Job) -> Bool {
        jobs[job.device]?.run == job.run
    }

    private func run(_ start: Job, account: String, source: String, until deadline: Date) async -> Bool {
        var job = start
        var did = false
        for _ in 0..<Self.batchesPerPass where job.waiting > 0 && Date() < deadline {
            // New blobs first; the ones set aside once every other has had its turn.
            let retrying = job.left.isEmpty
            let batch = retrying
                ? Array((job.later ?? []).prefix(HistoryHandoffWire.keyBatch))
                : Array(job.left.suffix(HistoryHandoffWire.keyBatch).reversed())
            var entries: [Data] = []
            var setAside: [Job.Item] = []
            var missing = 0
            var looked = 0
            let started = Date()
            while looked < batch.count, looked == 0 || Date().timeIntervalSince(started) < Self.batchBudget {
                let group = batch[looked..<min(looked + Self.parallel, batch.count)]
                let tasks = group.map { item in
                    Task { @MainActor in
                        await SharedStore.findItemKey(ref: item.ref, circleId: item.circle) {
                            await FeedStore.shared.itemKey(fromTail: $0)
                        }
                    }
                }
                for (var item, task) in zip(group, tasks) {
                    switch await task.value {
                    case .found(let entry): entries.append(entry)
                    case .missing: missing += 1
                    case .unreachable:
                        let now = HistoryHandoffWire.nowMs()
                        let since = item.since ?? now
                        if now >= since, now - since >= Self.giveUpAfterMs {
                            missing += 1
                        } else {
                            item.since = since
                            setAside.append(item)
                        }
                    }
                }
                looked += group.count
                guard isCurrent(job) else { return did }
            }
            if !entries.isEmpty {
                guard let grant = await FeedStore.shared.sealItemKeys(device: job.device, entries: entries) else {
                    HavenLog.sync("media keys: could not seal a batch to \(job.device.prefix(8))")
                    return did
                }
                guard await SelfSyncCoordinator.shared.accountLanePut(
                    HistoryHandoffWire.keysBatchKey(account, job.device, source, job.run, job.batches), grant) else { return did }
                job.batches += 1
            }
            guard isCurrent(job) else { return did }
            if retrying {
                job.later?.removeFirst(looked)
            } else {
                job.left.removeLast(looked)
            }
            job.later = (job.later ?? []) + setAside
            job.missing += missing
            jobs[job.device] = job
            save()
            await putManifest(job, account: account, source: source)
            // Only a blob settled for good is progress. Asking again about the ones set aside is
            // not: counted as such, it would hold the screen for as long as a relay stayed away.
            guard setAside.count < looked else { break }
            did = true
            HistoryHandoff.shared.noteSendingKeys()
        }
        if job.waiting == 0, !job.complete, isCurrent(job) {
            job.complete = true
            jobs[job.device] = job
            save()
            await putManifest(job, account: account, source: source)
            HavenLog.sync("media keys: sent to \(job.device.prefix(8)) — \(job.total) blobs, \(job.missing) without a key")
            did = true
        }
        return did
    }

    private func putManifest(_ job: Job, account: String, source: String) async {
        let m = HistoryHandoffWire.KeysManifest(
            run: job.run, source: source, forRequest: job.requestAt, batches: job.batches, complete: job.complete,
            updatedAt: HistoryHandoffWire.nowMs(), total: job.total, done: job.total - job.waiting,
            missing: job.missing)
        if let body = try? JSONEncoder().encode(m) {
            _ = await SelfSyncCoordinator.shared.accountLanePut(
                HistoryHandoffWire.keysManifestKey(account, job.device, source), body)
        }
    }
}
