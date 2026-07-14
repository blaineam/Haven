import SwiftUI
import Photos
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// User preferences (on-device only).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// Default for saving media YOU create in-app to Photos (per-circle overrides in CircleSettingsStore).
    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: kSave) } }
    /// Default for saving media OTHERS send you to Photos.
    @Published var saveOthersToPhotos: Bool { didSet { d.set(saveOthersToPhotos, forKey: kSaveOthers) } }
    @Published var autoOptimize: Bool { didSet { d.set(autoOptimize, forKey: kOpt) } }
    /// Auto-delete posts older than this many days (0 = keep forever).
    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: kRet) } }
    /// When auto-delete is on, keep MY OWN posts even after they'd age out for others (my archive).
    @Published var keepMyPosts: Bool { didSet { d.set(keepMyPosts, forKey: kKeepMine) } }
    /// Global mute — silences post music + video audio so you can browse quietly. DEVICE-LOCAL: it's
    /// seeded from this device's hardware silent switch (iOS) or defaults muted (macOS, which has no
    /// such switch), so it must never sync to your other devices — muting your Mac isn't muting your
    /// phone. Same rule as `videoSoundOn` below.
    @Published var silent: Bool {
        didSet { d.set(silent, forKey: kSilent); AudioCoordinator.shared.setSilent(silent) }
    }
    /// GLOBAL video-sound toggle. Tapping unmute/mute on ANY video flips this, and it persists — so a
    /// video stays unmuted across its own loops and as you scroll between videos (default muted, like
    /// every other social feed: you tap once to turn sound on for all of them).
    @Published var videoSoundOn: Bool { didSet { d.set(videoSoundOn, forKey: kVideoSound) } }
    private let d = UserDefaults.standard
    private let kSave = "haven.saveToPhotos"
    private let kSaveOthers = "haven.saveOthersToPhotos"
    private let kOpt = "haven.autoOptimize"
    private let kRet = "haven.retentionDays"
    private let kKeepMine = "haven.keepMyPosts"
    private let kSilent = "haven.silent"
    private let kVideoSound = "haven.videoSoundOn"

    private init() {
        saveToPhotos = d.object(forKey: kSave) as? Bool ?? true   // default ON
        saveOthersToPhotos = d.object(forKey: kSaveOthers) as? Bool ?? false   // default OFF — only my own posts auto-save
        autoOptimize = d.object(forKey: kOpt) as? Bool ?? true
        retentionDays = d.object(forKey: kRet) as? Int ?? 0       // default forever
        keepMyPosts = d.object(forKey: kKeepMine) as? Bool ?? true   // default: always keep my own archive
        #if os(macOS)
        // No hardware silent switch to seed from, so there's no signal that the user wants sound:
        // start MUTED and let one explicit unmute stick (same precedent as videoSoundOn — quiet by
        // default, tap once to turn it on). Anything else means a Mac window can start singing at you.
        silent = d.object(forKey: kSilent) as? Bool ?? true
        #else
        silent = d.object(forKey: kSilent) as? Bool ?? false   // re-seeded from the silent switch on open
        #endif
        videoSoundOn = d.object(forKey: kVideoSound) as? Bool ?? false   // default muted; tap any video to unmute all
    }

    /// Viewer retention in seconds (nil = forever).
    var retentionSecs: UInt64? { retentionDays <= 0 ? nil : UInt64(retentionDays) * 86_400 }
}

/// Saves Haven media into the user's Photos library, organized under a **Haven** folder with
/// **Shared** (media you created in-app) and **Received** (media others sent you) albums.
/// Library-selected media is never re-saved — it's already in Photos. We request read-write
/// access because creating the folder/albums needs it; honest privacy note: media saved here
/// leaves Haven's encrypted store for the user's own library, which may sync to iCloud Photos
/// — their choice, controlled by the toggle.
enum PhotoSaver {
    @MainActor
    static func saveIfEnabled(_ item: MediaItem, to album: HavenAlbumKind, circleId: String) {
        // Per circle: .shared = media you made; .received = media others sent you.
        let allowed = album == .shared
            ? CircleSettingsStore.shared.saveOwnToPhotos(circleId)
            : CircleSettingsStore.shared.saveOthersToPhotos(circleId)
        guard allowed else { return }
        save(item, to: album)
    }

    static func save(_ item: MediaItem, to album: HavenAlbumKind) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            HavenPhotoAlbums.shared.collection(for: album) { collection in
                PHPhotoLibrary.shared().performChanges {
                    let creation: PHAssetChangeRequest?
                    if item.kind == .video, let url = item.videoURL {
                        creation = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    } else if let img = item.image {
                        creation = PHAssetCreationRequest.creationRequestForAsset(from: img)
                    } else {
                        creation = nil
                    }
                    // Drop the new asset into the Haven album (if we have one — otherwise it
                    // still lands in the main library).
                    if let placeholder = creation?.placeholderForCreatedAsset,
                       let collection,
                       let albumChange = PHAssetCollectionChangeRequest(for: collection) {
                        albumChange.addAssets([placeholder] as NSArray)
                    }
                }
            }
        }
    }
}

/// Resign first responder app-wide (cross-platform) so a tap outside a focused field
/// dismisses the keyboard. Used on the You/Settings screens.
@MainActor func havenDismissKeyboard() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #else
    NSApp.keyWindow?.makeFirstResponder(nil)
    #endif
}

struct SettingsView: View {
    let account: Account
    let accountStore: AccountStore
    var onReset: () -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @State private var storageText = "…"

    /// Walk the media dir off the main actor and format the total (e.g. "1.2 GB · 340 files").
    private func measureStorage() async {
        let usage = await Task.detached(priority: .utility) { MediaStore.shared.diskUsage() }.value
        let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
        storageText = usage.files == 0 ? "None yet" : "\(size) · \(usage.files) file\(usage.files == 1 ? "" : "s")"
    }

    var body: some View {
        ZStack {
            HavenBackground()
                .contentShape(Rectangle())
                .onTapGesture { havenDismissKeyboard() }
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield.fill").font(.title3).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Your circle is private").font(.subheadline.weight(.semibold))
                            Text("Everything you share is locked so only your people can see it. No ads, no tracking — ever.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Toggle("Save your posts to Photos", isOn: $settings.saveToPhotos)
                        .tint(HavenTheme.pink)
                    Toggle("Save others' posts to Photos", isOn: $settings.saveOthersToPhotos)
                        .tint(HavenTheme.pink)
                } header: { Text("Save to Photos — default") }
                footer: {
                    Text("Media you create lands in a **Haven ▸ Shared** album; media others send you in **Haven ▸ Received**. Photos you pick from your own library aren't re-saved. These are the defaults — any circle can override them in its own settings.")
                }
                Section {
                    Toggle("Auto-optimize media", isOn: $settings.autoOptimize)
                        .tint(HavenTheme.pink)
                } footer: {
                    Text("Share smaller, optimized photos and videos by default. Turn off to send pristine originals. Per-circle override available.")
                }
                Section {
                    Picker("Auto-delete old posts", selection: $settings.retentionDays) {
                        Text("Off").tag(0)
                        Text("After 1 week").tag(7)
                        Text("After 1 month").tag(30)
                        Text("After 3 months").tag(90)
                        Text("After 1 year").tag(365)
                    }
                    .tint(HavenTheme.pink)
                    if settings.retentionDays > 0 {
                        Toggle("Always keep my own posts", isOn: $settings.keepMyPosts)
                            .tint(HavenTheme.pink)
                            .onChange(of: settings.keepMyPosts) { _, on in FeedStore.shared.setKeepOwnPosts(on) }
                    }
                } header: { Text("Auto-delete — default") }
                footer: {
                    Text("Auto-delete only affects YOUR view — it hides old posts from your feed to keep things tidy. It never deletes anything for other people, and posts you sent stay on their devices. A sender can set a shorter limit on their own posts (that one does expire everywhere). With “Always keep my own posts” on, your own posts stay in your feed as a personal archive. Per-circle override available.")
                }
                Section {
                    HStack {
                        Label("Synced media", systemImage: "internaldrive")
                        Spacer()
                        Text(storageText).foregroundStyle(.secondary).monospacedDigit()
                    }
                } header: { Text("Storage") }
                footer: {
                    Text("Photos and videos from your circles, cached on this device. Freeing space here just re-downloads them from your relay when you next view them.")
                }
                .task { await measureStorage() }
                Section {
                    NavigationLink { RelaysView() } label: {
                        Label("Relays", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("Manage where your circles' sealed posts & media live so they reach people who were offline. Add unlimited relays (a Haven node or your own S3 bucket), pick a default for every circle, and activate or deactivate each. Each circle can override the default in its own settings.")
                }
                Section {
                    NavigationLink { BlockedPeopleView() } label: {
                        Label("Blocked people", systemImage: "hand.raised.fill")
                    }
                } footer: {
                    Text("People you've blocked can't see your posts or reach you. Unblock anyone here.")
                }
                Section {
                    NavigationLink { IdentityBackupView(account: account, accountStore: accountStore) } label: {
                        Label("Identity & iCloud backup", systemImage: "icloud.fill")
                    }
                } footer: {
                    Text("Back up your identity to iCloud so it follows you to a new Apple device, move it to another device with a QR code, or restore/swap an identity here.")
                }
                Section {
                    NavigationLink { AuthorizedDevicesView(accountStore: accountStore) } label: {
                        Label("Devices", systemImage: "laptopcomputer.and.iphone")
                    }
                } footer: {
                    Text("Link this account to your other devices — each gets its own revocable key and syncs your profile + posts. See which devices are authorized, re-sync, or revoke one.")
                }
                Section {
                    NavigationLink {
                        AdvancedView(account: account, accountStore: accountStore, onReset: onReset)
                    } label: {
                        Label("Advanced", systemImage: "wrench.and.screwdriver")
                    }
                } footer: {
                    Text("Technical details, your identity, and starting over.")
                }
            }
            .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Settings")
        .havenInlineNavTitle()
    }
}
