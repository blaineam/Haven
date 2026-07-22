import Foundation
import SwiftUI
#if os(macOS)
import Darwin
import AppKit
#endif

/// macOS helper: spawn the bundled (or PATH) `cloudflared` binary as either
/// - a free **Quick Tunnel** (`*.trycloudflare.com`), or
/// - a **named** Cloudflare Tunnel using a Zero Trust install token + custom domain.
///
/// Reliability notes (free trycloudflare):
/// - Hostname is **ephemeral** — every restart gets a new `*.trycloudflare.com` URL; the old
///   one dies. Peers only learn the new URL via frame-19 reannounce.
/// - `stop()` must hard-kill *every* Haven-spawned cloudflared (tracked + orphan PIDs), not only
///   the last `Process` ref — otherwise toggle off/on leaves dual tunnels to :8674/:3340 and the
///   public URL never points at the path proxy again.
///
/// App Store note: ship `cloudflared` under `Contents/Helpers/` and code-sign it with the same
/// team identity as HavenMac. The binary is Apache-2.0 (Cloudflare). iOS has no helper-exec path —
/// this type is a no-op there.
@MainActor
final class CloudflaredTunnel: ObservableObject {
    static let shared = CloudflaredTunnel()

    // Foundation.Process (subprocess spawn) exists on macOS only — never declare it on iOS
    // or Xcode Cloud's Haven iOS archive fails with "Cannot find type 'Process' in scope".
    #if os(macOS)
    private var process: Process?
    /// Second free trycloudflare for the embedded DERP fabric bind (one origin per process).
    /// Prefer path-router single-tunnel mode; dual free tunnels are fallback only.
    private var derpProcess: Process?
    /// Local origin we last pointed the *main* tunnel at (e.g. `http://127.0.0.1:8675`).
    private(set) var lastLocalHTTP: String?
    /// Persisted so a crash / lost Process ref still gets cleaned on next start/stop.
    private let pidDefaultsKey = "haven.relay.cloudflaredPids"
    #endif
    /// Live public URL from a spawned tunnel (trycloudflare or named). Settings UI shows this.
    @Published private(set) var publicURL: String?
    /// Live public URL for the DERP fabric quick tunnel (if any).
    /// Only set in dual free-tunnel fallback — when path proxy works this stays nil and
    /// fabric shares `publicURL`.
    @Published private(set) var derpPublicURL: String?
    /// True when the main tunnel targets the unified path proxy (`:8675`) so media + DERP +
    /// hairpin share one public origin. False when dual free tunnels (or media-only) are used.
    @Published private(set) var usesPathProxy = false
    /// Local origin the main connector targets, e.g. `http://127.0.0.1:8675`.
    @Published private(set) var localFrontDoor: String?
    /// Non-nil when a second free trycloudflare was started (path proxy unavailable). Shown in UI
    /// so dual tunnels are never invisible.
    @Published private(set) var dualTunnelNote: String?
    /// True when system DNS (getaddrinfo) cannot resolve the live free hostname (NXDOMAIN /
    /// "nodename nor servname") even though cloudflared is up. Common with router DNS filters —
    /// Safari and peers on the same network will also fail. DoH may still resolve the name.
    @Published private(set) var freeTunnelDNSBroken = false
    /// Human-readable DNS diagnosis for Settings (nil when healthy / not applicable).
    @Published private(set) var freeTunnelDNSNote: String?
    /// Absolute path of the main cloudflared log file (media / path-proxy tunnel).
    @Published private(set) var mainLogPath: String?
    /// Absolute path of the DERP dual-tunnel log (nil when single path-proxy).
    @Published private(set) var derpLogPath: String?
    /// Absolute path of our DNS diagnosis log (system vs DoH for free hostnames).
    @Published private(set) var dnsLogPath: String?

    /// Front-door policy: `auto` | `manual` | `bundled` (see docs/CLOUDFLARE-TUNNEL.md).
    /// Manual is first-class: operator runs any tunnel/proxy; Haven only announces the URL.
    var frontDoorMode: String {
        get {
            let s = (UserDefaults.standard.string(forKey: "haven.relay.frontDoor") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == "manual" || s == "bundled" || s == "auto" { return s }
            // Legacy inference when mode key missing.
            if !configuredPublicURL.isEmpty {
                return tunnelToken.isEmpty ? "manual" : "bundled"
            }
            return "auto"
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            UserDefaults.standard.set(
                (v == "manual" || v == "bundled") ? v : "auto",
                forKey: "haven.relay.frontDoor"
            )
            // Keep autoTunnel in sync for older readers.
            autoEnabled = (frontDoorMode == "auto")
            objectWillChange.send()
        }
    }

    /// When true (default) and mode is auto with no custom domain, start free trycloudflare.
    var autoEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "haven.relay.autoTunnel") == nil { return true }
            return UserDefaults.standard.bool(forKey: "haven.relay.autoTunnel")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "haven.relay.autoTunnel")
            objectWillChange.send()
        }
    }

    /// Custom domain the circle should use (e.g. `https://relay.example.com`).
    var configuredPublicURL: String {
        get {
            (UserDefaults.standard.string(forKey: "haven.relay.publicURL") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { UserDefaults.standard.removeObject(forKey: "haven.relay.publicURL") }
            else { UserDefaults.standard.set(t, forKey: "haven.relay.publicURL") }
            objectWillChange.send()
        }
    }

    /// Cloudflare Zero Trust tunnel install token (dashboard → Tunnels → Install connector).
    /// Used only in **bundled** mode.
    var tunnelToken: String {
        get {
            (UserDefaults.standard.string(forKey: "haven.relay.cfTunnelToken") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { UserDefaults.standard.removeObject(forKey: "haven.relay.cfTunnelToken") }
            else { UserDefaults.standard.set(t, forKey: "haven.relay.cfTunnelToken") }
            objectWillChange.send()
        }
    }

    /// Result of applying front-door prefs for this host start.
    struct FrontDoorResult {
        /// URL to put first in the announce list (if any).
        var announceURL: String?
        /// True when we spawned cloudflared (quick or named).
        var spawnedConnector: Bool
    }

    /// Record whether this front-door cycle uses the path proxy (single public origin).
    /// Call before/around `apply` so the UI can explain one vs two cloudflared processes.
    func setFrontDoorLayout(pathProxy: Bool, localPort: UInt16, dualNote: String? = nil) {
        usesPathProxy = pathProxy
        localFrontDoor = "http://127.0.0.1:\(localPort)"
        dualTunnelNote = dualNote
        if pathProxy {
            // Single-origin: clear any stale dual-DERP URL from a previous start.
            derpPublicURL = nil
        }
        objectWillChange.send()
    }

    /// Apply front-door mode. Manual never spawns cloudflared — only returns the announce URL.
    /// Always cleans orphans first so a previous toggle cannot leave dual free tunnels alive.
    ///
    /// Prefer calling with the **path-proxy port (8675)** when the router is up — one free tunnel
    /// then covers media + DERP. Dual free tunnels are only started via `startQuickDerp` when the
    /// path proxy is unavailable.
    func apply(port: UInt16) async -> FrontDoorResult {
        await stopFully()
        // Brief settle so the previous free hostname/edge releases before we mint a new one.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #if os(macOS)
        let mode = frontDoorMode
        let domain = Self.normalizePublicURL(configuredPublicURL)
        switch mode {
        case "manual":
            // Operator's tunnel/proxy — durable path if free/token Cloudflare goes away.
            return FrontDoorResult(announceURL: domain, spawnedConnector: false)
        case "bundled":
            guard let domain, !tunnelToken.isEmpty else {
                HavenLog.relay("cloudflared: bundled mode needs domain + tunnel token")
                return FrontDoorResult(announceURL: domain, spawnedConnector: false)
            }
            if let u = await startNamed(token: tunnelToken, publicURL: domain) {
                return FrontDoorResult(announceURL: u, spawnedConnector: true)
            }
            return FrontDoorResult(announceURL: domain, spawnedConnector: false)
        default: // auto
            if let domain, !tunnelToken.isEmpty {
                if let u = await startNamed(token: tunnelToken, publicURL: domain) {
                    return FrontDoorResult(announceURL: u, spawnedConnector: true)
                }
            }
            if let domain {
                return FrontDoorResult(announceURL: domain, spawnedConnector: false)
            }
            guard autoEnabled else {
                return FrontDoorResult(announceURL: nil, spawnedConnector: false)
            }
            if let u = await startQuick(port: port) {
                return FrontDoorResult(announceURL: u, spawnedConnector: true)
            }
            return FrontDoorResult(announceURL: nil, spawnedConnector: false)
        }
        #else
        // iOS: announce-only public URL if set.
        let domain = Self.normalizePublicURL(configuredPublicURL)
        return FrontDoorResult(announceURL: domain, spawnedConnector: false)
        #endif
    }

    /// Start the right tunnel for current prefs. Returns the public HTTPS URL to announce, or nil.
    @available(*, deprecated, message: "Use apply(port:) for manual vs bundled vs auto")
    func start(port: UInt16) async -> String? {
        await apply(port: port).announceURL
    }

    /// True when the main connector Process is still running (named or quick).
    var isMainConnectorAlive: Bool {
        #if os(macOS)
        process?.isRunning == true
        #else
        false
        #endif
    }

    /// True when we currently claim a public URL that requires a live connector.
    var expectsLiveConnector: Bool {
        #if os(macOS)
        if frontDoorMode == "manual" { return false }
        if process != nil { return true }
        let url = publicURL ?? ""
        if url.contains("trycloudflare.com") { return true }
        if !tunnelToken.isEmpty, !(configuredPublicURL.isEmpty) { return true }
        return false
        #else
        false
        #endif
    }

    /// Fire-and-forget stop for UI toggle — kills on a background queue.
    func stop() {
        #if os(macOS)
        let main = process
        let derp = derpProcess
        process = nil
        publicURL = nil
        lastLocalHTTP = nil
        derpProcess = nil
        derpPublicURL = nil
        usesPathProxy = false
        localFrontDoor = nil
        dualTunnelNote = nil
        freeTunnelDNSBroken = false
        freeTunnelDNSNote = nil
        // Keep log paths published so Settings can still open them after stop.
        persistTrackedPids([])
        DispatchQueue.global(qos: .userInitiated).async {
            Self.hardStopProcess(main)
            Self.hardStopProcess(derp)
            Self.killOrphanCloudflareds(except: [])
        }
        #endif
    }

    /// Directory for cloudflared + DNS diagnosis logs (`Application Support/Haven/logs`).
    nonisolated static func logsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Open the logs folder in Finder (macOS).
    func revealLogsInFinder() {
        #if os(macOS)
        let dir = Self.logsDirectory()
        NSWorkspace.shared.open(dir)
        #endif
    }

    /// Awaitable full teardown — used before re-applying a front door so a new tunnel never
    /// races dual free tunnels still dying from the previous start.
    /// Does **not** clear layout flags (`usesPathProxy` / dual note) — those are set by the host
    /// before the next `apply` so the UI keeps explaining the planned layout during reconnect.
    func stopFully() async {
        #if os(macOS)
        let main = process
        let derp = derpProcess
        process = nil
        publicURL = nil
        lastLocalHTTP = nil
        derpProcess = nil
        // Keep derpPublicURL until host replaces layout — UI should not flash empty mid-recover.
        // Layout fields cleared only on full `stop()` (hosting off).
        persistTrackedPids([])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Self.hardStopProcess(main)
                Self.hardStopProcess(derp)
                Self.killOrphanCloudflareds(except: [])
                cont.resume()
            }
        }
        #endif
    }

    /// Free trycloudflare for a second local port (DERP fabric). Does **not** stop the media tunnel.
    /// Only use when the path router is unavailable (true dual-origin fallback).
    ///
    /// Sets `derpPublicURL` + `dualTunnelNote` so Settings shows **both** live hostnames —
    /// dual free tunnels must never be invisible.
    func startQuickDerp(port: UInt16) async -> String? {
        #if os(macOS)
        stopDerpOnly()
        usesPathProxy = false
        guard let bin = Self.findBinary() else {
            HavenLog.relay("cloudflared: binary not found for DERP tunnel")
            return nil
        }
        let local = "http://127.0.0.1:\(port)"
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["tunnel", "--url", local, "--no-autoupdate", "--protocol", "http2"]
        let ready = ReadyBox()
        guard attachDerp(proc: proc, ready: ready) else { return nil }

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let url = ready.url {
                derpPublicURL = url
                rememberPid(proc.processIdentifier)
                let media = publicURL ?? "(media tunnel)"
                dualTunnelNote =
                    "Path proxy unavailable — two free tunnels: media \(media) → "
                    + (localFrontDoor ?? "http://127.0.0.1:8674")
                    + "; DERP fabric \(url) → \(local)"
                HavenLog.relay(
                    "cloudflared: dual free tunnel (DERP) \(url) → \(local) "
                        + "(media \(media)); UI shows both URLs"
                )
                objectWillChange.send()
                return url
            }
            if !proc.isRunning {
                HavenLog.relay("cloudflared: DERP tunnel exited before printing a URL")
                derpProcess = nil
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        HavenLog.relay("cloudflared: timed out waiting for DERP trycloudflare URL")
        stopDerpOnly()
        return nil
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private func stopDerpOnly() {
        let derp = derpProcess
        derpProcess = nil
        derpPublicURL = nil
        // Drop DERP pid from the persisted set while keeping main.
        var keep: [Int32] = []
        if let p = process, p.isRunning { keep.append(p.processIdentifier) }
        persistTrackedPids(keep)
        let keepSet = Set(keep)
        DispatchQueue.global(qos: .userInitiated).async {
            Self.hardStopProcess(derp)
            Self.killOrphanCloudflareds(except: keepSet)
        }
    }

    private func attachDerp(proc: Process, ready: ReadyBox) -> Bool {
        let logURL = Self.prepareLogFile(name: "cloudflared-derp.log")
        derpLogPath = logURL.path
        Self.appendLogFile(logURL, line: "── spawn DERP dual tunnel \(ISO8601DateFormatter().string(from: Date())) ──")
        // Official file log + pipe tee (URL scrape still needs the pipe).
        var args = proc.arguments ?? []
        if !args.contains("--logfile") {
            args.insert(contentsOf: ["--logfile", logURL.path, "--loglevel", "info"], at: 0)
            proc.arguments = args
        }
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        let onData: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            // Append — cloudflared often splits the trycloudflare line across pipe reads.
            ready.appendLog(chunk)
            Self.appendLogFile(logURL, text: chunk)
            if let url = ready.url ?? Self.extractTrycloudflareURL(ready.logText) {
                ready.url = url
            }
        }
        out.fileHandleForReading.readabilityHandler = onData
        err.fileHandleForReading.readabilityHandler = onData
        do {
            try proc.run()
            derpProcess = proc
            HavenLog.relay("cloudflared: DERP log → \(logURL.path)")
            return true
        } catch {
            HavenLog.relay("cloudflared: DERP spawn failed \(error.localizedDescription)")
            return false
        }
    }

    private func startQuick(port: UInt16) async -> String? {
        guard let bin = Self.findBinary() else {
            HavenLog.relay("cloudflared: binary not found (bundle Helpers/ or PATH)")
            return nil
        }
        let local = "http://127.0.0.1:\(port)"
        lastLocalHTTP = local
        let logURL = Self.prepareLogFile(name: "cloudflared-main.log")
        mainLogPath = logURL.path
        Self.appendLogFile(
            logURL,
            line: "── spawn quick tunnel \(ISO8601DateFormatter().string(from: Date())) → \(local) ──"
        )
        let proc = Process()
        proc.executableURL = bin
        // --logfile is a global flag; put it before `tunnel` so cloudflared always writes disk logs.
        proc.arguments = [
            "--logfile", logURL.path, "--loglevel", "info",
            "tunnel", "--url", local, "--no-autoupdate", "--protocol", "http2",
        ]
        let ready = ReadyBox()
        guard attach(proc: proc, ready: ready, mode: .quick, teeLog: logURL) else { return nil }
        HavenLog.relay("cloudflared: main log → \(logURL.path)")

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            // Re-scan buffered log each tick in case the URL landed between handler calls.
            if ready.url == nil, let u = Self.extractTrycloudflareURL(ready.logText) {
                ready.url = u
            }
            if let url = ready.url {
                publicURL = url
                rememberPid(proc.processIdentifier)
                HavenLog.relay("cloudflared: quick tunnel \(url) → \(local)")
                // Diagnose system DNS vs DoH — many home routers NXDOMAIN free trycloudflare
                // hostnames over UDP while the connector is fine (DoH still resolves).
                await assessFreeTunnelDNS(publicURL: url)
                // Wait until local origin answers through the public URL (or 12s).
                // Without this, UI can show a trycloudflare host that still 530s.
                let live = await Self.waitPublicPathProxy(url: url, timeout: 12)
                if !live {
                    if freeTunnelDNSBroken {
                        HavenLog.relay(
                            "cloudflared: public \(url) unreachable via system DNS (NXDOMAIN) — "
                                + "tunnel process is up; use Custom domain/Manual or fix router DNS"
                        )
                    } else {
                        HavenLog.relay(
                            "cloudflared: public \(url) not serving path-proxy yet "
                                + "(will keep tunnel; health watch may recover)"
                        )
                    }
                }
                return url
            }
            if !proc.isRunning {
                HavenLog.relay("cloudflared: exited before printing a URL")
                process = nil
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        HavenLog.relay("cloudflared: timed out waiting for trycloudflare URL; log tail=\(ready.logText.suffix(400))")
        await stopFully()
        return nil
    }

    /// System getaddrinfo vs Cloudflare DoH for a free hostname. Sets `freeTunnelDNSBroken`.
    /// Free trycloudflare DNS often lags mint by a few seconds — we poll DoH before calling it dead.
    func assessFreeTunnelDNS(publicURL url: String) async {
        guard url.contains("trycloudflare.com"),
              let host = URL(string: url)?.host, !host.isEmpty else {
            freeTunnelDNSBroken = false
            freeTunnelDNSNote = nil
            return
        }
        let dnsURL = Self.prepareLogFile(name: "cloudflared-dns.log")
        dnsLogPath = dnsURL.path
        Self.appendLogFile(
            dnsURL,
            line: "\(ISO8601DateFormatter().string(from: Date())) assess start host=\(host) resolver=\(Self.primaryDNSHint())"
        )

        // Poll up to ~15s: free hostnames are often NXDOMAIN for a short window after mint.
        var systemOK = false
        var dohIPs: [String] = []
        let deadline = Date().addingTimeInterval(15)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            systemOK = await Task.detached(priority: .utility) {
                Self.systemResolves(host: host)
            }.value
            dohIPs = await Task.detached(priority: .utility) {
                Self.dohResolveA(host: host)
            }.value
            Self.appendLogFile(
                dnsURL,
                line: "\(ISO8601DateFormatter().string(from: Date())) attempt=\(attempt) system=\(systemOK) doh=\(dohIPs.isEmpty ? "miss" : dohIPs.joined(separator: ","))"
            )
            if systemOK {
                freeTunnelDNSBroken = false
                freeTunnelDNSNote = nil
                HavenLog.relay("cloudflared: system DNS resolves \(host) (attempt \(attempt))")
                objectWillChange.send()
                return
            }
            // DoH success with system fail = filtering; no need to wait full window.
            if !dohIPs.isEmpty { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if systemOK {
            freeTunnelDNSBroken = false
            freeTunnelDNSNote = nil
            return
        }
        freeTunnelDNSBroken = true
        if !dohIPs.isEmpty {
            freeTunnelDNSNote =
                "System DNS returns NXDOMAIN for \(host), but encrypted DNS (DoH) still resolves it. "
                + "Your router/DNS (\(Self.primaryDNSHint())) is filtering free Cloudflare tunnels — "
                + "Safari and most peers on this network cannot use free trycloudflare URLs. "
                + "Fix: System Settings → Network → DNS → 1.1.1.1 / 1.0.0.1 (or enable encrypted DNS), "
                + "or switch front door to Custom domain / Manual. Logs: Application Support/Haven/logs/"
            HavenLog.relay(
                "cloudflared: DNS BROKEN for free tunnel — system NXDOMAIN, DoH OK (\(dohIPs.joined(separator: ","))) host=\(host)"
            )
            Self.appendLogFile(
                dnsURL,
                line: "\(ISO8601DateFormatter().string(from: Date())) RESULT NXDOMAIN_system DoH_OK host=\(host) ips=\(dohIPs.joined(separator: ",")) resolver=\(Self.primaryDNSHint())"
            )
        } else {
            freeTunnelDNSNote =
                "Cannot resolve \(host) via system DNS or DoH after ~15s. Free trycloudflare DNS may be blocked, "
                + "or the hostname never propagated. See cloudflared-main.log + cloudflared-dns.log. "
                + "Prefer Custom domain / Manual for a stable front door."
            HavenLog.relay("cloudflared: free hostname \(host) resolves nowhere after retries (system+DoH miss)")
            Self.appendLogFile(
                dnsURL,
                line: "\(ISO8601DateFormatter().string(from: Date())) RESULT DEAD host=\(host) system+DoH miss after \(attempt) attempts resolver=\(Self.primaryDNSHint())"
            )
        }
        objectWillChange.send()
    }

    /// Best-effort primary DNS server for the warning string.
    nonisolated private static func primaryDNSHint() -> String {
        // resolv.conf is not always authoritative on macOS but is a useful hint.
        if let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("nameserver ") {
                    return String(t.dropFirst("nameserver ".count))
                }
            }
        }
        return "router DNS"
    }

    /// True if getaddrinfo can resolve `host` (what Safari / URLSession use).
    nonisolated private static func systemResolves(host: String) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let err = getaddrinfo(host, "443", &hints, &res)
        if let res { freeaddrinfo(res) }
        return err == 0
    }

    /// Resolve A records via Cloudflare DNS-over-HTTPS (bypasses broken router UDP DNS).
    nonisolated private static func dohResolveA(host: String) -> [String] {
        guard let url = URL(string: "https://1.1.1.1/dns-query?name=\(host)&type=A") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("application/dns-json", forHTTPHeaderField: "accept")
        req.timeoutInterval = 5
        let sem = DispatchSemaphore(value: 0)
        var ips: [String] = []
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = obj["Answer"] as? [[String: Any]] else { return }
            for a in answers {
                if let t = a["type"] as? Int, t == 1, let ip = a["data"] as? String {
                    ips.append(ip)
                }
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 6)
        return ips
    }

    /// Probe that the free public origin reaches our path proxy (or at least answers HTTP).
    nonisolated private static func waitPublicPathProxy(url: String, timeout: TimeInterval) async -> Bool {
        // If system DNS is NXDOMAIN, URLSession will always fail — skip waiting on public GET.
        if let host = URL(string: url)?.host, !Self.systemResolves(host: host) {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        let probe = url.hasSuffix("/") ? url : url + "/"
        while Date() < deadline {
            if await Self.quickPublicProbe(probe) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    nonisolated private static func quickPublicProbe(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        // Avoid multi-second hangs when the name is NXDOMAIN.
        if let host = u.host, !Self.systemResolves(host: host) {
            return false
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            if http.statusCode == 530 || http.statusCode == 502 || http.statusCode == 503 {
                return false
            }
            if let body = String(data: data, encoding: .utf8) {
                if body.contains("haven-path-proxy") || body.contains("haven") { return true }
                // Any non-edge-error HTTP from trycloudflare means the tunnel is up.
                if !body.contains("Error 1033") { return http.statusCode > 0 && http.statusCode < 600 }
            }
            return http.statusCode > 0
        } catch {
            return false
        }
    }

    private func startNamed(token: String, publicURL domain: String) async -> String? {
        guard let bin = Self.findBinary() else {
            HavenLog.relay("cloudflared: binary not found (bundle Helpers/ or PATH)")
            return nil
        }
        // Named tunnels should point at the path proxy when available; operator configures origin
        // in the Zero Trust UI (prefer http://127.0.0.1:8675).
        lastLocalHTTP = "http://127.0.0.1:8675"
        let logURL = Self.prepareLogFile(name: "cloudflared-main.log")
        mainLogPath = logURL.path
        Self.appendLogFile(
            logURL,
            line: "── spawn named tunnel \(ISO8601DateFormatter().string(from: Date())) domain=\(domain) ──"
        )
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [
            "--logfile", logURL.path, "--loglevel", "info",
            "tunnel", "--no-autoupdate", "--protocol", "http2",
            "run", "--token", token,
        ]
        let ready = ReadyBox()
        guard attach(proc: proc, ready: ready, mode: .named, teeLog: logURL) else { return nil }
        HavenLog.relay("cloudflared: named log → \(logURL.path)")

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if ready.namedReady || (ready.url != nil) {
                self.publicURL = domain
                rememberPid(proc.processIdentifier)
                HavenLog.relay("cloudflared: named tunnel \(domain)")
                return domain
            }
            if !proc.isRunning {
                HavenLog.relay("cloudflared: named tunnel exited early — check token / dashboard origin http://127.0.0.1:8675")
                process = nil
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Soft accept if still running (log wording varies by cloudflared version).
        if proc.isRunning {
            self.publicURL = domain
            rememberPid(proc.processIdentifier)
            HavenLog.relay("cloudflared: named tunnel assumed up \(domain)")
            return domain
        }
        HavenLog.relay("cloudflared: named tunnel failed to register")
        await stopFully()
        return nil
    }

    private enum Mode { case quick, named }

    private func attach(proc: Process, ready: ReadyBox, mode: Mode, teeLog: URL? = nil) -> Bool {
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        let onData: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            // Buffer chunks — trycloudflare URL often arrives split across pipe reads.
            ready.appendLog(chunk)
            if let teeLog {
                Self.appendLogFile(teeLog, text: chunk)
            }
            switch mode {
            case .quick:
                if let url = Self.extractTrycloudflareURL(ready.logText) { ready.url = url }
            case .named:
                let l = ready.logText.lowercased()
                if l.contains("registered tunnel connection")
                    || l.contains("connection registered")
                    || l.contains("connindex=")
                    || (l.contains("tunnel") && l.contains("connected")) {
                    ready.namedReady = true
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = onData
        err.fileHandleForReading.readabilityHandler = onData
        do {
            try proc.run()
        } catch {
            HavenLog.relay("cloudflared: spawn failed: \(error.localizedDescription)")
            return false
        }
        process = proc
        return true
    }

    /// Rotate if huge, truncate-create, return path for a named log under logs/.
    nonisolated private static func prepareLogFile(name: String) -> URL {
        let dir = logsDirectory()
        let url = dir.appendingPathComponent(name)
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 2_000_000 {
            let bak = dir.appendingPathComponent(name + ".1")
            try? fm.removeItem(at: bak)
            try? fm.moveItem(at: url, to: bak)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    nonisolated private static func appendLogFile(_ url: URL, line: String) {
        appendLogFile(url, text: line.hasSuffix("\n") ? line : line + "\n")
    }

    nonisolated private static func appendLogFile(_ url: URL, text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let fh = try? FileHandle(forWritingTo: url) else {
            // Create if missing (race with prepare).
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }

    /// Terminate → brief wait → SIGKILL by PID only.
    ///
    /// **Never** assign `standardOutput` / `standardError` after `run()` — Foundation's
    /// NOCOPY_SETTER throws and aborts the whole app (crash we hit on stopFully/health recover).
    /// Call from a background queue (blocks up to ~1.5s).
    nonisolated private static func hardStopProcess(_ proc: Process?) {
        guard let proc else { return }
        let pid = proc.processIdentifier
        guard pid > 1 else { return }

        // Drop readability handlers so we don't process pipe data during teardown.
        // Do NOT nil out standardOutput/standardError — that throws after launch.
        if let out = proc.standardOutput as? Pipe {
            out.fileHandleForReading.readabilityHandler = nil
        }
        if let err = proc.standardError as? Pipe {
            err.fileHandleForReading.readabilityHandler = nil
        }

        // PID signals only — Process is not safe to poke across queues after run().
        if kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(1.0)
            while kill(pid, 0) == 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
            // Non-blocking reap; do not waitpid(…, 0) forever if process group reparented.
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
        }
    }

    private func rememberPid(_ pid: Int32) {
        guard pid > 1 else { return }
        var pids = loadTrackedPids()
        if !pids.contains(pid) { pids.append(pid) }
        persistTrackedPids(pids)
    }

    private func loadTrackedPids() -> [Int32] {
        (UserDefaults.standard.array(forKey: pidDefaultsKey) as? [Int] ?? []).map { Int32($0) }
    }

    private func persistTrackedPids(_ pids: [Int32]) {
        UserDefaults.standard.set(pids.map { Int($0) }, forKey: pidDefaultsKey)
    }

    /// Kill every Haven-owned cloudflared we can find: persisted PIDs + Helpers path scan.
    /// Safe to call often; skips PIDs in `except` (currently live connectors). Prefer a
    /// background queue — may briefly sleep while reaping.
    nonisolated static func killOrphanCloudflareds(except: Set<Int32>) {
        var targets = Set<Int32>()
        // 1) Persisted from prior spawns (survives lost Process refs / crash).
        let key = "haven.relay.cloudflaredPids"
        let saved = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
        for n in saved {
            let pid = Int32(n)
            if pid > 1, !except.contains(pid) { targets.insert(pid) }
        }
        // 2) Live processes whose argv points at Haven's bundled helper (or known stub path).
        for pid in scanHavenCloudflaredPids() where !except.contains(pid) {
            targets.insert(pid)
        }
        guard !targets.isEmpty else {
            UserDefaults.standard.set(except.map { Int($0) }, forKey: key)
            return
        }
        for pid in targets {
            if kill(pid, 0) != 0 { continue }
            // HavenLog is MainActor — print via NSLog so we can call from any queue.
            NSLog("haven cloudflared: killing orphan pid=%d", pid)
            kill(pid, SIGTERM)
        }
        Thread.sleep(forTimeInterval: 0.35)
        for pid in targets {
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
            }
        }
        // Keep only the except set in defaults.
        UserDefaults.standard.set(except.map { Int($0) }, forKey: key)
    }

    /// PIDs of processes whose command line looks like Haven's cloudflared helper.
    nonisolated private static func scanHavenCloudflaredPids() -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax", "-o", "pid=", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Int32] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = trimmed[..<space].trimmingCharacters(in: .whitespaces)
            let cmd = trimmed[trimmed.index(after: space)...]
            guard let pid = Int32(pidStr), pid > 1 else { continue }
            // Match Haven-bundled helper or matrix stub helper — never a random homebrew cloudflared
            // unless it is clearly tunneling to Haven's local ports.
            let isHavenHelper = cmd.contains("/Contents/Helpers/cloudflared")
                || cmd.contains("matrix-haven-mac-stub") && cmd.contains("cloudflared")
                || cmd.contains("HavenStub") && cmd.contains("cloudflared")
            let isHavenLocalOrigin = cmd.contains("cloudflared")
                && (cmd.contains("127.0.0.1:8675")
                    || cmd.contains("127.0.0.1:8674")
                    || cmd.contains("127.0.0.1:3340"))
            if isHavenHelper || isHavenLocalOrigin {
                out.append(pid)
            }
        }
        return out
    }

    private static func findBinary() -> URL? {
        let name = "cloudflared"
        if let helpers = Bundle.main.privateFrameworksURL?
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers")
            .appendingPathComponent(name),
           FileManager.default.isExecutableFile(atPath: helpers.path) {
            return helpers
        }
        let helpers2 = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: helpers2.path) {
            return helpers2
        }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent(name),
           FileManager.default.isExecutableFile(atPath: exe.path) {
            return exe
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin"
        for dir in path.split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        return nil
    }

    static func extractTrycloudflareURL(_ text: String) -> String? {
        // Prefer an explicit trycloudflare host; scan every https:// occurrence (log lines
        // often include other URLs first).
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: "https://", range: search) {
            var s = String(text[r.lowerBound...])
            if let end = s.firstIndex(where: {
                $0.isWhitespace || $0 == "|" || $0 == "\"" || $0 == "'" || $0 == "]" || $0 == ")"
            }) {
                s = String(s[..<end])
            }
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}"))
            if s.contains("trycloudflare.com") {
                // Strip any trailing path so we announce origin only.
                if let schemeHost = URL(string: s), let host = schemeHost.host, host.contains("trycloudflare.com") {
                    return "https://\(host)"
                }
                return s
            }
            search = r.upperBound..<text.endIndex
        }
        return nil
    }

    private final class ReadyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: String?
        private var _named = false
        private var _log = ""
        var url: String? {
            get { lock.lock(); defer { lock.unlock() }; return _url }
            set { lock.lock(); _url = newValue; lock.unlock() }
        }
        var namedReady: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _named }
            set { lock.lock(); _named = newValue; lock.unlock() }
        }
        var logText: String {
            lock.lock(); defer { lock.unlock() }; return _log
        }
        func appendLog(_ chunk: String) {
            lock.lock()
            _log.append(chunk)
            // Cap so a long-lived tunnel log cannot grow without bound.
            if _log.count > 64_000 {
                _log = String(_log.suffix(32_000))
            }
            lock.unlock()
        }
    }
    #endif

    /// `https://host` with no trailing slash; accepts bare hostnames. Available on all platforms
    /// so Manual front door can announce a stable URL even where we cannot spawn cloudflared.
    static func normalizePublicURL(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        if !t.hasPrefix("http://") && !t.hasPrefix("https://") {
            t = "https://\(t)"
        }
        let afterScheme = t.split(separator: "://", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let hostOnly = afterScheme.split(separator: "/").first.map(String.init) ?? ""
        guard hostOnly.contains(".") else { return nil }
        return t
    }
}
