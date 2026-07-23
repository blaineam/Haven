import Foundation
import MultipeerConnectivity

/// Nearby offline transport over MultipeerConnectivity — spans Bluetooth + peer-to-peer
/// Wi-Fi with no internet or router, and forms a small mesh. It carries the exact same
/// sealed protocol frames ([type][payload]) as the iroh path, so two phones in the same
/// room sync even fully offline. The bytes are already E2E-encrypted by the core; the
/// Multipeer link adds its own transport encryption on top.
///
/// ## Heat / flood policy
///
/// Field log (Mac↔iPhone): continuous Multipeer at ~kpkt/s cooked the phone. Two rules:
///
/// 1. **Discovery only when needed** — advertise/browse for a short window at start or
///    `nudgeDiscovery()`, then park if nobody connects. Session stays up while peers exist.
/// 2. **Send rate limit** — token bucket on outbound frames (moderate sustained rate). Control
///    frames (hello, roster, small signals) get priority; media/history bulk shares the bucket
///    and is paced so neither side can flood the link.
///
/// ## Bonjour cancel crash
///
/// Field (Haven + HavenStub): `EXC_BREAKPOINT` in `_CFAssertMismatchedTypeID` →
/// `CFRunLoopSourceInvalidate` → `_BrowserCancel(__CFNetServiceBrowser*)` when Multipeer
/// discovery is stop/start thrash'd. CFNetwork's browser cancel is async on the main run
/// loop; double-stop, stop-while-start, or reusing a half-cancelled browser traps. We:
/// - track explicit start flags (never double-stop),
/// - settle ≥1s between stop and start,
/// - nil delegates + **retire** the old browser/advertiser (keep alive until cancel finishes)
///   and build fresh ones for the next start.
final class NearbyTransport: NSObject {
    private let serviceType = "haven-circle"   // 1–15 chars, lowercase + hyphens
    private let peerID: MCPeerID
    private let session: MCSession
    /// Rebuilt after every stop — never reuse a Multipeer discovery object mid-cancel.
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser

    private let onInbound: (Data) -> Void
    private let onPeerConnected: () -> Void
    /// All MCSession reads/writes happen here, never on the main thread.
    private let sendQueue = DispatchQueue(label: "haven.nearby.send", qos: .utility)

    // MARK: - Rate limit (token bucket)

    /// Sustained outbound budget. Field heat needed a ceiling, but media chunks are 32 KB sealed
    /// (~34–40 KB frames): at 64 KB/s a multi‑MB video finished the 192 KB burst then **hard-aborted**
    /// (one 50 ms retry could never refill a full chunk). Photos fit the burst; videos did not.
    /// ~256 KB/s keeps Multipeer well below the kpkt/s flood while finishing videos in reasonable time.
    private static let bytesPerSecond: Double = 256 * 1024
    private static let burstBytes: Double = 512 * 1024
    /// Cap control-ish frames so a hello storm still can't fill the queue.
    private static let maxFramesPerSecond: Double = 24
    private static let burstFrames: Double = 48

    private let rateLock = NSLock()
    private var byteTokens: Double = NearbyTransport.burstBytes
    private var frameTokens: Double = NearbyTransport.burstFrames
    private var lastRefill = Date()
    private var droppedBulk = 0

    /// True while advertise and/or browse are running.
    private(set) var isDiscovering = false
    private var parkWorkItem: DispatchWorkItem?
    /// Pending delayed start — Multipeer/Bonjour must not restart mid-cancel.
    private var restartWorkItem: DispatchWorkItem?
    /// Explicit flags: double `stopBrowsingForPeers` races CFNetwork `_BrowserCancel`.
    private var isAdvertising = false
    private var isBrowsing = false
    /// Wall-clock of last browse/advertise stop — restarts wait so `_BrowserCancel` can finish.
    private var lastDiscoveryStopAt: Date = .distantPast
    /// Minimum gap after stop before start again (Bonjour cancel is async on the run loop).
    /// 0.75s was still too short under macOS 27 + Multipeer advertiser concurrent publish.
    private static let discoveryRestartSettle: TimeInterval = 1.5
    // MARK: - Static retire pool (main-confined)
    //
    // Stopped/failed browser/advertiser objects must stay alive until CFNetwork's async
    // `_BrowserCancel` runloop source finishes — freeing one in the same runloop turn as its
    // cancel is the `_CFAssertMismatchedTypeID` EXC_BREAKPOINT. The pool used to live on the
    // INSTANCE, so deinit (reconfigure / seedless enroll / bringOnline re-entry tearing the
    // transport down) dropped the retiring objects along with the instance — exactly the
    // same-turn free the pool exists to prevent. Process-wide + main-confined instead: it
    // outlives every instance and purges ≥3s after the LAST retire.
    nonisolated(unsafe) private static var retiredPool: [AnyObject] = []
    nonisolated(unsafe) private static var retiredPurgeWork: DispatchWorkItem?
    /// Park objects in the static pool (hops to main if needed — deinit runs anywhere).
    static func retireToPool(_ objects: [AnyObject]) {
        guard !objects.isEmpty else { return }
        let park = {
            retiredPool.append(contentsOf: objects)
            retiredPurgeWork?.cancel()
            let work = DispatchWorkItem { retiredPool.removeAll(); retiredPurgeWork = nil }
            retiredPurgeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
        if Thread.isMainThread { park() } else { DispatchQueue.main.async(execute: park) }
    }

    /// `displayName` should be our node id hex (truncated to Multipeer's 63-byte limit).
    init(displayName: String, onInbound: @escaping (Data) -> Void, onPeerConnected: @escaping () -> Void) {
        self.onInbound = onInbound
        self.onPeerConnected = onPeerConnected
        let name = String(displayName.prefix(60))
        peerID = MCPeerID(displayName: name.isEmpty ? "haven" : name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    deinit {
        // Best-effort: tear down without hopping threads (deinit is non-isolated).
        advertiser.delegate = nil
        browser.delegate = nil
        session.delegate = nil
        if isAdvertising { advertiser.stopAdvertisingPeer() }
        if isBrowsing { browser.stopBrowsingForPeers() }
        session.disconnect()
        // Push the freshly-cancelled objects into the STATIC pool so they outlive this instance —
        // never free a browser in the same runloop turn as its cancel (the Bonjour cancel crash).
        NearbyTransport.retireToPool([advertiser, browser])
    }

    private let peersLock = NSLock()
    private var peersSnapshot: [MCPeerID] = []
    private var cachedPeers: [MCPeerID] {
        peersLock.lock(); defer { peersLock.unlock() }
        return peersSnapshot
    }

    var hasConnectedPeers: Bool { !cachedPeers.isEmpty }

    /// Start discovery (advertise + browse). Parks after `parkAfter` if still alone.
    func start(parkAfter: TimeInterval = 60) {
        // Multipeer advertiser/browser expect main-thread lifecycle; hop if called off-main.
        if Thread.isMainThread {
            startDiscovery(parkAfter: parkAfter)
        } else {
            DispatchQueue.main.async { [weak self] in self?.startDiscovery(parkAfter: parkAfter) }
        }
    }

    /// Re-open discovery briefly (force-sync, Storage, multi-device UI).
    func nudgeDiscovery(parkAfter: TimeInterval = 45) {
        if Thread.isMainThread {
            startDiscovery(parkAfter: parkAfter)
        } else {
            DispatchQueue.main.async { [weak self] in self?.startDiscovery(parkAfter: parkAfter) }
        }
    }

    private func startDiscovery(parkAfter: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        parkWorkItem?.cancel()
        restartWorkItem?.cancel()
        restartWorkItem = nil

        // Already have a live peer — discovery not needed; park without thrashing stop/start.
        if !cachedPeers.isEmpty {
            stopDiscoveryIfNeeded()
            isDiscovering = false
            return
        }

        // Already advertising+browsing: only refresh the park timer (no re-start of Bonjour).
        if isAdvertising && isBrowsing {
            isDiscovering = true
            schedulePark(after: parkAfter)
            return
        }

        // After a recent stop, wait for CFNetwork's async `_BrowserCancel` to finish.
        let sinceStop = Date().timeIntervalSince(lastDiscoveryStopAt)
        let settle = Self.discoveryRestartSettle
        if sinceStop < settle, lastDiscoveryStopAt != .distantPast {
            let delay = settle - sinceStop
            let work = DispatchWorkItem { [weak self] in
                self?.startDiscovery(parkAfter: parkAfter)
            }
            restartWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }

        beginDiscoveryNow(parkAfter: parkAfter)
    }

    private func beginDiscoveryNow(parkAfter: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard cachedPeers.isEmpty else {
            stopDiscoveryIfNeeded()
            isDiscovering = false
            return
        }
        // Partial state (e.g. only advertising): stop cleanly and wait a settle, never start
        // browse while advertiser is mid-flight or vice versa — that races CFNetService.
        if isAdvertising != isBrowsing {
            stopDiscoveryIfNeeded()
            let work = DispatchWorkItem { [weak self] in
                self?.startDiscovery(parkAfter: parkAfter)
            }
            restartWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.discoveryRestartSettle, execute: work)
            return
        }
        if !isAdvertising {
            advertiser.startAdvertisingPeer()
            isAdvertising = true
        }
        if !isBrowsing {
            browser.startBrowsingForPeers()
            isBrowsing = true
        }
        isDiscovering = true
        schedulePark(after: parkAfter)
    }

    private func schedulePark(after parkAfter: TimeInterval) {
        parkWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.cachedPeers.isEmpty {
                self.parkDiscovery()
            }
        }
        parkWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + parkAfter, execute: work)
    }

    /// Stop advertise/browse but keep any live session (no disconnect).
    func parkDiscovery() {
        if Thread.isMainThread {
            parkDiscoveryOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in self?.parkDiscoveryOnMain() }
        }
    }

    private func parkDiscoveryOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        parkWorkItem?.cancel()
        parkWorkItem = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        stopDiscoveryIfNeeded()
        isDiscovering = false
    }

    /// Call only on main. Idempotent — never double-stop Multipeer discovery.
    private func stopDiscoveryIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        var didStop = false
        if isAdvertising {
            // Detach before stop so late Bonjour callbacks don't re-enter us mid-cancel.
            advertiser.delegate = nil
            advertiser.stopAdvertisingPeer()
            Self.retireToPool([advertiser])
            isAdvertising = false
            didStop = true
        }
        if isBrowsing {
            browser.delegate = nil
            browser.stopBrowsingForPeers()
            Self.retireToPool([browser])
            isBrowsing = false
            didStop = true
        }
        if didStop {
            lastDiscoveryStopAt = Date()
            // Fresh objects for the next start — never call startBrowsing on a browser that
            // still has a `_BrowserCancel` source pending (the EXC_BREAKPOINT path).
            rebuildDiscoveryObjects()
        }
    }

    private func rebuildDiscoveryObjects() {
        dispatchPrecondition(condition: .onQueue(.main))
        let adv = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        let br = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        adv.delegate = self
        br.delegate = self
        advertiser = adv
        browser = br
    }

    func stop() {
        if Thread.isMainThread {
            stopOnMain()
        } else {
            // Never main.sync from an arbitrary queue (deadlock risk if main waits on us).
            DispatchQueue.main.async { [weak self] in self?.stopOnMain() }
        }
    }

    private func stopOnMain() {
        dispatchPrecondition(condition: .onQueue(.main))
        parkDiscoveryOnMain()
        session.disconnect()
        peersLock.lock(); peersSnapshot = []; peersLock.unlock()
    }

    private let backlogLock = NSLock()
    private var backlogBytes = 0
    static let sendBacklogCap = 2 * 1024 * 1024   // 2 MB unsent — tighter than old 4 MB flood
    var sendBacklogHigh: Bool {
        backlogLock.lock(); defer { backlogLock.unlock() }
        return backlogBytes > Self.sendBacklogCap
    }

    /// Control frame = small, high-value (hello, announce, signal). Bulk = history/media.
    enum SendClass {
        case control   // ≤ 2 KB — always try to send (still framed/sec limited lightly)
        case bulk      // history + media — full token bucket
    }

    /// Send a frame to every connected nearby peer. Returns false if dropped by rate limit / backlog.
    @discardableResult
    func broadcast(_ frame: Data, class sendClass: SendClass = .bulk) -> Bool {
        backlogLock.lock(); let backlog = backlogBytes; backlogLock.unlock()
        if frame.count > 8192 && backlog > Self.sendBacklogCap { return false }

        let cost = Double(frame.count)
        rateLock.lock()
        refillTokensLocked()
        let needFrames = sendClass == .control ? 0.25 : 1.0
        let needBytes = sendClass == .control ? min(cost, 2048) : cost
        if frameTokens < needFrames || byteTokens < needBytes {
            if sendClass == .bulk {
                droppedBulk += 1
                if droppedBulk % 50 == 1 {
                    NSLog("haven nearby: rate-limit drop bulk size=%d (dropped≈%d)", frame.count, droppedBulk)
                }
            }
            rateLock.unlock()
            if sendClass == .control {
                enqueuePaced(frame, waitMs: 40)
                return true
            }
            return false
        }
        frameTokens -= needFrames
        byteTokens -= needBytes
        rateLock.unlock()

        enqueuePaced(frame, waitMs: sendClass == .bulk && frame.count > 4096 ? 12 : 0)
        return true
    }

    /// Send bulk/media frames **waiting** for rate tokens instead of aborting the stream.
    @discardableResult
    func broadcastWaiting(_ frame: Data, class sendClass: SendClass = .bulk, maxWaitMs: Int = 8_000) -> Bool {
        let deadline = Date().addingTimeInterval(Double(maxWaitMs) / 1_000.0)
        var attempt = 0
        while Date() < deadline {
            if broadcast(frame, class: sendClass) { return true }
            attempt += 1
            let need = max(Double(frame.count), 1024)
            let sec = min(0.35, max(0.04, need / Self.bytesPerSecond))
            Thread.sleep(forTimeInterval: sec)
            if sendBacklogHigh {
                Thread.sleep(forTimeInterval: 0.15)
            }
            if attempt == 1 || attempt % 20 == 0 {
                NSLog("haven nearby: waiting for rate tokens size=%d attempt=%d", frame.count, attempt)
            }
        }
        return false
    }

    private func refillTokensLocked() {
        let now = Date()
        let dt = now.timeIntervalSince(lastRefill)
        lastRefill = now
        if dt > 0 {
            byteTokens = min(Self.burstBytes, byteTokens + dt * Self.bytesPerSecond)
            frameTokens = min(Self.burstFrames, frameTokens + dt * Self.maxFramesPerSecond)
        }
    }

    private func enqueuePaced(_ frame: Data, waitMs: Int) {
        backlogLock.lock(); backlogBytes += frame.count; backlogLock.unlock()
        sendQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.backlogLock.lock()
                self.backlogBytes -= frame.count
                self.backlogLock.unlock()
            }
            if waitMs > 0 {
                Thread.sleep(forTimeInterval: Double(waitMs) / 1000.0)
            }
            let peers = self.cachedPeers
            guard !peers.isEmpty else { return }
            try? self.session.send(frame, toPeers: peers, with: .reliable)
        }
    }
}

extension NearbyTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peers = session.connectedPeers
        peersLock.lock(); peersSnapshot = peers; peersLock.unlock()
        if state == .connected {
            onPeerConnected()
            // Discovery not needed while connected — session carries traffic.
            DispatchQueue.main.async { [weak self] in
                self?.parkDiscoveryOnMain()
            }
        } else if peers.isEmpty {
            // Peer left / Multipeer flap: debounced rediscovery (settle delay inside startDiscovery).
            DispatchQueue.main.async { [weak self] in
                self?.startDiscovery(parkAfter: 45)
            }
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onInbound(data)
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension NearbyTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        // Mark inactive so a later start rebuilds rather than double-starting a dead advertiser.
        // The failed object goes into the STATIC retire pool (CFNetwork may still be cancelling
        // its half-published service) and a fresh one takes its place; stamping the stop time
        // makes the next start wait out the settle window like any other stop.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            advertiser.delegate = nil
            NearbyTransport.retireToPool([advertiser])
            self.lastDiscoveryStopAt = Date()
            if advertiser === self.advertiser {
                self.isAdvertising = false
                self.isDiscovering = self.isBrowsing
                let adv = MCNearbyServiceAdvertiser(peer: self.peerID, discoveryInfo: nil, serviceType: self.serviceType)
                adv.delegate = self
                self.advertiser = adv
            }
        }
    }
}

extension NearbyTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        if self.peerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        // Same treatment as the advertiser above: retire the failed browser into the static pool,
        // stamp the stop time, and build a fresh replacement for the next start.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            browser.delegate = nil
            NearbyTransport.retireToPool([browser])
            self.lastDiscoveryStopAt = Date()
            if browser === self.browser {
                self.isBrowsing = false
                self.isDiscovering = self.isAdvertising
                let br = MCNearbyServiceBrowser(peer: self.peerID, serviceType: self.serviceType)
                br.delegate = self
                self.browser = br
            }
        }
    }
}
