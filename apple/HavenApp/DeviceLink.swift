import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Move your identity to another device (another phone, the Mac, the web app). The
/// transfer code IS your master seed — anyone holding it becomes you — so it's shown
/// only behind a confirmation and meant to be scanned by *your* other device.
struct TransferIdentityView: View {
    let accountStore: AccountStore
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 44)).foregroundStyle(HavenTheme.pink).padding(.top, 8)
                    Text("Move to another device").font(.title3.bold())
                    Text("On your other device, choose **Restore identity** and scan this code. You'll be the same person in your circle — same posts, same contacts.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if revealed {
                        let code = accountStore.transferCode()
                        if let img = QRCode.image(from: code) {
                            Image(platformImage: img).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240)
                                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .screenshotProtected()   // the QR encodes the full identity — keep it out of screenshots/recordings (H2)
                        }
                        Button {
                            PlatformPasteboard.setSecret(code)   // local-only + expiring (it's the full identity)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy transfer code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered).tint(HavenTheme.pink)
                        Label("Anyone with this code can become you. Never share it with anyone else, and don't post it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Button { revealed = true } label: {
                            Label("Reveal transfer code", systemImage: "eye.fill")
                        }
                        .buttonStyle(BrandButtonStyle())
                        Text("Only do this with your own device in front of you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 520)                     // one readable column on wide macOS windows
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Transfer")
        .havenInlineNavTitle()
    }
}

/// Link a *second* device to this identity. Unlike "Move", linking is meant to keep both
/// devices active on the same identity — they each post and receive, and (once both hold the
/// same seed) can sync content to each other directly. The mechanism is the same transfer
/// code, framed for keeping both devices.
struct LinkDeviceView: View {
    let accountStore: AccountStore
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 44)).foregroundStyle(HavenTheme.pink).padding(.top, 8)
                    Text("Link a new device").font(.title3.bold())
                    Text("On your other device, choose **“Link this as another of my devices”** on its welcome screen (or Settings → Devices), then scan this code — or tap Copy and paste it there. Both devices then act as **you**, each posting + receiving and syncing directly when near or online together.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if revealed {
                        let code = accountStore.transferCode()
                        if let img = QRCode.image(from: code) {
                            Image(platformImage: img).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240)
                                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .screenshotProtected()   // the QR encodes the full identity (H2)
                        }
                        Button {
                            PlatformPasteboard.string = code
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy link code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered).tint(HavenTheme.pink)
                        Label("This code grants your identity. Only scan it onto a device you own — never share or post it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Button { revealed = true } label: {
                            Label("Show link code", systemImage: "qrcode")
                        }
                        .buttonStyle(BrandButtonStyle())
                        Text("Only do this with your own second device in front of you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Link device")
        .havenInlineNavTitle()
    }
}

// MARK: - Seedless enrollment (seed-drop S4)

/// PRIMARY side: show a one-time `haven-enroll:` QR so a NEW device can link WITHOUT ever receiving
/// the master seed. The new device gets its own key + an account-signed credential + a granted
/// self-sync key + a copy of the circles — all cryptographically revocable, unlike a copied seed.
/// Only a seed-holding primary can mint the ticket (it must issue the credential + seal the grant).
struct EnrollDeviceView: View {
    @ObservedObject private var store = FeedStore.shared
    @State private var ticket: EnrollTicketFfi?
    @State private var code = ""
    @State private var copied = false

    private var canPrimary: Bool { AccountStore.storedSeed() != nil }

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "qrcode").font(.system(size: 44)).foregroundStyle(HavenTheme.pink).padding(.top, 8)
                    Text("Link a new device").font(.title3.bold())
                    if !canPrimary {
                        // A seedless (linked) device can't authorize others — the primary is the sole authority.
                        Text("This is a linked device. Link new devices from your **primary device** (the one that holds your master key).")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        Text("On your new device, choose **“Link a device”** on its welcome screen, then scan this code. It gets its own key and a copy of your circles — it **never receives your master key**, so you can revoke it anytime.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                        if let img = QRCode.image(from: code), !code.isEmpty {
                            Image(platformImage: img).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240)
                                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                                .screenshotProtected()   // one-time, but still an authorization credential (H2)
                            Button {
                                PlatformPasteboard.string = code
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy link code", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered).tint(HavenTheme.pink)
                            Label("This code links one device, once, and expires after a few minutes. Only scan it onto a device you own.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal)
                        } else {
                            ProgressView().padding(.vertical, 40)
                        }
                        Label("Your primary device keeps handling notifications for the new device for now.",
                              systemImage: "bell.badge").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(20).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Link device").havenInlineNavTitle()
        .onAppear { mint() }
        // The confirmation the plan requires: a frame-28 request pops a sheet naming the device; only
        // the user's confirm issues the grant.
        .confirmationDialog(store.pendingEnrollRequest.map { "Link “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { store.pendingEnrollRequest != nil },
                                                 set: { if !$0 { store.declineSeedlessEnroll() } }),
                            titleVisibility: .visible) {
            if let req = store.pendingEnrollRequest {
                Button("Link this device") { store.confirmSeedlessEnroll(req) }
            }
            Button("Not now", role: .cancel) { store.declineSeedlessEnroll() }
        } message: {
            Text("A device calling itself “\(store.pendingEnrollRequest?.name ?? "")” is asking to join your account. Only link it if it's yours and in front of you.")
        }
    }

    private func mint() {
        guard canPrimary, let t = store.mintEnrollTicket() else { return }
        ticket = t
        code = (try? enrollTicketEncode(ticket: t)) ?? ""
    }
}

/// NEW-DEVICE side: scan/paste a `haven-enroll:` code (or a legacy `haven-seed:`/`haven-link:` code
/// from an older primary) to link this device. On a seedless enroll the device sends a frame-28
/// request and waits for the primary's confirmation; the flow completes when the account flips to
/// seedless. A legacy code falls back to the seed-adopting path so old primaries keep working.
struct EnrollScanView: View {
    @ObservedObject var accountStore: AccountStore
    var onLinked: () -> Void
    @ObservedObject private var store = FeedStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var scanning = true
    @State private var error = false
    @State private var waiting = false

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    Text("Link this device").font(.title3.bold()).padding(.top, 8)
                    Text("On your primary device, open **Settings → Devices → Link a device** (or its welcome screen) to show a code, then scan it here — or paste it below.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if scanning && !waiting {
                        QRScannerView { code in attempt(code) }
                            .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HavenTheme.brandHorizontal, lineWidth: 2))
                    }

                    if waiting {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Waiting for your primary device to confirm…").font(.subheadline).foregroundStyle(.secondary)
                            Text("Keep your primary device (iPhone) nearby or online and confirm the prompt there.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(.vertical, 8)
                    }

                    VStack(spacing: 8) {
                        TextField("Paste your link code", text: $pasted, axis: .vertical)
                            .havenAutocap(.never).autocorrectionDisabled()
                            .textFieldStyle(.plain).padding(12)
                            .havenGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Button { attempt(pasted) } label: { Label("Link from code", systemImage: "link.badge.plus") }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty || waiting)
                    }

                    if error {
                        Label("That code isn't valid. Check you copied the whole thing.", systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Label("This device joins your account with its own key and a copy of your circles. Your primary device can revoke it anytime.",
                          systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(20).frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Link").havenInlineNavTitle()
        // Enrollment completed: the account flipped to seedless (grant accepted + engine booted).
        .onChange(of: accountStore.seedless) { _, isSeedless in
            if isSeedless { onLinked(); dismiss() }
        }
        // The primary rejected/failed the grant — surface it and let the user re-scan.
        .onChange(of: store.seedlessEnrollFailed) { _, failed in
            if failed { error = true; waiting = false }
        }
    }

    private func attempt(_ raw: String) {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("haven-enroll:") {
            guard let ticket = try? enrollTicketParse(text: code) else { error = true; return }
            error = false; waiting = true
            store.beginSeedlessEnroll(ticket: ticket)   // sends frame-28; completes when accountStore.seedless flips
            return
        }
        // Legacy `haven-seed:` / `haven-link:` from an older primary → adopt the seed directly (kept
        // working per plan §6: the seed link stays valid during the transition).
        if accountStore.restore(fromTransferCode: code) {
            FeedStore.shared.reconfigure(seed: accountStore.account.secretSeed())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { FeedStore.shared.requestDeviceEnrollment() }
            onLinked(); dismiss()
            return
        }
        error = true
    }
}

/// Adopt an existing identity on this device by scanning/pasting a transfer code.
struct RestoreIdentityView: View {
    let accountStore: AccountStore
    /// When true, the copy frames this as adding a *secondary device* to an existing account (vs.
    /// moving/restoring an identity). Mechanically identical — both adopt the account via its code.
    var linkMode: Bool = false
    var onRestored: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pasted = ""
    @State private var error = false
    @State private var scanning = true
    @State private var backups: [AccountStore.IdentitySummary] = []
    @State private var iCloudOn = AccountStore.iCloudSyncEnabled

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 18) {
                    Text(linkMode ? "Link this as your device" : "Restore your identity").font(.title3.bold()).padding(.top, 8)
                    Text(linkMode
                         ? "On your primary device, open Settings → Devices and show its link code, then scan it here — or paste it below."
                         : "Scan the transfer code from your other device, or paste it below.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)

                    if scanning {
                        QRScannerView { code in attempt(code) }
                            .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(HavenTheme.brandHorizontal, lineWidth: 2))
                    }

                    VStack(spacing: 8) {
                        TextField("Paste your recovery code", text: $pasted, axis: .vertical)
                            .havenAutocap(.never).autocorrectionDisabled()
                            .textFieldStyle(.plain)   // one glass surface, no system bezel inside it
                            .padding(12)
                            .havenGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        Button { attempt(pasted) } label: { Label("Restore from code", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if error {
                        Label("That code isn't valid. Check you copied the whole thing.", systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }

                    // Restore from a BACKUP already on this account — the iCloud Keychain recovery archive.
                    // No other device / QR needed; ideal when a transfer code isn't available.
                    Divider().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Restore from a backup").font(.subheadline.weight(.semibold))
                        if backups.isEmpty {
                            if iCloudOn {
                                Text("No backed-up identities found in your iCloud Keychain yet. Backups appear here once an identity has synced from another of your Apple devices.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Turn on iCloud Keychain backup to recover an identity you used on another Apple device — without needing a transfer code.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button {
                                    accountStore.setICloudSync(true)
                                    iCloudOn = true
                                    reloadBackups()
                                } label: { Label("Turn on iCloud backup", systemImage: "icloud.fill") }
                                    .buttonStyle(BrandButtonStyle())
                            }
                        } else {
                            ForEach(backups) { id in
                                Button { restoreBackup(id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(HavenTheme.pink)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(id.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                            Text(String(id.nodeHex.prefix(16)) + "…").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Label(linkMode ? "This device joins your account and syncs your profile + posts. Your primary device can revoke it anytime."
                                   : "This replaces the identity on this device.", systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Restore")
        .havenInlineNavTitle()
        .onAppear { reloadBackups() }
    }

    /// The backed-up identities available to restore (everything in the recovery archive except the one
    /// already active on this device).
    private func reloadBackups() {
        backups = accountStore.roster().filter { !$0.isCurrent }
    }

    private func restoreBackup(_ id: AccountStore.IdentitySummary) {
        guard accountStore.switchToIdentity(seedB64: id.seedB64) else { error = true; return }
        FeedStore.shared.reconfigure(seed: accountStore.account.secretSeed())
        onRestored()
        dismiss()
    }

    private func attempt(_ code: String) {
        if accountStore.restore(fromTransferCode: code) {
            FeedStore.shared.reconfigure(seed: accountStore.account.secretSeed())
            // As a secondary device, register with the primary so it's a revocable linked device and
            // pulls state. Best-effort + delayed so the engine/transport is up; it also re-asks on the
            // Devices screen, and the primary pushes state whenever the two next connect.
            if linkMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { FeedStore.shared.requestDeviceEnrollment() }
            }
            onRestored()
            dismiss()
        } else {
            error = true
        }
    }
}
