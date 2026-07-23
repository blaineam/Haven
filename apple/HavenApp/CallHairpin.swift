import Foundation

/// WebSocket call-media hairpin through the Haven path proxy (`/webrtc/hairpin`).
///
/// Free Cloudflare tunnels front **HTTPS + WebSocket**, not UDP TURN. When the circle fabric
/// has a public HTTPS origin (path-proxied DERP URL = media host), peers open a WSS per remote
/// and the proxy bipipes binary frames after a small JSON join.
///
/// Stock WebRTC media still tries ICE first. This path is the TCP/TLS fallback for hard NAT
/// when TURN/UDP is unavailable. v1: connection lifecycle + status; PCM media bridge can ride
/// the same binary frames (desktop already does when ICE fails).
@MainActor
final class CallHairpin {
    static let shared = CallHairpin()

    private var tasks: [String: URLSessionWebSocketTask] = [:]
    private var paired: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 90
        return URLSession(configuration: c)
    }()

    /// Public fabric/media HTTPS base → `wss://…/webrtc/hairpin`. Pure string→URL math, so it is
    /// nonisolated — callable from the host-less logic tests without the MainActor.
    nonisolated static func hairpinURL(fromPublicBase base: String) -> URL? {
        let t = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !t.isEmpty, let u = URL(string: t), let host = u.host else { return nil }
        var c = URLComponents()
        c.scheme = (u.scheme?.lowercased() == "http") ? "ws" : "wss"
        c.host = host
        c.port = u.port
        c.path = "/webrtc/hairpin"
        return c.url
    }

    /// Best fabric public base (DERP URL when path-proxied equals media origin).
    static func fabricBase() -> String? {
        let derp = UserDefaults.standard.stringArray(forKey: "haven.fabric.derpUrls") ?? []
        if let u = derp.first(where: { $0.hasPrefix("https://") || $0.hasPrefix("http://") }) {
            return u
        }
        return nil
    }

    /// Open (or keep) a hairpin to `remote` for this call session.
    func open(sessionId: String, me: String, remote: String) {
        guard !sessionId.isEmpty, !me.isEmpty, !remote.isEmpty, me != remote else { return }
        if tasks[remote] != nil { return }
        guard let base = Self.fabricBase(),
              let url = Self.hairpinURL(fromPublicBase: base) else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 90
        let task = session.webSocketTask(with: req)
        tasks[remote] = task
        task.resume()

        let join: [String: Any] = [
            "v": 1,
            "session": sessionId,
            "peer": me,
            "remote": remote,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: join),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] err in
            if let err {
                HavenLog.relay("hairpin join send failed \(remote.prefix(8)): \(err.localizedDescription)")
                Task { @MainActor in self?.close(remote: remote) }
            }
        }
        receiveLoop(remote: remote, task: task)
        HavenLog.relay("hairpin opening \(url.host ?? "?") → \(remote.prefix(8))…")
    }

    func openForRoster(sessionId: String, me: String, others: [String]) {
        for r in others where r != me {
            open(sessionId: sessionId, me: me, remote: r)
        }
    }

    func isPaired(_ remote: String) -> Bool { paired.contains(remote) }

    func close(remote: String) {
        tasks[remote]?.cancel(with: .goingAway, reason: nil)
        tasks.removeValue(forKey: remote)
        paired.remove(remote)
    }

    func closeAll() {
        for (_, t) in tasks {
            t.cancel(with: .goingAway, reason: nil)
        }
        tasks.removeAll()
        paired.removeAll()
    }

    private func receiveLoop(remote: String, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in self.close(remote: remote) }
            case .success(let message):
                Task { @MainActor in
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if obj["paired"] as? Bool == true
                                || (obj["ok"] as? Bool == true && obj["waiting"] as? Bool != true) {
                                self.paired.insert(remote)
                                HavenLog.relay("hairpin paired \(remote.prefix(8))…")
                            }
                            if let err = obj["err"] as? String {
                                HavenLog.relay("hairpin err \(remote.prefix(8)): \(err)")
                            }
                        }
                    case .data:
                        // Binary media frames — reserved for PCM/DTLS fallback (desktop uses this).
                        break
                    @unknown default:
                        break
                    }
                    // Keep reading while task still tracked.
                    if self.tasks[remote] === task {
                        self.receiveLoop(remote: remote, task: task)
                    }
                }
            }
        }
    }
}
