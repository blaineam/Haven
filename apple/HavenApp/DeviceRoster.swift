import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// This device's OWN keypair — distinct from the account master seed, never synced, never leaves the
/// device. Multi-device (D16): a linked device acts under this key plus an account-signed credential,
/// so the account can authorize it and revoke it individually.
///
/// ⚠️ **This key is additive today, not the device's operative identity.** The engine still runs under
/// the copied master seed (`HavenSocial(seed:)`), because linking transfers the seed itself
/// (`AccountStore.transferCode` → `haven-seed:` / `haven-link:`) and enrollment only hands a
/// credential to a device that already has it. So a linked device is cryptographically the account,
/// and revoking it does not take that away — see `DeviceRosterManager.revoke`.
///
/// The finishing move is D16 Phase 2's **seed-drop**: a device links by getting a credential for THIS
/// key and never receives the seed, and the engine runs under the device key with peers verifying the
/// device→account credential chain. Until that lands, revocation is honest only against a device that
/// is lost, not one that is compromised. Don't let this file's existence imply otherwise.
enum DeviceKeyStore {
    private static let service = "com.blaineam.kith"
    private static let accountKey = "haven.device-key-seed"

    /// The identity handed out this process. Cached so repeated calls return the SAME device key
    /// (callers derive `deviceNodeHex()` from it and compare it against the signed roster).
    private static var cached: Account?
    /// True when the keychain was unreadable and we handed out a throwaway: the real seed was NOT
    /// touched. Retried on the next call, so it settles onto the real key once the device unlocks.
    private(set) static var usingTemporaryIdentity = false

    /// This device's stable device Account — created once (32-byte seed in the data-protection keychain,
    /// device-local, never iCloud-synced).
    static func deviceAccount() -> Account {
        if let acct = cached, !usingTemporaryIdentity { return acct }   // settled on the real key
        switch loadSeedStatus() {
        case .found(let seed):
            guard let acct = try? Account.fromSeed(seed: seed) else {
                // Seed present but un-deriveable — NEVER overwrite it (mirrors AccountStore:35-38).
                return temporaryIdentity()
            }
            cached = acct; usingTemporaryIdentity = false
            return acct
        case .notFound:
            // Genuinely no seed → first run on this device. The ONLY case allowed to write.
            let fresh = Account.generate()
            saveSeed(fresh.secretSeed())
            cached = fresh; usingTemporaryIdentity = false
            return fresh
        case .lockedOrError:
            return temporaryIdentity()
        }
    }

    /// A throwaway used only while the real seed is unreadable. Never saved, and cached so this
    /// process keeps one stable id instead of minting a fresh key on every call.
    private static func temporaryIdentity() -> Account {
        if let acct = cached, usingTemporaryIdentity { return acct }
        let temp = Account.generate()
        cached = temp; usingTemporaryIdentity = true
        return temp
    }
    static func deviceNodeHex() -> String { deviceAccount().nodeIdHex() }
    static func deviceBundle() -> Data { deviceAccount().publicBundle() }

    /// A friendly label for this device (shown in "Authorized devices").
    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: accountKey, kSecUseDataProtectionKeychain as String: true]
    }
    /// The load result must distinguish three cases so we never wipe a live device key:
    ///   • `.found`         — seed is present and readable now.
    ///   • `.notFound`      — genuinely no seed (first run) → the only case allowed to generate.
    ///   • `.lockedOrError` — unreadable RIGHT NOW (locked / errSecInteractionNotAllowed). A real
    ///                        seed almost certainly exists; regenerating would destroy it.
    private enum SeedStatus { case found(Data), notFound, lockedOrError }

    /// A nil read is NOT absence. The item is `AfterFirstUnlockThisDeviceOnly` (`saveSeed`), so a
    /// read before first unlock returns `errSecInteractionNotAllowed` — indistinguishable from
    /// "new device" if the OSStatus is dropped. Only `errSecItemNotFound` means absent.
    private static func loadSeedStatus() -> SeedStatus {
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            // Success with no/again-unreadable data: present, not absent.
            guard let data = item as? Data, data.count == 32 else { return .lockedOrError }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .lockedOrError
        }
    }
    private static func saveSeed(_ seed: Data) {
        SecItemDelete(query() as CFDictionary)
        var add = query()
        add[kSecValueData as String] = seed
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// This device's account-signed credential (proof it's authorized), stored once enrollment grants it.
/// Its presence means "this device has been authorized with its own key"; the seed-drop that finalizes
/// revocation is a separate, guarded transition.
enum DeviceCredentialStore {
    private static let key = "haven.device-credential.v1"
    static func save(_ cred: Data) { UserDefaults.standard.set(cred, forKey: key) }
    static func load() -> Data? { UserDefaults.standard.data(forKey: key) }
    static var isAuthorized: Bool { load() != nil }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// One device in the account's roster (for the Authorized-Devices UI).
struct RosterDevice: Identifiable, Equatable {
    let nodeHex: String
    let name: String
    let isThisDevice: Bool
    let isPrimary: Bool          // the account key itself (the device that holds the master seed)
    var id: String { nodeHex }
}

/// Maintains the account's signed device roster on the **primary** (the device holding the master seed).
/// The roster = the account key as "device #0" (so the seed-holding device keeps receiving) plus each
/// linked device's own key. Issuing/revoking re-signs a versioned DeviceList + per-device credentials
/// and pushes them to the engine (`setMyDeviceRoster`); the engine + contacts pick it up via sync.
@MainActor
final class DeviceRosterManager: ObservableObject {
    static let shared = DeviceRosterManager()

    @Published private(set) var devices: [RosterDevice] = []

    private struct Entry { var bundle: Data; var name: String; var isPrimary: Bool }
    private var entries: [String: Entry] = [:]   // nodeHex → entry (active devices)
    private var revoked: Set<String> = []
    private var version: UInt64 = 0
    private var primaryHex = ""

    private let store = UserDefaults.standard
    private let key = "haven.deviceRoster.v2"

    private init() { load(); rebuild() }

    var isEnabled: Bool { version > 0 }

    /// Turn multi-device on: register the account key as the primary "device #0". Idempotent.
    @discardableResult
    func enable(social: HavenSocial?, accountSeed: Data, accountBundle: Data, accountHex: String) -> Bool {
        primaryHex = accountHex
        if entries[accountHex] == nil {
            entries[accountHex] = Entry(bundle: accountBundle, name: "Primary (this account's master key)", isPrimary: true)
        }
        return resign(social: social, accountSeed: accountSeed)
    }

    /// Authorize a newly-linked device. Returns that device's credential (to hand back via QR-C), or nil.
    func addLinkedDevice(bundle: Data, nodeHex: String, name: String,
                         social: HavenSocial?, accountSeed: Data) -> Data? {
        revoked.remove(nodeHex)
        entries[nodeHex] = Entry(bundle: bundle, name: name, isPrimary: false)
        guard resign(social: social, accountSeed: accountSeed) else { return nil }
        let now = UInt64(Date().timeIntervalSince1970)
        return try? issueDeviceCredential(accountSeed: accountSeed, deviceBundle: bundle, name: name, createdAt: now)
    }

    /// Revoke a device: drop it from the active set, bump the version, re-sign. It stops being a
    /// recipient of any circle's future key commits under its DEVICE key.
    ///
    /// ⚠️ This is **not** cryptographic revocation against an attacker, and must not be described as
    /// such. Linking copies the master seed, so every linked device also holds the account key — and
    /// circle key commits always seal to the account key as well (`recipients_with_devices`). Someone
    /// who extracted the seed therefore keeps decrypting after this call, and can re-sign a
    /// higher-version roster that re-adds them (the roster's authority IS the account key, so no rule
    /// here can bind them). What this DOES defeat: a device you no longer control whose keychain is
    /// intact — a lost or stolen phone, the ordinary case. For a device you believe was compromised,
    /// the only real remedy today is a new identity. See [`revocationCaveat`].
    @discardableResult
    func revoke(_ nodeHex: String, social: HavenSocial?, accountSeed: Data) -> Bool {
        guard nodeHex != primaryHex else { return false }   // never revoke the master key
        entries[nodeHex] = nil
        revoked.insert(nodeHex)
        return resign(social: social, accountSeed: accountSeed)
    }

    /// Step DOWN as primary: forget this device's roster entirely so it stops asserting the master key.
    /// Needed because both devices share the seed, so the WRONG one (e.g. the Mac) can claim primary and
    /// get stuck. After this the device shows the link button again and can be linked to the real primary
    /// (whose higher-version roster then supersedes anything this device published). Reversible.
    func stepDown() {
        version = 0; primaryHex = ""; entries = [:]; revoked = []
        DeviceCredentialStore.clear()   // also drop any stale linked-device credential → clean re-link
        rebuild(); save()
    }

    /// Re-issue every active device's credential + a fresh signed DeviceList and push to the engine.
    @discardableResult
    private func resign(social: HavenSocial?, accountSeed: Data) -> Bool {
        version &+= 1
        let now = UInt64(Date().timeIntervalSince1970)
        var creds: [Data] = []
        var activeIds: [Data] = []
        for (hex, e) in entries where !revoked.contains(hex) {
            guard let id = Self.hexToData(hex) else { continue }
            activeIds.append(id)
            if let c = try? issueDeviceCredential(accountSeed: accountSeed, deviceBundle: e.bundle, name: e.name, createdAt: now) {
                creds.append(c)
            }
        }
        let revokedIds = revoked.compactMap { Self.hexToData($0) }
        guard let list = try? signDeviceList(accountSeed: accountSeed, version: version, updatedAt: now,
                                             devices: activeIds, revoked: revokedIds) else { return false }
        let ok = social?.setMyDeviceRoster(list: list, credentials: creds) ?? false
        rebuild(); save()
        return ok
    }

    private func rebuild() {
        let me = DeviceKeyStore.deviceNodeHex()
        devices = entries.map { (hex, e) in
            RosterDevice(nodeHex: hex, name: e.name,
                         isThisDevice: hex == me || (e.isPrimary && AccountStore.currentNodeHex() == hex),
                         isPrimary: e.isPrimary)
        }.sorted { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }
    }

    static func hexToData(_ hex: String) -> Data? {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        return d.count == 32 ? d : nil
    }

    // MARK: persistence
    private struct Saved: Codable {
        var version: UInt64; var primaryHex: String
        var entries: [String: EntryCodable]; var revoked: [String]
        struct EntryCodable: Codable { var bundle: Data; var name: String; var isPrimary: Bool }
    }
    private func save() {
        let s = Saved(version: version, primaryHex: primaryHex,
                      entries: entries.mapValues { .init(bundle: $0.bundle, name: $0.name, isPrimary: $0.isPrimary) },
                      revoked: Array(revoked))
        if let d = try? JSONEncoder().encode(s) { store.set(d, forKey: key) }
    }
    private func load() {
        guard let d = store.data(forKey: key), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        version = s.version; primaryHex = s.primaryHex; revoked = Set(s.revoked)
        entries = s.entries.mapValues { Entry(bundle: $0.bundle, name: $0.name, isPrimary: $0.isPrimary) }
    }
}

/// Manage which devices can act for this account, and revoke any of them. The primary (master-key)
/// device turns on management; another device asks (over the local mesh) to be authorized with its own
/// key. Revoke cuts a device off from everything posted afterward.
struct AuthorizedDevicesView: View {
    /// Passed in so this screen can show a link code for a NEW device to scan/paste. Optional only so
    /// older call sites still compile; always pass it where you can.
    var accountStore: AccountStore? = nil
    @ObservedObject private var roster = DeviceRosterManager.shared
    @ObservedObject private var store = FeedStore.shared
    @State private var revokeTarget: RosterDevice?
    @State private var confirmStepDown = false

    private var thisDeviceAuthorized: Bool { DeviceCredentialStore.isAuthorized }
    private var hasSeed: Bool { AccountStore.storedSeed() != nil }

    /// The truth about what revoking buys you, stated where the user decides. Linking copies the master
    /// key, so revoking removes a device's access only if nobody pulled that key off it; against a
    /// genuinely compromised device the remedy is a new identity, and a user staring at a "revoked"
    /// checkmark should not think otherwise. Kept in one place so the dialog and the footer can't drift.
    static let revocationCaveat =
        "Revoking works if the device is simply out of your hands — lost or stolen. It can’t help if "
        + "someone has extracted your master key from it: linked devices hold a copy of that key, and "
        + "revoking doesn’t take it back. If you think that happened, start a new identity in Advanced."

    /// This device's role, shown at the top so a linked Mac clearly reads as "linked", not "primary".
    private var role: (icon: String, title: String, subtitle: String) {
        if roster.isEnabled {
            return ("key.fill", "This is your primary device",
                    "It holds your master key and authorizes or revokes your other devices.")
        } else if thisDeviceAuthorized {
            return ("checkmark.seal.fill", "This is a linked device",
                    "It holds a copy of your master key and syncs with your primary device, which can revoke it.")
        } else {
            return ("laptopcomputer", "This device isn’t linked yet",
                    "Make it your primary, or link it to the device that already is.")
        }
    }

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: role.icon).font(.title3).foregroundStyle(HavenTheme.pink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.title).font(.subheadline.weight(.semibold))
                            Text(role.subtitle).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                // Show a link code for a NEW device to scan/paste — this was missing, so there was no way
                // to actually link from here. Any device holding the account can present it.
                if let accountStore, hasSeed {
                    Section {
                        NavigationLink { LinkDeviceView(accountStore: accountStore) } label: {
                            Label("Link another device…", systemImage: "qrcode")
                        }
                    } footer: { Text("Show a QR/code for your other device to scan or paste on its welcome screen (“Link this as another of my devices”).")
                        .fixedSize(horizontal: false, vertical: true) }
                }
                Section {
                    if roster.devices.isEmpty {
                        Text("No devices linked yet.").foregroundStyle(.secondary)
                    }
                    ForEach(roster.devices) { d in
                        HStack(spacing: 12) {
                            Image(systemName: d.isPrimary ? "key.fill" : (d.isThisDevice ? "checkmark.seal.fill" : "laptopcomputer"))
                                .foregroundStyle(d.isPrimary ? HavenTheme.pink : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.subheadline.weight(.medium))
                                Text(d.isPrimary ? "Master key" : (d.isThisDevice ? "This device" : "Linked device"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !d.isPrimary {
                                Button(role: .destructive) { revokeTarget = d } label: { Text("Revoke") }
                                    .buttonStyle(.borderless).tint(.red)
                            }
                        }
                    }
                } header: { Text("Authorized devices") }
                footer: { Text("Each linked device holds a copy of your master key and has its own key on top, authorized by it. Revoking stops a device receiving what you post afterward. " + Self.revocationCaveat)
                    .fixedSize(horizontal: false, vertical: true) }

                // Only a device that ISN'T already the primary offers these. The primary (roster on) shows
                // just the roster + revoke above.
                if hasSeed && !roster.isEnabled {
                    Section {
                        // Glass pill on macOS (a bare Form Button bezels there); iOS row unchanged.
                        Button { store.enableDeviceRoster() } label: { Label("Make this my primary device", systemImage: "checkmark.shield") }
                            .havenToolbarPill()
                    } footer: { Text("The primary holds the master key and authorizes/revokes your other devices. Do this on ONE device (e.g. your iPhone).")
                        .fixedSize(horizontal: false, vertical: true) }
                }
                // This device IS the primary — let it step down if the wrong device claimed the role.
                if roster.isEnabled {
                    Section {
                        Button(role: .destructive) { confirmStepDown = true } label: {
                            Label("This isn’t my primary device", systemImage: "arrow.uturn.backward")
                        }
                        .havenToolbarPill(tint: .red)   // keep the destructive red the mac pill would drop
                    } footer: { Text("Stop this device acting as the primary (master key). Use it on your iPhone instead, then link this device to it.")
                        .fixedSize(horizontal: false, vertical: true) }
                }
                if !roster.isEnabled {
                    Section {
                        Button { store.requestDeviceEnrollment() } label: {
                            Label(thisDeviceAuthorized ? "Re-sync from my primary device" : "Make this a secure linked device",
                                  systemImage: thisDeviceAuthorized ? "arrow.triangle.2.circlepath" : "link.badge.plus")
                        }
                        .havenToolbarPill()
                    } footer: { Text(thisDeviceAuthorized
                        ? "This device is authorized. Pull your profile + posts from your primary device again (keep it nearby or online)."
                        : "Asks your primary device (keep it nearby or online) to authorize this device with its own key and send your profile + posts.")
                        .fixedSize(horizontal: false, vertical: true) }
                }
            }
            .havenSettingsForm()
        }
        .navigationTitle("Devices")
        .havenInlineNavTitle()
        .confirmationDialog(revokeTarget.map { "Revoke “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }),
                            titleVisibility: .visible) {
            if let t = revokeTarget {
                Button("Revoke device", role: .destructive) { store.revokeDevice(t.nodeHex); revokeTarget = nil }
            }
            Button("Cancel", role: .cancel) { revokeTarget = nil }
        } message: {
            Text("This device will no longer receive anything posted to your circles afterward. To use it again you'd re-link it.\n\n"
                 + Self.revocationCaveat)
        }
        .confirmationDialog("Stop being the primary device?", isPresented: $confirmStepDown, titleVisibility: .visible) {
            Button("Step down", role: .destructive) { store.stepDownAsPrimary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device will no longer hold the master-key role. Make your iPhone the primary, then link this device to it.")
        }
    }
}
