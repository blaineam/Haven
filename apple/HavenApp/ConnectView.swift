import SwiftUI

/// Where Haven's web links live. The landing page resolves the URL fragment — `/#<id>.<verify>` for an
/// invite, `/#p/<circle>.<post>` for a shared post — into an "open in Haven" page. Everything sensitive
/// stays in the fragment, which the browser never sends to the host; see DeepLink.swift.
///
/// Note the split between EMITTING (`inviteDomain`) and MATCHING (`sitePath`).
///
/// Links are emitted under a dedicated `/open` page, and that page alone is what the apps claim as a
/// Universal Link / App Link. The rest of the site — the marketing home page, /features/, /docs/,
/// /relay/ — is ordinary web content and must stay in the browser. Claiming the whole `/apps/haven`
/// subtree made every one of those pages offer to open Haven, which is what people were seeing:
///
///   • iOS matched on "any non-empty fragment", and the site is full of its OWN in-page anchors
///     (`#main` on every page, `#download`, `#privacy`, `#circles`, …). Every anchor tap looked like
///     a payload.
///   • Android App Links cannot match a fragment AT ALL — only scheme/host/path — so the fragment
///     gate that saved iOS did not exist there, and the whole subtree was claimed outright.
///
/// A distinct path is the only thing both platforms can agree on. The payload STAYS in the fragment;
/// `/open` is a constant, so the host still never learns which post or circle — only that some Haven
/// link was opened, which is what it already learned from the bare page load.
enum HavenSite {
    static let host = "wemiller.com"
    /// MATCHING prefix. Deliberately the whole site path: every link form ever emitted — including the
    /// pre-`/open` ones already pasted into people's chat histories — starts here, and those keep
    /// resolving once the app has the URL. Only which links AUTO-OPEN the app got narrower.
    static let sitePath = "/apps/haven"
    /// EMITTING. The dedicated deep-link landing page, and the only path the apps claim.
    static let inviteDomain = "\(host)\(sitePath)/open"
    static var path: String { sitePath }
}

/// The guided "make a connection" flow: show your invite, or add a friend from
/// theirs — in plain language, with friendly safety words instead of hex.
struct ConnectView: View {
    let account: Account
    @ObservedObject var contacts: ContactsStore
    @ObservedObject private var invites = FriendInviteStore.shared   // re-render on roll / expiry change
    /// An invite link the app was opened with (deep link) — jumps straight to "Add a friend".
    var incomingLink: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0
    @State private var pasted = ""
    @State private var found: LinkInfo?
    @State private var foundHints: [String] = []
    @State private var foundTicket: String?
    @State private var friendName = ""
    @State private var problem: String?
    @State private var addedName: String?
    @State private var showScanner = false
    /// The invite link and its QR, resolved OFF the main thread. They used to be computed inside
    /// `body`, which meant every evaluation could mint a post-quantum ticket and render a QR image
    /// on the main thread — seconds of freeze on a device with relays, then the watchdog. Empty
    /// means "still resolving"; the sheet shows a placeholder rather than blocking for it.
    @State private var resolvedLink = ""
    @State private var resolvedQR: PlatformImage?
    @State private var linkFailed = false

    var body: some View {
        #if os(macOS)
        // HavenMacSheet, not NavigationStack — its toolbar renders as grey system bands above and
        // below the gradient. The sheet scaffold runs the gradient to the sheet's extreme edges.
        HavenMacSheet("Connect") {
            connectColumn
        } footer: {
            // The "added!" confirmation screen has its own prominent Done — don't also show this one.
            if addedName == nil {
                Button("Done") { dismiss() }
                    .buttonStyle(BrandButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $showScanner) { scannerSheet }
        .onAppear { seedIncomingLink() }
        .task { await refreshInviteLink() }
        .havenPausesPostAudio()
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollView {
                    connectColumn
                        .padding(20)
                        .frame(maxWidth: 560)             // one readable column on wide windows
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Connect")
            .havenInlineNavTitle()
            // The "added!" confirmation screen has its own prominent Done — don't also show the toolbar one.
            .toolbar { if addedName == nil { ToolbarItem(placement: .havenConfirmTrailing) { Button("Done") { dismiss() }.havenToolbarPill() } } }
            .sheet(isPresented: $showScanner) { scannerSheet }
            .onAppear { seedIncomingLink() }
            .task { await refreshInviteLink() }
        }
        .havenPausesPostAudio()
        #endif
    }

    /// The sheet's content, shared by both platforms' scaffolds.
    @ViewBuilder private var connectColumn: some View {
        VStack(spacing: 20) {
            Picker("", selection: $mode) {
                Text("Invite a friend").tag(0)
                Text("Add a friend").tag(1)
            }
            .pickerStyle(.segmented)

            if mode == 0 { invite } else { addFriend }
        }
    }

    /// Opened with an invite link → jump straight to "Add a friend" and resolve it.
    /// Build the link and its QR without touching the main thread for the expensive parts.
    /// The ticket mint is already off-main inside the store; the QR render is CoreImage work, so it
    /// goes to a detached task too. Runs once per sheet, and again only when the user rolls.
    private func refreshInviteLink(roll: Bool = false) async {
        let base = InviteHints.embed(in: account.havenLink(domain: HavenSite.inviteDomain),
                                     deviceIds: FeedStore.shared.inviteDeviceIds())
        let ticket = roll ? await invites.rollInviteLinkAsync() : await invites.currentTicketLinkValueAsync()
        let link = ticket.map { InviteHints.appendQuery(in: base, name: "t", value: $0) } ?? base
        let image = await Task.detached(priority: .userInitiated) { QRCode.image(from: link) }.value
        resolvedLink = link
        resolvedQR = image
        linkFailed = image == nil
    }

    private func seedIncomingLink() {
        guard let link = incomingLink, !link.isEmpty else { return }
        mode = 1
        pasted = link
        lookup()
    }

    private var scannerSheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                QRScannerView { code in
                    pasted = code
                    showScanner = false
                    lookup()
                }
                .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Point at your friend's invite QR")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle("Scan QR")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenCancelTrailing) { Button("Cancel") { showScanner = false }.havenToolbarPill() } }
        }
    }

    // MARK: - Invite

    // The link used to be a computed property read from `body` (twice: once for the QR, once for
    // the share sheet). Each read could mint a post-quantum ticket and render a QR on the main
    // thread. It is now resolved once, off-main, into `resolvedLink` / `resolvedQR` — see
    // `refreshInviteLink`.

    private var invite: some View {
        VStack(spacing: 16) {
            Text("Invite someone you trust")
                .font(.title3.bold())
            Text("Have them scan this, or send them your invite link.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let qr = resolvedQR {
                Image(platformImage: qr)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 210, height: 210)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: HavenTheme.violet.opacity(0.25), radius: 16, y: 8)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(width: 234, height: 234)
                    .overlay(ProgressView())
                    .accessibilityIdentifier("inviteQRPlaceholder")
            }

            if let url = URL(string: resolvedLink), !resolvedLink.isEmpty {
                ShareLink(item: url) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(BrandButtonStyle())
                .accessibilityIdentifier("shareInviteLink")
            }

            if !resolvedLink.isEmpty {
                Text(resolvedLink)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("inviteLinkText")
            }

            // Offline-invite controls (only meaningful when this device hosts/uses a relay — that's
            // where an offline acceptance lands). Configurable expiry + a manual roll; the link is
            // otherwise stable and never auto-rotates.
            if !RelayMailboxStore.shared.allRelays().isEmpty {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Offline adds").font(.subheadline.weight(.medium))
                        Spacer()
                        Menu {
                            Button("7 days")  { invites.expirySecs = 7 * 24 * 3600 }
                            Button("30 days") { invites.expirySecs = 30 * 24 * 3600 }
                            Button("90 days") { invites.expirySecs = 90 * 24 * 3600 }
                            Button("1 year")  { invites.expirySecs = 365 * 24 * 3600 }
                            Divider()
                            Button("Never expire") { invites.expirySecs = FriendInviteStore.neverExpirySecs }
                        } label: {
                            Label(expiryLabel, systemImage: "clock.arrow.circlepath").font(.subheadline)
                        }
                    }
                    Text(expiryDetail)
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        // Off-main: rolling mints a fresh ticket (post-quantum) — see refreshInviteLink.
                        Task { await refreshInviteLink(roll: true) }
                    } label: {
                        Label("Regenerate invite link", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }

            safetyCard(
                title: "Your safety words",
                words: SafetyWords.words(fromHex: account.verificationHex()),
                note: "When your friend adds you, make sure they see these same words — that's how you both know it's really you."
            )
        }
        .havenCard()
    }

    private var expiryLabel: String {
        let s = invites.expirySecs
        if s >= FriendInviteStore.neverExpirySecs { return "Never expires" }
        let days = s / 86400
        return days >= 365 ? "Expires in 1 year" : "Expires in \(days) days"
    }

    private var expiryDetail: String {
        invites.expirySecs >= FriendInviteStore.neverExpirySecs
            ? "Your invite link stays valid until you regenerate it — someone can accept anytime, even while you're offline."
            : "Someone can accept while you're offline until the link expires; old links auto-retire. Regenerate to roll it now."
    }

    // MARK: - Add a friend

    private var addFriend: some View {
        VStack(spacing: 16) {
            if let added = addedName {
                addedConfirmation(added)
            } else if let f = found {
                foundConfirmation(f)
            } else {
                Text("Add a friend")
                    .font(.title3.bold())
                Text("Scan their invite QR, or paste the link they sent you.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button { showScanner = true } label: {
                    Label("Scan their QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(BrandButtonStyle())
                .accessibilityIdentifier("scanQR")

                Text("or").font(.caption).foregroundStyle(.secondary)

                TextField("Paste invite link…", text: $pasted, axis: .vertical)
                    .textFieldStyle(.plain)   // one glass surface (roundedBorder doubled with the mac bezel)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .havenGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("pasteLink")

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                Button("Find my friend") { lookup() }
                    .buttonStyle(.bordered).tint(HavenTheme.pink)
                    .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .havenCard()
    }

    private func foundConfirmation(_ f: LinkInfo) -> some View {
        VStack(spacing: 16) {
            Text("Found someone! 🎉").font(.title3.bold())
            safetyCard(
                title: "Check these safety words",
                words: SafetyWords.words(fromHex: f.verificationHex),
                note: "Ask your friend to read their safety words aloud. If they match, it's really them."
            )
            TextField("Add a nickname (optional)", text: $friendName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .havenGlass(in: Capsule())
                .accessibilityIdentifier("friendName")
            Text("Their own name will appear once you connect — they choose it, signed with their key.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add to my circle") {
                let trimmed = friendName.trimmingCharacters(in: .whitespaces)
                let name = trimmed.isEmpty ? "Friend" : trimmed
                contacts.add(name: name, idHex: f.idHex, verificationHex: f.verificationHex)
                // Scanning an invite is a DELIBERATE add: clear any old removal tombstone, or
                // their hellos stay dropped and self-sync re-severs them (re-add never sticks).
                FeedStore.shared.clearCircleRemovalEverywhere(idHex: f.idHex, circleId: "default")  // client + engine tombstone
                // Store the invite's device-id hints BEFORE the hello, so the very first dial
                // can reach their device (their account id resolves to no node post-device-seed).
                FeedStore.shared.recordDeviceHints(accountHex: f.idHex, deviceIds: foundHints)
                FeedStore.shared.syncWithContacts(force: true)   // user action: greet now, never coalesced
                // Ticketed invite: park a sealed acceptance on THEIR relays too, so this works
                // even if they're offline for days — the live hello above still wins when online.
                if let tv = foundTicket {
                    FriendInviteStore.shared.acceptTicket(linkValue: tv)
                }
                withAnimation(HavenTheme.bouncy) { addedName = name }
            }
            .buttonStyle(BrandButtonStyle())
            Text("You'll be connected the moment you're both online.")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func addedConfirmation(_ name: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54)).foregroundStyle(.green)
            Text("\(name) is in your circle")
                .font(.title3.bold()).multilineTextAlignment(.center)
            Text("They'll show up once you're both online.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(BrandButtonStyle())
        }
    }

    private func safetyCard(title: String, words: [String], note: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(words, id: \.self) { w in
                    Text(w)
                        .font(.callout.weight(.semibold).monospaced())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(HavenTheme.brandHorizontal.opacity(0.18), in: Capsule())
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func lookup() {
        problem = nil
        do {
            let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            let info = try parseLink(s: trimmed)
            foundHints = InviteHints.extract(from: trimmed)
            foundTicket = InviteHints.queryValue(from: trimmed, name: "t")
            withAnimation(HavenTheme.bouncy) { found = info }
        } catch {
            problem = "That doesn't look like a Haven invite link. Double-check and try again."
        }
    }
}
