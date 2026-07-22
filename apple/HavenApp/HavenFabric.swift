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
    /// | no | — | Google STUN (fallback only) |
    /// | yes | no | empty (host candidates; media may use `/webrtc/hairpin`) |
    /// | yes | yes | circle TURN only |
    nonisolated static func iceServersFromDefaults() -> [[String: Any]] {
        let turn = UserDefaults.standard.stringArray(forKey: "haven.fabric.turnUrls") ?? []
        let derp = UserDefaults.standard.stringArray(forKey: "haven.fabric.derpUrls") ?? []
        let user = UserDefaults.standard.string(forKey: "haven.fabric.turnUser") ?? ""
        let pass = UserDefaults.standard.string(forKey: "haven.fabric.turnPass") ?? ""
        if !turn.isEmpty, !user.isEmpty, !pass.isEmpty {
            return [[
                "urls": turn,
                "username": user,
                "credential": pass,
            ]]
        }
        if !derp.isEmpty || !turn.isEmpty {
            return [] // fabric present — never Google STUN as first path
        }
        return [[
            "urls": googleStunUrls,
        ]]
    }
}
