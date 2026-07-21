import Foundation

/// Process-wide view of the **Haven transport fabric**: circle-hosted iroh DERP URLs learned
/// from frame-19 announces / local host start.
///
/// Policy (matches `haven_net::endpoint_builder::apply_derp_urls` / FFI `applyDerpUrls`):
/// - **No Haven DERP known** → n0 public relays + Google STUN remain the only fallback.
/// - **≥1 Haven DERP known** → iroh should use those URLs only; WebRTC prefers non-Google ICE
///   (see `iceServers()`). Full TURN on haven-relay is future work; until then hard-NAT calls may
///   still need a STUN/TURN path — we avoid Google when a fabric is present and fall back only if
///   the operator has not configured any circle ICE yet.
///
/// Rust process policy is applied via `RelayMailboxStore.refreshHavenFabric()` → `applyDerpUrls`.
/// iroh `RelayMap` is bind-time: call refresh **before** `HavenNode.start` when prefs already know
/// a fabric; mid-session learns update policy for the next bind / process restart only.
@MainActor
final class HavenFabric: ObservableObject {
    static let shared = HavenFabric()

    @Published private(set) var derpUrls: [String] = []

    private init() {
        derpUrls = UserDefaults.standard.stringArray(forKey: "haven.fabric.derpUrls") ?? []
    }

    var isActive: Bool { !derpUrls.isEmpty }

    func update(derpUrls urls: [String]) {
        let next = Array(Set(urls.filter { !$0.isEmpty })).sorted()
        guard next != derpUrls else { return }
        derpUrls = next
        UserDefaults.standard.set(next, forKey: "haven.fabric.derpUrls")
        objectWillChange.send()
    }

    /// WebRTC ICE server list. Google STUN **only** when no Haven fabric is known.
    func iceServerUrls() -> [String] {
        if isActive {
            // Prefer host/srflx without third-party STUN when the circle has a fabric.
            // Operators can later advertise TURN via announce; until then empty = host candidates.
            // If that proves too weak for calls, add a Haven TURN role — do not silently re-add Google.
            return []
        }
        return [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ]
    }
}
