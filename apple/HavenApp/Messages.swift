import SwiftUI

/// Up to 6 pinned DM conversations, kept at the top of the Messages list (iMessage-style).
/// Order in the array is pin order; persisted so pins survive relaunch.
final class DMPinStore: ObservableObject {
    static let shared = DMPinStore()
    static let maxPins = 6
    @Published private(set) var pinned: [String]
    private let key = "haven.dm.pinned"
    private init() { pinned = UserDefaults.standard.stringArray(forKey: key) ?? [] }
    func isPinned(_ id: String) -> Bool { pinned.contains(id) }
    var isFull: Bool { pinned.count >= Self.maxPins }
    func toggle(_ id: String) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) }
        else if pinned.count < Self.maxPins { pinned.append(id) }
        UserDefaults.standard.set(pinned, forKey: key)
    }
    func remove(_ id: String) {
        guard let i = pinned.firstIndex(of: id) else { return }
        pinned.remove(at: i); UserDefaults.standard.set(pinned, forKey: key)
    }
    /// Commit a user-chosen order (from the rearrange mode). Keeps only ids that are still pinned.
    func setOrder(_ ids: [String]) {
        let kept = ids.filter { pinned.contains($0) }
        pinned = kept + pinned.filter { !kept.contains($0) }
        UserDefaults.standard.set(pinned, forKey: key)
    }
    /// Adopt a pinned list synced from one of my other devices (via SelfSyncCoordinator, last-writer-wins).
    func applySynced(_ ids: [String]) {
        let next = Array(ids.prefix(Self.maxPins))
        guard next != pinned else { return }
        DispatchQueue.main.async {
            self.pinned = next
            UserDefaults.standard.set(next, forKey: self.key)
        }
    }
}

/// Unread-count pill for conversation rows and pinned tiles (and anywhere else a count belongs).
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, count > 9 ? 6 : 0)
            .frame(minWidth: 20, minHeight: 20)
            .background(HavenTheme.pink, in: Capsule())
    }
}

private extension View {
    /// Force a List into active edit mode so `.onMove` shows reorder handles. `\.editMode` is iOS-only;
    /// macOS List reorders by drag without it, so this is a no-op there.
    @ViewBuilder func havenEditModeActive() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}

/// Direct messages. Each DM is a private 2-person circle, so it rides the same E2E
/// engine, delivery, mesh relay, and persistence as everything else.
struct MessagesView: View {
    let account: Account
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @ObservedObject private var pins = DMPinStore.shared
    @State private var showPicker = false
    @State private var newDM: String?      // chosen in the picker, opened after it closes
    @State private var pushedDM: String?   // pushed in THIS tab's stack → tab bar stays visible
    @State private var rearranging = false // drag-to-reorder mode for the pinned grid
    @State private var draftPins: [String] = []   // working order while rearranging (committed on Save)

    /// Newest activity in a conversation (last message time), for recency sorting.
    private func lastActivity(_ circleId: String) -> UInt64 {
        store.messages(in: circleId).map(\.createdAt).max() ?? 0
    }
    /// Pinned ids that still exist, in the user's chosen PIN ORDER (not recency — the whole point of
    /// rearrange is manual control; re-sorting by activity here is what made Save look like a no-op).
    private var pinnedIds: [String] {
        let all = Set(store.dmCircles.map(\.id))
        return pins.pinned.filter(all.contains)
    }
    /// Everything not pinned, most-recently-active first.
    private var unpinnedIds: [String] {
        store.dmCircles.map(\.id).filter { !pins.isPinned($0) }
            .sorted { lastActivity($0) > lastActivity($1) }
    }

    var body: some View {
        ZStack {
            HavenBackground()
            if rearranging {
                rearrangeView   // dedicated draggable grid — NOT inside a List (a List would drag the whole row)
            } else {
                List {
                    if store.dmCircles.isEmpty {
                        Text("No messages yet. Tap the pencil to start one.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    if !pinnedIds.isEmpty {
                        pinnedGrid
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    }
                    ForEach(unpinnedIds, id: \.self) { id in
                        NavigationLink { DMThreadView(circleId: id) } label: { rowLabel(id) }
                            .listRowBackground(Color.clear)
                            .swipeActions {
                                Button(role: .destructive) { store.deleteConversation(id) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu { conversationMenu(id) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(rearranging ? "Rearrange Pins" : "Messages")
        .havenInlineNavTitle()
        .toolbar {
            if rearranging {
                ToolbarItem(placement: .havenLeading) { Button("Cancel") { cancelRearrange() }.havenToolbarPill() }
                ToolbarItem(placement: .havenTrailing) { Button("Save") { saveRearrange() }.fontWeight(.semibold).havenToolbarPill(tint: HavenTheme.pink) }
            } else {
                ToolbarItem(placement: .havenTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(HavenGlassIcon())
                }
            }
        }
        // Open the new thread in the Messages tab's OWN stack (after the sheet closes) so
        // the tab bar stays visible — you can hop straight back to Circle, and Back lands
        // on the Messages list, not the picker.
        .navigationDestination(item: $pushedDM) { id in DMThreadView(circleId: id) }
        .sheet(isPresented: $showPicker, onDismiss: { if let id = newDM { newDM = nil; pushedDM = id } }) {
            DMContactPicker { id in newDM = id; showPicker = false }   // HavenMacSheet brings its own frame on macOS
        }
        .onAppear {
            // Screenshot harness: open the first DM thread for its hero shot.
            if DemoEnv.scene == .thread {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if pushedDM == nil, let id = store.dmCircles.first?.id { pushedDM = id }
                }
            }
        }
    }

    private func rowLabel(_ circleId: String) -> some View {
        let name = store.dmPartnerName(circleId)
        let unread = store.unreadMessages(in: circleId)
        return HStack(spacing: 12) {
            PeerAvatar(nodeHex: store.dmPartnerHex(circleId) ?? "", name: name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(unread > 0 ? .bold : .medium))
                // Most RECENT message by time — `.last` alone is storage order, not chronological,
                // so it was showing the wrong (often first) message.
                if let last = store.messages(in: circleId).max(by: { $0.createdAt < $1.createdAt }) {
                    Text(last.unsent ? "Message unsent" : (SecretMessages.isSecret(last.body) ? "🔒 Secret message" : last.body))
                        .font(.caption)
                        .foregroundStyle(unread > 0 ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            if unread > 0 {
                Spacer()
                UnreadBadge(count: unread)
            }
        }
    }

    private let pinColumns = [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 16)]

    /// iMessage-style grid of pinned conversations (large avatars) shown above the list (tap to open).
    private var pinnedGrid: some View {
        LazyVGrid(columns: pinColumns, spacing: 16) {
            ForEach(pinnedIds, id: \.self) { id in
                pinnedTile(id)
                    .onTapGesture { pushedDM = id }
                    .contextMenu { conversationMenu(id) }
            }
        }
    }

    /// Reorder pinned conversations via SwiftUI's native List `.onMove` with edit mode forced on — reliable
    /// drag handles on both iOS and macOS. (The earlier custom grid drag-and-drop left a tile stuck/dimmed
    /// after one move because the drag state never reset.) The Messages list still DISPLAYS pins as a grid;
    /// this is just the editing surface. Save/Cancel in the nav bar commit or discard `draftPins`.
    private var rearrangeView: some View {
        List {
            Section {
                ForEach(draftPins, id: \.self) { id in
                    HStack(spacing: 12) {
                        PeerAvatar(nodeHex: store.dmPartnerHex(id) ?? "", name: store.dmPartnerName(id), size: 40)
                        Text(store.dmPartnerName(id)).font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                .onMove { from, to in draftPins.move(fromOffsets: from, toOffset: to) }
            } header: {
                Text("Drag to reorder your pinned conversations")
            }
        }
        .scrollContentBackground(.hidden)
        .havenEditModeActive()
    }

    private func pinnedTile(_ id: String) -> some View {
        let unread = store.unreadMessages(in: id)
        return VStack(spacing: 6) {
            PeerAvatar(nodeHex: store.dmPartnerHex(id) ?? "", name: store.dmPartnerName(id), size: 60)
                // iMessage-style: the unread count rides the pinned avatar's shoulder.
                .overlay(alignment: .topTrailing) {
                    if unread > 0 { UnreadBadge(count: unread).offset(x: 6, y: -4) }
                }
            Text(store.dmPartnerName(id))
                .font(.caption2.weight(unread > 0 ? .bold : .regular))
                .lineLimit(1).foregroundStyle(.primary)
        }
    }

    private func beginRearrange() { draftPins = pinnedIds; withAnimation { rearranging = true } }
    private func saveRearrange() { pins.setOrder(draftPins); withAnimation { rearranging = false } }
    private func cancelRearrange() { withAnimation { rearranging = false } }

    /// Shared long-press menu: pin/unpin (respecting the 6-pin cap), rearrange pins, delete.
    @ViewBuilder private func conversationMenu(_ id: String) -> some View {
        if pins.isPinned(id) {
            Button { pins.toggle(id) } label: { Label("Unpin", systemImage: "pin.slash") }
            if pins.pinned.count > 1 {
                Button { beginRearrange() } label: { Label("Rearrange Pins", systemImage: "arrow.up.arrow.down") }
            }
        } else {
            Button { pins.toggle(id) } label: { Label("Pin", systemImage: "pin") }
                .disabled(pins.isFull)
        }
        Button(role: .destructive) { pins.remove(id); store.deleteConversation(id) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}


/// Pick a contact to start a DM with. Hands the new circle id back to the caller so the
/// thread opens in the Messages tab's own stack (tab bar visible), not inside this sheet.
struct DMContactPicker: View {
    var onPick: (String) -> Void
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var contacts = ContactsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []   // pick one → 1:1, pick several → group DM

    var body: some View {
        #if os(macOS)
        HavenMacSheet(selected.count > 1 ? "New group · \(selected.count)" : "New message") {
            contactColumn
        } footer: {
            Button(selected.count > 1 ? "Start group" : "Start") { start() }
                .buttonStyle(BrandButtonStyle())
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
        }
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                List(contacts.contacts) { c in
                    Button { toggle(c.idHex) } label: {
                        HStack(spacing: 12) {
                            PeerAvatar(nodeHex: c.idHex, name: c.displayName, size: 40)
                            Text(c.displayName).font(.body).foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(c.idHex) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(HavenTheme.pink)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(selected.count > 1 ? "New group · \(selected.count)" : "New message")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { dismiss() }.havenToolbarPill() }
                ToolbarItem(placement: .havenConfirmTrailing) {
                    Button(selected.count > 1 ? "Start group" : "Start") { start() }
                        .fontWeight(.semibold).havenToolbarPill(tint: HavenTheme.pink).disabled(selected.isEmpty)
                }
            }
        }
        #endif
    }

    #if os(macOS)
    /// A column of glass pills, not a List — HavenMacSheet's content lives in a ScrollView, which
    /// gives a List no height to lay out against.
    private var contactColumn: some View {
        VStack(spacing: 8) {
            ForEach(contacts.contacts) { c in
                Button { toggle(c.idHex) } label: {
                    HStack(spacing: 12) {
                        PeerAvatar(nodeHex: c.idHex, name: c.displayName, size: 40)
                        Text(c.displayName).font(.body).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(c.idHex) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(HavenTheme.pink)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .havenGlass(in: Capsule(), tint: selected.contains(c.idHex) ? HavenTheme.pink.opacity(0.35) : nil)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
    #endif

    private func toggle(_ hex: String) {
        if selected.contains(hex) { selected.remove(hex) } else { selected.insert(hex) }
    }

    private func start() {
        let chosen = contacts.contacts.filter { selected.contains($0.idHex) }
        guard !chosen.isEmpty else { return }
        if chosen.count == 1 {
            onPick(store.startDM(with: chosen[0].idHex, name: chosen[0].displayName))
        } else {
            let name = chosen.map(\.displayName).sorted().joined(separator: ", ")
            onPick(store.startGroupDM(members: chosen.map(\.idHex), name: name))
        }
    }
}

/// A chat thread for one DM.
struct DMThreadView: View {
    let circleId: String
    @ObservedObject private var store = FeedStore.shared
    @State private var text = ""
    @State private var secret = false
    @State private var editingId: String?      // editing one of my sent messages
    @State private var disappearSecs: UInt64?  // disappearing-message mode (nil = off)
    @State private var attachedMedia: [String] = []
    @State private var attachedTrack: TrackRefFfi?
    @State private var showMedia = false
    @State private var showSongs = false
    @State private var showAudio = false
    @State private var zoom: ZoomTarget?
    @State private var reactTarget: ReactTarget?

    struct ReactTarget: Identifiable { let id: String }
    @FocusState private var focused: Bool

    /// A GROUP DM has more than one OTHER participant — then each incoming message needs a sender name so
    /// the group knows who said what (a 1:1 DM doesn't).
    private var isGroupDM: Bool { store.memberHexes(circleId: circleId).count > 1 }
    private func senderName(_ m: FeedItemFfi) -> String {
        ContactsStore.shared.name(forNodePrefix: m.authorShort) ?? "Someone"
    }

    /// Thread title + presence ("Online" / "Last seen …"). Placed centered on iOS, leading on macOS.
    @ViewBuilder private var dmHeader: some View {
        let p = store.dmPresence(circleId)
        VStack(alignment: .leading, spacing: 1) {
            Text(store.dmPartnerName(circleId)).font(.headline)
            Text(p.online ? "Online"
                 : (p.lastSeen.map { "Last seen \(relativeTimeShort(UInt64($0.timeIntervalSince1970 * 1000))) ago" } ?? "Offline"))
                .font(.caption2).foregroundStyle(p.online ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 10)   // keep the text off the pill edges (was bleeding outside the shape)
        .fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        ZStack {
            HavenBackground()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(ordered, id: \.id) { m in
                            bubble(m).id(m.id)
                        }
                    }
                    .padding(16)
                    // Clear the floating composer so the newest bubble sits just above the input;
                    // older messages scroll UNDER it (and the tab bar) — same as the feed, no band.
                    .padding(.bottom, 64)
                }
                // A chat fills from the BOTTOM: a short thread sits just above the input (not floating
                // at the top with dead space below), and new messages stay pinned to the bottom while
                // scrolling up still reveals history.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.postTick) { scrollToBottom(proxy) }
                .onChange(of: store.items.count) { scrollToBottom(proxy) }
                .onAppear { scrollToBottom(proxy) }
            }
            // Floating input — no background slab; content scrolls beneath it (matches the feed).
            VStack { Spacer(); composer }
        }
        .havenInlineNavTitle()
        .toolbar {
            // On macOS a centered (.principal) header pushes the window's top tabs around as the name +
            // "last seen" line changes width — so pin it to the leading edge by the back button instead.
            #if os(macOS)
            ToolbarItem(placement: .havenLeading) { dmHeader }
            #else
            ToolbarItem(placement: .principal) { dmHeader }
            #endif
            ToolbarItem(placement: .havenTrailing) {
                Button {
                    // Ring EVERYONE in the thread — one person for a 1:1, the whole roster for a group DM.
                    let members = store.dmMemberHexes(circleId)
                    if !members.isEmpty {
                        CallManager.shared.startCall(participants: members, name: store.dmPartnerName(circleId))
                    }
                } label: { Image(systemName: "phone.fill") }
                .buttonStyle(HavenGlassIcon())
                .disabled(store.dmMemberHexes(circleId).isEmpty)
            }
        }
        .onAppear { store.forceSync(); store.markThreadRead(circleId) }
        // Messages arriving WHILE the thread is open are being read — keep the watermark current
        // so backing out never leaves a stale badge for a conversation the user just watched.
        .onChange(of: store.postTick) { store.markThreadRead(circleId) }
        .onDisappear { store.markThreadRead(circleId) }
        .onDisappear { MusicPlayback.shared.stop() }   // leaving the thread silences any DM song
        .havenFullScreenCover(item: $zoom, wide: true) { t in MediaZoomViewer(refs: t.refs, index: t.index) }
        .sheet(item: $reactTarget) { t in
            ReactionPicker { e in store.reactMessage(in: circleId, t.id, e) }
        }
    }

    @ViewBuilder private func dmMedia(_ m: FeedItemFfi) -> some View {
        let audio = m.media.filter { MediaKind(ref: $0) == .audio }
        let visual = m.media.filter { MediaKind(ref: $0) != .audio }
        VStack(alignment: m.isMe ? .trailing : .leading, spacing: 4) {
            ForEach(audio, id: \.self) { ref in
                if let url = MediaStore.shared.storagePath(for: ref) { AudioPlayerPill(url: url) }
            }
            if !visual.isEmpty { dmVisualMedia(visual, isMe: m.isMe) }
        }
    }

    @ViewBuilder private func dmVisualMedia(_ refs: [String], isMe: Bool) -> some View {
        if refs.count == 1, let ref = refs.first, let img = MediaStore.shared.item(ref)?.image {
            Image(platformImage: img).resizable().scaledToFill()
                .frame(maxWidth: 220, maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .center) {
                    if MediaStore.shared.item(ref)?.kind == .video {
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white)
                    }
                }
                .sensitiveContentGuard(ref: ref, circleId: circleId, scan: !isMe, cornerRadius: 14)
                .onTapGesture { zoom = ZoomTarget(refs: refs, index: 0) }
        } else if !refs.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible())], spacing: 4) {
                ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                    if let img = MediaStore.shared.item(ref)?.image {
                        Image(platformImage: img).resizable().scaledToFill().frame(width: 104, height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .center) {
                                if MediaStore.shared.item(ref)?.kind == .video { Image(systemName: "play.circle.fill").foregroundStyle(.white) }
                            }
                            .sensitiveContentGuard(ref: ref, circleId: circleId, scan: !isMe)
                            .onTapGesture { zoom = ZoomTarget(refs: refs, index: i) }
                    }
                }
            }
            .frame(width: 216)
        }
    }

    @ViewBuilder private func bubble(_ m: FeedItemFfi) -> some View {
        HStack {
            if m.isMe { Spacer(minLength: 50) }
            VStack(alignment: m.isMe ? .trailing : .leading, spacing: 4) {
                // In a group DM, label each INCOMING message with who sent it.
                if isGroupDM && !m.isMe {
                    Text(senderName(m)).font(.caption2.weight(.semibold))
                        .foregroundStyle(HavenTheme.pink).padding(.leading, 4)
                }
                if !m.media.isEmpty { dmMedia(m) }
                if let t = m.music { DMSongChip(track: t, isMe: m.isMe) }
                if m.unsent {
                    Text("Message unsent").italic()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.secondary)
                } else if SecretMessages.isSecret(m.body) {
                    SecretBubble(text: SecretMessages.text(m.body), isMe: m.isMe)
                } else if !m.body.isEmpty {
                    Text(m.body)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(m.isMe ? AnyShapeStyle(HavenTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(m.isMe ? .white : .primary)
                    // Rich Open Graph preview for a link in the message.
                    if let url = LinkScanner.urls(in: m.body).first {
                        LinkPreviewCard(url: url).frame(maxWidth: 260)
                    }
                }
                if !m.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(m.reactions, id: \.emoji) { r in
                            Text("\(r.emoji)\(r.count > 1 ? " \(r.count)" : "")")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                    }
                }
                HStack(spacing: 3) {
                    Text(relativeTimeShort(m.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                    if m.edited && !m.unsent { Text("edited").font(.caption2).foregroundStyle(.tertiary) }
                    if m.isMe && !m.unsent {
                        // sent → checkmark; on the circle's relay → filled (store-and-forward delivered)
                        Image(systemName: store.relayReachable ? "checkmark.circle.fill" : "checkmark")
                            .font(.system(size: 9))
                            .foregroundStyle(store.relayReachable ? HavenTheme.pink : Color.secondary)
                    }
                }
            }
            .contextMenu {
                if !m.unsent {
                    // Your most-used emoji as a single horizontal palette row (4 fits without
                    // wrapping to a second stacked row), then the full picker.
                    // Flat rows, each reacting on TAP. A ControlGroup here collapsed into a
                    // "❤️ 😎 👍 ›" SUBMENU on macOS: it showed the emoji, then made you open a
                    // second menu to actually pick one.
                    ForEach(EmojiStore.shared.frequent(3), id: \.self) { e in
                        Button("React \(e)") { EmojiStore.shared.record(e); store.reactMessage(in: circleId, m.id, e) }
                    }
                    Button { reactTarget = ReactTarget(id: m.id) } label: {
                        Label("More reactions…", systemImage: "face.smiling")
                    }
                }
                if m.isMe && !m.unsent {
                    if !m.body.isEmpty && !SecretMessages.isSecret(m.body) {
                        Button { beginEdit(m) } label: { Label("Edit", systemImage: "pencil") }
                    }
                    Button(role: .destructive) { store.deleteMessage(in: circleId, m.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            if !m.isMe { Spacer(minLength: 50) }
        }
    }

    private func beginEdit(_ m: FeedItemFfi) {
        editingId = m.id
        text = m.body
        secret = false
        focused = true
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if editingId != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil"); Text("Editing message").font(.caption)
                    Spacer()
                    Button("Cancel") { editingId = nil; text = ""; focused = false }.font(.caption)
                }
                .foregroundStyle(.secondary).padding(.horizontal, 6)
            } else if let secs = disappearSecs {
                HStack(spacing: 6) {
                    Image(systemName: "timer"); Text("Disappears after \(Self.disappearLabel(secs))").font(.caption)
                    Spacer()
                    Button("Off") { disappearSecs = nil }.font(.caption)
                }
                .foregroundStyle(HavenTheme.pink).padding(.horizontal, 6)
            }
            if !attachedMedia.isEmpty || attachedTrack != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedMedia, id: \.self) { ref in
                            if MediaKind(ref: ref) == .audio {
                                HStack(spacing: 5) {
                                    Image(systemName: "mic.fill"); Text("Voice").font(.caption)
                                    Button { attachedMedia.removeAll { $0 == ref } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain)   // the glyph IS the button — no macOS bezel behind it
                                }
                                .padding(.horizontal, 8).padding(.vertical, 8)
                                .background(HavenTheme.pink.opacity(0.18), in: Capsule())
                            } else if let img = MediaStore.shared.item(ref)?.image {
                                ZStack(alignment: .topTrailing) {
                                    Image(platformImage: img).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                                    Button { attachedMedia.removeAll { $0 == ref } } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white).background(Circle().fill(.black.opacity(0.5)))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(2)
                                }
                            }
                        }
                        if let t = attachedTrack {
                            HStack(spacing: 5) {
                                Image(systemName: "music.note")
                                Text(t.title).lineLimit(1)
                                Button { attachedTrack = nil } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                            }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 6)
                            .background(HavenTheme.pink.opacity(0.18), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            HStack(spacing: 10) {
                Menu {
                    Button { showMedia = true } label: { Label("Photo or video", systemImage: "photo") }
                    Button { showAudio = true } label: { Label("Voice message", systemImage: "mic") }
                    Button { showSongs = true } label: { Label("Song", systemImage: "music.note") }
                    Button { secret.toggle() } label: { Label(secret ? "Secret: on" : "Send secretly", systemImage: secret ? "lock.fill" : "lock") }
                    Menu {
                        Button { disappearSecs = nil } label: { Label("Off", systemImage: disappearSecs == nil ? "checkmark" : "circle") }
                        Button { disappearSecs = 3_600 } label: { Text("After 1 hour") }
                        Button { disappearSecs = 86_400 } label: { Text("After 1 day") }
                        Button { disappearSecs = 604_800 } label: { Text("After 1 week") }
                    } label: { Label("Disappearing", systemImage: "timer") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(HavenTheme.pink)
                }
                .menuIndicator(.hidden)
                #if os(macOS)
                .menuStyle(.borderlessButton)   // match the feed composer: just the pink circle, no button chrome
                .fixedSize()
                #endif
                TextField(secret ? "Secret message…" : "Message…", text: $text, axis: .vertical)
                    .focused($focused)
                    .textFieldStyle(.plain)   // drop macOS's default field border (was doubling with the glass)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    // Fixed-radius rounded rect, not havenPillField — a Capsule clips into multi-line text.
                    // Secret mode reads as a pink tint on the same single glass surface.
                    .havenGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                                tint: secret ? HavenTheme.pink.opacity(0.35) : nil)
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title).foregroundStyle(HavenTheme.pink)
                }
                .buttonStyle(PressableStyle())
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && attachedMedia.isEmpty && attachedTrack == nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // NO band behind the composer (matches the feed): a material slab read as a detached grey
        // bar. The + / field / send each carry their own glass surface and float over the backdrop;
        // contentShape keeps the whole bar tappable without one.
        .contentShape(Rectangle())
        .sheet(isPresented: $showMedia) { MediaPicker { refs in attachedMedia.append(contentsOf: refs) }.macSheetFrame() }
        .sheet(isPresented: $showSongs) { SongPicker { t in attachedTrack = t }.macSheetFrame() }
        .sheet(isPresented: $showAudio) { AudioRecorderView { ref in attachedMedia.append(ref) }.macSheetFrame() }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingId {   // saving an edit
            guard !t.isEmpty else { return }
            store.editMessage(in: circleId, id, t)
            editingId = nil; text = ""; focused = false
            return
        }
        guard !t.isEmpty || !attachedMedia.isEmpty || attachedTrack != nil else { return }
        let body = secret ? SecretMessages.encode(t) : t
        store.sendMessage(to: circleId, body, media: attachedMedia, music: attachedTrack, retentionSecs: disappearSecs)
        text = ""; secret = false; attachedMedia = []; attachedTrack = nil; focused = false
        // disappearSecs is sticky (stays on for the conversation until you turn it Off).
    }

    static func disappearLabel(_ secs: UInt64) -> String {
        switch secs {
        case ..<3_600: return "\(secs / 60)m"
        case ..<86_400: return "\(secs / 3_600)h"
        case ..<604_800: return "\(secs / 86_400)d"
        default: return "\(secs / 604_800)w"
        }
    }

    /// Oldest → newest, so the newest message sits at the bottom (standard chat order).
    private var ordered: [FeedItemFfi] {
        store.messages(in: circleId).sorted { $0.createdAt < $1.createdAt }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = ordered.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

/// A play/pause song chip for DM messages.
struct DMSongChip: View {
    let track: TrackRefFfi
    let isMe: Bool
    @State private var playing = false
    var body: some View {
        Button {
            if playing { MusicPlayback.shared.stop(); playing = false }
            else { MusicPlayback.shared.play(track); playing = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(track.artist).font(.caption2).lineLimit(1).opacity(0.8)
                }
                EqualizerBars(animating: playing)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(isMe ? .white : .primary)
            .background(isMe ? AnyShapeStyle(HavenTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
