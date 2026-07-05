import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if os(macOS) || targetEnvironment(macCatalyst)
import ServiceManagement
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
    private let d = UserDefaults.standard
    private let enabledKey = "haven.relay.host.enabled"

    private init() { enabled = d.bool(forKey: enabledKey) }

    /// Whether this kind of device makes a good always-on relay (informs the UI copy).
    var isDesktopClass: Bool {
        #if targetEnvironment(macCatalyst)
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

    func setEnabled(_ on: Bool) {
        enabled = on
        d.set(on, forKey: enabledKey)
        if on { start() } else { stop() }
    }

    /// Restart the relay at launch if the user had it on.
    func startIfEnabled() { if enabled && handle == nil { start() } }

    private func start() {
        guard handle == nil else { return }
        // The relay now ATTACHES to the messaging node's endpoint (one iroh node, two ALPNs) — running a
        // second in-process iroh node is what made iroh churn paths unboundedly (the tens-of-GB leak).
        guard let node = FeedStore.shared.transportNode else {
            // Node not up yet — retry shortly; the relay can't exist without the node to attach to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.start() }
            return
        }
        // Keep the screen on / device awake while relaying (essential on iOS, harmless on Mac).
        PlatformIdle.disabled = true
        let h = RelayServerHandle.attach(node: node, dir: storeDir)
        handle = h
        nodeId = h.nodeIdHex()   // == the account node id now (the relay shares the node)
        serving = true
        RelayMailboxStore.shared.unforget(nodeId)   // hosting is an explicit adoption of our own relay
        // Lock the mailbox down to circle members before announcing it (audit transport-F4).
        authorizeMembership()
        // Tell my circles to use this device (its account node id) as their mailbox.
        FeedStore.shared.broadcastRelayNode(nodeId)
        HavenLog.relay("hosting relay=\(nodeId.prefix(10)) serving=\(serving)")
        startHttpInterface(h)
    }

    /// Serve the relay's store over plain HTTP — the DEFAULT cross-NAT media transport (the iroh
    /// blob ALPN drops its datagrams over a pure-relay cross-NAT path, so blob dials that must
    /// cross a NAT stall ~30s and die while messaging works). Bearer-token gated; the token travels
    /// ONLY inside the sealed frame-19 announce, so only circle members hold it. Reachable URLs =
    /// the optional user-configured public URL (UserDefaults `haven.relay.publicURL` — set it when
    /// this host is port-forwarded / reverse-proxied / tunneled) first, then every LAN IPv4.
    private func startHttpInterface(_ h: RelayServerHandle) {
        let token = httpToken()
        Task { [weak self] in
            var port: UInt16?
            do { port = try await h.serveHttp(bind: "0.0.0.0:8674", token: token) }
            catch { port = try? await h.serveHttp(bind: "0.0.0.0:0", token: token) }   // port taken → ephemeral
            guard let self, let port else { HavenLog.relay("relay http serve FAILED"); return }
            let urls = Self.reachableHttpUrls(port: port)
            HavenLog.relay("relay http on :\(port) urls=\(urls.joined(separator: " "))")
            guard !urls.isEmpty, !self.nodeId.isEmpty else { return }
            RelayMailboxStore.shared.setHttpInterface(self.nodeId, urls: urls, token: token)
            FeedStore.shared.reannounceOwnRelay()   // re-announce WITH the http interface attached
        }
    }

    /// The persisted bearer token for OUR hosted relay's HTTP interface (generated once).
    private func httpToken() -> String {
        if let t = d.string(forKey: "haven.relay.httpToken"), !t.isEmpty { return t }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let tok = bytes.map { String(format: "%02x", $0) }.joined()
        d.set(tok, forKey: "haven.relay.httpToken")
        return tok
    }

    /// URLs peers can reach our HTTP interface at: the configured public URL first, then LAN IPv4s.
    static func reachableHttpUrls(port: UInt16) -> [String] {
        var out: [String] = []
        if let pub = UserDefaults.standard.string(forKey: "haven.relay.publicURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines), pub.hasPrefix("http") {
            out.append(pub.hasSuffix("/") ? String(pub.dropLast()) : pub)
        }
        for ip in lanIPv4s() { out.append("http://\(ip):\(port)") }
        return out
    }

    /// Every up, non-loopback, non-link-local IPv4 on this device (getifaddrs).
    static func lanIPv4s() -> [String] {
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
    func localPut(_ key: String, _ data: Data) -> Bool { handle?.localPut(key: key, data: data) ?? false }
    func localHas(_ key: String) -> Bool { handle?.localHas(key: key) ?? false }
    /// Read a blob from our OWN hosted mailbox (a sibling device's / friend's upload), without dialing
    /// ourselves — the host can't poll its own relay over iroh (self-dial guard), so it reads locally.
    func localGet(_ key: String) -> Data? { handle?.localGet(key: key) }
    /// Keys under `prefix` in our own mailbox, so the host can ingest what others uploaded to it.
    func localList(_ prefix: String) -> [String] { handle?.localList(prefix: prefix) ?? [] }

    private func stop() {
        handle?.disable()      // detach the relay from the node's endpoint
        handle = nil           // releases the FFI handle (best-effort; OS reclaims on exit)
        serving = false
        nodeId = ""
        PlatformIdle.disabled = false
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
        for (cid, members) in FeedStore.shared.circleMemberships() {
            let relays = RelayMailboxStore.shared.relays(forCircle: cid)
            handle.authorizeCircle(circleId: cid, members: members, relays: relays)
        }
    }

    func meshSyncTick() {
        guard let handle, serving else { return }
        authorizeMembership() // keep the allow-list fresh as membership / relays change
        let myHex = nodeId
        // Every distinct adopted relay (≠ self) that isn't currently backed off.
        let peers = RelayMailboxStore.shared.allRelays()
            .filter { $0 != myHex && RelayHealth.shared.available($0) }
        guard !peers.isEmpty else { return }
        Task {
            for peer in peers {
                let pulled = await handle.syncFrom(peerNodeHex: peer)
                if pulled > 0 {
                    RelayHealth.shared.recordSuccess(peer)
                    RelayMailboxStore.shared.markSeen(peer)
                    FeedStore.shared.markRelay(true)
                    // New blobs landed on our store → ingest anything we hadn't seen.
                    FeedStore.shared.pollMailboxNow()
                }
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
    /// the error. No-op off Catalyst.
    func setStartAtLogin(_ on: Bool) throws {
        #if targetEnvironment(macCatalyst)
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
    /// Bearer token the relay's HTTP interface requires (travels ONLY inside sealed announces).
    var httpToken: String?
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

    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

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
        if !loaded.isEmpty { d.set(loaded, forKey: key) }
        // Load persisted entries, then migrate any relay that only exists in relaysByCircle/default
        // into a RelayEntry (active=true, short-hex name, lastSeen=now so the clock starts now).
        if let data = d.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([String: RelayEntry].self, from: data) {
            entries = decoded
        }
        migrateEntries()
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
    func add(circleId: String, nodeHex: String, name: String? = nil, isS3: Bool = false) {
        let hex = isS3 ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isS3 ? hex.hasPrefix("s3:") : hex.count == 64 else { return }
        unforget(hex)
        ensureEntry(hex, name: name, isS3: isS3, activate: true)
        var list = relaysByCircle[circleId] ?? []
        if !list.contains(hex) {
            list.append(hex)
            relaysByCircle[circleId] = list
            UserDefaults.standard.set(relaysByCircle, forKey: key)
        }
    }

    /// Create-or-update the RelayEntry for a hex. `activate` flips it on; lastSeen is stamped now on
    /// first creation so a freshly-added relay's stale-clock starts now (not 1970).
    func ensureEntry(_ hex: String, name: String? = nil, isS3: Bool = false, activate: Bool = false) {
        if var e = entries[hex] {
            if let name, !name.isEmpty { e.name = name }
            if activate { e.active = true }
            entries[hex] = e
        } else {
            entries[hex] = RelayEntry(hex: hex, name: name ?? Self.shortName(hex),
                                      active: activate ? true : true, lastSeenMs: nowMs(), isS3: isS3)
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

    /// The relay's HTTP interface (urls + token), or nil for an iroh-only relay.
    func httpInterface(_ hex: String) -> (urls: [String], token: String)? {
        guard let e = entries[hex], let t = e.httpToken, !t.isEmpty,
              let u = e.httpUrls, !u.isEmpty else { return nil }
        return (u, t)
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
        guard suppressed.remove(hex) != nil else { return }
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
    }

    /// Reactivate a deactivated relay: flip active=true and clear its suppression so it's dialed again.
    func reactivate(_ hex: String) {
        unforget(hex)
        ensureEntry(hex, activate: true)
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
        persistEntries()
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        RelayClients.forget(hex)
        RelayHealth.shared.forget(hex)
        objectWillChange.send()
    }

    /// ERASE a relay for good — removes its associations across every circle, its entry, the default, and
    /// its caches. Used by "Delete now" in the Relays screen and by purgeStale.
    func eraseNow(_ nodeHex: String) {
        let hex = nodeHex.hasPrefix("s3:") ? nodeHex : nodeHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for cid in relaysByCircle.keys {
            relaysByCircle[cid]?.removeAll { $0 == hex }
            if relaysByCircle[cid]?.isEmpty == true { relaysByCircle[cid] = nil }
        }
        if defaultNodeHex == hex { defaultNodeHex = nil }
        entries[hex] = nil
        suppressed.insert(hex)
        UserDefaults.standard.set(relaysByCircle, forKey: key)
        UserDefaults.standard.set(Array(suppressed), forKey: suppressedKey)
        persistEntries()
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
        for h in hexes { add(circleId: "__bootstrap__", nodeHex: h) }
        if defaultNodeHex == nil, let first = hexes.first(where: { $0.count == 64 }) { defaultNodeHex = first }
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
    func recordFailure(_ nodeHex: String) {
        var h = byNode[nodeHex] ?? Health()
        h.fails = h.fails == UInt32.max ? h.fails : h.fails + 1
        let shift = UInt64(min(h.fails - 1, 6))   // cap the exponent so the shift never overflows
        let backoff = min(Self.baseBackoffMs * (1 << shift), Self.maxBackoffMs)
        h.nextRetryMs = nowMs() + backoff
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
        guard let c = try? node.relayClient(relayNodeHex: nodeHex) else {
            RelayHealth.shared.recordFailure(nodeHex)
            HavenLog.relay("dial relay \(nodeHex.prefix(10)) → CONNECT FAIL")
            return nil
        }
        RelayHealth.shared.recordSuccess(nodeHex)
        RelayMailboxStore.shared.markSeen(nodeHex)
        HavenLog.relay("dial relay \(nodeHex.prefix(10)) → ok")
        cache[nodeHex] = c
        return c
    }
    /// Drop a relay's cached connection (after a failure, or when forgetting it).
    static func forget(_ nodeHex: String) { cache[nodeHex] = nil }
}
