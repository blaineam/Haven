import Foundation
import MultipeerConnectivity

/// Nearby offline transport over MultipeerConnectivity — spans Bluetooth + peer-to-peer
/// Wi-Fi with no internet or router, and forms a small mesh. It carries the exact same
/// sealed protocol frames ([type][payload]) as the iroh path, so two phones in the same
/// room sync even fully offline. The bytes are already E2E-encrypted by the core; the
/// Multipeer link adds its own transport encryption on top.
final class NearbyTransport: NSObject {
    private let serviceType = "haven-circle"   // 1–15 chars, lowercase + hyphens 
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let onInbound: (Data) -> Void
    private let onPeerConnected: () -> Void
    /// All MCSession reads/writes happen here, never on the main thread. `connectedPeers` and
    /// `send(_:toPeers:)` both dispatch into MultipeerConnectivity's own serial queue; calling them
    /// from `@MainActor` (as every `nearbyBroadcast` caller does) means a backed-up send queue — e.g.
    /// posting a big batch of media, one frame per chunk — blocks the main thread until the 0x8BADF00D
    /// watchdog kills the app. Serializing here keeps frame order while freeing the main thread.
    private let sendQueue = DispatchQueue(label: "haven.nearby.send", qos: .utility)

    /// `displayName` should be our node id hex (truncated to Multipeer's 63-byte limit);
    /// it's only used to deduplicate who-invites-whom. Identity is still proven by the
    /// Hello bundle + verification-hash handshake at the protocol layer.
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

    /// Peer list CACHED from the delegate. Reading `session.connectedPeers` synchronously
    /// dispatch_syncs into MultipeerConnectivity's internal queue — and while the session's recv
    /// thread is mid-transfer (media chunks streaming) that call DEADLOCKS the caller against MC's
    /// internal rwlock. Observed live: the sync-status badge (a TimelineView — re-evaluated on a
    /// schedule) read it from the MAIN thread and wedged the app permanently: frozen video frame,
    /// dead touches, "swiping on a tall video post won't scroll the feed". The delegate callback is
    /// the sanctioned place to learn peer state; everything else reads this snapshot.
    private let peersLock = NSLock()
    private var peersSnapshot: [MCPeerID] = []
    private var cachedPeers: [MCPeerID] {
        peersLock.lock(); defer { peersLock.unlock() }
        return peersSnapshot
    }

    /// Whether any nearby peer is currently connected (used to tell the user whether a device-link
    /// request actually has a path to the other device). Lock-guarded cache — NEVER touches MCSession.
    var hasConnectedPeers: Bool { !cachedPeers.isEmpty }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        #if os(iOS)
        // iPhone heat: Multipeer discovery is expensive (BLE + peer Wi‑Fi). After a short window,
        // if nobody is connected, pause BOTH advertise and browse until something reconnects or
        // the app calls `nudgeDiscovery()`. Always-on discovery was a top field heat source.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self else { return }
            if self.cachedPeers.isEmpty {
                self.advertiser.stopAdvertisingPeer()
                self.browser.stopBrowsingForPeers()
            }
        }
        #endif
    }

    /// Re-open nearby discovery briefly (e.g. after user activity / open Storage).
    func nudgeDiscovery() {
        advertiser.startAdvertisingPeer()
        if cachedPeers.isEmpty {
            browser.startBrowsingForPeers()
        }
        #if os(iOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            if self.cachedPeers.isEmpty {
                self.advertiser.stopAdvertisingPeer()
                self.browser.stopBrowsingForPeers()
            }
        }
        #endif
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        peersLock.lock(); peersSnapshot = []; peersLock.unlock()
    }

    /// Bytes enqueued for sending but not yet handed off — backpressure so a slow link (BLE) can't let the
    /// send backlog grow unbounded (it ballooned to multi-GB and jetsam-killed the app).
    private let backlogLock = NSLock()
    private var backlogBytes = 0
    static let sendBacklogCap = 4 * 1024 * 1024   // 4 MB of unsent frames; drop large ones past this
    /// True when the unsent backlog is high — a media sender checks this to stop early instead of piling on.
    var sendBacklogHigh: Bool { backlogLock.lock(); defer { backlogLock.unlock() }; return backlogBytes > Self.sendBacklogCap }

    /// Send a frame to every connected nearby peer (recipients who can't open it ignore it).
    /// Fire-and-forget on a background queue so a slow/jammed Multipeer link never stalls the main
    /// thread (see `sendQueue`).
    func broadcast(_ frame: Data) {
        // Backpressure: when the unsent backlog is high, DROP large (media-chunk) frames — the receiver
        // re-requests / the sender re-pushes later. Small frames (posts/hellos/requests) always go through.
        backlogLock.lock(); let backlog = backlogBytes; backlogLock.unlock()
        if frame.count > 8192 && backlog > Self.sendBacklogCap { return }
        backlogLock.lock(); backlogBytes += frame.count; backlogLock.unlock()
        sendQueue.async { [weak self] in
            guard let self else { return }
            defer { self.backlogLock.lock(); self.backlogBytes -= frame.count; self.backlogLock.unlock() }
            // Cached peers, not session.connectedPeers — the sync read can deadlock against MC's
            // recv thread mid-transfer (see peersSnapshot), which would wedge this queue forever.
            let peers = self.cachedPeers
            guard !peers.isEmpty else { return }
            try? self.session.send(frame, toPeers: peers, with: .reliable)
        }
    }
}

extension NearbyTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // Refresh the snapshot HERE (we're on MC's own callback queue, where the read is safe) so
        // no other thread ever needs to touch session.connectedPeers.
        let peers = session.connectedPeers
        peersLock.lock(); peersSnapshot = peers; peersLock.unlock()
        if state == .connected {
            onPeerConnected()
            // Stop discovery entirely while connected — advertising next to a Mac kept inviting
            // flaps; browsing kept scanning. Session stays up for the active transfer only.
            browser.stopBrowsingForPeers()
            advertiser.stopAdvertisingPeer()
        } else if peers.isEmpty {
            #if os(iOS)
            // iPhone: do not auto-resume Multipeer discovery (heat). User/activity can nudge.
            #else
            advertiser.startAdvertisingPeer()
            browser.startBrowsingForPeers()
            #endif
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
        // Only one side initiates, to avoid dueling invitations (the other side accepts).
        if self.peerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
