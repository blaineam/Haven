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
/// A DM composer draft handed over from somewhere else in the app, plus which thread to open.
///
/// "Message the author" from a post used to start the DM, SEND the post's media immediately, and
/// switch the circle — so it published something you hadn't written yet and dropped you into the
/// feed layout instead of your conversation. What it should do is take you to the thread with the
/// post already referenced and the cursor waiting, so the message is still yours to write.
///
/// The reference is the post's LINK rather than its media: a draft that re-seals a whole video into
/// the DM circle does that work before you've decided to send anything, and the link opens the real
/// post (with its media) for anyone in the circle.
@MainActor
final class DMDraftStore: ObservableObject {
    static let shared = DMDraftStore()
    /// Thread the app should open next, if any — consumed by MessagesView.
    @Published var openThread: String?
    private var drafts: [String: String] = [:]

    private init() {}

    func stage(circleId: String, text: String) {
        drafts[circleId] = text
        openThread = circleId
    }

    /// Take the staged draft for a thread (once) — the composer owns the text from then on.
    func takeDraft(_ circleId: String) -> String? { drafts.removeValue(forKey: circleId) }
}

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
        // Somewhere else in the app staged a draft (e.g. "Message the author" on a post) — open that
        // thread in this tab's stack, exactly as picking it from the list would.
        .onReceive(DMDraftStore.shared.$openThread.compactMap { $0 }) { id in
            DMDraftStore.shared.openThread = nil
            pushedDM = id
        }
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
        .havenPausesPostAudio()
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
        .havenPausesPostAudio()
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
    /// Set when a DM's backup indicator is tapped — "which relays actually hold this attachment?"
    @State private var backupDetailRefs: BackupRefs?
    @State private var editingMedia: [String] = []          // its attachments, preserved across the edit
    @State private var editingTrack: TrackRefFfi?           // and its song
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
    /// Measured height of the floating composer — the ScrollView's bottom inset tracks it so the newest
    /// bubble always rests just above the input, whatever the composer is showing (edit/disappear banner,
    /// attachment row) and whichever thread. A fixed guess (76) was close enough for short 1:1 threads but
    /// left the last message sitting too low behind the composer on longer group threads.
    @State private var composerHeight: CGFloat = 76
    /// Is the newest message currently on screen? Drives whether an arriving message scrolls into
    /// view. Starts true because a thread opens pinned to the bottom.
    @State private var atBottom = true

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
                        // Zero-height marker that exists only to report whether the BOTTOM of the
                        // thread is on screen. Used to decide whether an arriving message should
                        // scroll into view or be left alone — see onChange(of: ordered.count).
                        Color.clear.frame(height: 1)
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(16)
                }
                // A chat fills from the BOTTOM: a short thread sits just above the input, new messages stay
                // pinned to the bottom, scrolling up still reveals history. A bottom CONTENT INSET the size
                // of the floating composer keeps the newest bubble ABOVE the input at rest — an inset works
                // regardless of how much history is loaded (unlike a scroll-to-anchor, which fails on a long
                // LazyVStack because the anchor isn't rendered yet). The inset tracks the composer's MEASURED
                // height (+ a small gap) so it's correct for every composer state and thread length.
                .contentMargins(.bottom, composerHeight + 10, for: .scrollContent)
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: store.postTick) { scrollToBottom(proxy); fetchMissingThreadMedia() }
                // postTick only moves for OUR OWN send/edit/delete — nothing bumps it on receive — so
                // watching it alone meant a picture arriving while you were looking at the thread was
                // fetched by nothing. Watch the message count, which does move when one lands.
                .onChange(of: ordered.count) {
                    fetchMissingThreadMedia()
                    // A message arriving while you are reading should be READABLE without you having
                    // to scroll for it — but only if you were at the bottom already. Yanking someone
                    // back down while they are reading history is worse than making them scroll.
                    if atBottom { scrollToBottom(proxy) }
                }
                .onChange(of: store.items.count) { scrollToBottom(proxy) }
                // Ask for anything this thread references and we don't hold — on open, and again when
                // a new message lands. Nothing else ever does this for DMs (see fetchMissingThreadMedia).
                .task(id: circleId) { fetchMissingThreadMedia() }
                .onChange(of: composerHeight) { scrollToBottom(proxy, animated: false) }
                // On open, `defaultScrollAnchor(.bottom)` gets short threads right, but a LONG (often group)
                // thread's lazy content isn't measured yet, so it can rest too low behind the composer.
                // Force the newest bubble into view once after the list settles — non-animated, twice, to
                // catch late lazy layout.
                .onAppear {
                    // A draft staged elsewhere (e.g. "Message the author" on a post) lands in the
                    // composer, unsent — appended, so re-entering a thread can't discard something
                    // half-typed.
                    if let staged = DMDraftStore.shared.takeDraft(circleId) {
                        text = text.isEmpty ? staged : "\(text)\n\(staged)"
                    }
                    scrollToBottom(proxy, animated: false)
                    DispatchQueue.main.async { scrollToBottom(proxy, animated: false) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { scrollToBottom(proxy, animated: false) }
                }
            }
            // Floating input — no background slab; content scrolls beneath it (matches the feed).
            // Measure its height so the ScrollView's bottom inset can track it exactly.
            VStack { Spacer(); composer
                .background(GeometryReader { geo in
                    Color.clear.preference(key: DMComposerHeightKey.self, value: geo.size.height)
                })
            }
            .onPreferenceChange(DMComposerHeightKey.self) { h in
                if h > 0, abs(h - composerHeight) > 1 { composerHeight = h }
            }
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
        .onAppear {
            // forceSync() used to re-fan hello/history/Multipeer every open — cooked phones and
            // locked the engine while the thread painted. Pull this circle's mailbox only.
            store.markThreadRead(circleId)
            store.pollMailboxNow()
        }
        // Messages arriving WHILE the thread is open are being read — keep the watermark current
        // so backing out never leaves a stale badge for a conversation the user just watched.
        .onChange(of: store.postTick) { store.markThreadRead(circleId) }
        .onDisappear { store.markThreadRead(circleId) }
        .onDisappear { MusicPlayback.shared.stop() }   // leaving the thread silences any DM song
        .havenFullScreenCover(item: $zoom, wide: true) { t in MediaZoomViewer(refs: t.refs, index: t.index) }
        .sheet(item: $reactTarget) { t in
            ReactionPicker { e in store.reactMessage(in: circleId, t.id, e) }
        }
        .sheet(item: $backupDetailRefs) { b in
            BackupDetailView(refs: b.refs, circleId: circleId)
                .macSheetFrame()
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }

    @ViewBuilder private func dmMedia(_ m: FeedItemFfi) -> some View {
        // Drop synthetic markers + original companions from the bubble; display only playable media.
        let display = MediaVariants.displayRefs(m.media)
        let audio = display.filter { MediaKind(ref: $0) == .audio }
        let files = display.filter { MediaKind(ref: $0) == .file }
        let visual = display.filter {
            let k = MediaKind(ref: $0); return k != .audio && k != .file
        }
        VStack(alignment: m.isMe ? .trailing : .leading, spacing: 4) {
            ForEach(audio, id: \.self) { ref in
                if let url = MediaStore.shared.storagePath(for: ref) { AudioPlayerPill(url: url) }
            }
            ForEach(files, id: \.self) { ref in
                if let url = MediaStore.shared.storagePath(for: ref) {
                    ShareLink(item: url) {
                        Label("File", systemImage: "doc.zipper")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color(.secondarySystemFill), in: Capsule())
                    }
                } else {
                    // Super data saver / not yet fetched — tap to pull.
                    Button {
                        store.requestMedia(ref, circleId: circleId)
                    } label: {
                        Label("Download file", systemImage: "arrow.down.doc")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !visual.isEmpty { dmVisualMedia(visual, isMe: m.isMe, postMedia: m.media) }
        }
    }

    @ViewBuilder private func dmVisualMedia(_ refs: [String], isMe: Bool, postMedia: [String] = []) -> some View {
        if refs.count == 1, let ref = refs.first {
            dmVisualTile(ref, postMedia: postMedia, isMe: isMe, maxW: 220, maxH: 280, corner: 14) {
                zoom = ZoomTarget(refs: refs, index: 0)
            }
        } else if !refs.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible())], spacing: 4) {
                ForEach(Array(refs.enumerated()), id: \.offset) { i, ref in
                    dmVisualTile(ref, postMedia: postMedia, isMe: isMe, maxW: 104, maxH: 104, corner: 10) {
                        zoom = ZoomTarget(refs: refs, index: i)
                    }
                }
            }
            .frame(width: 216)
        }
    }

    /// One DM attachment tile. Super data saver may only have the poster still for a video —
    /// show that + play, and on tap request the video then open the zoom player.
    @ViewBuilder private func dmVisualTile(_ ref: String, postMedia: [String], isMe: Bool,
                                          maxW: CGFloat, maxH: CGFloat, corner: CGFloat,
                                          onOpen: @escaping () -> Void) -> some View {
        let isVid = MediaKind(ref: ref) == .video
        let hasFile = MediaStore.shared.hasLocalFile(ref)
        let posterRef = isVid ? MediaVariants.poster(for: ref, in: postMedia) : nil
        let img = MediaStore.shared.item(ref)?.image
            ?? posterRef.flatMap { MediaStore.shared.item($0)?.image }
        if let img {
            Image(platformImage: img).resizable().scaledToFill()
                .frame(maxWidth: maxW, maxHeight: maxH)
                .frame(width: maxW == 104 ? 104 : nil, height: maxH == 104 ? 104 : nil)
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .overlay(alignment: .center) {
                    if isVid {
                        Image(systemName: "play.circle.fill")
                            .font(maxW >= 200 ? .largeTitle : .title2)
                            .foregroundStyle(.white)
                    }
                }
                .sensitiveContentGuard(ref: ref, circleId: circleId, scan: !isMe, cornerRadius: corner)
                .onTapGesture {
                    if isVid, !hasFile {
                        store.requestMedia(ref, circleId: circleId)
                    }
                    onOpen()
                }
        } else if isVid, !hasFile {
            // Poster not in yet either — still offer a tappable download affordance.
            RoundedRectangle(cornerRadius: corner)
                .fill(Color(.secondarySystemFill))
                .frame(width: maxW == 104 ? 104 : 160, height: maxH == 104 ? 104 : 120)
                .overlay {
                    Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                .onTapGesture {
                    store.requestMedia(ref, circleId: circleId)
                    onOpen()
                }
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
                    // The previewed link is dropped from the bubble: the card below already names the
                    // destination, so leaving the raw URL in the text repeats it (and a shared post
                    // link is long enough to swamp the sentence around it). A bubble with ONLY a link
                    // becomes just its card.
                    let previewed = LinkScanner.urls(in: m.body).first
                    let shown = previewed.map { LinkScanner.stripping($0, from: m.body) } ?? m.body
                    if !shown.isEmpty {
                        Text(shown)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(m.isMe ? AnyShapeStyle(HavenTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(m.isMe ? .white : .primary)
                    }
                    // Rich Open Graph preview for a link in the message.
                    if let url = previewed {
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
                    // A DM attachment is stored and fetched exactly like a post's, but the feed was
                    // the only place that ever said whether it landed — so "why can't they open the
                    // photo I sent?" had no answer anywhere in the app. Same ledger, same sheet.
                    if m.isMe && !m.unsent {
                        let blobs = m.media.filter { !MediaStore.isSynthetic($0) }
                        if !blobs.isEmpty {
                            let own = RelayHost.shared.serving ? RelayHost.shared.nodeId : ""
                            let hasRelay = !RelayMailboxStore.shared.relays(forCircle: circleId).isEmpty
                                || SharedStore.hasMailbox(circleId)
                            let backed = blobs.allSatisfy { MediaBackupLedger.hasAnyRemote($0, ownRelayHex: own) }
                            let localOnly = !backed && blobs.allSatisfy { MediaBackupLedger.hasAny($0) }
                            let pending = blobs.contains { MediaBackupQueue.shared.hasPending($0) }
                            let stuck = MediaUploadProgress.shared.looksStuck(blobs)
                                || (!backed && !hasRelay)
                                || (!backed && !pending && !localOnly)
                            let icon = backed ? "checkmark.icloud.fill"
                                : (!hasRelay || stuck ? "exclamationmark.icloud"
                                   : (localOnly ? "externaldrive.badge.exclamationmark" : "arrow.up.circle"))
                            let color: AnyShapeStyle = backed ? AnyShapeStyle(HavenTheme.pink)
                                : ((!hasRelay || stuck || localOnly) ? AnyShapeStyle(Color.orange)
                                   : AnyShapeStyle(Color.secondary))
                            Image(systemName: icon)
                                .font(.system(size: 9))
                                .foregroundStyle(color)
                                .help(!hasRelay
                                      ? "No relay known — attachment only on this device"
                                      : (backed ? "Backed up to a relay" : "Uploading to a relay…"))
                                .contentShape(Rectangle())
                                .onTapGesture { backupDetailRefs = BackupRefs(refs: blobs) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("Shows which relays hold a copy")
                        }
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
        // Held so `send()` can hand them back: an edit REPLACES the media array rather than merging,
        // so saving without them strips the photo or song off the message for both people.
        editingMedia = m.media
        editingTrack = m.music
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
            MediaProcessingCard()   // spinner while a video encodes — see MediaProcessing
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
            store.editMessage(in: circleId, id, t, media: editingMedia, music: editingTrack)
            editingId = nil; editingMedia = []; editingTrack = nil; text = ""; focused = false
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

    /// Fetch media this thread references but we don't hold.
    ///
    /// Nothing did this for DMs. `requestMissingMedia` scans `items` — the ACTIVE CIRCLE's feed — and
    /// DM messages are never in it, so a photo or video sent in a DM was only ever fetched from a
    /// relay by accident. It arrived if the sender happened to push it peer-to-peer while both were
    /// online, and otherwise never: the message showed up, sat there with nothing in it, and no device
    /// ever asked for the bytes — even when the blob was sitting complete on a relay the receiver was
    /// itself hosting.
    ///
    /// Bounded deliberately: newest messages first (what you're looking at), a handful per pass, and
    /// `requestMedia` no-ops for anything already held. Opening a thread must not turn into a fetch
    /// storm on a long history.
    private func fetchMissingThreadMedia() {
        var budget = 6
        let dataSaver = SettingsStore.shared.superDataSaver
        for item in ordered.reversed() {
            let candidates = dataSaver
                ? MediaVariants.dataSaverPrefetchRefs(item.media)
                : item.media.filter { !MediaStore.isSynthetic($0) }
            for ref in candidates where !MediaStore.shared.has(ref) {
                guard budget > 0 else { return }
                budget -= 1
                store.requestMedia(ref, circleId: circleId)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Keep the newest message pinned to the bottom on a new message / on open. The bottom content
        // inset (above) keeps it clear of the composer; here we just ensure the latest bubble is in view.
        // Non-animated on the initial settle so a long thread snaps into place without a visible jump.
        guard let last = ordered.last else { return }
        if animated { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
        else { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

/// Reports the floating DM composer's measured height up to the thread view (drives the ScrollView's
/// bottom inset so the newest bubble always rests just above the input).
private struct DMComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
