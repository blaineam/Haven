import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The friendly "You" screen: who you are, your circle, and an easy way to invite
/// people. The technical bits live behind "Advanced".
struct YouView: View {
    let account: Account
    let accountStore: AccountStore
    @ObservedObject var profile: ProfileStore
    @ObservedObject var contacts: ContactsStore
    @ObservedObject private var feed = FeedStore.shared
    var onReset: () -> Void

    @State private var showConnect = false
    @State private var showEditProfile = false
    @State private var showStories = false
    @State private var storyIndex = 0
    @State private var showIdentity = false   // screenshot harness: identity switcher sheet

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                    .contentShape(Rectangle())
                    .onTapGesture { havenDismissKeyboard() }   // tap outside a field to dismiss the keyboard
                ScrollView {
                    VStack(spacing: 18) {
                        profileHeader
                        if !feed.myStories.isEmpty { storiesRow }
                        postsSection
                    }
                    .padding(20)
                    // Pin the content to the viewport width. A vertical ScrollView proposes UNBOUNDED
                    // width to its content, so an unconstrained Text (the bio) laid out on one line wider
                    // than the screen — which made the whole content horizontally pannable (you could
                    // swipe the profile sideways). Constraining width forces text to wrap and kills the
                    // stray horizontal scroll. (The Circle feed didn't show it because its cards fill width.)
                    .frame(maxWidth: .infinity)
                }
                // Match the Circle feed: any scroll dismisses the comment keyboard (interactively
                // only dismissed on a deliberate keyboard drag, which felt stuck on the You tab).
                .scrollDismissesKeyboard(.immediately)
            }
            // No big "You" header — the profile header below already identifies the tab. Keep a
            // slim inline bar so the settings gear stays in the toolbar.
            .navigationTitle("")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .havenTrailing) {
                    NavigationLink {
                        SettingsView(account: account, accountStore: accountStore, onReset: onReset)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(HavenGlassIcon())
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showConnect) {
                ConnectView(account: account, contacts: contacts).macSheetFrame()
            }
            .sheet(isPresented: $showEditProfile) { EditProfileSheet().macSheetFrame() }   // has its own toolbar Done
            .havenFullScreenCover(isPresented: $showStories) {
                StoryViewer(stories: feed.myStories, index: storyIndex, friendName: "Friend")
            }
            .sheet(isPresented: $showIdentity) {
                NavigationStack { IdentityBackupView(account: account, accountStore: accountStore) }.macSheetFrame()
            }
            .onAppear {
                // Screenshot harness: open the identity switcher for its hero shot.
                if DemoEnv.scene == .identity {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showIdentity = true }
                }
            }
        }
    }

    /// Compact secondary actions: invite + jump to manage your circle.
    private var actionsRow: some View {
        HStack(spacing: 12) {
            Button { showConnect = true } label: {
                Label("Invite", systemImage: "person.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandButtonStyle())
            NavigationLink { CircleView(account: account) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                    Text(contacts.contacts.isEmpty ? "Circle" : "Circle · \(contacts.contacts.count)")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    /// Your own posts, shown right here — this *is* your profile.
    @ViewBuilder private var postsSection: some View {
        if feed.myPosts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.largeTitle).foregroundStyle(.tertiary)
                Text("Your posts show up here")
                    .font(.subheadline.weight(.medium))
                Text("Everything you share lives here — and a copy stays on your device.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28).havenCard()
        } else {
            VStack(spacing: 16) {
                ForEach(feed.myPosts, id: \.id) { item in
                    PostCard(
                        item: item, friendName: "Friend",
                        onReact: { e in withAnimation(HavenTheme.bouncy) { feed.react(item.id, e) } },
                        onUnreact: { e in withAnimation(HavenTheme.bouncy) { feed.unreact(item.id, e) } },
                        onComment: { b, m in withAnimation(HavenTheme.smooth) { feed.comment(item.id, b, m) } },
                        onEdit: { b in withAnimation(HavenTheme.smooth) { feed.edit(item.id, b) } },
                        onUnsend: { withAnimation(HavenTheme.smooth) { feed.unsend(item.id) } }
                    )
                    // Report center position so the You-page feed drives audio too — without this the
                    // centered post never became active, so songs animated but never actually played.
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: PostCenterKey.self, value: [item.id: geo.frame(in: .global).midY])
                    })
                }
            }
            .onPreferenceChange(PostCenterKey.self) { centers in
                // Same nearest-to-center logic the Circle feed uses, so the You page drives audio too.
                let target = PlatformScreen.bounds.midY
                let nearest = centers.min { abs($0.value - target) < abs($1.value - target) }
                AudioCoordinator.shared.center(nearest?.key)
            }
        }
    }

    private var storiesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your stories").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(feed.myStories.enumerated()), id: \.element.id) { idx, s in
                        Button { storyIndex = idx; showStories = true } label: {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [HavenTheme.violet, HavenTheme.pink, HavenTheme.amber],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 64, height: 64)
                                if let img = s.media.first.flatMap({ MediaStore.shared.item($0)?.image }) {
                                    Image(platformImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(Circle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .havenCard()
    }

    private var profileHeader: some View {
        VStack(spacing: 10) {
            Button { showEditProfile = true } label: {
                HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 92)
                    .shadow(color: HavenTheme.pink.opacity(0.35), radius: 16, y: 8)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title3).foregroundStyle(HavenTheme.pink)
                            .background(Circle().fill(.background))
                    }
            }
            .buttonStyle(.plain)
            Text(profile.displayName.isEmpty ? "You" : profile.displayName)
                .font(.title2.bold())
            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            if !profile.link.isEmpty {
                Button { LinkPresenter.shared.open(profile.link) } label: {
                    Label(profile.link, systemImage: "link")
                        .font(.footnote.weight(.medium)).foregroundStyle(HavenTheme.pink)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            if profile.bio.isEmpty && profile.link.isEmpty {
                Text("This is just for the people you choose.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)   // take the proposed (viewport) width so the bio/link wrap, not overflow
    }


    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your circle is private").font(.subheadline.weight(.semibold))
                Text("Everything you share is locked so only your people can see it. No ads, no tracking — ever.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .havenCard()
    }
}

/// Tucked-away technical details for the curious.
struct AdvancedView: View {
    let account: Account
    let accountStore: AccountStore
    var onReset: () -> Void

    @State private var report: SelfTestReport?
    @State private var runCount = 0
    @State private var showResetConfirm = false

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollView {
                VStack(spacing: 20) {
                    detailsCard
                    privacyCheckCard
                    NavigationLink { ConnectionView() } label: {
                        HStack {
                            Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .havenCard()
                    // Identity (iCloud sync / move / restore) lives in Settings ▸ "Identity & iCloud
                    // backup" (IdentityBackupView) — not duplicated here.
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Start over (new identity)", systemImage: "arrow.counterclockwise")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(20)
            }
        }
        .navigationTitle("Advanced")
        .havenInlineNavTitle()
        .sensoryFeedback(trigger: runCount) { _, _ in report?.allOk == true ? .success : .error }
        .confirmationDialog("Start over with a brand-new identity?",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Erase everything & start over", role: .destructive) {
                onReset()
                report = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases your identity, your whole circle, and every post on this device — and the people you've connected with will no longer recognize you. This can't be undone.")
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Under the hood").font(.headline)
            row("Your id", String(account.nodeIdHex().prefix(24)) + "…")
            row("Safety words", SafetyWords.words(fromHex: account.verificationHex()).joined(separator: " · "))
            Text("Haven uses hybrid post-quantum encryption (X25519 + ML-KEM-768, Ed25519 + ML-DSA). Your keys never leave this device.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .havenCard()
    }

    private var privacyCheckCard: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(HavenTheme.bouncy) { report = selfTest(); runCount += 1 }
            } label: {
                Label("Run privacy check", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HavenTheme.pink)
                    .padding(.vertical, 13).frame(maxWidth: .infinity)
                    .background(Capsule().strokeBorder(HavenTheme.brandHorizontal, lineWidth: 1.5))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("privacyCheck")

            if let r = report {
                VStack(spacing: 10) {
                    checkRow("Identity is yours", r.identityOk, 0)
                    checkRow("Your stuff is locked (seal → open)", r.hybridKemOk, 1)
                    checkRow("Messages are signed", r.signatureOk, 2)
                    checkRow("Invite links are safe", r.linkOk, 3)
                    Divider()
                    Label(r.summary, systemImage: r.allOk ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(r.allOk ? .green : .red)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .havenCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced()).multilineTextAlignment(.trailing)
        }
    }

    private func checkRow(_ title: String, _ ok: Bool, _ index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red).imageScale(.large)
            Text(title).font(.subheadline)
            Spacer()
        }
        .opacity(report != nil ? 1 : 0)
        .offset(x: report != nil ? 0 : -16)
        .animation(HavenTheme.bouncy.delay(Double(index) * 0.08), value: runCount)
    }
}

/// Prominent, first-class identity backup surface (also reachable from Advanced): turn on iCloud
/// Keychain backup so the identity follows the user to a new Apple device, move it to another
/// device with a QR code, or restore/swap an identity onto this device.
struct IdentityBackupView: View {
    let account: Account
    @ObservedObject var accountStore: AccountStore
    @ObservedObject private var profile = ProfileStore.shared
    @State private var iCloudSync = AccountStore.iCloudSyncEnabled
    @State private var identities: [AccountStore.IdentitySummary] = []
    @State private var switchTarget: AccountStore.IdentitySummary?
    @State private var renameTarget: AccountStore.IdentitySummary?
    @State private var renameDraft = ""
    @State private var deleteTarget: AccountStore.IdentitySummary?
    @State private var showFactoryReset = false
    @State private var showFactoryResetFinal = false

    var body: some View {
        ZStack {
            HavenBackground()
            Form {
                // The headline: every identity you've used on this device — tap to switch.
                Section {
                    ForEach(identities) { id in
                        Button {
                            if !id.isCurrent { switchTarget = id }
                        } label: {
                            HStack(spacing: 12) {
                                if id.isCurrent {
                                    HavenAvatar(image: profile.avatar, emoji: profile.emoji, size: 34)
                                } else {
                                    Circle().fill(Color.secondary.opacity(0.25)).frame(width: 34, height: 34)
                                        .overlay(Text(String(id.name.prefix(1)).uppercased())
                                            .font(.subheadline.bold()).foregroundStyle(.secondary))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(id.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    Text(String(id.nodeHex.prefix(16)) + "…")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if id.isCurrent {
                                    Text("Current").font(.caption2.weight(.semibold)).foregroundStyle(HavenTheme.pink)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(HavenTheme.pink.opacity(0.15), in: Capsule())
                                } else {
                                    Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { renameDraft = id.name; renameTarget = id } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            if !id.isCurrent {
                                Button(role: .destructive) { deleteTarget = id } label: {
                                    Label("Delete this identity", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: { Text("Your identities") }
                footer: { Text("Every identity you've used on this device. Tap one to switch to it — your current identity is kept here so you can switch back anytime. With iCloud backup on, these follow you to your other Apple devices.") }

                Section {
                    Toggle(isOn: $iCloudSync) {
                        Label("Back up to iCloud", systemImage: "icloud.fill")
                    }
                    .tint(HavenTheme.pink)
                    .onChange(of: iCloudSync) { _, on in accountStore.setICloudSync(on) }
                } header: { Text("iCloud backup") }
                footer: { Text("Securely keep your identities in your iCloud Keychain (end-to-end encrypted by Apple) so they're restored automatically when you sign into iCloud on a new iPhone, iPad, or Mac. Your active keys still never leave the device — only an encrypted recovery copy is backed up.") }

                Section {
                    NavigationLink { TransferIdentityView(accountStore: accountStore) } label: {
                        Label("Move to another device", systemImage: "qrcode")
                    }
                    NavigationLink { RestoreIdentityView(accountStore: accountStore, onRestored: { reload() }) } label: {
                        Label("Add / restore an identity here", systemImage: "arrow.down.circle")
                    }
                    // "Devices" moved up to a top-level Settings entry — managing/revoking linked devices
                    // isn't a backup/transfer task, and it was buried three levels deep here.
                } header: { Text("Transfer & restore") }
                footer: { Text("Move an identity to a new device by scanning a QR code, or add/restore one from a transfer code.") }

                Section {
                    Button(role: .destructive) { showFactoryReset = true } label: {
                        Label("Erase app & all identities", systemImage: "trash.fill")
                    }
                } header: { Text("Danger zone") }
                footer: { Text("Permanently erase every identity, circle, post, DM, and setting on this device and return Haven to a clean state. This cannot be undone, and — unlike “Start over” — nothing is recoverable, even with iCloud backup on.") }
            }
            .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Identity & backup")
        .havenInlineNavTitle()
        .onAppear { accountStore.rememberCurrentLabel(); reload() }
        .confirmationDialog(switchTarget.map { "Switch to “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { switchTarget != nil }, set: { if !$0 { switchTarget = nil } }),
                            titleVisibility: .visible) {
            if let t = switchTarget {
                Button("Switch identity") {
                    accountStore.switchToIdentity(seedB64: t.seedB64)
                    switchTarget = nil
                    reload()
                }
            }
            Button("Cancel", role: .cancel) { switchTarget = nil }
        } message: {
            Text("Haven will switch to this identity. Your circles, posts, and DMs for it appear; your current identity stays saved here to switch back to.")
        }
        .alert("Rename identity", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let t = renameTarget {
                    let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    // The current identity's label IS its profile name; past ones get a stored label.
                    if t.isCurrent { ProfileStore.shared.displayName = name }
                    else { AccountStore.setIdentityLabel(name, forNodeHex: t.nodeHex) }
                }
                renameTarget = nil; reload()
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Give this identity a name so you can tell your identities apart.")
        }
        .confirmationDialog(deleteTarget.map { "Delete “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            if let t = deleteTarget {
                Button("Delete this identity", role: .destructive) {
                    accountStore.deleteIdentity(seedB64: t.seedB64)
                    deleteTarget = nil; reload()
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This permanently removes this stored identity and its recovery copy from this device (and from iCloud backup). You won't be able to switch back to it. This can't be undone.")
        }
        // Two-step "ample warning" factory reset.
        .confirmationDialog("Erase Haven and every identity?", isPresented: $showFactoryReset, titleVisibility: .visible) {
            Button("Continue…", role: .destructive) { showFactoryResetFinal = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes ALL identities, circles, posts, DMs, media, and settings on this device and resets Haven to a clean state. Nothing is recoverable — not even with iCloud backup. The people in your circles will no longer recognize any of these identities.")
        }
        .alert("Are you absolutely sure?", isPresented: $showFactoryResetFinal) {
            Button("Erase everything", role: .destructive) {
                accountStore.factoryReset()
                reload()
            }
            Button("Keep my data", role: .cancel) {}
        } message: {
            Text("Last chance — this permanently destroys everything in Haven on this device and cannot be undone.")
        }
    }

    private func reload() { identities = accountStore.roster() }
}

/// Staggered slide-up entrance for a section.
struct Entrance: ViewModifier {
    let shown: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .animation(HavenTheme.smooth.delay(delay), value: shown)
    }
}

extension View {
    func entrance(_ shown: Bool, delay: Double) -> some View {
        modifier(Entrance(shown: shown, delay: delay))
    }
}
