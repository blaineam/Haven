import Foundation

/// macOS helper: spawn the bundled (or PATH) `cloudflared` binary as a Cloudflare Quick Tunnel
/// to the local relay HTTP port, scrape the `*.trycloudflare.com` URL, and kill the child on stop.
///
/// App Store note: ship `cloudflared` under `Contents/Helpers/` and code-sign it with the same
/// team identity as HavenMac. The binary is Apache-2.0 (Cloudflare). iOS has no helper-exec path —
/// this type is a no-op there.
@MainActor
final class CloudflaredTunnel {
    static let shared = CloudflaredTunnel()

    private var process: Process?
    private(set) var publicURL: String?

    /// When true (default) and no manual public URL is set, start a quick tunnel with the relay.
    var autoEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "haven.relay.autoTunnel") == nil { return true }
            return UserDefaults.standard.bool(forKey: "haven.relay.autoTunnel")
        }
        set { UserDefaults.standard.set(newValue, forKey: "haven.relay.autoTunnel") }
    }

    /// Start a quick tunnel to `http://127.0.0.1:<port>`. Returns the public HTTPS URL, or nil.
    func start(port: UInt16) async -> String? {
        stop()
        #if os(macOS)
        guard let bin = Self.findBinary() else {
            HavenLog.relay("cloudflared: binary not found (bundle Helpers/ or PATH)")
            return nil
        }
        let local = "http://127.0.0.1:\(port)"
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["tunnel", "--url", local, "--no-autoupdate", "--protocol", "http2"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        let urlBox = URLBox()
        let onData: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            if let url = Self.extractURL(line) {
                urlBox.set(url)
            }
        }
        out.fileHandleForReading.readabilityHandler = onData
        err.fileHandleForReading.readabilityHandler = onData

        do {
            try proc.run()
        } catch {
            HavenLog.relay("cloudflared: spawn failed: \(error.localizedDescription)")
            return nil
        }
        process = proc

        // Wait up to 45s for the trycloudflare hostname.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let url = urlBox.get() {
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
        #else
        return nil
        #endif
    }

    func stop() {
        #if os(macOS)
        if let p = process, p.isRunning {
            p.terminate()
            // Don't block the main actor on wait — best-effort.
            DispatchQueue.global(qos: .utility).async {
                p.waitUntilExit()
            }
        }
        process = nil
        publicURL = nil
        #endif
    }

    #if os(macOS)
    private static func findBinary() -> URL? {
        let name = "cloudflared"
        // 1. Contents/Helpers/cloudflared (App Store / signed helper)
        if let helpers = Bundle.main.privateFrameworksURL?
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers")
            .appendingPathComponent(name),
           FileManager.default.isExecutableFile(atPath: helpers.path) {
            return helpers
        }
        // Bundle.main.bundleURL/Contents/Helpers
        let helpers2 = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: helpers2.path) {
            return helpers2
        }
        // Next to the executable (dev builds)
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent(name),
           FileManager.default.isExecutableFile(atPath: exe.path) {
            return exe
        }
        // PATH
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin"
        for dir in path.split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        return nil
    }

    static func extractURL(_ text: String) -> String? {
        guard let r = text.range(of: "https://") else { return nil }
        var s = String(text[r.lowerBound...])
        if let end = s.firstIndex(where: { $0.isWhitespace || $0 == "|" || $0 == "\"" }) {
            s = String(s[..<end])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
        return s.contains("trycloudflare.com") ? s : nil
    }

    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var url: String?
        func set(_ u: String) { lock.lock(); url = u; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return url }
    }
    #endif
}
