import Foundation

/// macOS helper: spawn the bundled (or PATH) `cloudflared` binary as either
/// - a free **Quick Tunnel** (`*.trycloudflare.com`), or
/// - a **named** Cloudflare Tunnel using a Zero Trust install token + custom domain.
///
/// App Store note: ship `cloudflared` under `Contents/Helpers/` and code-sign it with the same
/// team identity as HavenMac. The binary is Apache-2.0 (Cloudflare). iOS has no helper-exec path —
/// this type is a no-op there.
@MainActor
final class CloudflaredTunnel {
    static let shared = CloudflaredTunnel()

    private var process: Process?
    private(set) var publicURL: String?

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
        }
    }

    /// When true (default) and mode is auto with no custom domain, start free trycloudflare.
    var autoEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "haven.relay.autoTunnel") == nil { return true }
            return UserDefaults.standard.bool(forKey: "haven.relay.autoTunnel")
        }
        set { UserDefaults.standard.set(newValue, forKey: "haven.relay.autoTunnel") }
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
        }
    }

    /// Result of applying front-door prefs for this host start.
    struct FrontDoorResult {
        /// URL to put first in the announce list (if any).
        var announceURL: String?
        /// True when we spawned cloudflared (quick or named).
        var spawnedConnector: Bool
    }

    /// Apply front-door mode. Manual never spawns cloudflared — only returns the announce URL.
    func apply(port: UInt16) async -> FrontDoorResult {
        stop()
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

    func stop() {
        #if os(macOS)
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global(qos: .utility).async {
                p.waitUntilExit()
            }
        }
        process = nil
        publicURL = nil
        #endif
    }

    #if os(macOS)
    private func startQuick(port: UInt16) async -> String? {
        guard let bin = Self.findBinary() else {
            HavenLog.relay("cloudflared: binary not found (bundle Helpers/ or PATH)")
            return nil
        }
        let local = "http://127.0.0.1:\(port)"
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["tunnel", "--url", local, "--no-autoupdate", "--protocol", "http2"]
        let ready = ReadyBox()
        guard attach(proc: proc, ready: ready, mode: .quick) else { return nil }

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let url = ready.url {
                publicURL = url
                HavenLog.relay("cloudflared: quick tunnel \(url)")
                return url
            }
            if !proc.isRunning {
                HavenLog.relay("cloudflared: exited before printing a URL")
                process = nil
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        HavenLog.relay("cloudflared: timed out waiting for trycloudflare URL")
        stop()
        return nil
    }

    private func startNamed(token: String, publicURL domain: String) async -> String? {
        guard let bin = Self.findBinary() else {
            HavenLog.relay("cloudflared: binary not found (bundle Helpers/ or PATH)")
            return nil
        }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [
            "tunnel", "--no-autoupdate", "--protocol", "http2",
            "run", "--token", token,
        ]
        let ready = ReadyBox()
        guard attach(proc: proc, ready: ready, mode: .named) else { return nil }

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if ready.namedReady || (ready.url != nil) {
                self.publicURL = domain
                HavenLog.relay("cloudflared: named tunnel \(domain)")
                return domain
            }
            if !proc.isRunning {
                HavenLog.relay("cloudflared: named tunnel exited early — check token / dashboard origin http://127.0.0.1:8674")
                process = nil
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Soft accept if still running (log wording varies by cloudflared version).
        if proc.isRunning {
            self.publicURL = domain
            HavenLog.relay("cloudflared: named tunnel assumed up \(domain)")
            return domain
        }
        HavenLog.relay("cloudflared: named tunnel failed to register")
        stop()
        return nil
    }

    private enum Mode { case quick, named }

    private func attach(proc: Process, ready: ReadyBox, mode: Mode) -> Bool {
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        let onData: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            switch mode {
            case .quick:
                if let url = Self.extractTrycloudflareURL(line) { ready.url = url }
            case .named:
                let l = line.lowercased()
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
        guard let r = text.range(of: "https://") else { return nil }
        var s = String(text[r.lowerBound...])
        if let end = s.firstIndex(where: { $0.isWhitespace || $0 == "|" || $0 == "\"" }) {
            s = String(s[..<end])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
        return s.contains("trycloudflare.com") ? s : nil
    }

    private final class ReadyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: String?
        private var _named = false
        var url: String? {
            get { lock.lock(); defer { lock.unlock() }; return _url }
            set { lock.lock(); _url = newValue; lock.unlock() }
        }
        var namedReady: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _named }
            set { lock.lock(); _named = newValue; lock.unlock() }
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
