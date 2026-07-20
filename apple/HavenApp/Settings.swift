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
    @Published var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: kSave); stamp(kSave) } }
    /// Default for saving media OTHERS send you to Photos.
    @Published var saveOthersToPhotos: Bool { didSet { d.set(saveOthersToPhotos, forKey: kSaveOthers); stamp(kSaveOthers) } }
    @Published var autoOptimize: Bool { didSet { d.set(autoOptimize, forKey: kOpt); stamp(kOpt) } }
    /// Auto-delete posts older than this many days (0 = keep forever).
    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: kRet); stamp(kRet) } }

    /// LAST-WRITER-WINS timestamps for the SYNCED settings, so two of your devices resolve a settings
    /// change by who changed it LAST rather than who synced last (the same ping-pong that hit profiles).
    /// Stamped only on a real LOCAL change (an `applyingRemote` flag suppresses sync-applied writes).
    private(set) var settingTs: [String: UInt64] = [:]
    private var applyingRemote = false
    private let kSettingTs = "haven.settingTs.v1"
    private func stamp(_ key: String) {
        guard !applyingRemote else { return }
        settingTs[key] = UInt64(Date().timeIntervalSince1970 * 1000)
        d.set(settingTs.mapValues { NSNumber(value: $0) }, forKey: kSettingTs)
    }
    func settingTimestamp(_ key: String) -> UInt64 { settingTs[key] ?? 0 }
    /// Apply a REMOTE synced setting only if it was changed more recently than our local one (LWW).
    @discardableResult func applyRemoteBool(_ key: String, _ value: Bool, ts: UInt64) -> Bool {
        guard ts > settingTimestamp(key) else { return false }
        applyingRemote = true
        switch key { case kSave: saveToPhotos = value; case kSaveOthers: saveOthersToPhotos = value; case kOpt: autoOptimize = value; default: break }
        applyingRemote = false
        settingTs[key] = ts; d.set(settingTs.mapValues { NSNumber(value: $0) }, forKey: kSettingTs)
        return true
    }
    @discardableResult func applyRemoteRetentionDays(_ value: Int, ts: UInt64) -> Bool {
        guard ts > settingTimestamp(kRet) else { return false }
        applyingRemote = true; retentionDays = value; applyingRemote = false
        settingTs[kRet] = ts; d.set(settingTs.mapValues { NSNumber(value: $0) }, forKey: kSettingTs)
        return true
    }
    // Public key accessors for the self-sync layer (keys are private).
    var tsKeySave: String { kSave }
    var tsKeySaveOthers: String { kSaveOthers }
    var tsKeyOpt: String { kOpt }
    var tsKeyRet: String { kRet }
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
    /// LOCAL media cap — delete this device's cached blobs older than N days (0 = no age limit). The
    /// EVENT stays; the blob becomes a re-downloadable placeholder. DEVICE-LOCAL, default off. The
    /// client sibling of the relay's retention; pinned + composer-staged media are exempt.
    @Published var localMediaMaxDays: Int { didSet { d.set(localMediaMaxDays, forKey: kLocMaxDays); FeedStore.shared.enforceLocalLimits(force: true) } }
    /// LOCAL media cap — keep this device's cached blobs under this many GB (0 = no size limit).
    /// Oldest-first eviction until under cap; pinned blobs are never evicted. DEVICE-LOCAL, default off.
    @Published var localMediaMaxGB: Int { didSet { d.set(localMediaMaxGB, forKey: kLocMaxGB); FeedStore.shared.enforceLocalLimits(force: true) } }
    private let d = UserDefaults.standard
    private let kSave = "haven.saveToPhotos"
    private let kSaveOthers = "haven.saveOthersToPhotos"
    private let kOpt = "haven.autoOptimize"
    private let kRet = "haven.retentionDays"
    private let kKeepMine = "haven.keepMyPosts"
    private let kSilent = "haven.silent"
    private let kVideoSound = "haven.videoSoundOn"
    private let kLocMaxDays = "haven.localMediaMaxDays"
    private let kLocMaxGB = "haven.localMediaMaxGB"

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
        localMediaMaxDays = d.object(forKey: kLocMaxDays) as? Int ?? 0    // default off (no age limit)
        localMediaMaxGB = d.object(forKey: kLocMaxGB) as? Int ?? 0        // default off (no size limit)
        settingTs = (d.dictionary(forKey: kSettingTs) as? [String: NSNumber])?.mapValues { $0.uint64Value } ?? [:]
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
    @ObservedObject private var pinnedStore = PinnedMediaStore.shared
    @State private var storageText = "…"
    @State private var cleaningMedia = false
    @State private var cleanupResult: String?
    private var pinnedCount: Int { pinnedStore.count }

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
                    NavigationLink { MediaCleanupView() } label: {
                        HStack {
                            Label("Manage media", systemImage: "square.grid.2x2")
                            Spacer()
                            if pinnedCount > 0 {
                                Text("\(pinnedCount) kept").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    Picker("Delete local media older than", selection: $settings.localMediaMaxDays) {
                        Text("Never").tag(0)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("6 months").tag(180)
                        Text("1 year").tag(365)
                    }
                    .tint(HavenTheme.pink)
                    Picker("Keep local media under", selection: $settings.localMediaMaxGB) {
                        Text("No limit").tag(0)
                        Text("1 GB").tag(1)
                        Text("2 GB").tag(2)
                        Text("5 GB").tag(5)
                        Text("10 GB").tag(10)
                        Text("25 GB").tag(25)
                    }
                    .tint(HavenTheme.pink)
                    // These two are NOT alternatives, and briefly shipping only the second one was a
                    // mistake. Cleanup frees space on THIS device by deleting blobs no post, message
                    // or scheduled send still references. Re-optimize re-encodes media already out in
                    // the circles so it gets smaller for EVERY member holding it. Different scope,
                    // different blast radius, different reason to reach for them: "my phone is full
                    // now" is not the same problem as "I shared 300 MB of video last year".
                    Button {
                        guard !cleaningMedia else { return }
                        cleaningMedia = true
                        cleanupResult = nil
                        Task {
                            let r = await FeedStore.shared.cleanupUnusedMedia()
                            cleanupResult = r.files == 0
                                ? "Nothing to clean up"
                                : "Freed \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)) · \(r.files) file\(r.files == 1 ? "" : "s")"
                            await measureStorage()
                            cleaningMedia = false
                        }
                    } label: {
                        HStack {
                            Label(cleaningMedia ? "Cleaning up…" : "Clean up unused media", systemImage: "trash")
                            Spacer()
                            if cleaningMedia { ProgressView() }
                            else if let cleanupResult {
                                Text(cleanupResult).foregroundStyle(.secondary).font(.caption).monospacedDigit()
                            }
                        }
                    }
                    .disabled(cleaningMedia)
                    ReoptimizeMediaRow(onFinished: { await measureStorage() })
                } header: { Text("Storage") }
                footer: {
                    Text("Photos and videos from your circles, cached on this device. **Manage media** lists everything by size so you can free the biggest items or keep favorites on this device forever. The local limits automatically remove old/excess cached media (oldest first) to stay under your caps — the posts stay and re-download on demand. Kept items are never removed. **Clean up unused media** removes only media no post, message or scheduled send references anymore — this device only, and it also happens on its own each week. **Re-optimize** re-encodes photos and videos you shared before Haven learned to compress them properly (or shared with auto-optimize off) and quietly re-shares the smaller copy, so everyone in the circle gets the space back — your captions, comments and timestamps are untouched.")
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
        // Settings covers the feed — the post song behind it must stop. Applied on the DESTINATION
        // rather than at each presentation site so it holds wherever this is opened from.
        .havenPausesPostAudio()
    }
}
