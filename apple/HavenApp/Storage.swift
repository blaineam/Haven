import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import CryptoKit
import Security

/// Where the user's media is stored. iCloud is the default (their own quota); they can
/// also bring their own S3-compatible bucket, or connect a cloud drive over OAuth.
/// Crucially: Haven never hosts any API keys or client secrets — S3 keys live in the
/// Keychain on-device, and drive logins use OAuth 2.0 + PKCE (public clients, no secret).
enum StorageProvider: String, CaseIterable, Identifiable {
    case s3   // iCloud removed: Apple-only + never wired for sharing. Relay (toggle) or S3 only.
    var id: String { rawValue }
    var title: String { "Custom S3 bucket" }
    var icon: String { "externaldrive.fill" }
}

@MainActor
final class StorageStore: ObservableObject {
    static let shared = StorageStore()

    @Published var provider: StorageProvider { didSet { d.set(provider.rawValue, forKey: "haven.storage.provider") } }
    @Published var s3Endpoint: String { didSet { d.set(s3Endpoint, forKey: "haven.s3.endpoint") } }
    @Published var s3Region: String { didSet { d.set(s3Region, forKey: "haven.s3.region") } }
    @Published var s3Bucket: String { didSet { d.set(s3Bucket, forKey: "haven.s3.bucket") } }
    @Published var s3AccessKey: String { didSet { Keychain.set(s3AccessKey, for: "s3AccessKey") } }
    @Published var s3Secret: String { didSet { Keychain.set(s3Secret, for: "s3Secret") } }
    /// "Volunteer as tribute": back up the circle's media (sealed to the circle, so it
    /// stays opaque to your storage provider) and re-serve it to members who are missing
    /// it — making your bucket a durable source for the whole circle.
    @Published var shareCircleMedia: Bool { didSet { d.set(shareCircleMedia, forKey: "haven.s3.share") } }

    private let d = UserDefaults.standard
    private init() {
        provider = .s3
        s3Endpoint = d.string(forKey: "haven.s3.endpoint") ?? ""
        s3Region = d.string(forKey: "haven.s3.region") ?? "us-east-1"
        s3Bucket = d.string(forKey: "haven.s3.bucket") ?? ""
        s3AccessKey = Keychain.get("s3AccessKey") ?? ""
        s3Secret = Keychain.get("s3Secret") ?? ""
        shareCircleMedia = d.bool(forKey: "haven.s3.share")
    }

    var s3Configured: Bool { !s3Endpoint.isEmpty && !s3Bucket.isEmpty && !s3AccessKey.isEmpty && !s3Secret.isEmpty }
}

struct StorageSettingsView: View {
    /// The circle being configured (nil = the active circle, for the global Settings entry).
    var circleId: String? = nil
    @ObservedObject private var mailbox = SharedMailboxStore.shared
    @ObservedObject private var relay = RelayHost.shared
    @State private var relayAdopted = false
    @State private var startAtLogin = false
    @State private var loginItemError: String?

    private var cid: String { circleId ?? FeedStore.shared.activeCircleId }

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                // The common path: make this device the circle's mailbox with one toggle.
                Section {
                    Toggle(isOn: Binding(get: { relay.enabled }, set: { relay.setEnabled($0) })) {
                        Label("Be your circle's relay", systemImage: "externaldrive.connected.to.line.below.fill")
                    }
                    .tint(HavenTheme.pink)
                    if relay.serving && !relay.nodeId.isEmpty {
                        Label("Relaying for your circles · \(String(relay.nodeId.prefix(8)))…", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else if relay.enabled {
                        Label("Starting…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    // Mac-only: keep the relay always-on by relaunching Haven at login. Catalyst
                    // can't run a true headless/menu-bar agent, so the best achievable is to
                    // auto-launch at login and keep relaying for the life of the process — leave a
                    // Haven window open (it can stay in the background) and the relay keeps serving.
                    if relay.enabled && relay.loginItemSupported {
                        Toggle(isOn: Binding(get: { startAtLogin }, set: { setStartAtLogin($0) })) {
                            Label("Start Haven at login (keep the relay running)", systemImage: "power")
                        }
                        .tint(HavenTheme.pink)
                        if let err = loginItemError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text("With this on, Haven relays invisibly in the background: close the window and it keeps serving your circle with no dock icon (launch Haven again to reopen it). At login it starts hidden — launch it a second time to open the window, like the first time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Mac: front-door controls (bundled cloudflared / custom domain / manual).
                    // Without this, Auto is invisible and users never see stable-domain options.
                    #if os(macOS)
                    if relay.enabled {
                        RelayFrontDoorControls()
                    }
                    #endif
                } header: {
                    Text("Circle relay")
                } footer: {
                    Text(relay.isDesktopClass
                         ? "Turn this Mac into your circles' always-available mailbox — sealed (unreadable) posts and media are stored here and re-served to your circle whenever someone's been offline. Just leave Haven running."
                         : "Use this device as your circles' mailbox — sealed posts/media live here and re-serve when someone's offline. On iPhone/iPad it serves while Haven is open and the screen's on (keep it on a charger); a Mac or the desktop app is best for always-on. No setup, no cloud.")
                }
                // Reuse a mailbox you already set up on another circle — a simple one-tap pick.
                let others = RelayMailboxStore.shared.circlesWithRelay(excluding: cid)
                if !others.isEmpty {
                    Section {
                        ForEach(others, id: \.self) { other in
                            if let node = RelayMailboxStore.shared.explicitRelays(forCircle: other).first {
                                Button {
                                    FeedStore.shared.adoptRelayNode(node, circleIds: [cid], setDefault: false)
                                    relayAdopted = true
                                } label: {
                                    HStack {
                                        Label(FeedStore.shared.circles.first { $0.id == other }?.name ?? "Another circle",
                                              systemImage: "arrow.triangle.2.circlepath")
                                        Spacer()
                                        Text("\(node.prefix(8))…").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if relayAdopted {
                            Label("Connected — used as the relay", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    } header: { Text("Use another circle's relay") }
                    footer: { Text("Point this circle at a relay you already connected for a different circle.") }
                }

                // The redundant relay pool for this circle: posts are mirrored to every one, and
                // read from any that's reachable. A relay in backoff (recently failed) shows as
                // "unreachable" and is skipped until it recovers. Swipe / tap to forget one.
                RelayPoolSection(circleId: cid)

                if let cfg = mailbox.config {
                    Section {
                        Label("Connected to your circle's relay", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green).font(.subheadline.weight(.medium))
                        Text("Bucket: \(cfg.bucket) @ \(cfg.endpoint)").font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) { SharedMailboxStore.shared.clear() } label: {
                            Text("Stop using this relay")
                        }
                    } header: { Text("Active relay") }
                    footer: { Text("Your circle shares this bucket so posts arrive even when people are offline. Only sealed, unreadable blobs are stored there.") }
                }

                // Power-user options live one tap deeper so the common path stays uncluttered:
                // connecting an external relay daemon by node id, or bringing your own S3 bucket.
                Section {
                    NavigationLink {
                        AdvancedStorageView(circleId: circleId)
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Connect an external always-on relay (a Mac, Linux box, or spare device running `haven-relay`), or point Haven at your own S3-compatible bucket. Optional — the toggle above is all most people need.")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .havenSettingsForm()
        .navigationTitle("Storage")
        .havenInlineNavTitle()
        .onAppear { startAtLogin = relay.startsAtLogin }
    }

    /// Register/unregister Haven as a macOS login item, reflecting the real status back into the
    /// toggle and surfacing any error (e.g. unsigned dev build) instead of crashing.
    private func setStartAtLogin(_ on: Bool) {
        loginItemError = nil
        do {
            try relay.setStartAtLogin(on)
        } catch {
            loginItemError = "Couldn't \(on ? "enable" : "disable") start-at-login: \(error.localizedDescription)"
        }
        // Reflect the OS's actual state (the user may have it disabled in System Settings).
        startAtLogin = relay.startsAtLogin
    }

}

/// The circle's redundant relay pool, surfaced in the Storage screen (mirrors the desktop Relay
/// view): every configured relay with a live reachability dot, plus swipe-to-forget. Posts are
/// mirrored to all of them and read from any reachable one; a failed relay backs off and is shown
/// as unreachable until it recovers.
struct RelayPoolSection: View {
    let circleId: String
    @ObservedObject private var mailbox = RelayMailboxStore.shared
    @ObservedObject private var health = RelayHealth.shared
    @ObservedObject private var relay = RelayHost.shared

    private var relays: [String] { mailbox.relays(forCircle: circleId) }

    var body: some View {
        if !relays.isEmpty {
            Section {
                ForEach(relays, id: \.self) { node in
                    // "Reachable" now means PROVEN — a successful op within 15 min — not merely
                    // "no recent failure", which showed long-dead relays as green forever.
                    let proven = health.provenAlive(node, withinMs: 900_000)
                    let backedOff = !health.available(node)
                    let isSelf = relay.serving && node == relay.nodeId
                    HStack(spacing: 10) {
                        Image(systemName: (proven || isSelf) ? "circle.fill"
                                          : (backedOff ? "exclamationmark.triangle.fill" : "circle.dotted"))
                            .font(.caption2)
                            .foregroundStyle((proven || isSelf) ? Color.green : (backedOff ? Color.orange : Color.secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(node.prefix(12))…").font(.system(.footnote, design: .monospaced))
                            Text(isSelf ? "This device · \(backedOff ? "backing off" : "reachable")"
                                        : (proven ? "Reachable"
                                           : (backedOff ? "Unreachable — retrying" : "Not verified recently")))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // A visible Forget button — `.swipeActions` is ignored inside a Form on macOS, so
                        // swipe-to-forget never worked there. The button works on every platform.
                        Button(role: .destructive) { FeedStore.shared.forgetRelay(node) } label: {
                            Image(systemName: "trash").font(.footnote)
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this relay everywhere")
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            FeedStore.shared.forgetRelay(node)
                        } label: { Label("Forget", systemImage: "trash") }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            FeedStore.shared.forgetRelay(node)
                        } label: { Label("Forget", systemImage: "trash") }
                    }
                }
            } header: {
                Text(relays.count == 1 ? "Relay" : "Relays · \(relays.count)")
            } footer: {
                Text("Posts and media are mirrored to every relay here and read from any that's reachable, so your circle keeps syncing as long as one is up. A relay that fails is paused and retried automatically. Swipe a relay to forget it everywhere.")
            }
        }
    }
}

/// Public HTTPS front door for the in-app relay (Mac only in practice — cloudflared is bundled
/// for HavenMac). Shared by Storage settings and the Relays hub so the controls are never buried
/// in a view that nothing navigates to.
///
/// Modes (see docs/CLOUDFLARE-TUNNEL.md):
/// - **auto** — free `*.trycloudflare.com` when the relay starts (hostname changes on restart)
/// - **bundled** — Haven runs cloudflared with your Zero Trust install token + custom domain
/// - **manual** — you run any tunnel/proxy; Haven only announces the URL
struct RelayFrontDoorControls: View {
    @ObservedObject private var tunnel = CloudflaredTunnel.shared
    @ObservedObject private var relay = RelayHost.shared

    private var help: String {
        switch tunnel.frontDoorMode {
        case "manual":
            return "Manual: point your proxy at http://127.0.0.1:8675 (path router: media + DERP) or :8674/:3340 separately. Haven only announces the HTTPS URL(s) — works even if free Cloudflare tunnels are blocked."
        case "bundled":
            return "Custom domain: paste media domain + Zero Trust install token. CF origin → http://127.0.0.1:8675 (path router fronts media + DERP). Optional sibling DERP URL if you dual-route without the path router."
        default:
            return "Auto: free ephemeral trycloudflare.com for media + a second free tunnel for DERP fabric. Hostnames change on restart — use Custom domain or Manual for stable always-on."
        }
    }

    var body: some View {
        Picker("Public front door", selection: Binding(
            get: { tunnel.frontDoorMode },
            set: { tunnel.frontDoorMode = $0 }
        )) {
            Text("Free trycloudflare (auto)").tag("auto")
            Text("Custom domain (Haven runs cloudflared)").tag("bundled")
            Text("Manual / external tunnel").tag("manual")
        }
        if tunnel.frontDoorMode != "auto" {
            TextField("Media public URL (https://relay.example.com)", text: Binding(
                get: { tunnel.configuredPublicURL },
                set: { v in
                    tunnel.configuredPublicURL = v
                    if relay.serving { FeedStore.shared.reannounceOwnRelay() }
                }
            ))
            .autocorrectionDisabled().havenAutocap(.never)
            .textContentType(.URL)
            // Optional dedicated DERP fabric URL when media and DERP use different public hosts.
            TextField("DERP fabric URL (optional)", text: Binding(
                get: { UserDefaults.standard.string(forKey: "haven.relay.derpURL") ?? "" },
                set: { v in
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if t.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "haven.relay.derpURL")
                    } else {
                        UserDefaults.standard.set(t, forKey: "haven.relay.derpURL")
                    }
                    // Announce immediately when hosting; process fabric policy updates for peers.
                    // Local DERP listen is already up — public URL is gossip only.
                    if relay.serving, !relay.nodeId.isEmpty {
                        RelayMailboxStore.shared.setDerpUrl(relay.nodeId, url: t.isEmpty ? nil : t)
                        FeedStore.shared.reannounceOwnRelay()
                    }
                }
            ))
            .autocorrectionDisabled().havenAutocap(.never)
            .textContentType(.URL)
            Text("Leave DERP empty to reuse the media URL (path router unifies both on :8675). Sibling hostname example: https://derp.example.com → http://127.0.0.1:3340.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if tunnel.frontDoorMode == "bundled" {
            SecureField("Cloudflare tunnel install token", text: Binding(
                get: { tunnel.tunnelToken },
                set: { tunnel.tunnelToken = $0 }
            ))
        }
        if let live = tunnel.publicURL, !live.isEmpty, tunnel.frontDoorMode == "auto" {
            Label("Live: \(live)", systemImage: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        Text(help)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Mailbox controls for a circle's settings. Prefer wiring this from circle settings when
/// per-circle hosting is shown; Mac global path uses StorageSettingsView + RelaysView.
struct CircleMailboxSection: View {
    let circleId: String
    @ObservedObject private var relay = RelayHost.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { relay.enabled }, set: { relay.setEnabled($0) })) {
                Label("Be this circle's relay", systemImage: "externaldrive.connected.to.line.below.fill")
            }
            .tint(HavenTheme.pink)
            if relay.serving && !relay.nodeId.isEmpty {
                Label("This device is relaying · \(String(relay.nodeId.prefix(8)))…", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if relay.enabled {
                Label("Starting…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
            if relay.enabled {
                RelayFrontDoorControls()
            }
            #else
            // iOS: announce-only public URL (no helper binary).
            if relay.serving && !relay.nodeId.isEmpty {
                TextField("Public relay URL (optional)", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "haven.relay.publicURL") ?? "" },
                    set: { v in
                        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t.isEmpty { UserDefaults.standard.removeObject(forKey: "haven.relay.publicURL") }
                        else { UserDefaults.standard.set(t, forKey: "haven.relay.publicURL") }
                        if relay.serving { FeedStore.shared.reannounceOwnRelay() }
                    }
                ))
                .autocorrectionDisabled().havenAutocap(.never)
                .font(.caption)
            }
            #endif
        } header: {
            Text("Relay")
        } footer: {
            Text("Where this circle's sealed posts & media live so they reach people who were offline. Leave a device on as the relay (easy), or point at an external relay / your own S3 bucket under Advanced. On Mac, set a custom Cloudflare domain + tunnel token so the bundled cloudflared connector serves a stable HTTPS front door (see docs/CLOUDFLARE-TUNNEL.md). Blobs stay E2E-sealed; the tunnel only moves ciphertext.")
                .fixedSize(horizontal: false, vertical: true)
        }
        RelayPoolSection(circleId: circleId)
        Section {
            NavigationLink { AdvancedStorageView(circleId: circleId) } label: {
                Label("Advanced — external relay or S3 bucket", systemImage: "slider.horizontal.3")
            }
        }
    }
}

/// Power-user storage, one tap below the simple relay toggle on the Storage screen: connect an
/// external `haven-relay` daemon by node id, or bring your own S3-compatible bucket. Kept off the
/// main screen so the common path (flip "Be your circle's relay") stays clean — advanced users
/// drill in when they need it.
struct AdvancedStorageView: View {
    var circleId: String? = nil
    @ObservedObject private var store = StorageStore.shared
    @State private var relayNodeInput = ""
    @State private var relayAdopted = false
    @State private var linkCopied = false
    @State private var applyToAll = true
    @State private var shared = false

    private var cid: String { circleId ?? FeedStore.shared.activeCircleId }

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                // Connect an external always-on relay daemon (Mac/Linux/an old device running
                // `haven-relay`): hand it this circle's link, then paste back the node id it prints
                // so the whole circle adopts it.
                Section {
                    Button {
                        if let link = FeedStore.shared.relayLinkForAllCircles() ?? FeedStore.shared.relayLink() {
                            PlatformPasteboard.string = link
                            linkCopied = true
                        }
                    } label: {
                        Label(linkCopied ? "Copied — run: haven-relay run --link …" : "1. Copy my relay link (all circles)",
                              systemImage: linkCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(linkCopied ? Color.green : HavenTheme.pink)
                    }
                    TextField("2. Paste node id (64 hex) or interface JSON", text: $relayNodeInput)
                        .autocorrectionDisabled().havenAutocap(.never)
                        .font(.system(.footnote, design: .monospaced))
                    Toggle("Use for all my circles (now & future)", isOn: $applyToAll).tint(HavenTheme.pink)
                    Button {
                        let raw = relayNodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let okBare = raw.count == 64 && raw.allSatisfy({ $0.isHexDigit })
                        let okJson = raw.hasPrefix("{") && raw.contains("node")
                        guard okBare || okJson else { return }
                        let targets = applyToAll ? FeedStore.shared.circles.map(\.id) : [cid]
                        FeedStore.shared.adoptRelayNode(raw, circleIds: targets, setDefault: applyToAll)
                        relayAdopted = true; relayNodeInput = ""
                    } label: {
                        Label(applyToAll ? "Connect for all my circles" : "Connect for this circle",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled({
                        let t = relayNodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        return !(t.count == 64 || (t.hasPrefix("{") && t.contains("node")))
                    }())
                    if relayAdopted {
                        Label("Connected — used as the relay", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                } header: { Text("Connect an external relay") }
                footer: {
                    Text("Running `haven-relay` on a Mac, Linux box, or a spare device? Copy the link above and start it with `haven-relay run --link <link>`, then paste back the interface JSON it prints (or the bare node id from `haven-relay id`). The JSON also carries media URL + Haven fabric DERP so n0 is not required. No cloud, no credentials.")
                }

                Section {
                    Text("Bring your own S3-compatible bucket instead: your key stays on this device and the circle gets scoped, expiring **pre-signed URLs**, never the secret.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Your own S3 bucket") }

                s3Section
            }
            .scrollContentBackground(.hidden)
        }
        .havenSettingsForm()
        .navigationTitle("Advanced")
        .havenInlineNavTitle()
    }

    @ViewBuilder private var s3Section: some View {
        Section {
            TextField("Endpoint (e.g. s3.amazonaws.com)", text: $store.s3Endpoint).autocorrectionDisabled().havenAutocap(.never)
            TextField("Region", text: $store.s3Region).autocorrectionDisabled().havenAutocap(.never)
            TextField("Bucket", text: $store.s3Bucket).autocorrectionDisabled().havenAutocap(.never)
            TextField("Access key id", text: $store.s3AccessKey).autocorrectionDisabled().havenAutocap(.never)
            SecureField("Secret access key", text: $store.s3Secret)
            if store.s3Configured {
                Label("Saved on this device", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
            }
        } header: { Text("Your S3-compatible bucket") }
        footer: { Text("Works with AWS S3, Cloudflare R2, Backblaze B2, rclone serve s3, etc. Keys are stored only in this device's Keychain — never on any server.") }

        if store.s3Configured {
            Section {
                Toggle(isOn: $store.shareCircleMedia) {
                    Label("Be the circle's backup", systemImage: "heart.circle.fill")
                }
                .tint(HavenTheme.pink)
                Button {
                    FeedStore.shared.shareBucketWithCircle(); shared = true
                } label: {
                    Label(shared ? "Shared with your circle ✓" : "Share this bucket as my circle's relay",
                          systemImage: "antenna.radiowaves.left.and.right")
                }
                .tint(HavenTheme.pink)
            } header: { Text("Volunteer as tribute") }
            footer: { Text("Your bucket becomes the circle's shared relay: every post is stored sealed and re-served to anyone who's missing it — so messages and memories arrive even when the sender is offline and you're never online at the same time. Tap “Share as my circle's relay” to send these credentials (sealed, only your circle can open them) so everyone uses the same bucket — rent one from any S3 provider, no server to run. Heads up: members you share with can read (still sealed) and write to the bucket, so only share with a circle you trust, and rotate the key if someone leaves.") }
        }
    }
}

/// OAuth 2.0 PKCE helpers (public client — no secret). Retained for a future
/// cloud-drive integration; not wired to any provider today (iCloud + S3 only).
enum PKCE {
    static func verifier() -> String { base64url(randomBytes(32)) }
    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal Keychain string store for storage credentials/tokens.
enum Keychain {
    private static let service = "com.blaineam.kith.storage"
    /// Data-protection keychain (entitlement-governed, no repeat macOS prompts) — iOS no-op. See
    /// AccountStore for the same pattern + migration rationale.
    private static func base(_ key: String, dataProtection: Bool = true) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: key]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }
    static func set(_ value: String, for key: String) {
        for dp in [true, false] { SecItemDelete(base(key, dataProtection: dp) as CFDictionary) }
        guard !value.isEmpty else { return }
        var add = base(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        func read(dataProtection: Bool) -> Data? {
            var q = base(key, dataProtection: dataProtection)
            q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
        }
        if let d = read(dataProtection: true) { return String(data: d, encoding: .utf8) }
        // Legacy keychain fallback → migrate forward (drop legacy only after the DP write lands).
        guard let d = read(dataProtection: false) else { return nil }
        var add = base(key)
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            SecItemDelete(base(key, dataProtection: false) as CFDictionary)
        }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Relays (global) — the "You ▸ Settings ▸ Relays" hub
//
// One place to manage EVERY configured relay (active + deactivated), add unlimited new ones (a Haven
// relay node, or an S3 bucket as store-and-forward), and pick the default every future unconfigured
// circle inherits. Removing a relay DEACTIVATES it (the config survives) so it can come back; "Delete
// now" erases it for good. Mirrors the deactivate-not-erase model in RelayMailboxStore.

/// How much of your circles' media this machine is willing to hold, and for how long.
///
/// Lives in its own view because there is more than one door into "this device is a relay" — the
/// Storage screen and the Relays screen (which is how macOS reaches it, via Circle settings →
/// Manage relays). These first shipped inline on the Storage screen only, so a Mac host — the
/// machine most likely to be left running as a relay, and the one where an unbounded store actually
/// matters — never saw them. Anywhere the host toggle appears, these belong with it.
struct RelayRetentionControls: View {
    @ObservedObject private var relay = RelayHost.shared

    var body: some View {
        if relay.enabled {
            Picker(selection: Binding(get: { relay.mediaMaxAgeDays },
                                      set: { relay.mediaMaxAgeDays = $0 })) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("No limit").tag(0)
            } label: { Label("Keep media for", systemImage: "clock.arrow.circlepath") }

            Picker(selection: Binding(get: { relay.mediaMaxBytes },
                                      set: { relay.mediaMaxBytes = $0 })) {
                Text("8 GB").tag(UInt64(8) << 30)
                Text("32 GB").tag(UInt64(32) << 30)
                Text("128 GB").tag(UInt64(128) << 30)
                Text("512 GB").tag(UInt64(512) << 30)
                Text("No limit").tag(UInt64(0))
            } label: { Label("Media storage limit", systemImage: "internaldrive") }

            Text(relay.serving
                 ? "Changes apply next time the relay starts — switch the relay off and on to apply them now."
                 : "Whichever limit is reached first wins: old media is swept on age, and the oldest goes first if the size cap is hit. Undelivered messages are never swept — only media.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RelaysView: View {
    @ObservedObject private var store = RelayMailboxStore.shared
    @ObservedObject private var health = RelayHealth.shared
    @ObservedObject private var relay = RelayHost.shared
    @State private var showAdd = false
    @State private var renaming: RelayEntry?
    @State private var renameText = ""

    private var entries: [RelayEntry] { store.allEntries() }

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                // This-device relay toggle: the zero-setup path that makes this device a relay.
                Section {
                    Toggle(isOn: Binding(get: { relay.enabled }, set: { relay.setEnabled($0) })) {
                        Label("Be a relay on this device", systemImage: "externaldrive.connected.to.line.below.fill")
                    }
                    .tint(HavenTheme.pink)
                    if relay.serving && !relay.nodeId.isEmpty {
                        Label("Relaying · \(String(relay.nodeId.prefix(8)))…", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else if relay.enabled {
                        Label("Starting…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    RelayRetentionControls()
                    // Mac hosts need front-door controls here too — this is the path Circle settings
                    // → Manage relays opens, and Storage was previously the only place that had
                    // the toggle without the Cloudflare/Manual settings.
                    #if os(macOS)
                    if relay.enabled {
                        RelayFrontDoorControls()
                    }
                    #endif
                } header: { Text("This device") }
                footer: { Text("Turn this device into an always-available relay — sealed (unreadable) posts and media live here and re-serve to your circles when someone's been offline. A Mac left running is ideal; on iPhone it serves while Haven is open. On Mac, pick a public front door below when the relay is on (free trycloudflare, custom domain, or your own tunnel).") }

                if entries.isEmpty {
                    Section { Text("No relays configured yet. Add one below, or flip the toggle above to use this device.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Section {
                        ForEach(entries) { e in relayRow(e) }
                    } header: { Text("Configured relays · \(entries.count)") }
                    footer: { Text("The default relay (★) is inherited by every circle that hasn't picked its own. Removing a relay DEACTIVATES it — its name and circle settings survive so you can turn it back on later. An inactive relay unseen for a week is cleaned up automatically.") }
                }

                Section {
                    Button { showAdd = true } label: {
                        Label("Add relay", systemImage: "plus.circle.fill").foregroundStyle(HavenTheme.pink)
                    }
                } footer: { Text("Add a Haven relay by node id, or bring your own S3 bucket as a store-and-forward relay.") }
            }
            .scrollContentBackground(.hidden)
        }
        .havenSettingsForm()
        .navigationTitle("Relays")
        .havenInlineNavTitle()
        .sheet(isPresented: $showAdd) { AddRelaySheet() }
        .alert("Rename relay", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let e = renaming { store.rename(e.hex, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }.havenPausesPostAudio()
    }

    @ViewBuilder private func relayRow(_ e: RelayEntry) -> some View {
        let isDefault = store.defaultNodeHex == e.hex
        let isSelf = relay.serving && e.hex == relay.nodeId
        // Green means PROVEN (a successful op within 15 min), not "no recent failure" —
        // long-dead relays used to sit green forever because nothing had dialed them lately.
        let proven = health.provenAlive(e.hex, withinMs: 900_000) || isSelf
        let backedOff = !health.available(e.hex)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: e.isS3 ? "externaldrive.fill"
                          : (e.active ? (proven ? "circle.fill" : (backedOff ? "exclamationmark.triangle.fill" : "circle.dotted")) : "pause.circle.fill"))
                    .font(.caption2)
                    .foregroundStyle(!e.active ? Color.secondary : (e.isS3 ? Color.blue : (proven ? Color.green : (backedOff ? Color.orange : Color.secondary))))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(e.name).font(.subheadline.weight(.medium))
                        if isDefault { Image(systemName: "star.fill").font(.caption2).foregroundStyle(HavenTheme.pink) }
                    }
                    Text(statusLine(e, isSelf: isSelf, proven: proven, backedOff: backedOff))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(e.isS3 ? e.hex : "\(e.hex.prefix(16))…")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            // A private/tailnet address is a SHORTCUT, not the relay's reachability. Members who
            // can't use it still reach this relay peer-to-peer — that path is the whole point, and
            // it's why the Docker relay, which advertises no address at all, works fine. So this is
            // informational: it explains why some members connect slower, and must NOT read as
            // "broken" or send anyone hunting for a different relay.
            if privateOnly(e) {
                Label("Direct address works on your network only — others connect peer-to-peer (slower first connect).",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if e.active {
                    Button { store.forget(nodeHex: e.hex) } label: { Label("Deactivate", systemImage: "pause.fill") }
                } else {
                    Button { store.reactivate(e.hex) } label: { Label("Reactivate", systemImage: "play.fill") }
                        .tint(.green)
                }
                if !isDefault {
                    Button { store.setDefault(e.hex) } label: { Label("Default", systemImage: "star") }
                } else {
                    Button { store.setDefault(nil) } label: { Label("Unset default", systemImage: "star.slash") }
                }
                Spacer()
                // Secondary actions in a roomy menu so the primary buttons stay big + tappable.
                Menu {
                    Button { renaming = e; renameText = e.name } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { store.eraseNow(e.hex) } label: { Label("Delete now", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                }
                .frame(width: 28)
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }

    /// True when this relay advertises HTTP addresses and NONE of them can be reached from another
    /// network. An iroh-only relay (no HTTP at all) is not flagged — it has no misleading fast path,
    /// which is exactly why the Dockerised NAS relay always behaved better than an in-app Mac one.
    private func privateOnly(_ e: RelayEntry) -> Bool {
        guard !e.isS3, let urls = e.httpUrls, !urls.isEmpty else { return false }
        return !urls.contains { RelayAddress.reachableByOthers($0) }
    }

    private func statusLine(_ e: RelayEntry, isSelf: Bool, proven: Bool, backedOff: Bool) -> String {
        if !e.active { return "Deactivated — config kept" }
        if e.isS3 { return "S3 bucket · store-and-forward" }
        if isSelf { return "This device · \(backedOff ? "backing off" : "reachable")" }
        if proven { return "Reachable" }
        return backedOff ? "Unreachable — retrying" : "Not verified recently"
    }
}

/// "Add relay" sheet: a Haven relay (paste a node id / link) OR an S3 bucket (with a store-and-forward
/// disclaimer). The S3 secret goes to the Keychain via SharedMailboxStore — never UserDefaults.
struct AddRelaySheet: View {
    @Environment(\.dismiss) private var dismiss
    enum Kind: String, CaseIterable { case haven = "Haven relay", s3 = "S3 bucket" }
    @State private var kind: Kind = .haven
    @State private var name = ""
    @State private var nodeInput = ""
    @State private var makeDefault = true
    @State private var linkCopied = false
    // S3 fields
    @State private var endpoint = ""
    @State private var region = "us-east-1"
    @State private var bucket = ""
    @State private var accessKey = ""
    @State private var secret = ""

    private var havenValid: Bool {
        let id = nodeInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return id.count == 64 && id.allSatisfy { $0.isHexDigit }
    }
    private var s3Valid: Bool { !endpoint.isEmpty && !bucket.isEmpty && !accessKey.isEmpty && !secret.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                Form {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Section {
                        TextField("Name (optional)", text: $name)
                        Toggle("Make the default for all circles", isOn: $makeDefault).tint(HavenTheme.pink)
                    }

                    if kind == .haven {
                        // Setting up a `haven-relay` daemon (or the Docker relay)? It needs THIS
                        // circle's link first; then it prints a node id you paste below. Surface the
                        // link-copy right here so the two-step flow is discoverable (it also lives on
                        // Storage ▸ Advanced ▸ Connect an external relay).
                        Section {
                            Button {
                                if let link = FeedStore.shared.relayLinkForAllCircles() ?? FeedStore.shared.relayLink() {
                                    PlatformPasteboard.string = link
                                    linkCopied = true
                                }
                            } label: {
                                Label(linkCopied ? "Copied — run: haven-relay run --link …"
                                                 : "Copy my relay link (all circles)",
                                      systemImage: linkCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                    .foregroundStyle(linkCopied ? Color.green : HavenTheme.pink)
                            }
                        } header: { Text("Running your own relay?") }
                        footer: { Text("For a `haven-relay` daemon or the Docker relay: copy this link, start the relay with it (`haven-relay run --link <link>`), then paste back the node id it prints below.") }

                        Section {
                            TextField("Node id (64 hex) or interface JSON", text: $nodeInput)
                                .autocorrectionDisabled().havenAutocap(.never)
                                .font(.system(.footnote, design: .monospaced))
                        } header: { Text("Haven relay") }
                        footer: { Text("Paste the interface JSON (or bare node id) printed by a `haven-relay` daemon, or another device that's acting as a relay. JSON includes media + Haven DERP fabric so the circle can drop n0.") }
                    } else {
                        Section {
                            TextField("Endpoint (e.g. s3.amazonaws.com)", text: $endpoint).autocorrectionDisabled().havenAutocap(.never)
                            TextField("Region", text: $region).autocorrectionDisabled().havenAutocap(.never)
                            TextField("Bucket", text: $bucket).autocorrectionDisabled().havenAutocap(.never)
                            TextField("Access key id", text: $accessKey).autocorrectionDisabled().havenAutocap(.never)
                            SecureField("Secret access key", text: $secret)
                        } header: { Text("S3 bucket") }
                        footer: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                                Text("Store-and-forward only: an S3 bucket holds sealed posts & media for offline delivery (mailbox/backup) — it is **not** a live P2P relay (no realtime fan-out). Your secret stays in this device's Keychain, never on any server.")
                            }.font(.caption)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .havenSettingsForm()
            .navigationTitle("Add relay")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.havenToolbarPill() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .havenToolbarPill(tint: HavenTheme.pink)
                        .disabled(kind == .haven ? !havenValid : !s3Valid)
                }
            }
        }.havenPausesPostAudio()
    }

    private func add() {
        let circles = FeedStore.shared.circles.map(\.id)
        if kind == .haven {
            let raw = nodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
            FeedStore.shared.adoptRelayNode(raw, circleIds: circles, setDefault: makeDefault)
            // Rename uses the resolved node hex (JSON paste stores under "node").
            var hex = raw.lowercased()
            if raw.hasPrefix("{"),
               let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let n = obj["node"] as? String {
                hex = n.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hex.count == 64 {
                RelayMailboxStore.shared.rename(hex, to: name)
            }
        } else {
            let cfg = S3Config(endpoint: endpoint, region: region.isEmpty ? "us-east-1" : region,
                               bucket: bucket, accessKey: accessKey, secret: secret)
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "S3 · \(bucket)" : name
            FeedStore.shared.addS3Relay(cfg, name: label, circleIds: circles, setDefault: makeDefault)
        }
        dismiss()
    }
}
