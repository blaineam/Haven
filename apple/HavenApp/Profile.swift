import SwiftUI
import PhotosUI

/// The user's chosen display name, emoji, and optional profile photo. Not PII
/// collection — it lives on this device and is only ever shared, end-to-end, with
/// people you connect to.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    // Demo seeding overwrites these in memory (PII-free synthetic profile) but must NEVER persist —
    // otherwise the demo "Riley Avery" profile lands in the real (shared-container) defaults.
    @Published var displayName: String { didSet { if !DemoEnv.isDemo { defaults.set(displayName, forKey: nameKey) } } }
    @Published var emoji: String { didSet { if !DemoEnv.isDemo { defaults.set(emoji, forKey: emojiKey) }; FeedStore.shared.rebroadcastProfile() } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: doneKey) } }
    /// A short bio + a link the user chooses to show — a little "business card" shared,
    /// signed and end-to-end, with the people they connect to.
    @Published var bio: String { didSet { if !DemoEnv.isDemo { defaults.set(bio, forKey: bioKey) } } }
    @Published var link: String { didSet { if !DemoEnv.isDemo { defaults.set(link, forKey: linkKey) } } }
    @Published private(set) var avatar: PlatformImage?

    private let defaults = UserDefaults.standard
    /// Profile fields are namespaced per identity (by node-id hex) so each identity keeps its own
    /// name/photo/emoji/bio/link, and switching identities loads the right one. `onboarded` stays
    /// global — it's about the app, not an identity.
    private var ns: String = AccountStore.currentNodeHex()
    private func key(_ base: String) -> String { ns.isEmpty ? base : "\(base).\(ns)" }
    private var nameKey: String { key("haven.displayName") }
    private var emojiKey: String { key("haven.emoji") }
    private let doneKey = "haven.onboarded"
    private var bioKey: String { key("haven.bio") }
    private var linkKey: String { key("haven.link") }

    private init() {
        let d = UserDefaults.standard
        let ns0 = AccountStore.currentNodeHex()
        Self.migrateLegacyIfNeeded(ns: ns0, d: d)
        func k(_ base: String) -> String { ns0.isEmpty ? base : "\(base).\(ns0)" }
        displayName = d.string(forKey: k("haven.displayName")) ?? ""
        emoji = d.string(forKey: k("haven.emoji")) ?? "🌿"
        onboarded = d.bool(forKey: "haven.onboarded")
        bio = d.string(forKey: k("haven.bio")) ?? ""
        link = d.string(forKey: k("haven.link")) ?? ""
        avatar = Self.loadAvatar(ns: ns0)

        if ProcessInfo.processInfo.environment["HAVEN_SKIP_ONBOARDING"] == "1" {
            if displayName.isEmpty { displayName = "You" }
            onboarded = true
        }
    }

    /// Re-read all profile fields for the now-current identity (call right after an identity switch
    /// / reset). Republishes to the UI; the emoji didSet re-broadcasts this identity's card.
    func reloadForCurrentIdentity() {
        ns = AccountStore.currentNodeHex()
        Self.migrateLegacyIfNeeded(ns: ns, d: defaults)
        displayName = defaults.string(forKey: nameKey) ?? ""
        bio = defaults.string(forKey: bioKey) ?? ""
        link = defaults.string(forKey: linkKey) ?? ""
        emoji = defaults.string(forKey: emojiKey) ?? "🌿"
        avatar = Self.loadAvatar(ns: ns)
        avatarB64Cache = nil
    }

    /// One-time: copy the pre-namespacing (global) profile into the CURRENT identity's namespace so
    /// existing users keep their name/photo on the identity they're already using. Identities created
    /// afterward start blank (the flag stops legacy values leaking into every new identity).
    private static func migrateLegacyIfNeeded(ns: String, d: UserDefaults) {
        guard !ns.isEmpty, !d.bool(forKey: "haven.profile.migrated") else { return }
        d.set(true, forKey: "haven.profile.migrated")
        for base in ["haven.displayName", "haven.emoji", "haven.bio", "haven.link"] {
            if let v = d.string(forKey: base) { d.set(v, forKey: "\(base).\(ns)") }
        }
        let legacy = avatarURL(ns: "")
        let target = avatarURL(ns: ns)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.copyItem(at: legacy, to: target)
        }
    }

    /// A small (≤192px) JPEG of the avatar, base64-encoded — light enough to ride the signed
    /// profile card so circle members see your real photo. Empty when there's no photo.
    /// Cached: re-rendering the JPEG on every handshake reply was heavy enough to hitch the main
    /// thread under a burst of handshakes — invalidated whenever the photo changes (`setAvatar`).
    private var avatarB64Cache: String?
    var avatarBase64: String {
        if let c = avatarB64Cache { return c }
        guard let avatar else { avatarB64Cache = ""; return "" }
        // Cross-platform downscale (Platform.swift) — was UIGraphicsImageRenderer (iOS-only).
        let small = avatar.downscaled(maxDimension: 192)
        let b64 = small.jpegData(compressionQuality: 0.7)?.base64EncodedString() ?? ""
        avatarB64Cache = b64
        return b64
    }

    /// Set or clear the custom profile photo (emoji remains the fallback).
    func setAvatar(_ image: PlatformImage?) {
        avatar = image
        avatarB64Cache = nil   // re-encode lazily next time the card is built
        let url = Self.avatarURL(ns: ns)
        if let image, let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        FeedStore.shared.rebroadcastProfile()   // push my new photo to people I'm connected to
    }

    /// Per-identity avatar file (`ns` empty = the legacy global file, used for migration).
    private static func avatarURL(ns: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(ns.isEmpty ? "haven-avatar.jpg" : "haven-avatar-\(ns).jpg")
    }
    private static func loadAvatar(ns: String) -> PlatformImage? {
        (try? Data(contentsOf: avatarURL(ns: ns))).flatMap { PlatformImage(data: $0) }
    }

    static let avatarChoices = ["🌿", "🌸", "🔥", "⭐️", "🦊", "🐢", "🌊", "🍯", "🎈", "🪴", "🦋", "🌙"]
}

/// A profile avatar: the custom photo if set, otherwise the emoji on a brand circle.
struct HavenAvatar: View {
    var image: PlatformImage?
    var emoji: String
    var size: CGFloat
    var gradient: LinearGradient = HavenTheme.brand

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                gradient.overlay(Text(emoji).font(.system(size: size * 0.5)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Another person's avatar — their synced photo, else their synced emoji, else an initialed
/// gradient. Resolved from the signed profile card we stored on the contact.
struct PeerAvatar: View {
    let nodeHex: String
    let name: String
    var size: CGFloat = 34
    @ObservedObject private var contacts = ContactsStore.shared

    var body: some View {
        if let img = contacts.avatarImage(forNodePrefix: nodeHex) {
            HavenAvatar(image: img, emoji: "", size: size)
        } else if let e = contacts.emoji(forNodePrefix: nodeHex), !e.isEmpty {
            HavenAvatar(image: nil, emoji: e, size: size)
        } else {
            Circle()
                .fill(LinearGradient(colors: [HavenTheme.amber, HavenTheme.pink], startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay(Text(String(name.prefix(1))).font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white))
        }
    }
}

#if os(macOS)
/// Native macOS single-image picker via `NSOpenPanel` (no PHPicker presentation on Mac).
/// Renders nothing; opens the panel on appear and returns the chosen image.
struct SingleImagePicker: View {
    var onPicked: (PlatformImage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
                onPicked(img)
            }
            dismiss()
        }
    }
}
#else
/// Single-image picker (Photos library) returning a `PlatformImage`.
struct SingleImagePicker: UIViewControllerRepresentable {
    var onPicked: (PlatformImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: SingleImagePicker
        init(_ parent: SingleImagePicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            defer { parent.dismiss() }
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: PlatformImage.self) else { return }
            provider.loadObject(ofClass: PlatformImage.self) { object, _ in
                if let img = object as? PlatformImage {
                    Task { @MainActor in self.parent.onPicked(img) }
                }
            }
        }
    }
}
#endif

/// Edit your name, emoji, and profile photo.
struct EditProfileSheet: View {
    @ObservedObject private var profile = ProfileStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPhotoPicker = false
    // Edit LOCAL copies of the text fields, not the live store. Self-sync writes incoming profile values
    // straight into ProfileStore; binding the text fields to it made them jump/swap mid-type whenever a
    // sync landed. We seed these once on appear and commit them back on Done/dismiss (last write wins).
    @State private var name = ""
    @State private var bio = ""
    @State private var link = ""
    @State private var loaded = false

    private func commit() {
        if profile.displayName != name { profile.displayName = name }
        if profile.bio != bio { profile.bio = bio }
        if profile.link != link { profile.link = link }
    }

    var body: some View {
        #if os(macOS)
        HavenMacSheet("Edit profile") {
            editColumn
        } footer: {
            Button("Done") { commit(); dismiss() }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollView { editColumn }
            }
            .navigationTitle("Edit profile")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmTrailing) { Button("Done") { commit(); dismiss() }.havenToolbarPill(tint: HavenTheme.pink) } }
        }
        #endif
    }

    private var editColumn: some View {
        VStack(spacing: 22) {
            Color.clear.frame(height: 0)
                .onDisappear { commit(); FeedStore.shared.rebroadcastProfile() }   // save edits + sync to contacts
            HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 110)
                .shadow(color: HavenTheme.pink.opacity(0.3), radius: 14, y: 8)

            HStack(spacing: 12) {
                Button { showPhotoPicker = true } label: {
                    Label(profile.avatar == nil ? "Add photo" : "Change photo", systemImage: "photo")
                }.buttonStyle(.bordered).tint(HavenTheme.pink)
                if profile.avatar != nil {
                    Button(role: .destructive) { profile.setAvatar(nil) } label: {
                        Label("Remove", systemImage: "trash")
                    }.buttonStyle(.bordered)
                }
            }

            // Fields carry exactly ONE surface (glass) — the default macOS field style
            // painted its own bezel + focus ring inside the custom shapes.
            TextField("Your name", text: $name)
                .font(.title3).multilineTextAlignment(.center)
                .havenPillField()
                .padding(.horizontal, 30)

            VStack(spacing: 10) {
                TextField("Add a short bio", text: $bio, axis: .vertical)
                    .lineLimit(1...3)
                    .havenAutocap(.sentences)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .havenGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                TextField("Add a link (e.g. yoursite.com)", text: $link)
                    .havenAutocap(.never)
                    .autocorrectionDisabled()
                    .havenURLKeyboard()
                    .textFieldStyle(.plain)
                    .padding(12)
                    .havenGlass(in: Capsule())
            }
            .font(.subheadline).padding(.horizontal, 24)
            Text("Your bio and link show on your profile for the people in your circle.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Text(profile.avatar == nil ? "Pick an emoji" : "Emoji (used if you remove your photo)")
                .font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(ProfileStore.avatarChoices, id: \.self) { e in
                    Text(e).font(.system(size: 30)).frame(width: 44, height: 44)
                        .background(profile.emoji == e ? AnyShapeStyle(HavenTheme.brandHorizontal.opacity(0.25)) : AnyShapeStyle(Color(.secondarySystemFill)), in: Circle())
                        .overlay(Circle().strokeBorder(profile.emoji == e ? HavenTheme.pink : .clear, lineWidth: 2))
                        .onTapGesture { withAnimation(HavenTheme.snappy) { profile.emoji = e } }
                }
            }.padding(.horizontal, 20)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: 520)                     // one readable column on wide macOS windows
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !loaded else { return }   // seed once; later syncs won't clobber what you're typing
            name = profile.displayName; bio = profile.bio; link = profile.link
            loaded = true
        }
        .sheet(isPresented: $showPhotoPicker) {
            SingleImagePicker { profile.setAvatar($0) }.macSheetFrame()
        }
    }
}
