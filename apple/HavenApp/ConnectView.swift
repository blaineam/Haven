import SwiftUI

/// Where Haven's web links live. The static landing page at `wemiller.com/apps/haven/` resolves
/// the URL fragment — `/#<id>.<verify>` for an invite, `/#p/<circle>.<post>` for a shared post —
/// into an "open in Haven" page. Everything sensitive stays in the fragment, which the browser
/// never sends to the host; see DeepLink.swift.
enum HavenSite {
    static let inviteDomain = "wemiller.com/apps/haven"
    /// `inviteDomain` split for matching an incoming Universal Link.
    static var host: String { String(inviteDomain.prefix { $0 != "/" }) }
    static var path: String { String(inviteDomain.drop { $0 != "/" }) }
}

/// The guided "make a connection" flow: show your invite, or add a friend from
/// theirs — in plain language, with friendly safety words instead of hex.
struct ConnectView: View {
    let account: Account
    @ObservedObject var contacts: ContactsStore
    /// An invite link the app was opened with (deep link) — jumps straight to "Add a friend".
    var incomingLink: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0
    @State private var pasted = ""
    @State private var found: LinkInfo?
    @State private var foundHints: [String] = []
    @State private var friendName = ""
    @State private var problem: String?
    @State private var addedName: String?
    @State private var showScanner = false

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
        }
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

    /// The shareable link, carrying my device node id(s) as `?d=` dial hints — the scanner's only
    /// reachable ids for me until my signed roster arrives (device-seed transport bootstrap).
    private var inviteLink: String {
        InviteHints.embed(in: account.havenLink(domain: HavenSite.inviteDomain),
                          deviceIds: FeedStore.shared.inviteDeviceIds())
    }

    private var invite: some View {
        VStack(spacing: 16) {
            Text("Invite someone you trust")
                .font(.title3.bold())
            Text("Have them scan this, or send them your invite link.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let qr = QRCode.image(from: inviteLink) {
                Image(platformImage: qr)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 210, height: 210)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: HavenTheme.violet.opacity(0.25), radius: 16, y: 8)
            }

            if let url = URL(string: inviteLink) {
                ShareLink(item: url) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(BrandButtonStyle())
            }

            safetyCard(
                title: "Your safety words",
                words: SafetyWords.words(fromHex: account.verificationHex()),
                note: "When your friend adds you, make sure they see these same words — that's how you both know it's really you."
            )
        }
        .havenCard()
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
                ConnectionsStore.shared.clearCircleRemoval(f.idHex, circleId: "default")
                // Store the invite's device-id hints BEFORE the hello, so the very first dial
                // can reach their device (their account id resolves to no node post-device-seed).
                FeedStore.shared.recordDeviceHints(accountHex: f.idHex, deviceIds: foundHints)
                FeedStore.shared.syncWithContacts()   // say hello over the network
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
            withAnimation(HavenTheme.bouncy) { found = info }
        } catch {
            problem = "That doesn't look like a Haven invite link. Double-check and try again."
        }
    }
}
