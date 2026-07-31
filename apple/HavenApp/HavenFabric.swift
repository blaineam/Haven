import Foundation

/// Process-wide view of the **Haven transport fabric**: circle-hosted iroh DERP URLs + optional
/// circle TURN for WebRTC, learned from frame-19 announces / local host start.
///
/// Policy (matches `haven_net::endpoint_builder::apply_derp_urls` / FFI `applyDerpUrls`):
/// - **No Haven DERP known** → n0 public relays + Google STUN are the **fallback only**.
/// - **≥1 Haven DERP known** → iroh uses those URLs only (**n0 off** — not first path).
/// - **WebRTC ICE when fabric active:** circle TURN when known; otherwise **host candidates
///   only** (no Google STUN). Call media may use the path-proxy WebSocket hairpin
///   (`/webrtc/hairpin`) over free CF; signaling rides sealed iroh / fabric DERP.
///
/// Rust process policy is applied via `RelayMailboxStore.refreshHavenFabric()` → `applyDerpUrls`.
/// iroh `RelayMap` is bind-time: call refresh **before** `HavenNode.start` when prefs already know
/// a fabric; mid-session learns update policy for the next bind / process restart only.
@MainActor
final class HavenFabric: ObservableObject {
    static let shared = HavenFabric()

    @Published private(set) var derpUrls: [String] = []
    @Published private(set) var turnUrls: [String] = []
    @Published private(set) var turnUser: String = ""
    @Published private(set) var turnPass: String = ""

    private init() {
        derpUrls = UserDefaults.standard.stringArray(forKey: "haven.fabric.derpUrls") ?? []
        turnUrls = UserDefaults.standard.stringArray(forKey: "haven.fabric.turnUrls") ?? []
        turnUser = UserDefaults.standard.string(forKey: "haven.fabric.turnUser") ?? ""
        turnPass = UserDefaults.standard.string(forKey: "haven.fabric.turnPass") ?? ""
    }

    var isActive: Bool { !derpUrls.isEmpty }

    func update(derpUrls urls: [String]) {
        let next = Array(Set(urls.filter { !$0.isEmpty })).sorted()
        guard next != derpUrls else { return }
        derpUrls = next
        UserDefaults.standard.set(next, forKey: "haven.fabric.derpUrls")
        objectWillChange.send()
    }

    func updateTurn(urls: [String], user: String, pass: String) {
        let next = Array(Set(urls.filter { !$0.isEmpty && ($0.hasPrefix("turn:") || $0.hasPrefix("turns:")) })).sorted()
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = pass.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != turnUrls || u != turnUser || p != turnPass else { return }
        turnUrls = next
        turnUser = u
        turnPass = p
        UserDefaults.standard.set(next, forKey: "haven.fabric.turnUrls")
        UserDefaults.standard.set(u, forKey: "haven.fabric.turnUser")
        UserDefaults.standard.set(p, forKey: "haven.fabric.turnPass")
        objectWillChange.send()
    }

    /// Google STUN — used **only** when no Haven fabric is known (not first path with a circle relay).
    nonisolated static let googleStunUrls: [String] = [
        "stun:stun.l.google.com:19302",
        "stun:stun1.l.google.com:19302",
    ]

    /// WebRTC ICE server URL strings (legacy helpers). Prefer `iceServersFromDefaults()`.
    nonisolated func iceServerUrls() -> [String] {
        Self.iceServerUrlsFromDefaults()
    }

    /// Haven-first ICE URL list (no MainActor).
    /// Fabric + TURN → circle TURN. Fabric without TURN → empty (host + hairpin). No fabric → Google STUN.
    nonisolated static func iceServerUrlsFromDefaults() -> [String] {
        let turn = UserDefaults.standard.stringArray(forKey: "haven.fabric.turnUrls") ?? []
        let derp = UserDefaults.standard.stringArray(forKey: "haven.fabric.derpUrls") ?? []
        if !turn.isEmpty { return turn }
        if !derp.isEmpty { return [] } // fabric on — no Google
        return googleStunUrls
    }

    /// Full ICE server dicts for WebRTC.
    ///
    /// | Fabric | TURN | ICE |
    /// |---|---|---|
    /// | no | none / private only | Google STUN (nothing else can pair two home NATs) |
    /// | no | public TURN | circle TURN + STUN on the same host |
    /// | yes | any (incl. none) | circle TURN/STUN if present — never Google; the hairpin carries media |
    ///
    /// The old policy returned the circle TURN as the ONLY server, and an EMPTY list when a
    /// fabric existed without TURN. In the field the relay advertised a Docker-internal TURN
    /// host (`turn:172.20.0.2:3478`), so both phones ended up with one unreachable server, no
    /// STUN, host candidates only — calls "connected" at the app layer with zero media both
    /// ways. ICE server lists are candidates, not commitments: a dead entry costs a lookup,
    /// a missing STUN costs the call. Circle infrastructure stays FIRST; Google STUN is added
    /// only when the circle can't possibly provide a server-reflexive path itself.
    nonisolated static func iceServersFromDefaults() -> [[String: Any]] {
        let turn = UserDefaults.standard.stringArray(forKey: "haven.fabric.turnUrls") ?? []
        let user = UserDefaults.standard.string(forKey: "haven.fabric.turnUser") ?? ""
        let pass = UserDefaults.standard.string(forKey: "haven.fabric.turnPass") ?? ""
        var servers: [[String: Any]] = []
        var havePublicTurn = false
        if !turn.isEmpty, !user.isEmpty, !pass.isEmpty {
            servers.append(["urls": turn, "username": user, "credential": pass])
            // The circle TURN host doubles as a STUN server (same socket, no credentials) —
            // srflx candidates from our own infrastructure, no third party involved.
            let stun = turn.compactMap { url -> String? in
                let hostPort = url.split(separator: ":").dropFirst().joined(separator: ":")
                return hostPort.isEmpty ? nil : "stun:\(hostPort)"
            }
            if !stun.isEmpty { servers.append(["urls": stun]) }
            havePublicTurn = turn.contains { !Self.hostLooksPrivate($0) }
        }
        // PUBLIC STUN IS A LAST RESORT, not a default companion.
        //
        // The rule: Google is used only when NO Haven relay is available to carry this call. A
        // configured fabric counts as available even with no TURN, because the relay's path proxy
        // serves the WebRTC hairpin — media has a route that never touches a third party.
        //
        // This tightens the previous behaviour, which appended Google whenever no PUBLICLY
        // reachable TURN was configured, including when a working fabric was present. That rule
        // came from a real field failure (a relay advertising a Docker-internal
        // `turn:172.20.0.2:3478`, leaving both phones with one dead server, no STUN and host
        // candidates only — calls that "connected" with zero media). That case is still covered:
        // an unreachable private TURN with no fabric is not an available relay, so the fallback
        // still applies. What changes is that a healthy fabric no longer discloses the caller's IP
        // to Google during ICE just because it has no TURN of its own — the hairpin, which did not
        // exist when that fallback was written, is the path for exactly that situation.
        let haveFabric = !(UserDefaults.standard.stringArray(forKey: "haven.fabric.derpUrls") ?? []).isEmpty
        let havenRelayAvailable = haveFabric || havePublicTurn
        if !havenRelayAvailable {
            servers.append(["urls": googleStunUrls])
        }
        return servers
    }

    /// Best-effort "is this turn:/stun: URL's host a private/unroutable address" check.
    nonisolated private static func hostLooksPrivate(_ url: String) -> Bool {
        let host = url.split(separator: ":").dropFirst().first.map(String.init) ?? ""
        return host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("127.")
            || host.hasPrefix("169.254.")
            || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? -1))
    }
}

/// Where a relay's public origin exposes the WebRTC hairpin.
///
/// Lives here, not on CallHairpin, so it stays reachable from the host-LESS HavenLogicTests target.
/// CallHairpin grew a FeedStore/RelayMailboxStore dependency in its failure path, which quietly
/// broke that target's "Foundation-only" promise and stopped it compiling at all — this derivation
/// is pure Foundation and belongs with the rest of the fabric address logic.
enum HavenHairpin {

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
}
