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
final class NearbyTransport: NSObject {
    private let serviceType = "haven-circle"   // 1–15 chars, lowercase + hyphens
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let onInbound: (Data) -> Void
    private let onPeerConnected: () -> Void
    /// All MCSession reads/writes happen here, never on the main thread.
    private let sendQueue = DispatchQueue(label: "haven.nearby.send", qos: .utility)

    // MARK: - Rate limit (token bucket)

    /// Sustained outbound budget — enough for hello/catch-up, far below field flood rates.
    /// ~64 KB/s sustained, burst 192 KB. Media chunks (32 KB) ≈ 2/s peak.
    private static let bytesPerSecond: Double = 64 * 1024
    private static let burstBytes: Double = 192 * 1024
    /// Cap control-ish frames so a hello storm still can't fill the queue.
    private static let maxFramesPerSecond: Double = 12
    private static let burstFrames: Double = 24

    private let rateLock = NSLock()
    private var byteTokens: Double = NearbyTransport.burstBytes
    private var frameTokens: Double = NearbyTransport.burstFrames
    private var lastRefill = Date()
    private var droppedBulk = 0

    /// True while advertise and/or browse are running.
    private(set) var isDiscovering = false
    private var parkWorkItem: DispatchWorkItem?

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

    private let peersLock = NSLock()
    private var peersSnapshot: [MCPeerID] = []
    private var cachedPeers: [MCPeerID] {
        peersLock.lock(); defer { peersLock.unlock() }
        return peersSnapshot
    }

    var hasConnectedPeers: Bool { !cachedPeers.isEmpty }

    /// Start discovery (advertise + browse). Parks after `parkAfter` if still alone.
    func start(parkAfter: TimeInterval = 60) {
        startDiscovery(parkAfter: parkAfter)
    }

    /// Re-open discovery briefly (force-sync, Storage, multi-device UI).
    func nudgeDiscovery(parkAfter: TimeInterval = 45) {
        startDiscovery(parkAfter: parkAfter)
    }

    private func startDiscovery(parkAfter: TimeInterval) {
        parkWorkItem?.cancel()
        advertiser.startAdvertisingPeer()
        if cachedPeers.isEmpty {
            browser.startBrowsingForPeers()
        }
        isDiscovering = true
        // While connected we only need the session — stop discovery once a peer is up.
        if !cachedPeers.isEmpty {
            browser.stopBrowsingForPeers()
            advertiser.stopAdvertisingPeer()
            isDiscovering = false
            return
        }
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
        parkWorkItem?.cancel()
        parkWorkItem = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        isDiscovering = false
    }

    func stop() {
        parkDiscovery()
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
                    // Occasional log without spam
                    NSLog("haven nearby: rate-limit drop bulk size=%d (dropped≈%d)", frame.count, droppedBulk)
                }
            }
            rateLock.unlock()
            // Control frames: wait briefly on the send queue instead of hard-dropping.
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
                self?.parkDiscovery()
            }
        } else if peers.isEmpty {
            // Peer left: short rediscovery window so devices can find each other again.
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
}

extension NearbyTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        if self.peerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
