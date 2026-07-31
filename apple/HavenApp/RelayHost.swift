import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if os(macOS) || targetEnvironment(macCatalyst)
import ServiceManagement
import Darwin
#endif

/// Runs this device as the circle's **relay / mailbox** in-process (the `haven-relay` core via
/// FFI): an iroh blob store on local disk that holds sealed (unreadable) circle media + events
/// and re-serves them so the circle has an always-available mailbox. The common, zero-setup path
/// — no S3, no terminal, no cloud — just a toggle.
///
/// Lifetime by platform: on **Mac** it runs as long as the app is open (set-and-forget). On
/// **iPhone/iPad** iOS suspends background apps, so it serves while Haven is foregrounded and
/// awake — we disable auto-lock so a device left on a charger keeps relaying. (Linux/Windows use
/// the standalone binary; Android will use a foreground service.)
@MainActor
final class RelayHost: ObservableObject {
    static let shared = RelayHost()

    @Published private(set) var enabled: Bool
    @Published private(set) var serving = false
    @Published private(set) var nodeId = ""

    private var handle: RelayServerHandle?
    /// Embedded iroh-relay (DERP) fabric — desktop-class hosts only; held while hosting.
    private var derpHandle: DerpServerHandle?
    /// Single-origin path router (media + DERP by path) — tunnel targets this port when set.
    private var pathRouterHandle: PathRouterHandle?
    /// Bumps on every stop/start so in-flight `startHttpInterface` Tasks cannot resurrect
    /// dual free tunnels or a dead path-proxy after the user toggled hosting.
    private var startGeneration: UInt64 = 0
    /// Media HTTP bind port (usually 8674) — watchdog verifies it stays up.
    private var mediaHttpPort: UInt16?
    /// Front-door local port (path router 8675 when unified, else media).
    private var frontDoorPort: UInt16?
    /// Cancels the tunnel/local health loop on stop.
    private var healthWatchTask: Task<Void, Never>?
    /// The same handle, reachable OFF the main actor.
    ///
    /// RelayHost is @MainActor, so every local-store accessor below used to force its caller onto the
    /// main thread — and those accessors do file I/O. The mailbox poll's own-relay branch lists the
    /// store and then reads EVERY unseen key through them, which on a freshly-enabled relay means the
    /// entire store, synchronously, on the main thread. That is the "unresponsive since I turned the
    /// relay on" report, and why the hang counter climbs many times a second rather than once per
    /// sync tick. The Rust side is internally locked, so the only thing needing protection here is the
    /// pointer itself, which changes just at start/stop.
    nonisolated private static let handleLock = NSLock()
    nonisolated(unsafe) private static var sharedHandle: RelayServerHandle?
    nonisolated private static func currentHandle() -> RelayServerHandle? {
        handleLock.lock(); defer { handleLock.unlock() }
        return sharedHandle
    }
    private func setHandle(_ h: RelayServerHandle?) {
        handle = h
        Self.handleLock.lock(); Self.sharedHandle = h; Self.handleLock.unlock()
    }
    private let d = UserDefaults.standard
    private let enabledKey = "haven.relay.host.enabled"
    private let maxAgeKey = "haven.relay.host.mediaMaxAgeDays"
    private let maxBytesKey = "haven.relay.host.mediaMaxBytes"

    /// How much of your circles' media this host is willing to keep, and for how long. Volunteering a
    /// machine shouldn't mean volunteering the whole disk, so both are user-chosen; `0` on either
    /// means "no limit" for that dimension. When both are set the sweep applies whichever frees space
    /// first. Defaults are deliberately generous but finite — an unbounded default is how a helpful
    /// relay quietly eats a laptop.
    static let defaultMediaMaxAgeDays = 30
    static let defaultMediaMaxBytes: UInt64 = 32 * 1024 * 1024 * 1024   // 32 GB

    /// Changing either takes effect when the relay next starts — the retention is handed to the store
    /// at attach time, so the UI tells the user to toggle hosting off and on rather than pretending
    /// a live change applied.
    var mediaMaxAgeDays: Int {
        get { d.object(forKey: maxAgeKey) as? Int ?? Self.defaultMediaMaxAgeDays }
        set { d.set(newValue, forKey: maxAgeKey); objectWillChange.send() }
    }
    var mediaMaxBytes: UInt64 {
        get { (d.object(forKey: maxBytesKey) as? NSNumber)?.uint64Value ?? Self.defaultMediaMaxBytes }
        set { d.set(NSNumber(value: newValue), forKey: maxBytesKey); objectWillChange.send() }
    }

    private init() { enabled = d.bool(forKey: enabledKey) }

    /// Whether this kind of device makes a good always-on relay (informs the UI copy).
    ///
    /// `os(macOS)` for the same reason as `setStartAtLogin`: Catalyst was dropped for the native
    /// HavenMac target, so a Catalyst-only gate answers FALSE on the shipping Mac app — which fed
    /// Storage.swift the iPhone/iPad footer telling a Mac user "a Mac or the desktop app is best
    /// for always-on".
    var isDesktopClass: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    private var storeDir: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("haven-relay-store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Retries while waiting for `FeedStore.transportNode` (shows as "Starting…" in the Relays UI).
    private var startWaitAttempts = 0

    func setEnabled(_ on: Bool) {
        if on {
            // Stuck "Starting…" (toggle on, never serving) — force a clean restart rather than
            // no-op'ing into the same failed half-state (fabric rebind detaches then fails reattach).
            if enabled && !serving {
                HavenLog.relay("host toggle on while stuck Starting — force stop+start")
                stop()
            }
            enabled = true
            d.set(true, forKey: enabledKey)
            start()
        } else {
            enabled = false
            d.set(false, forKey: enabledKey)
            stop()
        }
    }

    /// Restart the relay at launch if the user had it on.
    func startIfEnabled() { if enabled && handle == nil { start() } }

    /// Detach mailbox from the messaging node without killing cloudflared / embedded DERP —
    /// used by fabric soft-rebind (same-key endpoint must fully stop before re-spawn).
    func detachForFabricRebind() {
        handle?.disable()
        setHandle(nil)
        serving = false
        // Keep nodeId so reannounce still has a stable id; reattach refreshes it.
        HavenLog.relay("host detached for fabric rebind (will reattach when node is back)")
    }

    /// Re-attach after `FeedStore` restarted the messaging node onto Haven RelayMap.
    func reattachAfterFabricRebind() {
        guard enabled, handle == nil else { return }
        guard let node = FeedStore.shared.transportNode else {
            startWaitAttempts += 1
            if startWaitAttempts <= 30 || startWaitAttempts % 10 == 0 {
                HavenLog.relay("reattach waiting for messaging node (attempt \(startWaitAttempts))")
            }
            // Cap silent wait — after ~15s fall through to full start() which has the same wait,
            // but keeps UI honest and recovers if rebind left us stranded.
            if startWaitAttempts > 30 {
                HavenLog.relay("reattach gave up waiting — full start()")
                start()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.reattachAfterFabricRebind()
            }
            return
        }
        startWaitAttempts = 0
        updateSleepAssertion()
        let h = RelayServerHandle.attachWithLimits(node: node, dir: storeDir,
                                                   mediaMaxAgeDays: UInt32(max(0, mediaMaxAgeDays)),
                                                   mediaMaxBytes: mediaMaxBytes)
        setHandle(h)
        nodeId = h.nodeIdHex()
        serving = true
        updateSleepAssertion()
        authorizeMembership()
        // HTTP only — tunnels/DERP already running from the original start.
        // CRITICAL: re-publish the *live tunnel* media URL. reachableHttpUrls() without the
        // free/named front door is LAN-only — fabric rebind used to wipe https://…trycloudflare
        // media URLs and leave only 10.x:8674, so iroh (DERP public URL) still worked while
        // remote media never did.
        Task { [weak self] in
            guard let self else { return }
            let token = self.httpToken()
            var port: UInt16?
            do { port = try await h.serveHttp(bind: "0.0.0.0:8674", token: token) }
            catch { port = try? await h.serveHttp(bind: "0.0.0.0:0", token: token) }
            guard let port else { HavenLog.relay("reattach http FAILED"); return }
            self.mediaHttpPort = port
            let urls = Self.announceHttpUrls(mediaPort: port)
            if !urls.isEmpty, !self.nodeId.isEmpty {
                RelayMailboxStore.shared.setHttpInterface(self.nodeId, urls: urls, token: token)
                self.publishOwnInterface(urls: urls, token: token)
                // Keep DERP on the same public origin when path-proxy single-tunnel is live.
                #if os(macOS)
                if CloudflaredTunnel.shared.usesPathProxy,
                   let pub = Self.publicDerpCandidate(urls) {
                    RelayMailboxStore.shared.setDerpUrl(self.nodeId, url: pub)
                }
                #endif
            }
            FeedStore.shared.reannounceOwnRelay()
            HavenLog.relay(
                "reattach after fabric rebind relay=\(self.nodeId.prefix(10)) :\(port) urls=\(urls.joined(separator: " "))"
            )
        }
    }

    private func start() {
        guard enabled else { return }
        guard handle == nil else { return }
        // The relay now ATTACHES to the messaging node's endpoint (one iroh node, two ALPNs) — running a
        // second in-process iroh node is what made iroh churn paths unboundedly (the tens-of-GB leak).
        guard let node = FeedStore.shared.transportNode else {
            // Node not up yet — retry shortly; the relay can't exist without the node to attach to.
            startWaitAttempts += 1
            if startWaitAttempts == 1 || startWaitAttempts % 5 == 0 {
                HavenLog.relay("host waiting for messaging node (attempt \(startWaitAttempts))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.start() }
            return
        }
        startWaitAttempts = 0
        startGeneration &+= 1
        let gen = startGeneration
        // Mac: prevent system sleep so a laptop left closed as a relay keeps serving.
        // iPhone/iPad: NEVER pin the idle timer — keeping the screen awake for hosting was a
        // major battery/heat source (user field: multi-% drain in minutes while "just open").
        // iOS already suspends background work when the screen dims; that's the right trade-off
        // for a phone. Desktop-class is the always-on path.
        updateSleepAssertion()
        #if os(macOS)
        // Clear any orphan free tunnels before we bind so port/origin chaos cannot stick.
        DispatchQueue.global(qos: .userInitiated).async {
            CloudflaredTunnel.killOrphanCloudflareds(except: [])
        }
        #endif
        let h = RelayServerHandle.attachWithLimits(node: node, dir: storeDir,
                                                   mediaMaxAgeDays: UInt32(max(0, mediaMaxAgeDays)),
                                                   mediaMaxBytes: mediaMaxBytes)
        setHandle(h)
        nodeId = h.nodeIdHex()   // == the account node id now (the relay shares the node)
        serving = true
        updateSleepAssertion()
        RelayMailboxStore.shared.unforget(nodeId)   // hosting is an explicit adoption of our own relay
        // Lock the mailbox down to circle members before announcing it (audit transport-F4).
        authorizeMembership()
        // Tell my circles to use this device (its account node id) as their mailbox.
        FeedStore.shared.broadcastRelayNode(nodeId)
        HavenLog.relay("hosting relay=\(nodeId.prefix(10)) serving=\(serving) gen=\(gen)")
        startHttpInterface(h, generation: gen)
    }

    /// Serve the relay's store over plain HTTP — the DEFAULT cross-NAT media transport (the iroh
    /// blob ALPN drops its datagrams over a pure-relay cross-NAT path, so blob dials that must
    /// cross a NAT stall ~30s and die while messaging works). Gated on a per-request signature over
    /// the caller's transport key + circle membership — the same check the iroh path runs; the token
    /// travels ONLY inside the sealed frame-19 announce and is mixed into that signature rather than
    /// sent, so it is a pre-filter and never the authorization. Reachable URLs =
    /// the optional user-configured public URL (UserDefaults `haven.relay.publicURL` — set it when
    /// this host is port-forwarded / reverse-proxied / tunneled) first, then every LAN IPv4.
    private func startHttpInterface(_ h: RelayServerHandle, generation: UInt64) {
        let token = httpToken()
        Task { [weak self] in
            var port: UInt16?
            do { port = try await h.serveHttp(bind: "0.0.0.0:8674", token: token) }
            catch { port = try? await h.serveHttp(bind: "0.0.0.0:0", token: token) }   // port taken → ephemeral
            guard let self, let port else { HavenLog.relay("relay http serve FAILED"); return }
            guard self.startGeneration == generation, self.enabled, self.handle != nil else {
                HavenLog.relay("relay http start aborted (stale gen=\(generation))")
                return
            }
            self.mediaHttpPort = port

            // Tunnel targets this port (path router when fabric is unified, else media).
            var frontPort = port
            var pathRouted = false
            #if os(macOS)
            // Start DERP before the front door so a single-origin path router can front both.
            let configuredDerp = (UserDefaults.standard.string(forKey: "haven.relay.derpURL") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let mediaPublicPref = (UserDefaults.standard.string(forKey: "haven.relay.publicURL") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let siblingDerp = !configuredDerp.isEmpty
                && (mediaPublicPref.isEmpty || configuredDerp != mediaPublicPref)
            var derpLocalPort: UInt16?
            do {
                let derp = try await DerpServerHandle.spawn(bind: "127.0.0.1:3340", publicUrl: "")
                guard self.startGeneration == generation else { return }
                self.derpHandle = derp
                derpLocalPort = derp.localPort()
                HavenLog.relay("relay DERP fabric local=\(derp.localAddr())")
            } catch {
                HavenLog.relay("relay DERP failed: \(error.localizedDescription)")
            }
            var pathFailReason: String?
            if siblingDerp {
                // Operator chose a dedicated DERP hostname — skip path proxy, no free dual tunnel.
                pathFailReason = "sibling DERP URL configured (path proxy skipped)"
                HavenLog.relay("path router skipped — \(pathFailReason!)")
            } else if let dport = derpLocalPort {
                // Prefer single free tunnel via path proxy on the well-known port only.
                // Never fall back to an ephemeral bind — dual proxies (:8675 + random) confuse
                // cloudflared origin selection and leave dead listeners behind.
                for attempt in 1...3 {
                    do {
                        let router = try await PathRouterHandle.spawn(
                            bind: "127.0.0.1:8675",
                            mediaBackend: "127.0.0.1:\(port)",
                            derpBackend: "127.0.0.1:\(dport)",
                            httpToken: token
                        )
                        guard self.startGeneration == generation else { return }
                        self.pathRouterHandle = router
                        frontPort = router.localPort()
                        pathRouted = true
                        HavenLog.relay(
                            "path router on \(router.localAddr()) — single origin media+DERP "
                                + "(one cloudflared)"
                        )
                        break
                    } catch {
                        pathFailReason = error.localizedDescription
                        HavenLog.relay(
                            "path router attempt \(attempt) failed: \(error.localizedDescription)"
                        )
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                        }
                    }
                }
            } else {
                pathFailReason = "DERP fabric did not start"
                HavenLog.relay("path router skipped — \(pathFailReason!)")
            }
            self.frontDoorPort = frontPort

            // Tell the tunnel layer + UI the layout *before* apply so Settings can show
            // "one tunnel via path proxy" vs "dual free tunnels" without a flash of wrong copy.
            if pathRouted {
                CloudflaredTunnel.shared.setFrontDoorLayout(
                    pathProxy: true, localPort: frontPort, dualNote: nil
                )
            } else {
                CloudflaredTunnel.shared.setFrontDoorLayout(
                    pathProxy: false,
                    localPort: frontPort,
                    dualNote: "Path proxy off (\(pathFailReason ?? "unknown")) — "
                        + "media and DERP use separate free tunnels when auto is on"
                )
            }

            let fd = await CloudflaredTunnel.shared.apply(port: frontPort)
            guard self.startGeneration == generation, self.enabled else {
                HavenLog.relay("relay front door aborted (stale gen=\(generation))")
                CloudflaredTunnel.shared.stop()
                return
            }
            // After apply, publicURL is set — announceHttpUrls prefers it over LAN.
            var urls = Self.announceHttpUrls(mediaPort: port)
            if let u = fd.announceURL {
                urls = [u] + urls.filter { $0 != u }
                HavenLog.relay(
                    "relay front door \(CloudflaredTunnel.shared.frontDoorMode)"
                        + (fd.spawnedConnector ? " (cloudflared)" : " (announce-only)")
                        + (pathRouted ? " path-router" : "")
                        + " \(u)"
                )
            }
            HavenLog.relay(
                "relay http on :\(port) front=:\(frontPort) pathRouted=\(pathRouted) urls=\(urls.joined(separator: " "))"
            )
            guard !urls.isEmpty, !self.nodeId.isEmpty else { return }
            RelayMailboxStore.shared.setHttpInterface(self.nodeId, urls: urls, token: token)
            self.publishOwnInterface(urls: urls, token: token)
            // New public origin — drop cool-downs so phones don't sit on stale trycloudflare skips.
            SharedStore.clearAllHttpUrlBad()

            // Public DERP: single-origin shares media URL (call signaling hairpins over /relay);
            // sibling hostname uses configured URL; dual free tunnel only when path router is off.
            await self.finalizeDerpPublic(
                mediaUrls: urls,
                pathRouted: pathRouted,
                configuredDerp: configuredDerp,
                siblingDerp: siblingDerp
            )
            guard self.startGeneration == generation else { return }
            self.startHealthWatch(generation: generation, pathRouted: pathRouted, token: token)
            // Free trycloudflare rotates on every restart — burst reannounce so peers drop the
            // dead hostname and learn the new one (frame 19).
            self.reannounceBurst()
            #else
            var urls = Self.reachableHttpUrls(port: port)
            HavenLog.relay(
                "relay http on :\(port) front=:\(frontPort) pathRouted=\(pathRouted) urls=\(urls.joined(separator: " "))"
            )
            guard !urls.isEmpty, !self.nodeId.isEmpty else { return }
            RelayMailboxStore.shared.setHttpInterface(self.nodeId, urls: urls, token: token)
            self.publishOwnInterface(urls: urls, token: token)
            SharedStore.clearAllHttpUrlBad()
            self.reannounceBurst()
            #endif
        }
    }

    /// Write our CURRENT interface doc into the hosted relay's own store under the reserved key
    /// (`haven/relay/__interface__`), generation-stamped — parity with the CLI relay's startup
    /// publication. Any member/fleet device that can still dial us over iroh can then learn a
    /// rotated front door even when it missed every frame-19 burst (asleep, backgrounded, offline).
    private func publishOwnInterface(urls: [String], token: String) {
        guard !nodeId.isEmpty, !urls.isEmpty else { return }
        var doc: [String: Any] = [
            "v": 1,
            "gen": UInt64(Date().timeIntervalSince1970 * 1000),
            "node": nodeId,
            "urls": urls,
            "token": token,
        ]
        if let derp = RelayMailboxStore.shared.entries[nodeId]?.derpUrl, !derp.isEmpty {
            doc["derp"] = derp
        }
        if let data = try? JSONSerialization.data(withJSONObject: doc) {
            _ = localPut("haven/relay/__interface__", data)
        }
    }

    /// Frame-19 burst after URL rotate / host start — peers that missed the first announce recover.
    private func reannounceBurst() {
        FeedStore.shared.reannounceOwnRelay()
        let delays: [Double] = [2, 5, 12, 25]
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, self.serving, self.enabled else { return }
                FeedStore.shared.reannounceOwnRelay()
            }
        }
    }

    #if os(macOS)
    /// Keep free/named tunnels + local backends alive. On death: kill orphans, re-apply front
    /// door to the path proxy, update HTTP interface, reannounce the (possibly new) public URL.
    private func startHealthWatch(generation: UInt64, pathRouted: Bool, token: String) {
        healthWatchTask?.cancel()
        healthWatchTask = Task { [weak self] in
            // First check after connectors have a chance to settle (trycloudflare + edge).
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            var consecutiveHardFails = 0
            var consecutivePublicFails = 0
            while !Task.isCancelled {
                guard let self else { return }
                let stillMine = await MainActor.run {
                    self.startGeneration == generation && self.enabled && self.serving
                }
                guard stillMine else { return }

                let localOk = await self.probeLocalFrontDoor()
                let connectorOk = await MainActor.run { () -> Bool in
                    let cf = CloudflaredTunnel.shared
                    let mode = cf.frontDoorMode
                    if mode == "manual" { return true }
                    // Auto free tunnel expected but never came up (or died without Process ref).
                    if mode == "auto", cf.autoEnabled, cf.configuredPublicURL.isEmpty {
                        if cf.publicURL == nil || !cf.isMainConnectorAlive {
                            return false
                        }
                        return true
                    }
                    // Bundled / named: require live connector while token+domain are set.
                    if cf.expectsLiveConnector {
                        return cf.isMainConnectorAlive
                    }
                    return true
                }
                // When free-tunnel DNS is NXDOMAIN on this network, public GET always fails —
                // do NOT restart cloudflared (new free hostnames will also be unresolvable).
                let dnsBroken = await MainActor.run { CloudflaredTunnel.shared.freeTunnelDNSBroken }
                let publicOk: Bool
                if dnsBroken {
                    publicOk = true // treat as N/A — local+connector are the only signals
                } else if localOk && connectorOk {
                    publicOk = await self.probePublicFrontDoor()
                } else {
                    publicOk = false
                }

                if !localOk || !connectorOk {
                    consecutiveHardFails += 1
                    consecutivePublicFails = 0
                    HavenLog.relay(
                        "relay health HARD fail #\(consecutiveHardFails) local=\(localOk) connector=\(connectorOk) public=\(publicOk) dnsBroken=\(dnsBroken)"
                    )
                } else if !publicOk {
                    consecutiveHardFails = 0
                    consecutivePublicFails += 1
                    HavenLog.relay(
                        "relay health public soft fail #\(consecutivePublicFails) (connector still up)"
                    )
                } else {
                    consecutiveHardFails = 0
                    consecutivePublicFails = 0
                    // Re-check DNS periodically while hosting free tunnels.
                    let shouldRecheckDNS = await MainActor.run { () -> Bool in
                        CloudflaredTunnel.shared.frontDoorMode == "auto"
                            && (CloudflaredTunnel.shared.publicURL?.contains("trycloudflare") == true)
                    }
                    if shouldRecheckDNS {
                        let u = await MainActor.run { () -> String? in
                            CloudflaredTunnel.shared.publicURL
                        }
                        if let u {
                            await CloudflaredTunnel.shared.assessFreeTunnelDNS(publicURL: u)
                        }
                    }
                    // Heal LAN-only media announce while DERP public URL still works.
                    await MainActor.run {
                        self.ensurePublicMediaUrlsAnnounced(token: token)
                    }
                }

                // Hard: 2 ticks. Soft public-only: 4 ticks. Never recover solely for DNS NXDOMAIN.
                // A failed GET of our OWN public URL is NOT proof the tunnel is down. We probe it
                // from inside the same network, where hairpin NAT and this network's documented
                // trycloudflare DNS filtering both make it fail while outside peers are served
                // perfectly well by the very same connector. Recovering on that signal restarts
                // cloudflared, and a FREE quick tunnel comes back with a DIFFERENT hostname —
                // stranding every peer that holds the old one, whereupon the new hostname fails
                // the same self-probe and the whole thing repeats. That churn is what kept the
                // relay's address moving out from under peers all day.
                //
                // So: recover only when the LOCAL door or the connector is actually dead (a real,
                // actionable failure). A public-only failure restarts nothing when the hostname
                // would rotate; for a NAMED tunnel the hostname is stable, so a restart is
                // harmless there and still allowed.
                let freeTunnel = await MainActor.run {
                    CloudflaredTunnel.shared.publicURL?.contains("trycloudflare") == true
                }
                if !dnsBroken, consecutivePublicFails >= 4, freeTunnel {
                    HavenLog.relay(
                        "relay health: public probe failing but connector is UP — NOT restarting a free tunnel (its hostname would change and strand peers)"
                    )
                    consecutivePublicFails = 0
                }
                let shouldRecover = consecutiveHardFails >= 2
                    || (!dnsBroken && !freeTunnel && consecutivePublicFails >= 4)
                if shouldRecover {
                    consecutiveHardFails = 0
                    consecutivePublicFails = 0
                    await self.recoverFrontDoor(generation: generation, pathRouted: pathRouted, token: token)
                }

                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func probeLocalFrontDoor() async -> Bool {
        let port = await MainActor.run { self.frontDoorPort ?? self.mediaHttpPort }
        guard let port, port > 0 else { return false }
        return await Self.httpReachable(url: "http://127.0.0.1:\(port)/", timeout: 3)
    }

    private func probePublicFrontDoor() async -> Bool {
        let url = await MainActor.run { CloudflaredTunnel.shared.publicURL }
        guard let url, url.hasPrefix("https://") else {
            // Manual/LAN may have no cloudflared public URL — local probe is enough.
            return true
        }
        // trycloudflare dead hostnames often 530/502/timeout; a live path-proxy returns JSON.
        return await Self.httpReachable(url: url.hasSuffix("/") ? url : url + "/", timeout: 8)
    }

    /// GET that succeeds on any HTTP response (including 4xx) — connection refused / timeout = dead.
    private static func httpReachable(url: String, timeout: TimeInterval) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // Ephemeral session — avoids shared-session cookie / cache quirks on trycloudflare.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            // Cloudflare edge: 530 = origin/tunnel down for trycloudflare.
            if http.statusCode == 530 || http.statusCode == 502 || http.statusCode == 503 {
                return false
            }
            // Path-proxy root returns JSON with haven-path-proxy; bare DERP-only is wrong for
            // the unified front door but still "reachable". Prefer path-proxy marker when present.
            if let body = String(data: data, encoding: .utf8),
               body.contains("Iroh Relay"),
               !body.contains("haven-path-proxy"),
               !body.contains("haven") {
                // Likely pointed at raw :3340 instead of path proxy — treat as unhealthy for
                // single-origin mode so we recover onto :8675.
                return false
            }
            return http.statusCode > 0
        } catch {
            return false
        }
    }

    private func recoverFrontDoor(generation: UInt64, pathRouted: Bool, token: String) async {
        let ok = await MainActor.run {
            self.startGeneration == generation && self.enabled && self.serving
        }
        guard ok else { return }
        let frontPort = await MainActor.run { self.frontDoorPort ?? self.mediaHttpPort ?? 8675 }
        HavenLog.relay("relay front door recovering → :\(frontPort) (pathRouted=\(pathRouted))")

        // Local media/path-proxy dead → full host restart (not just tunnel).
        let localOk = await probeLocalFrontDoor()
        if !localOk {
            HavenLog.relay("relay local front door dead — full host restart")
            await MainActor.run {
                guard self.startGeneration == generation else { return }
                self.stop()
                if self.enabled { self.start() }
            }
            return
        }

        // Re-assert layout so Settings stays honest about one vs two tunnels.
        await MainActor.run {
            if pathRouted {
                CloudflaredTunnel.shared.setFrontDoorLayout(
                    pathProxy: true, localPort: frontPort, dualNote: nil
                )
            } else {
                CloudflaredTunnel.shared.setFrontDoorLayout(
                    pathProxy: false,
                    localPort: frontPort,
                    dualNote: "Path proxy off — dual free tunnels (media + DERP)"
                )
            }
        }
        let fd = await CloudflaredTunnel.shared.apply(port: frontPort)
        var urls: [String] = []
        await MainActor.run {
            guard self.startGeneration == generation, self.enabled, !self.nodeId.isEmpty else {
                CloudflaredTunnel.shared.stop()
                return
            }
            urls = Self.announceHttpUrls(mediaPort: self.mediaHttpPort ?? frontPort)
            if let u = fd.announceURL {
                urls = [u] + urls.filter { $0 != u }
                HavenLog.relay("relay front door recovered \(u)")
            } else {
                HavenLog.relay("relay front door recover produced no public URL")
            }
            if !urls.isEmpty {
                RelayMailboxStore.shared.setHttpInterface(self.nodeId, urls: urls, token: token)
                self.publishOwnInterface(urls: urls, token: token)
            }
        }
        // Dual free-tunnel mode: re-spawn the DERP trycloudflare too (apply only restarts media).
        if !pathRouted {
            let derpPort = await MainActor.run { self.derpHandle?.localPort() }
            if let dport = derpPort {
                let derpURL = await CloudflaredTunnel.shared.startQuickDerp(port: dport)
                await MainActor.run {
                    if let d = derpURL, !d.isEmpty, !self.nodeId.isEmpty {
                        RelayMailboxStore.shared.setDerpUrl(self.nodeId, url: d)
                    }
                }
            }
        } else if let pub = Self.publicDerpCandidate(urls) {
            await MainActor.run {
                if !self.nodeId.isEmpty {
                    RelayMailboxStore.shared.setDerpUrl(self.nodeId, url: pub)
                }
            }
        }
        await MainActor.run {
            guard self.startGeneration == generation, self.enabled else { return }
            self.reannounceBurst()
        }
    }
    #endif

    #if os(macOS)
    /// Record public DERP URL on our RelayEntry after the front door is known.
    private func finalizeDerpPublic(
        mediaUrls: [String],
        pathRouted: Bool,
        configuredDerp: String,
        siblingDerp: Bool
    ) async {
        guard derpHandle != nil else { return }
        var derpPublic: String?
        if siblingDerp {
            derpPublic = configuredDerp
        } else if pathRouted {
            // Same public origin as media — HTTPS fabric for live frames + call signaling.
            derpPublic = mediaUrls.first
        } else if !configuredDerp.isEmpty {
            derpPublic = configuredDerp
        } else if let u = mediaUrls.first(where: {
            $0.hasPrefix("https://") && !$0.contains("trycloudflare")
        }) {
            derpPublic = u
        } else if let port = derpHandle?.localPort() {
            // Dual free tunnel fallback when path router failed — second trycloudflare is
            // intentional here; CloudflaredTunnel publishes both live URLs for the Settings UI.
            HavenLog.relay(
                "path proxy not active — starting second free cloudflared for DERP :\(port)"
            )
            derpPublic = await CloudflaredTunnel.shared.startQuickDerp(port: port)
        }
        if let d = derpPublic, !d.isEmpty {
            RelayMailboxStore.shared.setDerpUrl(self.nodeId, url: d)
            HavenLog.relay(
                "relay DERP fabric public=\(d)"
                    + (pathRouted ? " (single-tunnel hairpin via path proxy)" : " (dual free tunnel)")
            )
        } else {
            HavenLog.relay("relay DERP listening — no public URL yet")
        }
    }
    #endif

    /// The persisted bearer token for OUR hosted relay's HTTP interface (generated once).
    private func httpToken() -> String {
        if let t = d.string(forKey: "haven.relay.httpToken"), !t.isEmpty { return t }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let tok = bytes.map { String(format: "%02x", $0) }.joined()
        d.set(tok, forKey: "haven.relay.httpToken")
        return tok
    }

    /// URLs peers can reach our HTTP **media** interface at.
    ///
    /// Order of preference:
    /// 1. **Live free/named cloudflared URL** (`CloudflaredTunnel.publicURL`) — path-proxy or media
    /// 2. Configured public URL (manual / bundled domain)
    /// 3. LAN IPv4s only when no public origin is known
    ///
    /// Public HTTPS wins OUTRIGHT — LAN is not appended. Appending `192.168.x` behind a public URL
    /// makes remote members burn timeouts. That bug + fabric-rebind reattach used to leave
    /// **LAN-only media URLs while DERP kept trycloudflare** → iroh works, media never does.
    static func reachableHttpUrls(port: UInt16) -> [String] {
        announceHttpUrls(mediaPort: port)
    }


    /// The first URL usable as an iroh DERP origin: a PUBLIC https:// host only.
    ///
    /// DERP is the fabric peers dial from anywhere, so a LAN address is never a valid answer —
    /// off-network peers cannot reach 10.x/192.168.x, and publishing one there silently strands
    /// the fabric. The media announce list deliberately carries LAN addresses (a peer on this
    /// network should use them for blobs), so the two lists must not be conflated: take the
    /// public entry for DERP, or none at all.
    static func publicDerpCandidate(_ urls: [String]) -> String? {
        urls.first { u in
            guard u.hasPrefix("https://"), let h = URL(string: u)?.host else { return false }
            if h.hasSuffix(".local") { return false }
            // Dotted-quad private ranges (and loopback) are LAN, never a DERP origin.
            let parts = h.split(separator: ".")
            if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
                let o = parts.compactMap { UInt8($0) }
                if o[0] == 10 || o[0] == 127 { return false }
                if o[0] == 192 && o[1] == 168 { return false }
                if o[0] == 172 && (16...31).contains(o[1]) { return false }
                if o[0] == 169 && o[1] == 254 { return false }
            }
            return true
        }
    }

    /// Build the media announce list (shared by host start, reattach, health recover).
    ///
    /// Public URL FIRST (reaches anyone), then this host's LAN addresses — never one INSTEAD of
    /// the other. Treating LAN as a mere fallback for "no tunnel yet" broke the most common case
    /// there is: two phones and this relay on the same Wi-Fi, the relay serving on its media port
    /// the whole time, and neither phone able to use it because the only address they were given
    /// was a free-tunnel hostname — one that changes on every relay restart and that a system
    /// resolver can refuse while Safari resolves it fine. Peers try each URL in turn, so shipping
    /// the LAN address alongside costs nothing off-network and makes same-network delivery work
    /// with no tunnel, no public DNS, and no rotating hostname to chase.
    static func announceHttpUrls(mediaPort: UInt16) -> [String] {
        var urls: [String] = []
        #if os(macOS)
        // Live tunnel (free trycloudflare or named) — most important for remote peers.
        if let live = CloudflaredTunnel.shared.publicURL?
            .trimmingCharacters(in: .whitespacesAndNewlines), !live.isEmpty {
            var t = live
            while t.hasSuffix("/") { t.removeLast() }
            if let n = CloudflaredTunnel.normalizePublicURL(t) { urls.append(n) }
            else if t.hasPrefix("https://") || t.hasPrefix("http://") { urls.append(t) }
        }
        #endif
        // Manual / bundled configured domain.
        if urls.isEmpty, let pub = CloudflaredTunnel.normalizePublicURL(
            UserDefaults.standard.string(forKey: "haven.relay.publicURL") ?? ""
        ) {
            urls.append(pub)
        }
        for lan in lanIPv4s().map({ "http://\($0):\(mediaPort)" }) where !urls.contains(lan) {
            urls.append(lan)
        }
        return urls
    }

    /// If our entry lost the public media URL (LAN-only wipe), restore from the live tunnel.
    #if os(macOS)
    func ensurePublicMediaUrlsAnnounced(token: String) {
        guard serving, !nodeId.isEmpty else { return }
        guard let live = CloudflaredTunnel.shared.publicURL?
            .trimmingCharacters(in: .whitespacesAndNewlines), !live.isEmpty else { return }
        let current = RelayMailboxStore.shared.httpInterface(nodeId)?.urls ?? []
        let hasPublicHttps = current.contains { $0.hasPrefix("https://") }
        if hasPublicHttps, current.contains(where: { $0.contains(live) || live.contains($0) }) {
            return
        }
        var t = live
        while t.hasSuffix("/") { t.removeLast() }
        let urls = [CloudflaredTunnel.normalizePublicURL(t) ?? t]
        RelayMailboxStore.shared.setHttpInterface(nodeId, urls: urls, token: token)
        publishOwnInterface(urls: urls, token: token)
        if CloudflaredTunnel.shared.usesPathProxy, let pub = Self.publicDerpCandidate(urls) {
            RelayMailboxStore.shared.setDerpUrl(nodeId, url: pub)
        }
        HavenLog.relay("media announce restored public URL \(urls[0]) (was LAN-only=\(current))")
        reannounceBurst()
    }
    #endif

    /// Every up, non-loopback, non-link-local IPv4 on this device (getifaddrs).
    ///
    /// TTL-cached: `getifaddrs` is a sysctl walk of every interface, and this is called from
    /// `urlPlausiblyReachable` — per URL, per relay, per circle, per poll — which put the walk on
    /// the MAIN thread hundreds of times a second (20% of a b350 beachball sample). Interfaces
    /// change on the timescale of network hops, not polls; 15 s of staleness only delays a
    /// LAN-plausibility verdict, never breaks it.
    private static let lanIPv4Lock = NSLock()
    private static var lanIPv4Cache: (ips: [String], at: Date)?
    static func lanIPv4s() -> [String] {
        lanIPv4Lock.lock()
        if let c = lanIPv4Cache, Date().timeIntervalSince(c.at) < 15 {
            lanIPv4Lock.unlock()
            return c.ips
        }
        lanIPv4Lock.unlock()
        let fresh = lanIPv4sUncached()
        lanIPv4Lock.lock()
        lanIPv4Cache = (fresh, Date())
        lanIPv4Lock.unlock()
        return fresh
    }

    private static func lanIPv4sUncached() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return out }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
            var sin = addr.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                let ip = String(cString: buf)
                if !ip.hasPrefix("169.254."), !out.contains(ip) { out.append(ip) }
            }
        }
        return out
    }

    /// Store one of OUR OWN sealed events/media into the in-process mailbox directly (no iroh
    /// self-connection). Returns false if we aren't currently hosting.
    nonisolated func localPut(_ key: String, _ data: Data) -> Bool {
        Self.currentHandle()?.localPut(key: key, data: data) ?? false
    }
    nonisolated func localHas(_ key: String) -> Bool { Self.currentHandle()?.localHas(key: key) ?? false }
    /// Read a blob from our OWN hosted mailbox (a sibling device's / friend's upload), without dialing
    /// ourselves — the host can't poll its own relay over iroh (self-dial guard), so it reads locally.
    nonisolated func localGet(_ key: String) -> Data? { Self.currentHandle()?.localGet(key: key) }
    /// Keys under `prefix` in our own mailbox, so the host can ingest what others uploaded to it.
    nonisolated func localList(_ prefix: String) -> [String] {
        Self.currentHandle()?.localList(prefix: prefix) ?? []
    }
    /// Refresh the liveness of `keys` in our OWN hosted mailbox (the daily refresh can't TOUCH
    /// itself over iroh — self-dial guard). Returns the keys the store lacks (re-PUT via localPut);
    /// empty when not hosting so a stopped relay never triggers a local re-upload storm.
    ///
    /// `nonisolated`, like every other local-store accessor above — this one was missed when they
    /// moved, and it is the most expensive of the set. A TOUCH is one `open` + `set_modified` +
    /// `close` PER KEY, and `touchHeldKeys` hands it every mailbox key we have ever ingested for a
    /// circle: on a hosting Mac with a real store that is ~12,000 files of synchronous I/O on the
    /// thread drawing the UI, in one call. Measured as a ~13-second main-thread stall repeating on
    /// the poll cadence — the "beachballs every 20 seconds and comes back" report. Nothing about
    /// the work needs the main actor; the Rust side is internally locked and `currentHandle()` is
    /// the same not-serving guard `serving` was (stop() nils it), so callers can run it off-main.
    nonisolated func localTouch(_ keys: [String]) -> [String] {
        Self.currentHandle()?.localTouch(keys: keys) ?? []
    }

    private func stop() {
        // Invalidate any in-flight startHttpInterface / health watch immediately.
        startGeneration &+= 1
        healthWatchTask?.cancel()
        healthWatchTask = nil
        mediaHttpPort = nil
        frontDoorPort = nil
        #if os(macOS)
        CloudflaredTunnel.shared.stop() // also sweeps orphans off-main
        pathRouterHandle = nil  // drops unified media+DERP front door
        derpHandle = nil   // drops embedded iroh-relay
        #endif
        handle?.disable()      // detach the relay from the node's endpoint
        setHandle(nil)         // releases the FFI handle (best-effort; OS reclaims on exit)
        serving = false
        nodeId = ""
        updateSleepAssertion()
    }

    /// Hold/release the macOS keep-awake assertion from (serving × the user's toggle). The
    /// assertion prevents IDLE system sleep only — a closed lid or an explicit Sleep still
    /// sleeps the Mac, and Power Nap cannot keep third-party sockets alive; the toggle's UI
    /// copy says so honestly.
    func updateSleepAssertion() {
        #if os(macOS)
        PlatformIdle.disabled = serving && SettingsStore.shared.keepAwakeWhileHosting
        #endif
    }

    /// Mesh anti-entropy: while we're hosting, pull every sealed blob each SIBLING relay holds that
    /// we lack, so the circle's mailbox self-replicates across relays (any relay can join/leave
    /// without losing data). Health-aware — relays in backoff are skipped, and a successful pull
    /// clears their backoff. Mirrors the desktop `mesh_sync`; driven on FeedStore's sync timer.
    /// Push current circle membership to the in-process relay so each circle's mailbox is served ONLY
    /// to its members (+ sibling relays for mesh sync) — a stranger who learns the relay id gets
    /// nothing (audit transport-F4). Idempotent; safe to call on start and whenever membership or the
    /// relay set changes. The relay stays permissive until the first circle is authorized here.
    func authorizeMembership() {
        guard let handle, serving else { return }
        // Matrix QA stub (`com.blaineam.kith.qa.stub`) hosts a pure relay with no social graph.
        // Calling authorizeCircle with only the host locks the door (RelayAuth fails CLOSED when
        // members are just the host) so every client gets HTTP REFUSED forever — posts/media never
        // land for multi-device or cross-user. Union extra hexes from Application Support so the
        // driver can authorize iOS/Android/Tauri accounts (and their device ids) for the mailbox.
        let qaExtra = Self.qaAuthorizeMembers()
        for (cid, members) in FeedStore.shared.circleMemberships() {
            var m = members
            for h in qaExtra where !m.contains(h) { m.append(h) }
            let relays = RelayMailboxStore.shared.relays(forCircle: cid)
            handle.authorizeCircle(circleId: cid, members: m, relays: relays)
        }
        // Stub may have zero circles in its social engine — still authorize "default" for QA.
        if Bundle.main.bundleIdentifier?.contains("qa.stub") == true {
            var m = qaExtra
            let me = AccountStore.currentNodeHex()
            if !me.isEmpty, !m.contains(me) { m.append(me) }
            if !m.isEmpty {
                handle.authorizeCircle(circleId: "default", members: m, relays: [nodeId].filter { !$0.isEmpty })
                HavenLog.relay("stub authorize default members=\(m.count)")
            }
        }
    }

    /// Hexes (account and/or device) the matrix driver wants this host relay to serve.
    /// File: Application Support/`qa-authorize-members.txt` — one 64-hex id per line.
    /// Also checks common sandboxed subdirs (HavenStub / bundle id) used by macOS containers,
    /// the absolute container path, and `/tmp/haven-mac-stub-home/…` when the stub is launched
    /// with an isolated HOME (matrix driver).
    private static func qaAuthorizeMembers() -> [String] {
        #if DEBUG
        var candidates: [URL] = []
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(base.appendingPathComponent("qa-authorize-members.txt"))
            for sub in ["HavenStub", "com.blaineam.kith.qa.stub", Bundle.main.bundleIdentifier ?? ""] where !sub.isEmpty {
                candidates.append(base.appendingPathComponent(sub).appendingPathComponent("qa-authorize-members.txt"))
            }
        }
        #if os(macOS)
        // Matrix paths only make sense on Mac (the QA stub host). iOS never hosts the matrix relay.
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(
            "Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/qa-authorize-members.txt"))
        candidates.append(home.appendingPathComponent(
            "Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/HavenStub/qa-authorize-members.txt"))
        // Isolated matrix HOME (driver often launches with HOME=/tmp/haven-mac-stub-home).
        candidates.append(URL(fileURLWithPath: "/tmp/haven-mac-stub-home/Library/Application Support/qa-authorize-members.txt"))
        candidates.append(URL(fileURLWithPath: "/tmp/haven-mac-stub-home/Library/Application Support/HavenStub/qa-authorize-members.txt"))
        // Real user container even when process HOME is isolated.
        if let pw = getpwuid(getuid()) {
            let realHome = String(cString: pw.pointee.pw_dir)
            candidates.append(URL(fileURLWithPath: realHome)
                .appendingPathComponent("Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/qa-authorize-members.txt"))
            candidates.append(URL(fileURLWithPath: realHome)
                .appendingPathComponent("Library/Containers/com.blaineam.kith.qa.stub/Data/Library/Application Support/HavenStub/qa-authorize-members.txt"))
        }
        #endif
        var seen = Set<String>()
        var all: [String] = []
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hexes = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }
            for h in hexes where seen.insert(h).inserted { all.append(h) }
            if !hexes.isEmpty {
                HavenLog.relay("qa-authorize-members +\(hexes.count) from \(url.path)")
            }
        }
        if all.isEmpty {
            HavenLog.relay("qa-authorize-members empty (checked \(candidates.count) paths)")
        } else {
            HavenLog.relay("qa-authorize-members union=\(all.count)")
        }
        return all
        #else
        return []
        #endif
    }

    /// Last mesh anti-entropy pass (ms). Field: host Macs ran this every sync tick (~20s),
    /// listing every sibling's full `haven/*` store and pulling ≤256 MB blobs into RAM — friend's
    /// Mac sample hit **4.6 GB peak** and stayed unresponsive while "just hosting a relay."
    private var lastMeshSyncMs: UInt64 = 0
    private static let meshSyncMinIntervalMs: UInt64 = 300_000   // 5 minutes

    /// Hand each relay the circle's full relay list so the mesh is symmetric. Throttled with the
    /// mesh tick itself (≥5 min) — the list changes rarely and this is one round trip per relay.
    private func teachSiblingRelays(pool: [String]) {
        let hexes = pool.filter { $0.count == 64 }
        guard hexes.count > 1 else { return }   // nothing to teach when we're the only relay
        let circleIds = FeedStore.shared.circles.map(\.id)
        guard !circleIds.isEmpty else { return }
        Task.detached {
            for target in hexes {
                guard let client = await RelayClients.client(target) else { continue }
                for cid in circleIds {
                    _ = await client.teachRelays(circleId: cid, relays: hexes.filter { $0 != target })
                }
            }
        }
    }

    func meshSyncTick() {
        guard let handle, serving else { return }
        authorizeMembership() // keep the allow-list fresh as membership / relays change
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        // Cheap path every tick: membership only. Expensive pull is throttled hard.
        guard nowMs &- lastMeshSyncMs >= Self.meshSyncMinIntervalMs else { return }
        lastMeshSyncMs = nowMs
        let myHex = nodeId
        // Only peers we have recently proven OR that advertise a public HTTP front door.
        // `available` alone is true for never-tried / backoff-expired dead NAS → mesh dial timeouts
        // every pass while the UI still looks "fine."
        let peers = RelayMailboxStore.shared.allRelays()
            .filter { $0 != myHex && RelayHealth.shared.available($0) }
            .filter {
                RelayHealth.shared.provenAlive($0, withinMs: 900_000)
                    || (RelayMailboxStore.shared.httpInterface($0)?.urls
                        .contains(where: { RelayMailboxStore.urlReachableByOthers($0) }) ?? false)
            }
        guard !peers.isEmpty else { return }
        // Teach every relay in the pool about the others. We already pull from all of them; a
        // HEADLESS relay knew only the `--peer` hexes its operator typed, so it never pulled back
        // and anything uploaded while it was offline stayed missing there. Best-effort and silent —
        // an older relay has no such verb.
        teachSiblingRelays(pool: peers + [myHex])
        Task {
            var anyPull = false
            for peer in peers {
                let pulled = await handle.syncFrom(peerNodeHex: peer)
                if pulled > 0 {
                    anyPull = true
                    RelayHealth.shared.recordSuccess(peer)
                    RelayMailboxStore.shared.markSeen(peer)
                    FeedStore.shared.markRelay(true)
                } else if !RelayHealth.shared.provenAlive(peer, withinMs: 60_000) {
                    // Zero pull + no recent success: treat as soft fail so dead NAS drops out.
                    // (Successful empty-sync still records success in FFI only when client dials.)
                }
            }
            // One mailbox poll after the whole pass — not per peer (was cascading main-actor work).
            if anyPull {
                FeedStore.shared.pollMailboxNow()
            }
        }
    }

    /// A stable, relay-specific 32-byte identity (distinct from the messaging account), so the
    /// relay's node id is its own and stable across restarts.
    private static func relaySeed() -> Data {
        if let b64 = Keychain.get("relaySeed"), let s = Data(base64Encoded: b64), s.count == 32 { return s }
        var b = Data(count: 32)
        _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        Keychain.set(b.base64EncodedString(), for: "relaySeed")
        return b
    }

    // MARK: - Start at login (Mac Catalyst only)
    //
    // On the Mac we want the relay to come back automatically after a reboot/logout so the
    // circle's mailbox stays "always-on". `SMAppService.mainApp` registers Haven as a login
    // item, so macOS relaunches it at login; the relay then resumes via `startIfEnabled()`.
    //
    // Catalyst can't run a true windowless/menu-bar agent (see notes in `StorageSettingsView`),
    // so the best achievable is: auto-launch at login + keep relaying for the life of the
    // process (the relay is never torn down on background/window-close — only when the toggle
    // is turned off or the app fully quits).

    /// Whether "start at login" is supported (native macOS + Mac Catalyst).
    var loginItemSupported: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// True when the app is currently registered to launch at login. No-op (false) on iOS.
    var startsAtLogin: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return SMAppService.mainApp.status == .enabled
        #else
        return false
        #endif
    }

    /// Register/unregister Haven as a macOS login item. Throws on failure (e.g. unsigned dev
    /// builds, or when the user has disabled the item in System Settings) so the UI can surface
    /// the error. No-op on iOS.
    ///
    /// Gated on `os(macOS)` too, not Catalyst alone: Catalyst was dropped for the native HavenMac
    /// target, so the Catalyst-only gate compiled this body out of the shipping Mac app entirely —
    /// `loginItemSupported` and `startsAtLogin` both answered for native macOS while the setter
    /// silently did nothing. SMAppService is the native path and needs no Catalyst.
    func setStartAtLogin(_ on: Bool) throws {
        #if os(macOS) || targetEnvironment(macCatalyst)
        if on {
            // Already enabled? `register()` is idempotent but throws if the user disabled it in
            // System Settings; treat "already enabled" as success.
            if SMAppService.mainApp.status == .enabled { return }
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
        #endif
    }
}

/// Per-circle mailbox config: the node ids of the Haven relays serving each circle (learned from
/// relay-host sealed broadcasts, or set when this device is the host). A circle can have several
/// relays — posts are mirrored to ALL of them (redundancy) and read from any (graceful fallback).
/// When a circle has no relay, the app falls back to the S3 option.
///
/// Mirrors the desktop `prefs.relays: HashMap<String, Vec<String>>`. The legacy single-relay map
/// (`haven.relay.byCircle` as `[String: String]`) is migrated into the list form on first load.
///
/// DEACTIVATE-NOT-ERASE: "removing" a relay no longer wipes its circle associations — it flips the
/// relay's `RelayEntry.active` to false (and suppresses it so auto-learn doesn't resurface it while
/// it's deactivated). The config (name, which circles use it, whether it's an S3 bucket) survives, so
/// a relay can be reactivated later without re-pasting anything. Only `purgeStale` truly erases — and
/// only entries that are BOTH inactive AND unseen for > 7 days. An ACTIVE-but-unreachable relay is
/// never purged. The `relaysByCircle` map stays the source of truth for *associations*; `entries`
/// adds the per-relay metadata (name / active / lastSeen / isS3) layered on top.

/// One configured relay: a Haven relay node (isS3=false) or an S3 bucket transport (isS3=true).
/// `hex` is the node id for a Haven relay, or a synthetic "s3:<bucket>" id for an S3 entry (so the
/// same map can address both kinds — SharedStore already treats them as interchangeable transports).
/// A deleted relay, kept just long enough to undo the deletion (see `RelayMailboxStore.erasedRelays`).
struct ErasedRelay: Codable, Identifiable, Equatable {
    var entry: RelayEntry
    /// The circles it served, so Restore puts it back where it was rather than nowhere.
    var circles: [String]
    var wasDefault: Bool
    var erasedAt: UInt64
    var id: String { entry.hex }
}

struct RelayEntry: Codable, Identifiable, Equatable {
    var hex: String
    var name: String
    var active: Bool
    var lastSeenMs: UInt64
    var isS3: Bool
    /// Plain-HTTP interface of this relay (LAN + optional public URLs) — the DEFAULT cross-NAT
    /// media transport (the iroh blob ALPN drops datagrams on pure-relay cross-NAT paths).
    /// Learned from the sealed frame-19 announce; nil/empty = iroh-only relay.
    var httpUrls: [String]?
    /// Shared relay secret folded into each request signature (travels ONLY inside sealed announces,
    /// and is never put on the wire — see SharedStore.httpAuth).
    var httpToken: String?
    /// Public HTTPS URL of this relay's embedded iroh-relay (DERP) fabric role. When set, peers
    /// prefer it over n0 for NAT fallback. Empty = use n0 (or another relay's DERP).
    var derpUrl: String?
    /// Public TURN URLs for WebRTC ICE (`turn:host:port`). When fabric is active and non-empty,
    /// clients use these for WebRTC media ICE (else STUN for srflx).
    var turnUrls: [String]?
    /// TURN username (default `haven`).
    var turnUser: String?
    /// TURN password (long-lived secret). Travels only inside sealed announces.
    var turnPass: String?
    /// When this relay was last (re-)ADOPTED into a circle (unix ms). Rides the announce so a member
    /// who FORGOT it earlier reactivates on a NEWER re-add (LWW), while a stale third-party echo —
    /// which carries the original, older timestamp — loses and stays forgotten. Defaulted (0) so old
    /// state files load; a 0 announce never beats a real forget time.
    var addedAtMs: UInt64?
    var id: String { hex }
}

@MainActor
final class RelayMailboxStore: ObservableObject {
    static let shared = RelayMailboxStore()
    /// circleId -> ordered list of relay node hexes (mirrored writes, fallback reads).
    @Published private(set) var relaysByCircle: [String: [String]]
    /// Per-relay metadata records, keyed by hex. The config survives deactivation here.
    @Published private(set) var entries: [String: RelayEntry] = [:]
    private let key = "haven.relay.relaysByCircle"
    private let legacyKey = "haven.relay.byCircle"   // old single-relay-per-circle map
    private let defaultKey = "haven.relay.default"
    private let suppressedKey = "haven.relay.suppressed"
    private let entriesKey = "haven.relay.entries"
    static let staleAfterMs: UInt64 = 7 * 24 * 3600 * 1000   // erase inactive+unseen entries after 7 days
    /// Relays the user explicitly FORGOT/deactivated. Auto-learn paths (frame-19 announce, SelfSync,
    /// bootstrap) must NOT resurrect a *user-forgotten* relay while it's inactive — but a deliberate
    /// re-announce DOES reactivate it (handleRelayNode clears the suppression + flips active=true), so
    /// your own re-announced relay can come back. Cleared on explicit adoption / reactivation.
    private var suppressed: Set<String>
    /// When each relay was FORGOTTEN (unix ms), for LWW against a re-announce's `addedAtMs`. A newer
    /// re-add reactivates; a forget newer than the last re-add keeps it dead. Parallel to `suppressed`.
    private var forgotAt: [String: UInt64] = [:]
    private let forgotAtKey = "haven.relay.forgotAt"
    /// Relays we deliberately RE-ADDED after a deletion (hex → re-add unix ms). Kept — like the
    /// friend-removal cleared-set — so self-sync publishes an explicit CLEAR (relay-removal = 0) that
    /// supersedes a sibling's stale deletion tombstone. Without it a grow-only relay tombstone would
    /// re-forget a re-added relay on every sibling's sync pass, forever.
    private var clearedRelayForgets: [String: UInt64] = [:]
    private let clearedRelayForgetsKey = "haven.relay.forgotAt.cleared"
    /// Relays the user DELETED, archived so the delete can be undone. `eraseNow` drops the live entry,
    /// every circle association and the default pick, so nothing about a deleted relay survives on disk
    /// otherwise — "Delete now" was the one action in the app with no way back, and a relay you can no
    /// longer name (it's a 64-char node id) is not something you re-add from memory.
    private var erased: [String: ErasedRelay] = [:]
    private let erasedKey = "haven.relay.erased"
    /// Cap + TTL for the archive: enough to undo a mistake, not a permanent record of every relay the
    /// app ever auto-purged.
    private static let erasedKeepMax = 12
    private static let erasedTtlMs: UInt64 = 30 * 24 * 60 * 60 * 1000

    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// The adoption timestamp announced for a relay (bumped on explicit add/reactivate), 0 if unknown.
    func addedAtMs(_ hex: String) -> UInt64 { entries[hex]?.addedAtMs ?? 0 }
    /// When a relay was forgotten (0 if never), for the LWW reactivation gate.
    func forgottenAtMs(_ hex: String) -> UInt64 { forgotAt[hex.lowercased()] ?? 0 }
    /// Every relay we've forgotten, with its deletion timestamp — published to our OTHER devices via
    /// self-sync so a deletion PROPAGATES (a sibling that still had the relay active learns it's gone).
    var forgottenRelays: [String: UInt64] { forgotAt }
    /// Relays we deliberately re-added (hex → re-add ms) — published as a CLEAR so a sibling's stale
    /// deletion tombstone doesn't re-forget a relay we brought back.
    var clearedRelayForgetRecords: [String: UInt64] { clearedRelayForgets }

    /// Apply a relay-deletion CLEAR (re-add) from another device — un-forget the relay so it can be
    /// re-learned — but ONLY when the re-add is NEWER than our local deletion (LWW on `atMs`). Without
    /// this timestamp check a stale re-add un-deleted a relay the user had since deleted, forever (the
    /// "deleted relays keep coming back" bug: the grow-only cleared set re-broadcast an old re-add every
    /// sync and it always won). A re-add older than our forget loses and the relay stays gone.
    func applyClearedRelayForget(_ nodeHex: String, atMs: UInt64) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard atMs > 0 else { return }
        // Our local deletion is newer than this re-add → the delete wins; ignore the stale clear.
        if (forgotAt[hex] ?? 0) > atMs { return }
        // Already cleared at/after this time → nothing to do.
        if !suppressed.contains(hex) && forgotAt[hex] == nil && (clearedRelayForgets[hex] ?? 0) >= atMs { return }
        HavenLog.relay("CLEARED-FORGET \(hex.prefix(8)) atMs=\(atMs) localForgot=\(forgotAt[hex] ?? 0) — self-sync un-forgot")
        suppressed.remove(hex)
        forgotAt.removeValue(forKey: hex)
        clearedRelayForgets[hex] = max(clearedRelayForgets[hex] ?? 0, atMs)
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        UserDefaults.standard.set(forgotAt, forKey: forgotAtKey)
        UserDefaults.standard.set(clearedRelayForgets, forKey: clearedRelayForgetsKey)
        objectWillChange.send()
    }

    /// Add a relay learned via SELF-SYNC (another of my devices' circle record) WITHOUT stamping a
    /// fresh adoption time. Self-sync carries only a hex list (no timestamps), so the old code
    /// fabricated addedAt=now() here — which let a sibling perpetually re-stamp a relay and defeat a
    /// deletion's LWW ("deleted relays keep returning when another device syncs"). A sync-learned relay
    /// keeps its EXISTING adoption stamp, or 0 (unknown) for a brand-new one — and 0 loses the LWW gate
    /// to any real forget, so it can never resurrect a relay this device deleted. Respects the tombstone.
    func addSynced(circleId: String, nodeHex: String) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.hasPrefix("s3:") ? true : hex.count == 64 else { return }
        guard !isForgotten(hex) else { return }   // never re-add a relay the user deleted
        if entries[hex] == nil {
            entries[hex] = RelayEntry(hex: hex, name: Self.shortName(hex), active: true,
                                      lastSeenMs: nowMs(), isS3: hex.hasPrefix("s3:"), addedAtMs: 0)
            persistEntries()
        }
        var list = relaysByCircle[circleId] ?? []
        if !list.contains(hex) {
            list.append(hex)
            relaysByCircle[circleId] = list
            UserDefaults.standard.set(relaysByCircle, forKey: key)
        }
    }

    /// Apply a relay-deletion tombstone learned from another of my devices via self-sync (LWW). Forget
    /// the relay locally IF the sibling's deletion is NEWER than our own adoption of it — so a deletion
    /// on one device drops the relay on all of them, but a device that legitimately RE-ADDED it later
    /// (addedAt > the synced forget time) keeps it. Idempotent.
    func applyForgottenTombstone(_ nodeHex: String, atMs: UInt64) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard atMs > 0 else { return }
        // A newer local re-add wins over the synced deletion (either a fresh adoption stamp, or a
        // re-add clear newer than this delete).
        if addedAtMs(hex) > atMs { return }
        if (clearedRelayForgets[hex] ?? 0) > atMs { return }
        // Already forgotten at or after this time → nothing to do.
        if (forgotAt[hex] ?? 0) >= atMs { return }
        if var e = entries[hex] { e.active = false; entries[hex] = e }
        suppressed.insert(hex)
        forgotAt[hex] = atMs
        // Drop any stale re-add record so THIS device stops re-broadcasting a clear that this newer
        // deletion supersedes — otherwise the two would ping-pong across the fleet.
        let hadClear = clearedRelayForgets.removeValue(forKey: hex) != nil
        persistEntries()
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        UserDefaults.standard.set(forgotAt, forKey: forgotAtKey)
        if hadClear { UserDefaults.standard.set(clearedRelayForgets, forKey: clearedRelayForgetsKey) }
        RelayClients.forget(hex)
        RelayHealth.shared.forget(hex)
        objectWillChange.send()
    }

    private init() {
        let d = UserDefaults.standard
        var loaded: [String: [String]] = (d.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        // Idempotent migration: fold the legacy single-relay map into the redundant list and drop it.
        if let legacy = d.dictionary(forKey: legacyKey) as? [String: String] {
            for (cid, hex) in legacy where !hex.isEmpty {
                var list = loaded[cid] ?? []
                if !list.contains(hex) { list.append(hex) }
                loaded[cid] = list
            }
            d.removeObject(forKey: legacyKey)
        }
        relaysByCircle = loaded
        suppressed = Set((d.array(forKey: suppressedKey) as? [String]) ?? [])
        forgotAt = (d.dictionary(forKey: forgotAtKey) as? [String: UInt64]) ?? [:]
        clearedRelayForgets = (d.dictionary(forKey: clearedRelayForgetsKey) as? [String: UInt64]) ?? [:]
        if let data = d.data(forKey: erasedKey),
           let decoded = try? JSONDecoder().decode([String: ErasedRelay].self, from: data) {
            erased = decoded
        }
        // MIGRATION: relays deleted on a build BEFORE the deletion-timestamp existed are in
        // `suppressed` but have no `forgotAt` entry. Without a deletion time the LWW gate can't tell
        // a deliberate re-add from an owner merely reopening the app, so those old deletions leaked
        // back. Stamp them "deleted now" so any future re-announce carrying the relay's ORIGINAL
        // (older) adoption time loses — only a genuine re-add stamped after this migration wins.
        var migrated = false
        let nowStamp = UInt64(Date().timeIntervalSince1970 * 1000)
        for hex in suppressed where forgotAt[hex] == nil { forgotAt[hex] = nowStamp; migrated = true }
        if migrated { d.set(forgotAt, forKey: forgotAtKey) }
        if !loaded.isEmpty { d.set(loaded, forKey: key) }
        // Load persisted entries, then migrate any relay that only exists in relaysByCircle/default
        // into a RelayEntry (active=true, short-hex name, lastSeen=now so the clock starts now).
        if let data = d.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([String: RelayEntry].self, from: data) {
            entries = decoded
        }
        migrateEntries()
        // Do NOT call refreshHavenFabric() here. That path reads `RelayMailboxStore.shared`,
        // which is still inside this dispatch_once init → recursive lock → SIGTRAP on launch
        // (libdispatch: "trying to lock recursively"). Push fabric after init returns.
        // The NSE relay mirror refreshes here too so the first launch of this build seeds it
        // even before any relay bookkeeping changes.
        DispatchQueue.main.async { [weak self] in
            Self.refreshHavenFabric()
            self?.mirrorRelayDirectory()
        }
    }

    /// Ensure every relay referenced by relaysByCircle / the default has a RelayEntry record.
    private func migrateEntries() {
        var changed = false
        var known = Set<String>()
        for list in relaysByCircle.values { for h in list { known.insert(h) } }
        if let def = UserDefaults.standard.string(forKey: defaultKey), !def.isEmpty { known.insert(def) }
        for hex in known where entries[hex] == nil {
            entries[hex] = RelayEntry(hex: hex, name: Self.shortName(hex), active: true,
                                      lastSeenMs: nowMs(), isS3: hex.hasPrefix("s3:"))
            changed = true
        }
        if changed { persistEntries() }
    }

    static func shortName(_ hex: String) -> String {
        if hex.hasPrefix("s3:") { return "S3 · " + String(hex.dropFirst(3).prefix(16)) }
        return "Relay · " + String(hex.prefix(8)) + "…"
    }

    private func persistEntries() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: entriesKey) }
        mirrorRelayDirectory()
    }

    /// Mirror every circle's relay HTTP interface into the App Group (`SharedRelayDirectory`) so
    /// the NSE can fetch a pushed envelope BEFORE the app opens (push-before-content). Rides
    /// `persistEntries` — the chokepoint every entry mutation (adopt, announce, http-interface,
    /// forget) already funnels through; the write itself dedupes by content, so this is cheap.
    private func mirrorRelayDirectory() {
        var circles: [String: [SharedRelayDirectory.RelayInterface]] = [:]
        for cid in relaysByCircle.keys {
            let ifaces = relays(forCircle: cid).compactMap { hex -> SharedRelayDirectory.RelayInterface? in
                guard let http = httpInterface(hex) else { return nil }
                return .init(u: http.urls, t: http.token)
            }
            if !ifaces.isEmpty { circles[cid] = ifaces }
        }
        var any: [SharedRelayDirectory.RelayInterface] = []
        if let def = defaultNodeHex, !def.isEmpty, isActive(def), let http = httpInterface(def) {
            any.append(.init(u: http.urls, t: http.token))
        }
        SharedRelayDirectory.write(circles: circles, any: any)
    }

    /// True when this relay has a config record and is currently active. Unknown hexes (never recorded,
    /// e.g. a freshly-announced relay before its entry lands) are treated as active so nothing breaks.
    func isActive(_ hex: String) -> Bool { entries[hex]?.active ?? true }

    /// A relay applied to "all circles (and future ones)": any circle inherits it. nil = none.
    var defaultNodeHex: String? {
        get { UserDefaults.standard.string(forKey: defaultKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultKey); objectWillChange.send() }
    }

    /// Every ACTIVE relay configured for a circle: its own list plus the all-circles default (deduped).
    /// Deactivated relays are filtered out so they aren't dialed/served, but their config survives.
    func relays(forCircle circleId: String) -> [String] {
        var out = (relaysByCircle[circleId] ?? []).filter { isActive($0) }
        if let def = defaultNodeHex, !def.isEmpty, isActive(def), !out.contains(def) { out.append(def) }
        return out
    }
    /// The relays explicitly associated with this circle (no default fallback, INCLUDING inactive) —
    /// for the settings UI, which shows active + inactive with toggles.
    func explicitRelays(forCircle circleId: String) -> [String] { relaysByCircle[circleId] ?? [] }
    /// The ACTIVE relays explicitly associated with this circle (no default fallback).
    func activeExplicitRelays(forCircle circleId: String) -> [String] {
        (relaysByCircle[circleId] ?? []).filter { isActive($0) }
    }

    /// First active relay for a circle — back-compat convenience (some callers only need "is there one").
    func nodeId(forCircle circleId: String) -> String? { relays(forCircle: circleId).first }

    /// ADD a relay to a circle (append, don't replace) — mirrors desktop `adopt_relay`. This is the
    /// EXPLICIT path (user adopts / hosts), so it CLEARS any suppression AND reactivates the entry —
    /// re-adding a previously-deactivated relay always works.
    /// `adoptedAtMs`: 0 = an EXPLICIT local adoption (stamp now()); a non-zero value = the adoption
    /// timestamp carried by a peer's announce (propagate it, don't invent a fresh one — inventing now()
    /// on every echo would let a stale relay's re-announce keep beating a user's forget = zombie loop).
    func add(circleId: String, nodeHex: String, name: String? = nil, isS3: Bool = false, adoptedAtMs: UInt64 = 0) {
        let hex = isS3 ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isS3 ? hex.hasPrefix("s3:") : hex.count == 64 else { return }
        unforget(hex)
        ensureEntry(hex, name: name, isS3: isS3, activate: true, adoptedAtMs: adoptedAtMs == 0 ? nowMs() : adoptedAtMs)
        var list = relaysByCircle[circleId] ?? []
        if !list.contains(hex) {
            list.append(hex)
            relaysByCircle[circleId] = list
            UserDefaults.standard.set(relaysByCircle, forKey: key)
        }
    }

    /// Create-or-update the RelayEntry for a hex. `activate` flips it on; lastSeen is stamped now on
    /// first creation so a freshly-added relay's stale-clock starts now (not 1970).
    func ensureEntry(_ hex: String, name: String? = nil, isS3: Bool = false, activate: Bool = false, adoptedAtMs: UInt64 = 0) {
        if var e = entries[hex] {
            if let name, !name.isEmpty { e.name = name }
            if activate { e.active = true }
            // Adoption stamp only ever moves FORWARD (max) — so the freshest legitimate re-add
            // propagates while a stale echo can't roll it back or refresh it to now().
            if adoptedAtMs > 0 { e.addedAtMs = max(e.addedAtMs ?? 0, adoptedAtMs) }
            entries[hex] = e
        } else {
            entries[hex] = RelayEntry(hex: hex, name: name ?? Self.shortName(hex),
                                      active: activate ? true : true, lastSeenMs: nowMs(), isS3: isS3,
                                      addedAtMs: adoptedAtMs > 0 ? adoptedAtMs : nowMs())
        }
        persistEntries()
    }

    /// Record a relay's plain-HTTP media interface (from our own host start, or a sealed announce).
    func setHttpInterface(_ hex: String, urls: [String], token: String) {
        ensureEntry(hex, activate: true)
        guard var e = entries[hex] else { return }
        if e.httpUrls == urls, e.httpToken == token { return }
        e.httpUrls = urls
        e.httpToken = token
        entries[hex] = e
        persistEntries()
        objectWillChange.send()
    }

    /// Record a relay's public iroh-relay (DERP) URL for Haven-first fabric (n0 only when empty).
    func setDerpUrl(_ hex: String, url: String?) {
        ensureEntry(hex, activate: true)
        guard var e = entries[hex] else { return }
        let t = url?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let next = (t?.isEmpty == false) ? t : nil
        if e.derpUrl == next { return }
        e.derpUrl = next
        entries[hex] = e
        persistEntries()
        objectWillChange.send()
        pushHavenFabric()
    }

    /// Record a relay's circle TURN URLs + credentials for WebRTC ICE.
    func setTurn(_ hex: String, urls: [String], user: String, pass: String) {
        ensureEntry(hex, activate: true)
        guard var e = entries[hex] else { return }
        let cleaned = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.turnUrls == cleaned, e.turnUser == u, e.turnPass == p { return }
        e.turnUrls = cleaned.isEmpty ? nil : cleaned
        e.turnUser = u.isEmpty ? nil : u
        e.turnPass = p.isEmpty ? nil : p
        entries[hex] = e
        persistEntries()
        objectWillChange.send()
        pushHavenFabric()
    }

    /// Every live DERP URL we know — feeds iroh RelayMap (Haven-first) and WebRTC ICE preference.
    func allDerpUrls() -> [String] {
        entries.values.compactMap { e -> String? in
            guard e.active, let u = e.derpUrl, !u.isEmpty else { return nil }
            return u
        }.sorted()
    }

    /// Union of live TURN URLs + first non-empty credentials across active relays.
    func allTurnIce() -> (urls: [String], user: String, pass: String) {
        var urls: [String] = []
        var user = ""
        var pass = ""
        for e in entries.values where e.active {
            guard let t = e.turnUrls, !t.isEmpty else { continue }
            for u in t where !urls.contains(u) { urls.append(u) }
            if user.isEmpty, let uu = e.turnUser, let pp = e.turnPass, !uu.isEmpty, !pp.isEmpty {
                user = uu; pass = pp
            }
        }
        return (urls.sorted(), user, pass)
    }

    /// Push known DERP URLs into the process fabric policy (Rust `apply_derp_urls`) for the **next**
    /// `HavenNode.start` bind, and into UserDefaults / `HavenFabric` for WebRTC ICE. When a live
    /// messaging node is already up and the fabric set changed, `FeedStore` soft-rebinds (stop + start).
    ///
    /// Prefer the instance form when you already hold `self` (avoids re-entering `.shared`).
    func pushHavenFabric() {
        let urls = allDerpUrls()
        UserDefaults.standard.set(urls, forKey: "haven.fabric.derpUrls")
        HavenFabric.shared.update(derpUrls: urls)
        let turn = allTurnIce()
        HavenFabric.shared.updateTurn(urls: turn.urls, user: turn.user, pass: turn.pass)
        applyDerpUrls(urls: urls)
        // Soft-rebind if the messaging node is live on a stale RelayMap (MainActor FeedStore).
        Task { @MainActor in
            FeedStore.shared.noteFabricUrlsChanged(urls)
        }
    }

    static func refreshHavenFabric() {
        shared.pushHavenFabric()
    }

    /// The relay's HTTP interface (urls + token), or nil for an iroh-only relay.
    ///
    /// PRIVATE addresses are dropped unless we are on that subnet ourselves. A relay hosted in the
    /// app announces every LAN IPv4 it has, which is right for a member on the same network and
    /// useless to everyone else — a `192.168.4.x` URL cannot be reached from a `10.0.0.x` network,
    /// ever. Those URLs were tried FIRST anyway (HTTP is the preferred media path), so every remote
    /// member burned a connect attempt and a timeout per operation on an address that could never
    /// work, then fell through to iroh in a worse state.
    ///
    /// This is exactly why the Dockerised NAS relay behaved better than the in-app Mac relays: it
    /// announces no HTTP interface at all, so callers go straight to the path that works. Filtering
    /// here gives the Mac relays the same behaviour instead of a broken fast path.
    func httpInterface(_ hex: String) -> (urls: [String], token: String)? {
        guard let e = entries[hex], let t = e.httpToken, !t.isEmpty,
              let u = e.httpUrls, !u.isEmpty else { return nil }
        let usable = u.filter { Self.urlPlausiblyReachable($0) }
        guard !usable.isEmpty else { return nil }   // nil = iroh-only, which is the honest answer
        return (usable, t)
    }

    /// Is this URL worth trying from where we are? Public hosts always; an address that only works
    /// inside some private network only when we are demonstrably inside that same network.
    ///
    /// TWO kinds of "private", and they need different tests:
    ///
    ///  - **RFC1918** (`10/8`, `172.16/12`, `192.168/16`) — ordinary LANs, which are subnetted, so
    ///    "are we on the same /24" is a good proxy for "can we reach it".
    ///
    ///  - **CGNAT `100.64.0.0/10`** — what Tailscale (and carrier NAT) hands out. The /24 test is
    ///    WRONG here: Tailscale assigns every device a /32 out of one flat /10, so two peers on the
    ///    same tailnet almost never share a /24 and the check rejects addresses that work perfectly.
    ///    Membership of the /10 at all is the honest signal available locally.
    ///
    /// This mattered in practice: a Mac relay hosted in-app announced its Tailscale address, that
    /// relay became someone's DEFAULT, and every post and photo went to an address no one outside
    /// the tailnet could resolve — silently, because CGNAT is not RFC1918 and sailed past the filter
    /// that catches `192.168.x`. Same failure as the LAN case, wearing an address that looks public.
    /// The rules live in `RelayAddress` (dependency-free, so `HavenLogicTests` can cover them).
    static func urlPlausiblyReachable(_ url: String) -> Bool {
        RelayAddress.plausiblyReachable(url, ourIPv4s: RelayHost.lanIPv4s())
    }

    /// Can a member on some OTHER network fetch from this URL? See `RelayAddress.reachableByOthers`.
    static func urlReachableByOthers(_ url: String) -> Bool {
        RelayAddress.reachableByOthers(url)
    }

    /// Stamp a relay as just-seen (a successful op). Cheap; persisted so "last seen" survives a restart.
    func markSeen(_ hex: String) {
        guard var e = entries[hex] else { return }
        e.lastSeenMs = nowMs()
        entries[hex] = e
        persistEntries()
    }

    /// Rename a relay (user-facing label only).
    func rename(_ hex: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var e = entries[hex], !trimmed.isEmpty else { return }
        e.name = trimmed
        entries[hex] = e
        persistEntries()
    }

    /// Pick a relay as the all-circles default (every present + future circle inherits it).
    func setDefault(_ hex: String?) {
        if let hex { ensureEntry(hex, activate: true) }
        defaultNodeHex = hex
    }

    /// Whether the user has FORGOTTEN/deactivated this relay — auto-learn checks this and skips so a
    /// just-deactivated relay isn't immediately re-added by a passive announce. (A deliberate re-announce
    /// REACTIVATES it via handleRelayNode rather than being permanently ignored.)
    func isForgotten(_ nodeHex: String) -> Bool {
        suppressed.contains(nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Clear a relay's FORGOTTEN tombstone (an explicit adoption / reactivation overrides a prior Forget).
    func unforget(_ nodeHex: String) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hadTombstone = suppressed.remove(hex) != nil
        let hadForget = forgotAt.removeValue(forKey: hex) != nil
        if hadTombstone || hadForget {
            // DIAGNOSTIC: something is un-forgetting a relay the user deleted. Log the caller chain so
            // we can find the resurrection path (frames past the RelayMailboxStore internals).
            let caller = Thread.callStackSymbols.dropFirst(1).prefix(6)
                .map { $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.dropFirst(3).joined(separator: " ") }
                .joined(separator: " ← ")
            HavenLog.relay("UNFORGET \(hex.prefix(8)) hadForget=\(hadForget) ⟵ \(caller)")
        }
        if hadForget { UserDefaults.standard.set(forgotAt, forKey: forgotAtKey) }
        // Record the re-add as a CLEAR so self-sync supersedes a sibling's stale deletion tombstone.
        if hadTombstone || hadForget {
            clearedRelayForgets[hex] = nowMs()
            UserDefaults.standard.set(clearedRelayForgets, forKey: clearedRelayForgetsKey)
        }
        guard hadTombstone else { return }
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
    }

    /// Reactivate a deactivated relay: flip active=true and clear its suppression so it's dialed again.
    /// `adoptedAtMs`: 0 = explicit local reactivation (stamp now()); non-zero = the announce's stamp.
    func reactivate(_ hex: String, adoptedAtMs: UInt64 = 0) {
        unforget(hex)
        ensureEntry(hex, activate: true, adoptedAtMs: adoptedAtMs == 0 ? nowMs() : adoptedAtMs)
        RelayHealth.shared.forget(hex)   // clear any stale backoff so it's retried immediately
        objectWillChange.send()
    }

    /// Drop a single relay's ASSOCIATION with a circle (deactivates the entry if no circle uses it now).
    func remove(circleId: String, nodeHex: String) {
        guard var list = relaysByCircle[circleId] else { return }
        list.removeAll { $0 == nodeHex }
        if list.isEmpty { relaysByCircle[circleId] = nil } else { relaysByCircle[circleId] = list }
        UserDefaults.standard.set(relaysByCircle, forKey: key)
        objectWillChange.send()
    }

    /// DEACTIVATE a relay across EVERY circle (mirrors the old "forget" entry point, but non-destructive):
    /// flip active=false, keep its name + circle associations, suppress auto-relearn while inactive, and
    /// drop its cached connection + health. The config survives so it can be reactivated later.
    func forget(nodeHex: String) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if var e = entries[hex] { e.active = false; entries[hex] = e }
        else { entries[hex] = RelayEntry(hex: hex, name: Self.shortName(hex), active: false, lastSeenMs: nowMs(), isS3: hex.hasPrefix("s3:")) }
        // Keep relaysByCircle + the default intact — only the active flag changes. (relays(forCircle:)
        // already filters inactive entries out, so it stops being dialed/served immediately.)
        suppressed.insert(hex)
        forgotAt[hex] = nowMs()   // LWW stamp: a re-announce only wins if it was (re-)added AFTER this
        clearedRelayForgets.removeValue(forKey: hex)   // a fresh deletion supersedes any prior re-add clear
        persistEntries()
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        UserDefaults.standard.set(forgotAt, forKey: forgotAtKey)
        UserDefaults.standard.set(clearedRelayForgets, forKey: clearedRelayForgetsKey)
        RelayClients.forget(hex)
        RelayHealth.shared.forget(hex)
        objectWillChange.send()
    }

    /// Relays the user FORGOT but which are still recoverable — `forget` only clears the active
    /// flag and keeps the entry plus its circle associations, so everything needed to bring one
    /// back is still on disk. `eraseNow` is the one that is genuinely gone (entry removed), and
    /// those correctly do not appear here.
    var recoverableRelays: [RelayEntry] {
        entries.values
            .filter { !$0.active && (forgotAt[$0.hex] ?? 0) > 0 }
            .sorted { ($0.name.isEmpty ? $0.hex : $0.name) < ($1.name.isEmpty ? $1.hex : $1.name) }
    }

    /// Undo a `forget`. Clears the suppression + the LWW deletion stamp and stamps a re-add at NOW,
    /// which is what stops a sibling device's older `relay-removal:` record from simply forgetting
    /// it again on the next self-sync pass (same mechanism `clearForget` uses when a re-add arrives
    /// from another device — see the CLEARED-FORGET path).
    func restore(nodeHex: String) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard var e = entries[hex] else { return }   // erased for good — nothing to recover
        e.active = true
        e.lastSeenMs = nowMs()
        entries[hex] = e
        suppressed.remove(hex)
        forgotAt.removeValue(forKey: hex)
        clearedRelayForgets[hex] = nowMs()
        persistEntries()
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        UserDefaults.standard.set(forgotAt, forKey: forgotAtKey)
        UserDefaults.standard.set(clearedRelayForgets, forKey: clearedRelayForgetsKey)
        MediaBackupLedger.forgetDest(hex)   // re-mirror media to it; its copy may be stale or gone
        HavenLog.relay("RESTORED relay \(hex.prefix(8)) — un-forgotten by the user")
        objectWillChange.send()
    }

    /// Relays the user DELETED that can still be brought back, newest deletion first.
    ///
    /// Two sources. The ARCHIVE holds full records (name + the circles it served) but only for
    /// deletions made since it existed. Everything deleted before that left only its LWW tombstone
    /// in `forgotAt` — which is still enough to bring the relay back, because a relay IS its node
    /// id: the name is cosmetic and the circle list is re-derivable. Without this second source the
    /// feature would have shipped showing an empty list to anyone who deleted a relay yesterday.
    ///
    /// The 30-day TTL applies only to the archive. A legacy tombstone has no other home and is
    /// shown regardless of age, capped so this can't become an unbounded wall of hex.
    var erasedRelays: [ErasedRelay] {
        let cutoff = nowMs() &- Self.erasedTtlMs
        var out = erased.values.filter { $0.erasedAt > cutoff }
        for (hex, at) in forgotAt where at > 0 && entries[hex] == nil && erased[hex] == nil {
            out.append(ErasedRelay(
                entry: RelayEntry(hex: hex, name: Self.shortName(hex), active: false,
                                  lastSeenMs: at, isS3: hex.hasPrefix("s3:")),
                circles: [], wasDefault: false, erasedAt: at))
        }
        return Array(out.sorted { $0.erasedAt > $1.erasedAt }.prefix(20))
    }

    /// Whether we hold a FULL archived record for this hex (name + circles), as opposed to a bare
    /// legacy tombstone — the caller restores those two differently.
    func hasErasedRecord(_ nodeHex: String) -> Bool { erased[nodeHex] != nil }

    /// Undo a "Delete now": put the entry, its circle associations and (if it held it) the default pick
    /// back, and clear the suppression/deletion stamps the same way `restore` does — otherwise the very
    /// next self-sync pass would read our own tombstone and delete it again.
    func restoreErased(_ nodeHex: String) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let rec = erased.removeValue(forKey: hex) else { return }
        var e = rec.entry
        e.active = true
        e.lastSeenMs = nowMs()
        e.addedAtMs = nowMs()   // a re-add stamped NOW beats any sibling's older removal record
        entries[hex] = e
        for cid in rec.circles where !(relaysByCircle[cid]?.contains(hex) ?? false) {
            relaysByCircle[cid, default: []].append(hex)
        }
        if rec.wasDefault, defaultNodeHex == nil { defaultNodeHex = hex }
        suppressed.remove(hex)
        forgotAt.removeValue(forKey: hex)
        clearedRelayForgets[hex] = nowMs()
        persistEntries()
        persistErased()
        UserDefaults.standard.set(relaysByCircle, forKey: key)
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        UserDefaults.standard.set(forgotAt, forKey: forgotAtKey)
        UserDefaults.standard.set(clearedRelayForgets, forKey: clearedRelayForgetsKey)
        MediaBackupLedger.forgetDest(hex)   // its copy of our media may be stale or gone — re-mirror
        RelayHealth.shared.forget(hex)      // clear any stale backoff so it is retried immediately
        HavenLog.relay("RESTORED deleted relay \(hex.prefix(8)) circles=\(rec.circles.count)")
        objectWillChange.send()
    }

    /// Forget an archived deletion for good (the user chose not to keep the undo around).
    func dropErased(_ nodeHex: String) {
        guard erased.removeValue(forKey: nodeHex) != nil else { return }
        persistErased()
        objectWillChange.send()
    }

    private func pruneErased() {
        let cutoff = nowMs() &- Self.erasedTtlMs
        erased = erased.filter { $0.value.erasedAt > cutoff }
        let excess = erased.count - Self.erasedKeepMax
        if excess > 0 {
            for r in erased.values.sorted(by: { $0.erasedAt < $1.erasedAt }).prefix(excess) {
                erased.removeValue(forKey: r.entry.hex)
            }
        }
    }

    private func persistErased() {
        if let data = try? JSONEncoder().encode(erased) { UserDefaults.standard.set(data, forKey: erasedKey) }
    }

    /// ERASE a relay for good — removes its associations across every circle, its entry, the default, and
    /// its caches. Used by "Delete now" in the Relays screen and by purgeStale.
    func eraseNow(_ nodeHex: String) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for cid in relaysByCircle.keys {
            relaysByCircle[cid]?.removeAll { $0 == hex }
            if relaysByCircle[cid]?.isEmpty == true { relaysByCircle[cid] = nil }
        }
        // Archive BEFORE the entry and its associations are dropped — afterwards there is nothing
        // left to reconstruct it from.
        if let e = entries[hex] {
            erased[hex] = ErasedRelay(entry: e,
                                      circles: relaysByCircle.filter { $0.value.contains(hex) }.map(\.key),
                                      wasDefault: defaultNodeHex == hex,
                                      erasedAt: nowMs())
            pruneErased()
        }
        if defaultNodeHex == hex { defaultNodeHex = nil }
        entries[hex] = nil
        suppressed.insert(hex)
        // Stamp the deletion so it SYNCS to my other devices (self-sync `relay-removal:` iterates
        // forgotAt) — otherwise "Delete now" was device-local, a sibling kept the relay and re-announced
        // it, and it bounced back forever. And drop any stale re-add clear so a fresh delete wins LWW.
        forgotAt[hex] = nowMs()
        let hadClear = clearedRelayForgets.removeValue(forKey: hex) != nil
        UserDefaults.standard.set(relaysByCircle, forKey: key)
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        UserDefaults.standard.set(forgotAt, forKey: forgotAtKey)
        if hadClear { UserDefaults.standard.set(clearedRelayForgets, forKey: clearedRelayForgetsKey) }
        persistEntries()
        persistErased()
        MediaBackupLedger.forgetDest(hex)   // relay gone for good → re-mirror if this id ever returns
        RelayClients.forget(hex)
        RelayHealth.shared.forget(hex)
        objectWillChange.send()
    }

    /// ERASE only entries that are BOTH inactive AND unseen for > 7 days. An ACTIVE relay that's merely
    /// unreachable is never purged. Called on launch + on the sync timer.
    func purgeStale(nowMs now: UInt64? = nil) {
        let cutoff = now ?? nowMs()
        let dead = entries.values.filter { !$0.active && (cutoff &- $0.lastSeenMs) > Self.staleAfterMs }
        for e in dead { eraseNow(e.hex) }
    }

    /// Remove every relay association for a circle (deactivates nothing else; entries linger for reuse).
    func clear(circleId: String) {
        relaysByCircle[circleId] = nil
        UserDefaults.standard.set(relaysByCircle, forKey: key)
    }
    /// Circles (other than `excluding`) that have an explicit ACTIVE relay — for "copy another circle".
    func circlesWithRelay(excluding: String) -> [String] {
        relaysByCircle.filter { $0.key != excluding && $0.value.contains(where: { isActive($0) }) }.map(\.key)
    }
    /// Seed this device's relays from a transfer/link code so a freshly-linked device has a transport
    /// to bootstrap from. Stored under a synthetic circle so `allRelays()` returns them all; the first
    /// SelfSync pull then learns the real circles and registers their relays. (Doesn't appear in the
    /// circles UI — that comes from the social graph, not this store.)
    func adoptBootstrapRelays(_ hexes: [String]) {
        // NEVER auto-adopt a relay the user DELETED — add() would un-forget it, resurrecting a deleted
        // relay on every launch (bootstrap runs at account load). A deleted relay only comes back on an
        // explicit user re-add.
        for h in hexes where !isForgotten(h) { add(circleId: "__bootstrap__", nodeHex: h) }
        if defaultNodeHex == nil, let first = hexes.first(where: { $0.count == 64 && !isForgotten($0) }) { defaultNodeHex = first }
    }

    /// Every distinct ACTIVE relay across all circles — for mesh sync / the active transport set.
    func allRelays() -> [String] {
        var seen: [String] = []
        for list in relaysByCircle.values { for h in list where isActive(h) && !seen.contains(h) { seen.append(h) } }
        if let def = defaultNodeHex, !def.isEmpty, isActive(def), !seen.contains(def) { seen.append(def) }
        return seen
    }

    /// Every configured relay (active + inactive), sorted active-first then by name — for the Relays screen.
    func allEntries() -> [RelayEntry] {
        entries.values.sorted { a, b in
            if a.active != b.active { return a.active && !b.active }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// Per-relay exponential backoff so a dead relay is skipped and auto-recovers — a 1:1 port of the
/// desktop `RelayHealth` (5s base, ×2 each failure, capped at 5m; success clears it).
@MainActor
final class RelayHealth: ObservableObject {
    static let shared = RelayHealth()
    private init() {}

    private struct Health { var fails: UInt32 = 0; var nextRetryMs: UInt64 = 0; var lastSuccessMs: UInt64 = 0 }
    private var byNode: [String: Health] = [:]

    private static let baseBackoffMs: UInt64 = 5_000     // first failure → 5s cool-off
    private static let maxBackoffMs: UInt64 = 300_000    // capped at 5 minutes
    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Is the relay usable right now (not inside a backoff window)? Unknown relays are available.
    func available(_ nodeHex: String) -> Bool {
        guard let h = byNode[nodeHex] else { return true }
        return nowMs() >= h.nextRetryMs
    }
    /// Did WE personally complete a successful op against this relay within `withinMs`? In-memory
    /// only (resets on relaunch) — deliberately strict, it gates what we re-announce to the circle:
    /// vouching for a relay we haven't actually reached lately is how dead relay ids echoed around
    /// the mesh forever ("old relays keep coming back and report reachable").
    func provenAlive(_ nodeHex: String, withinMs: UInt64) -> Bool {
        guard let t = byNode[nodeHex]?.lastSuccessMs, t > 0 else { return false }
        return nowMs() &- t <= withinMs
    }
    /// A successful op clears the backoff (and stamps proof-of-life for announce gating).
    func recordSuccess(_ nodeHex: String) {
        byNode[nodeHex] = Health(fails: 0, nextRetryMs: 0, lastSuccessMs: nowMs())
        objectWillChange.send()
    }
    /// A failure grows the backoff exponentially (5s, 10s, 20s … capped at 5m).
    ///
    /// Proof-of-life is cleared only after **two** consecutive failures: a single free-CF DNS miss
    /// or one cold dial used to zero `lastSuccessMs` and paint the relay orange, then the next
    /// HTTP poll greened it again — the iPhone "cycling unreachable / reachable" UI. One blip
    /// still backs off retries; two in a row drop proven-alive.
    func recordFailure(_ nodeHex: String) {
        var h = byNode[nodeHex] ?? Health()
        h.fails = h.fails == UInt32.max ? h.fails : h.fails + 1
        let shift = UInt64(min(h.fails - 1, 6))   // cap the exponent so the shift never overflows
        let backoff = min(Self.baseBackoffMs * (1 << shift), Self.maxBackoffMs)
        h.nextRetryMs = nowMs() + backoff
        if h.fails >= 2 {
            h.lastSuccessMs = 0   // no longer proven alive after repeated failure
        }
        byNode[nodeHex] = h
        objectWillChange.send()
    }
    func forget(_ nodeHex: String) { byNode[nodeHex] = nil; objectWillChange.send() }
}

/// Caches connected `RelayClient`s by relay node id (connecting is async + reusable). Skips a relay
/// that's currently in its backoff window (health-aware), and records success/failure so a dead
/// relay backs off and a recovered one is picked up again.
@MainActor
enum RelayClients {
    private static var cache: [String: RelayClient] = [:]
    /// A connected client for a relay, honoring per-relay backoff. nil if in backoff or unreachable.
    static func client(_ nodeHex: String) async -> RelayClient? {
        if let c = cache[nodeHex] { return c }
        // NEVER dial our OWN DEVICE node id (our iroh transport id — Option 1). A node dialing itself
        // sends iroh's path discovery into a tight loop (open_path_on_all_conns), exploding memory by tens
        // of GB — THE runaway leak. We never need a client to ourselves: our own events go to the local
        // mailbox, and own-device sync rides the nearby mesh. Distinct per-device ids mean a SIBLING
        // device's relay is a different id, so we CAN read it (no longer stranded).
        let mine = FeedStore.shared.transportNodeHex.lowercased()   // our OWN relay's id (account id if host, else device id)
        if !mine.isEmpty, nodeHex.lowercased() == mine { return nil }
        // We CONNECT below as our ACCOUNT identity (storedSeed), so dialing a relay whose id == our own
        // ACCOUNT id is the account dialing ITSELF — the same iroh path-discovery runaway (tens of GB). Under
        // the device-seed transport the guard above only catches our DEVICE id, so a stale relay entry equal
        // to our account id (left over from the pre-device-seed transport, when the relay WAS the account id)
        // would self-connect and leak. Skip it explicitly.
        let myAccount = AccountStore.currentNodeHex().lowercased()
        if !myAccount.isEmpty, nodeHex.lowercased() == myAccount { return nil }
        if RelayHost.shared.serving, !RelayHost.shared.nodeId.isEmpty, nodeHex == RelayHost.shared.nodeId {
            return nil
        }
        guard RelayHealth.shared.available(nodeHex) else { return nil }   // skip relays in backoff
        // Dial the relay over our NODE's warm, DERP-established endpoint (node.relayClient) — NOT a fresh
        // RelayClient.connect endpoint. A fresh per-fetch endpoint cold-starts its own DERP relay handshake
        // every time, so cross-network relay GETs timed out at 30s even while the long-lived messaging
        // endpoint on the same node showed "Connected · Relay". Reusing that warm endpoint is what lets media
        // fetches actually complete over the internet. (Peer identity is now our device id; media keys are
        // permissive so they serve regardless, and mailbox auth expands to device ids via the roster.)
        guard let node = FeedStore.shared.transportNode else { return nil }
        // `relayClient` is async now: it hands back the node's CACHED blob client (shared with the
        // relay mesh) instead of minting a fresh, cold one per call.
        guard let c = try? await node.relayClient(relayNodeHex: nodeHex) else {
            RelayHealth.shared.recordFailure(nodeHex)
            HavenLog.relay("dial relay \(nodeHex.prefix(10)) → CONNECT FAIL")
            return nil
        }
        // DO NOT record proof-of-life here. `node.relayClient(...)` is a LAZY constructor that does ZERO
        // network I/O — the QUIC connection is established on the first real op. Recording success on it
        // marked ANY well-formed node id "reachable" (dead relays showed a green dot), and vouched for
        // dead ids in the re-announce gate. Proof-of-life is stamped by the ACTUAL ops (put/get/list/has/
        // touch) at their call sites once bytes really move. Getting a client == "dialable", not "alive".
        HavenLog.relay("dial relay \(nodeHex.prefix(10)) → client ready (unverified until first op)")
        cache[nodeHex] = c
        return c
    }
    /// Drop a relay's cached client. ONLY for a DELIBERATE removal — never for a failed op.
    ///
    /// Discarding it on a timeout was self-reinforcing: the op times out after 30s, the client is
    /// thrown away, the next attempt builds a fresh one, that dials COLD — starting on the DERP relay
    /// path, because no direct path is punched yet — times out in turn, and is thrown away again. The
    /// connection is destroyed by the very failure it needs to survive in order to fix itself, so it
    /// never lives long enough for iroh to promote it to a direct path. Blob traffic then stays pinned
    /// to a relay route that drops its datagrams cross-NAT, which is why the mailbox — and therefore
    /// every offline delivery — was dead between networks while peer-to-peer kept working.
    ///
    /// Keeping the client costs nothing: `BlobClient::conn()` re-dials by itself if the connection has
    /// genuinely dropped, and `RelayHealth` backoff still throttles how often we try a sick relay.
    /// (Same fix as e91ee62 on the relay-to-relay mesh tick; this is the app-side half.)
    static func forget(_ nodeHex: String) { cache[nodeHex] = nil }

    /// Drop EVERY cached client — mandatory whenever the underlying `HavenNode` is replaced or torn
    /// down.
    ///
    /// A cached `RelayClient` wraps a `BlobClient` built over that node's iroh endpoint. When the
    /// node is shut down the endpoint closes, and every op on a client still holding it fails with
    /// "endpoint stopping" — forever, because nothing here noticed. The Rust side already clears its
    /// own blob-client cache on `Node::shutdown` (core/haven-net/src/lib.rs); this cache never did,
    /// so a single fabric rebind silently killed relay I/O for the rest of the process:
    /// `BlobClient::conn` stamped a dial failure, the cooldown escalated 60s → 900s, and because
    /// `has()` reported a transport error as "the relay does not have it", every media backfill
    /// re-queued an upload that then bailed instantly on the cooldown. The own relay's local copy
    /// still said `landed`, so the job was reported a success and dropped. That is why posts,
    /// media and DMs stopped crossing while the app looked healthy.
    static func clearAll() {
        guard !cache.isEmpty else { return }
        HavenLog.relay("relay clients: dropping \(cache.count) cached client(s) — transport replaced")
        cache.removeAll()
    }
}
