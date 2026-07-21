import Foundation

/// Process-wide view of the **Haven transport fabric**: circle-hosted iroh DERP URLs + optional
/// circle TURN for WebRTC, learned from frame-19 announces / local host start.
///
/// Policy (matches `haven_net::endpoint_builder::apply_derp_urls` / FFI `applyDerpUrls`):
/// - **No Haven DERP known** → n0 public relays + Google STUN remain the only fallback.
/// - **≥1 Haven DERP known** → iroh uses those URLs only; WebRTC uses circle TURN when known,
///   else host candidates only (no Google).
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

    /// WebRTC ICE server URL strings (legacy helpers). Prefer `iceServers()` for credentials.
    ///
    /// When fabric is active and TURN is known → circle `turn:` URLs.
    /// When fabric is active without TURN → empty (host candidates only; no Google).
    /// When no fabric → Google STUN.
    nonisolated func iceServerUrls() -> [String] {
        Self.iceServerUrlsFromDefaults()
    }

    /// Same policy without requiring the MainActor singleton (safe from any thread).
    nonisolated static func iceServerUrlsFromDefaults() -> [String] {
        let turn = UserDefaults.standard.stringArray(forKey: "haven.fabric.turnUrls") ?? []
        let derp = UserDefaults.standard.stringArray(forKey: "haven.fabric.derpUrls") ?? []
        if !turn.isEmpty { return turn }
        if !derp.isEmpty { return [] }
        return [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ]
    }

    /// Full ICE server dicts for WebRTC (includes TURN username/credential when known).
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
            return [] // fabric present — no Google
        }
        return [[
            "urls": [
                "stun:stun.l.google.com:19302",
                "stun:stun1.l.google.com:19302",
            ]
        ]]
    }
}
