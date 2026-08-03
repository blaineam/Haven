import Foundation
import SwiftUI
import LocalAuthentication

/// Per-circle preferences (on-device only), keyed by circle id. These live app-side rather
/// than in the Rust engine because they're personal viewing choices, not part of the shared
/// circle state: whether this circle's posts go into Spotlight, and whether opening the circle
/// requires a Face ID / Touch ID unlock.
@MainActor
final class CircleSettingsStore: ObservableObject {
    static let shared = CircleSettingsStore()

    @Published private var spotlight: [String: Bool]
    @Published private var biometric: [String: Bool]
    // Per-circle media overrides. A MISSING key = inherit the global default (SettingsStore).
    @Published private var saveOwn: [String: Bool]
    @Published private var saveOthers: [String: Bool]
    @Published private var optimize: [String: Bool]
    @Published private var retention: [String: Int]
    /// What *I* call this circle. Purely local, exactly like a contact nickname: it never leaves this
    /// account, so renaming a circle can't rename it for everyone else in it. The circle's real name
    /// stays authoritative on the wire — this only changes what I see.
    @Published private var nickname: [String: String]

    private let d = UserDefaults.standard
    private let kSpot = "haven.circle.spotlight"
    private let kBio = "haven.circle.biometric"
    private let kSaveOwn = "haven.circle.saveOwn"
    private let kSaveOthers = "haven.circle.saveOthers"
    private let kOptimize = "haven.circle.optimize"
    private let kRetention = "haven.circle.retention"
    private let kNickname = "haven.circle.nickname"

    private init() {
        spotlight = (d.dictionary(forKey: kSpot) as? [String: Bool]) ?? [:]
        biometric = (d.dictionary(forKey: kBio) as? [String: Bool]) ?? [:]
        saveOwn = (d.dictionary(forKey: kSaveOwn) as? [String: Bool]) ?? [:]
        saveOthers = (d.dictionary(forKey: kSaveOthers) as? [String: Bool]) ?? [:]
        optimize = (d.dictionary(forKey: kOptimize) as? [String: Bool]) ?? [:]
        retention = (d.dictionary(forKey: kRetention) as? [String: Int]) ?? [:]
        nickname = (d.dictionary(forKey: kNickname) as? [String: String]) ?? [:]
    }

    /// Factory-reset this store — clear all per-circle settings + unlocks (in-memory + persisted).
    func wipe() {
        spotlight = [:]; biometric = [:]; saveOwn = [:]; saveOthers = [:]; optimize = [:]; retention = [:]
        nickname = [:]
        [kSpot, kBio, kSaveOwn, kSaveOthers, kOptimize, kRetention, kNickname].forEach { d.removeObject(forKey: $0) }
    }

    // MARK: My own name for a circle (local only — never sent, never synced to members)

    /// What I call this circle, if I've renamed it. `nil` = use the circle's real name.
    func nickname(_ c: String) -> String? {
        guard let n = nickname[c]?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return n
    }

    /// The name to SHOW for a circle: my nickname if I set one, else its real name. Every display
    /// site should go through this so a renamed circle doesn't revert wherever one was missed.
    func displayName(_ c: String, real: String) -> String { nickname(c) ?? real }

    /// Set (or clear, with an empty string) my own name for a circle.
    func setNickname(_ v: String, for c: String) {
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { nickname.removeValue(forKey: c) } else { nickname[c] = trimmed }
        d.set(nickname, forKey: kNickname)
        objectWillChange.send()
    }

    // MARK: Media settings (per circle, falling back to the global default)

    func saveOwnToPhotos(_ c: String) -> Bool { saveOwn[c] ?? SettingsStore.shared.saveToPhotos }
    func saveOthersToPhotos(_ c: String) -> Bool { saveOthers[c] ?? SettingsStore.shared.saveOthersToPhotos }
    func autoOptimize(_ c: String) -> Bool { optimize[c] ?? SettingsStore.shared.autoOptimize }
    func retentionDays(_ c: String) -> Int { retention[c] ?? SettingsStore.shared.retentionDays }
    func retentionSecs(_ c: String) -> UInt64? { let n = retentionDays(c); return n <= 0 ? nil : UInt64(n) * 86_400 }

    /// True when the circle overrides a setting (so the UI can show "Custom" vs "Default").
    func hasMediaOverride(_ c: String) -> Bool {
        saveOwn[c] != nil || saveOthers[c] != nil || optimize[c] != nil || retention[c] != nil
    }

    // nil clears the override (back to the global default).
    func setSaveOwn(_ v: Bool?, for c: String) { saveOwn[c] = v; d.set(saveOwn, forKey: kSaveOwn); objectWillChange.send() }
    func setSaveOthers(_ v: Bool?, for c: String) { saveOthers[c] = v; d.set(saveOthers, forKey: kSaveOthers); objectWillChange.send() }
    func setOptimize(_ v: Bool?, for c: String) { optimize[c] = v; d.set(optimize, forKey: kOptimize); objectWillChange.send() }
    func setRetention(_ v: Int?, for c: String) { retention[c] = v; d.set(retention, forKey: kRetention); objectWillChange.send() }
    func clearMediaOverrides(for c: String) {
        saveOwn[c] = nil; saveOthers[c] = nil; optimize[c] = nil; retention[c] = nil
        d.set(saveOwn, forKey: kSaveOwn); d.set(saveOthers, forKey: kSaveOthers)
        d.set(optimize, forKey: kOptimize); d.set(retention, forKey: kRetention)
        objectWillChange.send()
    }
    /// Whether this circle has its OWN value for each setting (for the UI's per-row "default" state).
    func ownOverride(_ c: String) -> Bool? { saveOwn[c] }
    func othersOverride(_ c: String) -> Bool? { saveOthers[c] }
    func optimizeOverride(_ c: String) -> Bool? { optimize[c] }
    func retentionOverride(_ c: String) -> Int? { retention[c] }

    // MARK: Spotlight (per circle)

    func spotlightEnabled(_ circleId: String) -> Bool { spotlight[circleId] ?? false }

    func setSpotlight(_ on: Bool, for circleId: String) {
        spotlight[circleId] = on
        d.set(spotlight, forKey: kSpot)
        if on { SpotlightIndex.reindexCircle(circleId) } else { SpotlightIndex.clearCircle(circleId) }
    }

    /// Circle ids that opt into Spotlight AND aren't biometric-locked (a locked circle must
    /// never leak its posts into the system search index).
    var spotlightCircleIds: [String] {
        spotlight.filter { $0.value && !(biometric[$0.key] ?? false) }.map(\.key)
    }

    // MARK: Biometric lock (per circle)

    func biometricRequired(_ circleId: String) -> Bool { biometric[circleId] ?? false }

    func setBiometric(_ on: Bool, for circleId: String) {
        biometric[circleId] = on
        d.set(biometric, forKey: kBio)
        // Mirror the locked set so the Notification Service Extension can redact pushes for it.
        SharedLockedCircles.write(Set(biometric.filter { $0.value }.map(\.key)))
        // A circle that just became locked must drop out of Spotlight immediately.
        if on, spotlightEnabled(circleId) { SpotlightIndex.clearCircle(circleId) }
        if !on, spotlightEnabled(circleId) { SpotlightIndex.reindexCircle(circleId) }
        #if os(iOS)
        // …and out of the share sheet's suggestion row, for the same reason: a locked circle hides
        // that it exists, which a tile bearing its name in every other app's share sheet would not.
        if on { ShareSuggestions.forget(circleId: circleId) } else { ShareSuggestions.donate(circleId: circleId) }
        #endif
        BiometricGate.shared.relock(circleId)
    }

    /// Whether the device can actually do biometric auth (so we hide the toggle otherwise).
    static var biometricsAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }
}

/// Tracks which biometric-locked circles are unlocked for the current foreground session.
/// Locking is per app-foreground: going to the background relocks everything.
@MainActor
final class BiometricGate: ObservableObject {
    static let shared = BiometricGate()
    @Published private(set) var unlocked: Set<String> = []
    @Published var lastError: String?

    /// True when this circle is gated and not yet unlocked this session.
    func isLocked(_ circleId: String) -> Bool {
        CircleSettingsStore.shared.biometricRequired(circleId) && !unlocked.contains(circleId)
    }

    /// Prompt for Face ID / Touch ID (falling back to the device passcode) to open a circle.
    func unlock(_ circleId: String) {
        guard isLocked(circleId) else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No biometrics/passcode set up — don't trap the user out of their own circle.
            unlocked.insert(circleId)
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock this circle") { [weak self] ok, error in
            Task { @MainActor in
                if ok {
                    self?.unlocked.insert(circleId)
                    self?.lastError = nil
                } else {
                    self?.lastError = error?.localizedDescription
                    // Don't trap the user: if they have a circle that isn't locked, drop them
                    // there. If every circle is locked, they stay on the lock screen.
                    FeedStore.shared.switchToUnlockedCircle(excluding: circleId)
                }
            }
        }
    }

    /// Relock a specific circle (e.g. its requirement was just turned on).
    func relock(_ circleId: String) { unlocked.remove(circleId) }

    /// Relock everything — called when the app goes to the background.
    func relockAll() { unlocked.removeAll() }
}

/// The full-screen cover shown over a biometric-locked circle's feed until the user unlocks it.
struct CircleLockView: View {
    let circleName: String
    @ObservedObject private var gate = BiometricGate.shared
    let circleId: String

    var body: some View {
        ZStack {
            HavenBackground()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(HavenTheme.pink)
                Text(circleName).font(.title3.weight(.semibold))
                Text("This circle is locked. Unlock with Face ID to view it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button { gate.unlock(circleId) } label: {
                    Label("Unlock", systemImage: "faceid")
                        .font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
                        .background(HavenTheme.pink, in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)   // the pill IS the button — no macOS bezel behind it
                if let err = gate.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { gate.unlock(circleId) }   // prompt immediately
    }
}

/// A full-screen privacy cover shown while a biometric-locked circle is active but the app
/// isn't frontmost — so the app-switcher snapshot (and a glance over your shoulder) shows
/// only this, never locked content.
struct PrivacyBlurView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(HavenTheme.pink)
                Text("Haven is locked").font(.headline)
            }
        }
        .ignoresSafeArea()   // a privacy cover that stops at the safe area isn't one
    }
}

/// Settings for a single circle — rename it, control its Spotlight/biometric privacy, and
/// leave it. Mirrors the You settings screen, reached from the gear in the circle view.
struct CircleSettingsView: View {
    let circleId: String
    // Do NOT @ObservedObject FeedStore — every sync/mailbox tick republishes and re-lays out this
    // sheet on the main actor while the engine lock is contested (field: Mac freezes the moment
    // circle settings opens). Snapshot the name once; mutations go through FeedStore.shared.
    @ObservedObject private var circleSettings = CircleSettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// My PRIVATE name for this circle. Separate from `name`, which renames it for everyone —
    /// this one never leaves the device, exactly like a contact nickname.
    @State private var nick = ""
    @State private var showRelays = false   // macOS only — "Manage relays" is a NavigationLink on iOS

    private var isDefault: Bool { circleId == "default" }

    var body: some View {
        platformBody
            // Settings covers the feed — the post song behind it must stop. Applied on the DESTINATION
            // rather than at each presentation site so it holds wherever this is opened from.
            .havenPausesPostAudio()
            .onAppear {
                name = FeedStore.shared.circles.first { $0.id == circleId }?.name ?? ""
                nick = circleSettings.nickname(circleId) ?? ""
            }
            .onDisappear {
                FeedStore.shared.renameCircle(circleId, to: name)   // persist a rename made without hitting return
                circleSettings.setNickname(nick, for: circleId)
            }
    }

    @ViewBuilder private var platformBody: some View {
        #if os(macOS)
        // Presented as a nested SHEET from CircleView, not pushed: a NavigationStack inside a sheet
        // paints gray bands above and below the content on macOS. HavenMacSheet runs the gradient to
        // the sheet's extreme edges, so relays open as one more sheet rather than a push.
        HavenMacSheet("Circle settings") { settingsColumn }
            .sheet(isPresented: $showRelays) { RelaysView().macSheetClose() }
        #else
        formBody
        #endif
    }

    #if !os(macOS)
    private var formBody: some View {
        ZStack {
            HavenBackground()
            Form {
                Section {
                    TextField("Circle name", text: $name)
                        .onSubmit { FeedStore.shared.renameCircle(circleId, to: name) }
                } header: {
                    Text("Name")
                } footer: {
                    Text("What this circle is called for you and everyone in it.")
                }

                Section {
                    TextField("Your name for this circle", text: $nick)
                        .onSubmit { circleSettings.setNickname(nick, for: circleId) }
                } header: {
                    Text("Your name")
                } footer: {
                    Text("Only you see this nickname — it doesn't rename the circle for anyone else.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { circleSettings.spotlightEnabled(circleId) },
                        set: { circleSettings.setSpotlight($0, for: circleId) }
                    )) { Label("Index in Spotlight", systemImage: "magnifyingglass") }
                    .tint(HavenTheme.pink)
                    .disabled(circleSettings.biometricRequired(circleId))

                    if CircleSettingsStore.biometricsAvailable {
                        Toggle(isOn: Binding(
                            get: { circleSettings.biometricRequired(circleId) },
                            set: { circleSettings.setBiometric($0, for: circleId) }
                        )) { Label("Require Face ID to open", systemImage: "faceid") }
                        .tint(HavenTheme.pink)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(circleSettings.biometricRequired(circleId)
                         ? "Locked — hidden from Spotlight; notifications hide content until you unlock."
                         : "Spotlight searches this circle on-device only. Face ID relocks it on each open.")
                }

                Section {
                    Picker(selection: Binding(get: { circleSettings.ownOverride(circleId) },
                                              set: { circleSettings.setSaveOwn($0, for: circleId) })) {
                        Text("Default (\(SettingsStore.shared.saveToPhotos ? "On" : "Off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                    } label: { Label("Save your posts", systemImage: "square.and.arrow.down") }
                    Picker(selection: Binding(get: { circleSettings.othersOverride(circleId) },
                                              set: { circleSettings.setSaveOthers($0, for: circleId) })) {
                        Text("Default (\(SettingsStore.shared.saveOthersToPhotos ? "On" : "Off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                    } label: { Label("Save others' posts", systemImage: "square.and.arrow.down.on.square") }
                    Picker(selection: Binding(get: { circleSettings.optimizeOverride(circleId) },
                                              set: { circleSettings.setOptimize($0, for: circleId) })) {
                        Text("Default (\(SettingsStore.shared.autoOptimize ? "On" : "Off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                    } label: { Label("Auto-optimize media", systemImage: "wand.and.stars") }
                    Picker(selection: Binding(get: { circleSettings.retentionOverride(circleId) },
                                              set: { circleSettings.setRetention($0, for: circleId) })) {
                        Text("Default").tag(Int?.none)
                        Text("Off").tag(Int?.some(0)); Text("After 1 week").tag(Int?.some(7))
                        Text("After 1 month").tag(Int?.some(30)); Text("After 3 months").tag(Int?.some(90))
                        Text("After 1 year").tag(Int?.some(365))
                    } label: { Label("Auto-delete old posts", systemImage: "trash") }
                    if circleSettings.hasMediaOverride(circleId) {
                        Button("Use the app defaults here") { circleSettings.clearMediaOverrides(for: circleId) }
                    }
                } header: {
                    Text("Media in this circle")
                } footer: {
                    Text("Override the app-wide Photos / optimize / auto-delete defaults just for this circle.")
                        .fixedSize(horizontal: false, vertical: true)   // wrap fully; don't truncate on macOS
                }

                // Per-circle relay OVERRIDE: pick which configured relays THIS circle uses, beyond the
                // global default. Configuring/adding relays lives in Settings ▸ Relays — this screen only
                // SELECTS from already-configured relays, plus a link to go manage them.
                CircleRelayOverrideSection(circleId: circleId)
                Section {
                    NavigationLink { RelaysView() } label: {
                        Label("Manage relays", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Add, name, deactivate, or set a default relay under Settings ▸ Relays.")
                }

                if !isDefault {
                    Section {
                        Button(role: .destructive) {
                            FeedStore.shared.leaveActiveCircle(); dismiss()
                        } label: {
                            Label("Leave this circle", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Circle settings")
        .havenInlineNavTitle()
    }
    #endif

    #if os(macOS)
    /// A hand-rolled column, not a Form — HavenMacSheet's content lives in a ScrollView, which gives
    /// a Form no height to lay out against. Same rows, same order, same bindings as the iOS Form.
    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Name")
                TextField("Circle name", text: $name)
                    .onSubmit { FeedStore.shared.renameCircle(circleId, to: name) }
                    .havenPillField()
                footnote("What this circle is called for you and everyone in it.")
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Your name")
                TextField("Your name for this circle", text: $nick)
                    .onSubmit { circleSettings.setNickname(nick, for: circleId) }
                    .havenPillField()
                footnote("Only you see this nickname — it doesn't rename the circle for anyone else.")
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Privacy")
                togglePill(Binding(get: { circleSettings.spotlightEnabled(circleId) },
                                   set: { circleSettings.setSpotlight($0, for: circleId) }),
                           "Index in Spotlight", "magnifyingglass")
                    .disabled(circleSettings.biometricRequired(circleId))
                if CircleSettingsStore.biometricsAvailable {
                    togglePill(Binding(get: { circleSettings.biometricRequired(circleId) },
                                       set: { circleSettings.setBiometric($0, for: circleId) }),
                               "Require Face ID to open", "faceid")
                }
                footnote(circleSettings.biometricRequired(circleId)
                         ? "Locked — hidden from Spotlight; notifications hide content until you unlock."
                         : "Spotlight searches this circle on-device only. Face ID relocks it on each open.")
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Media in this circle")
                Picker(selection: Binding(get: { circleSettings.ownOverride(circleId) },
                                          set: { circleSettings.setSaveOwn($0, for: circleId) })) {
                    Text("Default (\(SettingsStore.shared.saveToPhotos ? "On" : "Off"))").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                } label: { Label("Save your posts", systemImage: "square.and.arrow.down") }
                Picker(selection: Binding(get: { circleSettings.othersOverride(circleId) },
                                          set: { circleSettings.setSaveOthers($0, for: circleId) })) {
                    Text("Default (\(SettingsStore.shared.saveOthersToPhotos ? "On" : "Off"))").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                } label: { Label("Save others' posts", systemImage: "square.and.arrow.down.on.square") }
                Picker(selection: Binding(get: { circleSettings.optimizeOverride(circleId) },
                                          set: { circleSettings.setOptimize($0, for: circleId) })) {
                    Text("Default (\(SettingsStore.shared.autoOptimize ? "On" : "Off"))").tag(Bool?.none)
                    Text("On").tag(Bool?.some(true)); Text("Off").tag(Bool?.some(false))
                } label: { Label("Auto-optimize media", systemImage: "wand.and.stars") }
                Picker(selection: Binding(get: { circleSettings.retentionOverride(circleId) },
                                          set: { circleSettings.setRetention($0, for: circleId) })) {
                    Text("Default").tag(Int?.none)
                    Text("Off").tag(Int?.some(0)); Text("After 1 week").tag(Int?.some(7))
                    Text("After 1 month").tag(Int?.some(30)); Text("After 3 months").tag(Int?.some(90))
                    Text("After 1 year").tag(Int?.some(365))
                } label: { Label("Auto-delete old posts", systemImage: "trash") }
                if circleSettings.hasMediaOverride(circleId) {
                    Button("Use the app defaults here") { circleSettings.clearMediaOverrides(for: circleId) }
                        .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
                }
                footnote("Override the app-wide Photos / optimize / auto-delete defaults just for this circle.")
            }

            CircleRelayOverrideSection(circleId: circleId)
            VStack(alignment: .leading, spacing: 8) {
                Button { showRelays = true } label: {
                    Label("Manage relays", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
                footnote("Add, name, deactivate, or set a default relay under Settings ▸ Relays.")
            }

            if !isDefault {
                Button { FeedStore.shared.leaveActiveCircle(); dismiss() } label: {
                    Label("Leave this circle", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(GlassPillButtonStyle(tint: .red))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Label leading, switch trailing — a bare Toggle glues them together and reads lost in a pill.
    private func togglePill(_ isOn: Binding<Bool>, _ title: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(HavenTheme.pink)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .havenGlass(in: Capsule())
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)   // wrap fully; don't truncate on macOS
    }
    #endif
}

/// Per-circle relay OVERRIDE: toggle which of your configured relays THIS circle uses. The all-circles
/// default still applies on top (shown but not toggleable here — manage it under Settings ▸ Relays).
/// Wired to RelayMailboxStore's per-circle associations (`relaysByCircle`).
struct CircleRelayOverrideSection: View {
    let circleId: String
    @ObservedObject private var store = RelayMailboxStore.shared

    private var configured: [RelayEntry] { store.allEntries().filter { $0.active } }
    private var explicit: Set<String> { Set(store.explicitRelays(forCircle: circleId)) }

    private let footerText = "Pick which relays this circle uses. Posts mirror to every one turned on. The default (★) always applies — manage it in Settings ▸ Relays."

    var body: some View {
        if configured.isEmpty {
            EmptyView()
        } else {
            #if os(macOS)
            // The mac settings screen is a plain column inside HavenMacSheet's ScrollView — a Form
            // Section has nothing to lay out in there.
            relayColumn
            #else
            Section {
                ForEach(configured) { e in relayToggle(e) }
            } header: {
                Text("Relays for this circle")
            } footer: {
                Text(footerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        }
    }

    #if os(macOS)
    private var relayColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Relays for this circle").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(configured) { e in
                relayToggle(e)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .havenGlass(in: Capsule())
            }
            Text(footerText).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    private func relayToggle(_ e: RelayEntry) -> some View {
        let isDefault = store.defaultNodeHex == e.hex
        return Toggle(isOn: Binding(
            get: { explicit.contains(e.hex) || isDefault },
            set: { FeedStore.shared.setCircleRelay(e.hex, circleId: circleId, on: $0) }
        )) {
            HStack(spacing: 6) {
                Image(systemName: e.isS3 ? "externaldrive.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name).font(.subheadline)
                    if isDefault { Text("Default — inherited by every circle").font(.caption2).foregroundStyle(.secondary) }
                }
                #if os(macOS)
                Spacer()   // the pill is full-width — push the switch to its trailing edge
                #endif
            }
        }
        #if os(macOS)
        .toggleStyle(.switch)   // a switch reads modern in the pill; the checkbox looked dated
        #endif
        .tint(HavenTheme.pink)
        .disabled(isDefault)   // the default is always on; manage it under Settings ▸ Relays
    }
}
