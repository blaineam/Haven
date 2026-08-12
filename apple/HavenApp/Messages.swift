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
        nudgeSync()
    }
    func remove(_ id: String) {
        guard let i = pinned.firstIndex(of: id) else { return }
        pinned.remove(at: i); UserDefaults.standard.set(pinned, forKey: key)
        nudgeSync()
    }
    /// Commit a user-chosen order (from the rearrange mode). Keeps only ids that are still pinned.
    func setOrder(_ ids: [String]) {
        let kept = ids.filter { pinned.contains($0) }
        pinned = kept + pinned.filter { !kept.contains($0) }
        UserDefaults.standard.set(pinned, forKey: key)
        nudgeSync()
    }
    /// A LOCAL pin change (never `applySynced`) reaches my other devices in seconds via a
    /// debounced forced self-sync pass, instead of waiting out the 2-minute periodic gate.
    private func nudgeSync() {
        Task { @MainActor in FeedStore.shared.nudgeSelfSyncSoon() }
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

    /// A message the opening thread should scroll to (a notification tap names the exact
    /// message). Staged by DeepLinkRouter.openDM, consumed once by the thread's onAppear.
    private var scrollTargets: [String: String] = [:]
    func stageScroll(circleId: String, messageId: String) { scrollTargets[circleId] = messageId }
    func takeScrollTarget(_ circleId: String) -> String? { scrollTargets.removeValue(forKey: circleId) }
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
        // Somewhere else in the app staged a draft (e.g. "Message the author" on a post, or an
        // Activity row) — open that thread in this tab's stack, exactly as picking it from the list
        // would.
        .onReceive(DMDraftStore.shared.$openThread.compactMap { $0 }) { id in openStaged(id) }
        .sheet(isPresented: $showPicker, onDismiss: { if let id = newDM { newDM = nil; pushedDM = id } }) {
            DMContactPicker { id in newDM = id; showPicker = false }   // HavenMacSheet brings its own frame on macOS
        }
        .onAppear {
            // A tab request that arrived BEFORE this view existed.
            //
            // On iOS a TabView builds a tab's content the first time that tab is shown, so an
            // Activity row tapped from the Circle tab publishes `openThread` and switches tabs
            // while MessagesView still does not exist — there is nobody subscribed to receive it.
            // macOS builds the tab eagerly, which is the whole reason this worked there and not
            // here. The request is durable (nothing clears it but a consumer), so the fix is simply
            // to also look for one on the way in.
            if let staged = DMDraftStore.shared.openThread { openStaged(staged) }
            // Screenshot harness: open the first DM thread for its hero shot.
            if DemoEnv.scene == .thread {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if pushedDM == nil, let id = store.dmCircles.first?.id { pushedDM = id }
                }
            }
        }
    }

    /// Push a thread that some other surface asked us to open, from either the live subscription or
    /// the on-appear catch-up.
    private func openStaged(_ id: String) {
        // Clear on the NEXT tick, not inline. `@Published` publishes from `willSet`, so the
        // subscription path runs BEFORE the store has written the new value — an inline `= nil` is
        // immediately overwritten by the assignment that woke us, and `openThread` stays pinned to
        // this id forever. That left the request permanently "pending": every later subscription
        // replayed it (re-pushing a thread the user had already backed out of), and a second tap on
        // the SAME conversation published a value that was already there, so `pushedDM` never
        // changed and nothing pushed at all.
        DispatchQueue.main.async {
            if DMDraftStore.shared.openThread == id { DMDraftStore.shared.openThread = nil }
        }
        // Always a tick later, never in this render pass. Two reasons, and the second is why an
        // Activity row landed on a blank screen: `navigationDestination(item:)` normally nils
        // `pushedDM` when the user backs out, but if anything left it set then assigning the same
        // value is a no-op and the tap does nothing — so the bounce through nil. And when this
        // arrives from `onAppear`, the NavigationStack is being built in this very frame; handing
        // it a destination value before its `navigationDestination` is registered pushes a view
        // with nothing declared for it, which renders as an empty page.
        if pushedDM == id { pushedDM = nil }
        DispatchQueue.main.async { pushedDM = id }
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
    /// How much of the ScrollView's bottom the floating composer actually covers, measured in GLOBAL
    /// coordinates as (scroll view's bottom edge − composer's top edge).
    ///
    /// Deriving this from the composer's own height does not work, and neither does adding its
    /// `safeAreaInsets`: a GeometryReader INSIDE the composer sits in an already-inset context and
    /// reports a bottom inset of 0, so the correction was silently zero. Meanwhile the real overlap
    /// is composer + home indicator + tab bar — everything between the composer's top and the bottom
    /// of the scrollable area. Measuring both edges globally asks the layout what it actually did
    /// instead of trying to reconstruct it, so it stays right when the tab bar, the keyboard, or a
    /// growing composer changes any of the pieces.
    @State private var composerCover: CGFloat = 86
    @State private var composerTopY: CGFloat = 0
    @State private var scrollBottomY: CGFloat = 0
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

    /// Is this thread actually on this device? A deep link (or a notification tap) can name a `dm:`
    /// circle we have never synced — a group someone else created, or one whose circle hasn't
    /// arrived yet. Pushing the normal view for it rendered an empty scroll area under an empty
    /// header: a screen that looks broken rather than one that explains itself. Desktop already
    /// said so out loud ("That conversation isn't on this device yet"); iOS did not.
    ///
    /// An EMPTY circle list counts as "known": on a cold launch from a notification tap this view can
    /// render before `circles` has been populated for the first time, and an empty list there means
    /// "we haven't loaded yet", not "you don't have this". Answering "not on this device" during that
    /// window flashed the not-here card at people opening a conversation they very much do have.
    private var threadKnown: Bool {
        store.circles.isEmpty || store.circles.contains { $0.id == circleId }
    }

    var body: some View {
        ZStack {
            HavenBackground()
            if !threadKnown {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("This conversation isn't on this device yet")
                        .font(.headline).multilineTextAlignment(.center)
                    Text("It'll appear here once it syncs from your circle. Nothing is lost.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(ordered, id: \.id) { m in
                            bubble(m).id(m.id)
                        }
                        // Zero-height marker that reports whether the BOTTOM of the thread is on
                        // screen (so an arriving message can scroll into view or be left alone —
                        // see onChange(of: ordered.count)) AND serves as the scroll target itself.
                        //
                        // Scrolling to the LAST BUBBLE with `anchor: .bottom` is what produced the
                        // "not quite the bottom" resting position: the anchor aligns that bubble's
                        // bottom edge with the scroll view's, but the composer-sized bottom content
                        // margin means the true end of the thread is further down still — and for a
                        // bubble taller than the viewport (a photo or video card) SwiftUI resolves
                        // the anchor against a frame it can't fully show, landing somewhere
                        // arbitrary. A zero-height marker has no height to resolve against, so
                        // "scroll here" means the end of the thread, exactly, every time.
                        Color.clear.frame(height: 1)
                            .id(Self.bottomAnchor)
                            .onAppear { atBottom = true; HavenLog.sync("dm.scroll marker APPEAR → atBottom=true") }
                            .onDisappear { atBottom = false; HavenLog.sync("dm.scroll marker DISAPPEAR → atBottom=false") }
                    }
                    .padding(16)
                }
                // A chat fills from the BOTTOM: a short thread sits just above the input, new messages stay
                // pinned to the bottom, scrolling up still reveals history. A bottom CONTENT INSET the size
                // of the floating composer keeps the newest bubble ABOVE the input at rest — an inset works
                // regardless of how much history is loaded (unlike a scroll-to-anchor, which fails on a long
                // LazyVStack because the anchor isn't rendered yet). The inset tracks the composer's MEASURED
                // height (+ a small gap) so it's correct for every composer state and thread length.
                // `safeAreaInset` — NOT a hand-computed `contentMargins`.
                //
                // Four attempts died reconstructing this number: the composer's own height misses
                // the home indicator; a GeometryReader inside the composer reports a zero safe-area
                // inset because it is already inset; and measuring the two global edges samples them
                // at different moments during the push transition, so the difference is whatever the
                // animation happened to be doing. SwiftUI already knows the answer exactly — it did
                // the layout — so hand it the composer and let it reserve the space, including the
                // tab bar and home indicator beneath it. The resting position is then correct by
                // construction rather than by arithmetic that has to be re-derived every time the
                // chrome changes.
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                // postTick moves for OUR OWN send/edit/delete. Sending is an explicit "I want to see
                // this" — always ride to the bottom for it.
                .onChange(of: store.postTick) { scrollToBottom(proxy, why: "postTick"); fetchMissingThreadMedia() }
                // postTick doesn't move on receive, so watch the message count, which does when one
                // lands — that's also what keeps arriving media getting fetched.
                .onChange(of: ordered.count) {
                    fetchMissingThreadMedia()
                    // A message arriving while you are reading should be READABLE without you having
                    // to scroll for it — but only if you were at the bottom already. Yanking someone
                    // back down while they are reading history is worse than making them scroll.
                    if atBottom { scrollToBottom(proxy, why: "count->\(ordered.count)") }
                    else { HavenLog.sync("dm.scroll count->\(ordered.count) SKIPPED (atBottom=false)") }
                }
                // DELIBERATELY NOT watching `store.items`. That is the ACTIVE CIRCLE's feed — it has
                // nothing to do with this thread, and it changes on every sync tick, every reaction,
                // every comment, every story anywhere in that circle. Each of those re-ran a scroll
                // against a lazily-measured list, which is what made an open conversation jerk itself
                // to some arbitrary offset every few seconds and stay unreadable. A DM's scroll may
                // only be moved by this DM.
                // Ask for anything this thread references and we don't hold — on open, and again when
                // a new message lands. Nothing else ever does this for DMs (see fetchMissingThreadMedia).
                .task(id: circleId) { fetchMissingThreadMedia() }
                // The composer grew or shrank (attachment tray, edit banner, a wrapping draft) and the
                // content inset moved with it — re-pin so the newest bubble stays put. Only when we
                // were AT the bottom: attaching a photo while reading history must not yank you down.
                .onChange(of: composerHeight) { if atBottom { scrollToBottom(proxy, animated: false, why: "composerH=\(Int(composerHeight))") } else { HavenLog.sync("dm.scroll composerH changed SKIPPED (atBottom=false)") } }
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
                    // A notification tap names the exact message — land on IT, not the bottom
                    // (twice, non-animated, to catch late lazy layout — same trick as below).
                    // The bottom is only the right default when nothing specific was asked for.
                    if let target = DMDraftStore.shared.takeScrollTarget(circleId),
                       ordered.contains(where: { $0.id == target }) {
                        // ...unless the named message is the NEWEST one, which is the common case
                        // for a notification tap. Centering the last bubble parks it mid-screen with
                        // half a view of dead space beneath it — it reads as the thread having
                        // scrolled up and left the latest message stranded low. Centering is only
                        // right when there is genuinely more conversation below to show.
                        if ordered.last?.id == target {
                            scrollToBottom(proxy, animated: false, why: "open.target-is-last")
                            DispatchQueue.main.async { scrollToBottom(proxy, animated: false, why: "open.target-is-last.async") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                scrollToBottom(proxy, animated: false, why: "open.target-is-last.late")
                            }
                            return
                        }
                        proxy.scrollTo(target, anchor: .center)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        return
                    }
                    // NOTHING on open. `defaultScrollAnchor(.bottom)` already opens at the end of
                    // the thread, and now that `safeAreaInset` owns the composer's space it lands in
                    // the right place on its own.
                    //
                    // The three manual scrolls here are what made it "open correctly and then shift
                    // up": the last of them fired 0.25s later, after the inset had settled, and
                    // re-resolved `scrollTo(anchor: .bottom)` against a layout that had already
                    // moved — dragging the thread off the resting position SwiftUI had just put it
                    // in. They existed to paper over the hand-computed inset being wrong at open;
                    // with the inset correct they have nothing left to fix and only cause the jump.
                    HavenLog.sync("dm.scroll open — leaving the resting position to defaultScrollAnchor(.bottom)")
                }
            }
            // (The composer lives in the ScrollView's `safeAreaInset` above — it must NOT also be
            // overlaid here, or it would be drawn twice and reserve space twice.)
            }   // threadKnown
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
            #if os(iOS)
            // Opening a thread is a usage signal, and the share sheet's suggestion row is ranked by
            // donation recency. Donating only on SEND under-reported the conversations you read most
            // and reply to elsewhere, which is exactly the ranking that decides whether iOS gives
            // Haven a slot at all.
            ShareSuggestions.donate(circleId: circleId)
            #endif
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

    /// Body text for a DM bubble after stripping a story/post deep-link token that the card already shows.
    private static func dmShownBody(_ body: String, storyRaw: String?, previewed: URL?) -> String {
        if let raw = storyRaw {
            var shown = body
            if let u = URL(string: raw) {
                shown = LinkScanner.stripping(u, from: shown)
            }
            if shown.contains(raw) {
                shown = shown.replacingOccurrences(of: raw, with: "")
            }
            return shown.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let previewed {
            return LinkScanner.stripping(previewed, from: body)
        }
        return body
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
                // Story reply: never keep showing resealed media after the story is gone.
                // Explicit link / association / inference → StoryReplyCard (live thumb or
                // "Story no longer available"). Legacy single story-shaped attach past 24h with
                // no recoverable event → unavailable tile (not the eternal media crop).
                let storyTarget = !m.unsent ? DeepLink.storyReplyTarget(message: m, dmCircleId: circleId) : nil
                let explicitStory = DeepLink.firstStory(in: m.body)
                let isStoryReply = !m.unsent && DeepLink.isStoryReplyMessage(m, dmCircleId: circleId)

                if let storyTarget {
                    StoryReplyCard(circleId: storyTarget.circleId, postId: storyTarget.postId)
                } else if isStoryReply {
                    // Classified as a story reply but no openable story (expired + purged, not kept).
                    StoryNoLongerAvailableCard()
                } else if !m.media.isEmpty {
                    dmMedia(m)
                }

                if let t = m.music { DMSongChip(track: t, isMe: m.isMe) }
                if m.unsent {
                    Text("Message unsent").italic()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.secondary)
                } else if SecretMessages.isSecret(m.body) {
                    SecretBubble(text: SecretMessages.text(m.body), isMe: m.isMe)
                } else if !m.body.isEmpty {
                    // Story reply: tall framed crop + deep-link open (same path as activity feed).
                    // Prefer over a generic OG card — a story pointer is not a web page.
                    let storyRef = explicitStory
                    // The previewed link is dropped from the bubble: the card below already names the
                    // destination, so leaving the raw URL in the text repeats it (and a shared post
                    // link is long enough to swamp the sentence around it). A bubble with ONLY a link
                    // becomes just its card.
                    let previewed = storyRef == nil ? LinkScanner.urls(in: m.body).first : nil
                    let shown = Self.dmShownBody(m.body, storyRaw: storyRef?.raw, previewed: previewed)
                    if !shown.isEmpty {
                        Text(shown)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(m.isMe ? AnyShapeStyle(HavenTheme.brand) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(m.isMe ? .white : .primary)
                    }
                    // Explicit link card is already drawn above when storyTarget is set; only need
                    // the OG card for non-story URLs here.
                    if storyRef == nil, let url = previewed {
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
                        // `displayRefs`, not the raw list: poster/original/thumb companions ride with
                        // their playable ref and would otherwise each draw their own chip.
                        ForEach(MediaVariants.displayRefs(attachedMedia), id: \.self) { ref in
                            if MediaKind(ref: ref) == .audio {
                                HStack(spacing: 5) {
                                    Image(systemName: "mic.fill"); Text("Voice").font(.caption)
                                    Button { removeAttachment(ref) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain)   // the glyph IS the button — no macOS bezel behind it
                                }
                                .padding(.horizontal, 8).padding(.vertical, 8)
                                .background(HavenTheme.pink.opacity(0.18), in: Capsule())
                            } else {
                                // Unconditional: a video whose poster hasn't been cut yet, and a file,
                                // both used to fall through this branch and draw NOTHING — so a DM
                                // attachment could sit staged and invisible. See ComposerAttachmentTile.
                                ZStack(alignment: .topTrailing) {
                                    ComposerAttachmentTile(ref: ref, media: attachedMedia, size: 52)
                                    Button { removeAttachment(ref) } label: {
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
                    // Claim the full width and pin the tiles to the LEADING edge. The ScrollView
                    // sizes itself to its content, so with one or two attachments it was narrower
                    // than the composer and its parent centred it — a single photo floated in the
                    // middle of the tray, and adding more made them drift outward from the centre
                    // instead of filling from the left and scrolling. Chips read as a queue; a queue
                    // starts at the beginning.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .defaultScrollAnchor(.leading)
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

    /// Drop an attachment AND every companion tied to it — a poster or original left behind would
    /// ride along on the next message with no playable ref to belong to.
    private func removeAttachment(_ ref: String) {
        attachedMedia.removeAll { r in
            if r == ref { return true }
            if let p = MediaVariants.parsePoster(r), p.video == ref || p.poster == ref { return true }
            if let o = MediaVariants.parseOriginal(r), o.optimized == ref || o.original == ref { return true }
            if let t = MediaVariants.parseThumb(r), t.content == ref || t.thumb == ref { return true }
            return false
        }
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

    /// Identity of the zero-height end-of-thread marker. Everything that means "go to the bottom"
    /// targets THIS, never the last bubble — see the marker's own comment for why.
    fileprivate static let bottomAnchor = "haven.dm.bottom"

    /// Both edges are reported independently and in either order, so fold them here.
    private func recomputeCover() {
        guard composerTopY > 0, scrollBottomY > 0 else {
            HavenLog.sync("dm.scroll cover NOT READY composerTop=\(Int(composerTopY)) scrollBottom=\(Int(scrollBottomY))")
            return
        }
        let cover = scrollBottomY - composerTopY
        // Sanity-bound it: a mid-transition layout can briefly report nonsense, and a wild inset is
        // far more visible than a slightly stale one.
        guard cover > 0, cover < 400, abs(cover - composerCover) > 1 else { return }
        composerCover = cover
        HavenLog.sync("dm.scroll composerCover=\(Int(cover)) (scrollBottom=\(Int(scrollBottomY)) composerTop=\(Int(composerTopY)))")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true, why: String = "?") {
        HavenLog.sync("dm.scroll scrollToBottom(\(why)) animated=\(animated) count=\(ordered.count) composerH=\(Int(composerHeight)) atBottom=\(atBottom)")
        scrollToBottomImpl(proxy, animated: animated)
    }

    private func scrollToBottomImpl(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Keep the newest message pinned to the bottom on a new message / on open. The bottom content
        // inset (above) keeps it clear of the composer; here we just ensure the end of the thread is in
        // view. Non-animated on the initial settle so a long thread snaps into place without a jump.
        guard !ordered.isEmpty else { return }
        // We are, by construction, at the bottom after this — say so rather than waiting for the
        // marker's `onAppear` to say it for us.
        //
        // `atBottom` was driven ONLY by a 1pt marker at the end of a lazy stack: `onDisappear` set
        // it false, `onAppear` set it true. Lazy re-layout — media landing and changing a bubble's
        // height, the composer growing — can tear that marker down without ever bringing it back,
        // and then `atBottom` is stuck false forever: arriving messages stop scrolling into view and
        // the thread appears to abandon the bottom. Scrolling by hand re-instantiates the marker,
        // which is why nudging it "fixed" itself. A programmatic scroll to the end is the one moment
        // we know the answer without asking the view.
        atBottom = true
        if animated { withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) } }
        else { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
    }
}

/// Reports the floating DM composer's measured height up to the thread view (drives the ScrollView's
/// bottom inset so the newest bubble always rests just above the input).
private struct DMComposerTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    /// `max`, NOT "last wins". Every view in the subtree contributes the default (0), so a
    /// last-wins reduce let those zeros clobber the composer's real y — the cover was never
    /// computed and the inset silently stayed at its default.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct DMScrollBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

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
