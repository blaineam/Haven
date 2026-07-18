#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UserNotifications
// PushKit (VoIP pushes) is iOS/Catalyst-only — there's no PushKit on native macOS.
#if os(iOS)
import PushKit
#endif

/// Talks to the self-hosted Haven push relay (a blind Cloudflare Worker). Registers this
/// device's APNs token under our pseudonymous node id, and asks the relay to wake circle
/// members when we post/message — so notifications arrive even when the app is killed
/// (background fetch is unreliable; this is the real fix).
///
/// v1 sends a generic alert ("New message") — no content leaves the device. Showing the
/// actual text needs a Notification Service Extension (later), which is purely additive.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    /// The push relay this install talks to.
    ///
    /// This used to be a compile-time constant, which meant the project could only ever have ONE
    /// push relay, forever, and pointing at a different one required shipping three app updates.
    /// That is a single point of failure attached to one person's Cloudflare account — see
    /// `docs/SUCCESSION.md`. It is now an override with the current worker as the default, so a
    /// successor operator (or a self-hoster) can redirect an already-installed app.
    ///
    /// Empty string is a MEANINGFUL value: "no push relay". Everything degrades to mailbox polling
    /// — foreground sync plus best-effort `BGAppRefresh` — rather than breaking. See
    /// `docs/NOTIFICATIONS-FALLBACK.md` for exactly what that does and does not deliver.
    static let relayOverrideKey = "HavenPushRelayURL"

    static var relay: String {
        // `object(forKey:)`, not `string(forKey:)`, so an explicitly-set empty string ("disable
        // push entirely") is distinguishable from "never configured" and is honoured.
        guard let v = UserDefaults.standard.object(forKey: relayOverrideKey) as? String else {
            return defaultRelay
        }
        return v
    }

    /// The relay used when nothing has been configured. Still ours, still the fast path.
    static let defaultRelay = "https://haven-push.blaineams3.workers.dev"

    /// Point this install at a different push relay, or pass `""` to turn push off entirely and
    /// rely on polling. `nil` restores the default.
    static func setRelay(_ url: String?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: relayOverrideKey)
            return
        }
        UserDefaults.standard.set(url, forKey: relayOverrideKey)
    }

    /// Whether push is configured at all. When false the app must not imply push-speed delivery.
    static var pushEnabled: Bool { !relay.isEmpty }

    /// Ask for permission + register for remote notifications (call at launch).
    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { PlatformApp.registerForRemoteNotifications() }
        }
    }

    private var lastToken = ""
    #if os(iOS)
    private var voipRegistry: PKPushRegistry?
    #endif

    /// Register for PushKit VoIP pushes so calls ring even from a fully-killed/locked device.
    /// The VoIP push is a blind doorbell: it carries only the caller's name SEALED to us; the
    /// worker can't read it, and isn't in the call (signaling = sealed iroh, media = P2P).
    /// No PushKit on native macOS — no-op there.
    func startVoip() {
        #if os(iOS)
        guard voipRegistry == nil else { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        voipRegistry = r
        #endif
    }

    func registerVoip(_ tokenHex: String) {
        guard let nodeId = myNodeId() else { return }
        post("/register-voip", ["nodeId": nodeId, "token": tokenHex, "sandbox": isSandbox].merging(signedReg(token: tokenHex)) { $1 })
    }

    /// Wake a peer for an incoming call (VoIP push). `ciphertext` = caller name sealed to them.
    func callPush(to nodeId: String, ciphertext: String?) {
        guard !nodeId.isEmpty else { return }
        post("/call", ["nodeId": nodeId, "ciphertext": ciphertext ?? "_"])
    }

    /// APNs handed us a device token → register it with the relay under our node id.
    func registered(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        lastToken = hex
        guard let nodeId = myNodeId() else { return }
        // platform tells the relay how to push: iOS gets alert+NSE; macOS gets a silent
        // content-available push it decrypts in-process (no NSE on macOS).
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        post("/register", ["nodeId": nodeId, "token": hex, "sandbox": isSandbox, "platform": platform].merging(signedReg(token: hex)) { $1 })
    }

    /// Register as an S3-bucket owner so the worker's cron can send a silent push to re-mint
    /// pre-signed URLs before they expire. (No-op if push isn't set up — the app re-mints on
    /// launch + a local reminder covers it.)
    func registerStorageOwner() {
        guard !lastToken.isEmpty, let nodeId = myNodeId() else { return }
        post("/register-owner", ["nodeId": nodeId, "token": lastToken, "sandbox": isSandbox].merging(signedReg(token: lastToken)) { $1 })
    }

    /// Ask the relay to wake a (possibly offline) peer. `ciphertext` is the base64 of a blob
    /// sealed to *that* peer (so only they can read it); the relay forwards it blind and the
    /// peer's Notification Service Extension decrypts it into the real banner. Pass `nil` when
    /// we can't seal — the relay then shows a generic "New activity" alert.
    /// `event` is the base64 of the sealed circle event itself; when present (and small enough)
    /// the relay inlines it in the push so the recipient's NSE stashes it and the app ingests it
    /// with no mailbox round-trip (push-inline sync).
    func wake(_ nodeId: String, ciphertext: String? = nil, event: String? = nil) {
        guard !nodeId.isEmpty else { return }
        var body: [String: Any] = ["nodeId": nodeId, "ciphertext": ciphertext ?? "_"]
        if let event { body["event"] = event }
        post("/notify", body)
    }

    /// Multi-device: sync an event we authored to our OWN other devices (linked to this
    /// identity). A `silent` push (no banner) so we don't self-notify; the other devices stash
    /// the inline event and ingest it — no mailbox needed.
    func syncSelf(event: String) {
        guard let nodeId = myNodeId() else { return }
        post("/notify", ["nodeId": nodeId, "event": event, "silent": true])
    }

    private var isSandbox: Bool {
        #if DEBUG
        return true   // Xcode/dev builds use the APNs sandbox
        #else
        return false  // TestFlight / App Store = production
        #endif
    }

    private func myNodeId() -> String? {
        guard let seed = AccountStore.storedSeed(), let acct = try? Account.fromSeed(seed: seed) else { return nil }
        return acct.nodeIdHex()
    }

    /// Signed registration fields (audit F5): a timestamp + the identity's Ed25519 signature over
    /// (nodeId, token, ts), so the worker can confirm the registration is genuinely ours and reject a
    /// token-hijack attempt registering under our node id.
    private func signedReg(token: String) -> [String: Any] {
        guard let seed = AccountStore.storedSeed(), let acct = try? Account.fromSeed(seed: seed) else { return [:] }
        let ts = UInt64(Date().timeIntervalSince1970)
        let sig = acct.signPushRegistration(token: token, tsSecs: ts)
        return ["ts": ts, "sig": sig.base64EncodedString()]
    }

    private func post(_ path: String, _ body: [String: Any]) {
        // No relay configured = push deliberately off. Fail silently and let polling carry it;
        // `URL(string: "/register")` would otherwise be a relative URL and a confusing failure.
        guard Self.pushEnabled, let url = URL(string: Self.relay + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}

#if os(iOS)
extension PushManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in self.registerVoip(hex) }
    }
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

    /// A VoIP push arrived — we MUST report a new incoming call synchronously (iOS kills the app
    /// otherwise). The registry runs on the main queue, so we're already main-isolated here.
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                  didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType,
                                  completion: @escaping () -> Void) {
        MainActor.assumeIsolated {
            var name = "Someone", peerHex = ""
            if let e = payload.dictionaryPayload["e"] as? String, e != "_",
               let sealed = Data(base64Encoded: e), let seed = SharedSeed.read(),
               // Authenticated open: only a validly-signed caller payload rings the phone (audit H2).
               let opened = openSignedNotificationWithSeed(seed: seed, blob: sealed),
               let obj = try? JSONSerialization.jsonObject(with: opened.data) as? [String: String] {
                name = obj["t"] ?? name
                peerHex = obj["h"] ?? ""
            }
            CallManager.shared.reportIncomingFromPush(name: name, peerHex: peerHex)
            completion()
        }
    }
}
#endif
