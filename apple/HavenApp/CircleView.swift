import SwiftUI

/// Manage who's in your circle: see each person's real (signed) name + whether the
/// secure handshake has completed, remove people, or invite someone new. "Waiting"
/// means you don't yet hold their keys — usually because you haven't both added each
/// other, you're on different app versions, or one of you started a new identity.
struct CircleView: View {
    let account: Account
    @ObservedObject private var contacts = ContactsStore.shared
    @ObservedObject private var store = FeedStore.shared
    @State private var showInvite = false
    @State private var showSettings = false   // macOS only — the gear is a NavigationLink on iOS
    @State private var nicknameTarget: Contact?
    @State private var nicknameDraft = ""

    private var isDefault: Bool { store.activeCircleId == "default" }
    private var nonContactMembers: [String] { store.nonContactMembers(in: store.activeCircleId) }
    private var memberIds: Set<String> { Set(store.handshaked(in: store.activeCircleId)) }
    private var membersInCircle: [Contact] {
        isDefault ? contacts.contacts : contacts.contacts.filter { memberIds.contains($0.idHex) }
    }
    private var addable: [Contact] { contacts.contacts.filter { !memberIds.contains($0.idHex) } }
    private var title: String { isDefault ? "Your circle" : store.activeCircleName }

    /// Everyone the call button would ring — me excluded, removed/blocked people excluded.
    private var callableMembers: [String] {
        store.memberHexes(circleId: store.activeCircleId).filter {
            $0 != store.myNodeHex
            && !ConnectionsStore.shared.isRemovedFromCircle($0, circleId: store.activeCircleId)
            && !ConnectionsStore.shared.isBlocked($0)
        }
    }

    var body: some View {
        platformBody
            // Membership covers the feed — stop the post song playing behind it.
            .havenPausesPostAudio()
            .sheet(isPresented: $showInvite) { ConnectView(account: account, contacts: contacts).macSheetFrame() }
            .alert("Nickname", isPresented: Binding(get: { nicknameTarget != nil }, set: { if !$0 { nicknameTarget = nil } })) {
                TextField("Nickname", text: $nicknameDraft)
                Button("Save") { if let c = nicknameTarget { ContactsStore.shared.setNickname(idHex: c.idHex, nicknameDraft) }; nicknameTarget = nil }
                Button("Clear", role: .destructive) { if let c = nicknameTarget { ContactsStore.shared.setNickname(idHex: c.idHex, "") }; nicknameTarget = nil }
                Button("Cancel", role: .cancel) { nicknameTarget = nil }
            } message: { Text("How this person shows up for you — long-press anyone in your circle to set it.") }
    }

    @ViewBuilder private var platformBody: some View {
        #if os(macOS)
        // No NavigationStack on macOS: this screen is a SHEET, and a stack's nav bar inside a sheet
        // paints gray bands above and below the content that no toolbar modifier can hide. The house
        // scaffold runs the gradient to the sheet's extreme edges instead, so the gear opens settings
        // as a nested sheet rather than a push.
        HavenMacSheet(title) { memberColumn } footer: { actionRow }
            .sheet(isPresented: $showSettings) {
                CircleSettingsView(circleId: store.activeCircleId)   // HavenMacSheet brings its own frame
            }
        #else
        listBody
        #endif
    }

    // MARK: - iOS

    #if !os(macOS)
    private var listBody: some View {
        ZStack {
            HavenBackground()
            List {
                Section {
                    if membersInCircle.isEmpty {
                        Text(emptyMembersText)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(membersInCircle) { c in
                        row(c)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)   // the default hairline dividers looked harsh over the gradient
                            .contextMenu { rowMenu(c) }
                            .swipeActions(edge: .leading) {
                                Button { store.forceSync() } label: {
                                    Label("Reconnect", systemImage: "arrow.clockwise")
                                }.tint(HavenTheme.pink)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.blockConnection(c.idHex) } label: {
                                    Label("Block", systemImage: "hand.raised.fill")
                                }
                                Button { removeWithoutBlocking(c) } label: {
                                    Label("Remove", systemImage: "person.badge.minus")
                                }.tint(.orange)
                            }
                    }
                    .onDelete { offsets in
                        let members = offsets.map { membersInCircle[$0] }
                        members.forEach { store.removeFromActiveCircle($0.idHex) }   // tombstone + engine removal
                        if isDefault { members.forEach(contacts.remove) }            // My Circle also drops the contact
                    }
                    // The explanatory note as a ROW, not the Section's footer slot — macOS truncates
                    // List footers to one line regardless of fixedSize, which cut off the "Waiting" text.
                    Text(membersNote)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    Text(membersHeader)
                }

                if !nonContactMembers.isEmpty {
                    Section {
                        ForEach(nonContactMembers, id: \.self) { idHex in
                            HStack(spacing: 12) {
                                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 34, height: 34)
                                    .overlay(Image(systemName: "person.fill").font(.caption).foregroundStyle(.white))
                                Text(String(idHex.prefix(8))).font(.subheadline.monospaced())
                                Spacer()
                                Button { store.addMemberToMyCircle(idHex) } label: {
                                    Label("Add", systemImage: "person.badge.plus")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent).tint(HavenTheme.pink).controlSize(.small)
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("Also in this circle")
                    } footer: {
                        Text(nonContactNote)
                    }
                }

                if !isDefault {
                    Section("Add from your contacts") {
                        if addable.isEmpty {
                            Text("Everyone you know is already here.")
                                .font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
                        }
                        ForEach(addable) { c in
                            Button { store.addContactToActiveCircle(idHex: c.idHex) } label: {
                                HStack {
                                    Text(c.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(HavenTheme.pink)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)   // custom row label — keep macOS's bezel off it
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        Button(role: .destructive) { store.leaveActiveCircle() } label: {
                            Label("Leave this circle", systemImage: "rectangle.portrait.and.arrow.right")
                        }.listRowBackground(Color.clear)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .havenInlineNavTitle()
        .toolbar {
            ToolbarItem(placement: .havenTrailing) {
                Button {
                    CallManager.shared.startCall(participants: callableMembers, name: store.activeCircleName)
                } label: { Image(systemName: "phone.fill") }
                .buttonStyle(HavenGlassIcon())
                .disabled(callableMembers.isEmpty)
                .accessibilityLabel("Start group call")
            }
            ToolbarItem(placement: .havenTrailing) {
                Button { showInvite = true } label: { Image(systemName: "person.badge.plus") }
                    .buttonStyle(HavenGlassIcon())
            }
            ToolbarItem(placement: .havenTrailing) {
                NavigationLink { CircleSettingsView(circleId: store.activeCircleId) } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(HavenGlassIcon())
                .accessibilityLabel("Circle settings")
            }
        }
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    /// A hand-rolled column, not a List — HavenMacSheet's content lives in a ScrollView, which gives
    /// a List no height to lay out against. Right-click carries the row actions iOS puts on swipes.
    private var memberColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(membersHeader)
                if membersInCircle.isEmpty {
                    Text(emptyMembersText).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(membersInCircle) { c in
                    row(c)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .havenGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contextMenu { rowMenu(c) }
                }
                Text(membersNote)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !nonContactMembers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Also in this circle")
                    ForEach(nonContactMembers, id: \.self) { idHex in
                        HStack(spacing: 12) {
                            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 34, height: 34)
                                .overlay(Image(systemName: "person.fill").font(.caption).foregroundStyle(.white))
                            Text(String(idHex.prefix(8))).font(.subheadline.monospaced())
                            Spacer()
                            Button { store.addMemberToMyCircle(idHex) } label: {
                                Label("Add", systemImage: "person.badge.plus").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .havenGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    Text(nonContactNote).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !isDefault {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Add from your contacts")
                    if addable.isEmpty {
                        Text("Everyone you know is already here.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(addable) { c in
                        Button { store.addContactToActiveCircle(idHex: c.idHex) } label: {
                            HStack {
                                Text(c.displayName).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(HavenTheme.pink)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .havenGlass(in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)   // the pill IS the button — no macOS bezel behind it
                    }
                }
                Button { store.leaveActiveCircle() } label: {
                    Label("Leave this circle", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(GlassPillButtonStyle(tint: .red))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The circle's actions in the sheet's footer — without a NavigationStack there's no toolbar to
    /// hang them on, and the sheet's toolbar band is exactly the gray we're getting rid of.
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                CallManager.shared.startCall(participants: callableMembers, name: store.activeCircleName)
            } label: { Image(systemName: "phone.fill") }
            .buttonStyle(GlassIconButtonStyle())
            .disabled(callableMembers.isEmpty)
            .accessibilityLabel("Start group call")

            Button { showInvite = true } label: { Image(systemName: "person.badge.plus") }
                .buttonStyle(GlassIconButtonStyle())
                .accessibilityLabel("Invite someone")

            Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(GlassIconButtonStyle())
                .accessibilityLabel("Circle settings")

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
    #endif

    // MARK: - Shared pieces

    private var membersHeader: String { isDefault ? "People in your circle" : "In \(store.activeCircleName)" }
    private var emptyMembersText: String {
        isDefault ? "No one yet. Tap + to invite someone." : "No one here yet — add from your contacts below."
    }
    private var nonContactNote: String {
        "People sharing this circle who aren't in your My Circle yet. Add anyone to connect with them directly."
    }
    /// The row-actions hint names the gesture each platform actually has: swipes on iOS, right-click
    /// on macOS (the mac column is a plain VStack, so there are no swipes to promise).
    private var membersNote: String {
        #if os(macOS)
        return isDefault
            ? "“Waiting” means the secure handshake hasn't completed yet. Now just one of you needs to scan the other's invite — the other gets a request to approve. Right-click anyone to set a nickname, remove them, or block them."
            : "Right-click to remove someone from just this circle (they stay in your other circles), or to block them everywhere."
        #else
        return isDefault
            ? "“Waiting” means the secure handshake hasn't completed yet. Now just one of you needs to scan the other's invite — the other gets a request to approve. Swipe to remove, or swipe left to block."
            : "Swipe to remove someone from just this circle (they stay in your other circles). Swipe left to block them everywhere."
        #endif
    }

    /// Per-person actions — the context menu on both platforms (and the only row actions macOS has).
    @ViewBuilder private func rowMenu(_ c: Contact) -> some View {
        Button { nicknameDraft = c.nickname ?? ""; nicknameTarget = c } label: {
            Label("Set nickname", systemImage: "pencil")
        }
        Button { removeWithoutBlocking(c) } label: {
            Label(isDefault ? "Remove from my circle" : "Remove from this circle",
                  systemImage: "person.badge.minus")
        }
        // "Get this person out of everything" — pulls them from EVERY group circle at once (each removal
        // is tombstoned so they can't rejoin), for when removing from one circle keeps leaving them in
        // the others. DMs are left intact.
        Button(role: .destructive) {
            let n = store.removeFromAllCircles(c.idHex)
            if isDefault || n > 0 { contacts.remove(c) }
        } label: {
            Label("Remove from all circles", systemImage: "person.2.slash")
        }
        Button(role: .destructive) { store.blockConnection(c.idHex) } label: {
            Label("Block", systemImage: "hand.raised.fill")
        }
    }

    /// Remove someone from this circle without blocking them. In the default circle this drops
    /// them from your contacts (My Circle); in a custom circle it removes them from just that one.
    private func removeWithoutBlocking(_ c: Contact) {
        store.removeFromActiveCircle(c.idHex)   // tombstone + engine removal (now authoritative for default too)
        if isDefault { contacts.remove(c) }     // My Circle also drops them from contacts
    }

    private func row(_ c: Contact) -> some View {
        let connected = store.isConnected(c.idHex)
        return HStack(spacing: 12) {
            PeerAvatar(nodeHex: c.idHex, name: c.displayName, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName).font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(connected ? "Connected" : "Waiting to connect")
                        .font(.caption2).foregroundStyle(connected ? .green : .secondary)
                }
            }
            Spacer()
            Text(String(c.idHex.prefix(6))).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
