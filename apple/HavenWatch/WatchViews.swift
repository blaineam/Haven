import SwiftUI
import UIKit   // UIImage (available on watchOS) — render real post thumbnails

// MARK: - Conversations list (Circles and Messages kept separate)

/// Two clearly-separated sections — your circle feeds and your direct messages. Tap to open.
/// Syncs automatically (on open + whenever the phone pushes an update); no manual refresh button.
struct WatchConversationsView: View {
    @EnvironmentObject private var client: WatchConnectivityClient
    @State private var path: [WatchThread] = []

    private var circles: [WatchThread] { client.threads.filter { !$0.isDM } }
    private var dms: [WatchThread] { client.threads.filter { $0.isDM } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if client.threads.isEmpty {
                    Text(client.reachable ? "No conversations yet." : "Open Haven on your iPhone to sync.")
                        .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                if !circles.isEmpty {
                    Section {
                        ForEach(circles) { row($0) }
                    } header: { WatchSectionHeader("Circles", "circle.grid.2x2.fill") }
                }
                if !dms.isEmpty {
                    Section {
                        ForEach(dms) { row($0) }
                    } header: { WatchSectionHeader("Messages", "bubble.left.and.bubble.right.fill") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatchBackground())
            .navigationTitle("Haven")
            .navigationDestination(for: WatchThread.self) { t in
                WatchThreadView(threadId: t.id, title: t.title, isDM: t.isDM)
            }
        }
        .onAppear {
            client.refresh()   // auto-sync on open; the phone also pushes updates as they happen
            if WatchDemo.opensThread, path.isEmpty, let first = client.threads.first { path = [first] }
        }
    }

    private func row(_ t: WatchThread) -> some View {
        NavigationLink(value: t) { WatchThreadRow(thread: t) }.listRowBackground(Color.clear)
    }
}

private struct WatchSectionHeader: View {
    let title: String, icon: String
    init(_ t: String, _ i: String) { title = t; icon = i }
    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold)).foregroundStyle(WTheme.pink)
    }
}

private struct WatchThreadRow: View {
    let thread: WatchThread
    var body: some View {
        HStack(spacing: 9) {
            WatchAvatar(title: thread.title, isDM: thread.isDM, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(thread.title).font(.system(.headline, design: .rounded)).lineLimit(1)
                    Spacer(minLength: 2)
                    if thread.timestamp > 0 {
                        Text(watchRelativeTime(thread.timestamp)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !thread.subtitle.isEmpty {
                    Text(thread.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .watchCard()
    }
}

// MARK: - Thread: a DM chat, OR a circle feed (story rings + posts)

struct WatchThreadView: View {
    let threadId: String
    let title: String
    let isDM: Bool
    @EnvironmentObject private var client: WatchConnectivityClient
    @State private var acting: WatchMessage?        // long-pressed item awaiting an action choice
    @State private var reactingTo: WatchMessage?
    @State private var replyTarget: WatchMessage?
    @State private var openStory: WatchStoryGroup?

    private var all: [WatchMessage] {
        client.openThread?.threadId == threadId ? (client.openThread?.messages ?? []) : []
    }
    private var posts: [WatchMessage] { all.filter { !$0.isStory } }
    private var stories: [WatchStoryGroup] { WatchStoryGroup.group(all.filter { $0.isStory }) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // Circle: story rings ride at the top of the feed (not mixed in as posts).
                if !isDM && !stories.isEmpty {
                    WatchStoryTray(groups: stories) { openStory = $0 }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                }
                if posts.isEmpty && (isDM || stories.isEmpty) {
                    Text(client.loadingThread ? "Loading…" : (isDM ? "No messages yet." : "No posts yet."))
                        .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                ForEach(posts) { msg in
                    WatchMessageRow(message: msg)
                        .id(msg.id)
                        .onLongPressGesture(minimumDuration: 0.3) { acting = msg }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatchBackground())
            // A DM reads as a chat: start (and stay) scrolled to the newest at the bottom.
            .onChange(of: posts.count) { _, _ in toBottom(proxy) }
            .onAppear { toBottom(proxy) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { client.openThread(threadId) }
        // Long-press → choose Reply/Comment or React (no more ambiguous bottom Reply button).
        .confirmationDialog(actingTitle, isPresented: actingShown, titleVisibility: .visible) {
            Button(replyVerb) { replyTarget = acting; acting = nil }
            Button("React") { reactingTo = acting; acting = nil }
        }
        .sheet(item: $replyTarget) { msg in
            WatchReplyView(threadId: threadId,
                           targetId: isDM ? nil : msg.id,           // circle → comment on that post
                           to: msg.isMe ? "your post" : msg.author) { replyTarget = nil }
                .environmentObject(client)
        }
        .sheet(item: $reactingTo) { msg in
            WatchReactionPicker { emoji in
                client.react(threadId: threadId, messageId: msg.id, emoji: emoji)
                reactingTo = nil
            }
        }
        .sheet(item: $openStory) { WatchStoryViewer(group: $0) }
    }

    private var replyVerb: String { isDM ? "Reply" : "Comment" }
    private var actingTitle: String { acting.map { $0.isMe ? "Your post" : $0.author } ?? "" }
    private var actingShown: Binding<Bool> {
        Binding(get: { acting != nil }, set: { if !$0 { acting = nil } })
    }
    private func toBottom(_ proxy: ScrollViewProxy) {
        guard isDM, let last = posts.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }
}

// MARK: - One post / message (author name, media carousel, reactions)

private struct WatchMessageRow: View {
    let message: WatchMessage

    private var bubbleColor: Color { message.isMe ? Color.pink.opacity(0.32) : Color.white.opacity(0.12) }
    private var hasBubble: Bool { !message.body.isEmpty || !message.media.isEmpty || message.hasMedia }

    var body: some View {
        VStack(alignment: message.isMe ? .trailing : .leading, spacing: 3) {
            // Show WHO posted (a name/nickname — never the node-id prefix) for everyone but me.
            if !message.isMe {
                Text(message.author).font(.caption2.weight(.semibold)).foregroundStyle(WTheme.pink.opacity(0.95))
            }
            if hasBubble {
                VStack(alignment: .leading, spacing: 6) {
                    if !message.media.isEmpty {
                        WatchMediaCarousel(media: message.media)
                    } else if message.hasMedia {
                        Label(message.media.first?.isVideo == true ? "Video" : "Photo",
                              systemImage: "photo.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if !message.body.isEmpty { Text(message.body).font(.body) }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 4) {
                if !message.reactions.isEmpty { Text(message.reactions).font(.caption2) }
                Text(watchRelativeTime(message.timestamp)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isMe ? .trailing : .leading)
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(Color.clear)
    }
}

/// A swipeable media carousel rendered at the SOURCE aspect ratio (not a forced square), with page
/// dots and a play badge for video. Single media just shows the one image.
private struct WatchMediaCarousel: View {
    let media: [WatchMedia]
    @State private var current: Int? = 0

    private var aspect: Double { media.first?.aspect ?? 1 }

    var body: some View {
        Group {
            if media.count == 1 {
                tile(media[0])
            } else {
                ZStack(alignment: .bottom) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(media.indices, id: \.self) { i in
                                tile(media[i]).containerRelativeFrame(.horizontal).id(i)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $current)
                    HStack(spacing: 4) {
                        ForEach(media.indices, id: \.self) { i in
                            Circle().fill(i == (current ?? 0) ? Color.white : Color.white.opacity(0.4))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 7)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(.bottom, 5)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func tile(_ m: WatchMedia) -> some View {
        ZStack {
            if let ui = UIImage(data: m.thumbnail) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.06)
            }
            if m.isVideo {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 3)
            }
        }
    }
}

// MARK: - Stories (rings + full-screen viewer)

/// One author's stories, grouped for a single ring in the circle's story tray.
struct WatchStoryGroup: Identifiable, Hashable {
    let id: String          // author display name (the ring's identity)
    let author: String
    let items: [WatchMessage]
    var cover: WatchMedia? { items.last?.media.first ?? items.first?.media.first }

    static func group(_ stories: [WatchMessage]) -> [WatchStoryGroup] {
        var order: [String] = []
        var byAuthor: [String: [WatchMessage]] = [:]
        for s in stories {
            if byAuthor[s.author] == nil { order.append(s.author) }
            byAuthor[s.author, default: []].append(s)
        }
        return order.map { WatchStoryGroup(id: $0, author: $0, items: byAuthor[$0] ?? []) }
    }
}

private struct WatchStoryTray: View {
    let groups: [WatchStoryGroup]
    let onOpen: (WatchStoryGroup) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(groups) { g in
                    Button { onOpen(g) } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                Circle().fill(WTheme.brandH).frame(width: 50, height: 50)
                                Circle().fill(Color.black).frame(width: 43, height: 43)
                                if let cover = g.cover, let ui = UIImage(data: cover.thumbnail) {
                                    Image(uiImage: ui).resizable().scaledToFill()
                                        .frame(width: 43, height: 43).clipShape(Circle())
                                } else {
                                    Text(g.author.prefix(1)).font(.headline).foregroundStyle(.white)
                                }
                            }
                            Text(g.author).font(.system(size: 9)).lineLimit(1).frame(width: 54)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4).padding(.top, 2)
        }
        .scrollIndicators(.hidden)
    }
}

/// Full-screen story viewer: tap to advance through one author's stories, then dismiss.
private struct WatchStoryViewer: View {
    let group: WatchStoryGroup
    @Environment(\.dismiss) private var dismiss
    @State private var idx = 0

    var body: some View {
        let item = group.items[min(idx, group.items.count - 1)]
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 6) {
                if let m = item.media.first, let ui = UIImage(data: m.thumbnail) {
                    Image(uiImage: ui).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if !item.body.isEmpty {
                    Text(item.body).font(.footnote).multilineTextAlignment(.center).padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 8)
            VStack {
                HStack(spacing: 3) {
                    ForEach(group.items.indices, id: \.self) { i in
                        Capsule().fill(i <= idx ? Color.white : Color.white.opacity(0.3)).frame(height: 2.5)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 2)
                Spacer()
                Text(group.author).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.bottom, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if idx + 1 < group.items.count { idx += 1 } else { dismiss() } }
    }
}

// MARK: - Reply / comment compose (dictation / Scribble + canned)

struct WatchReplyView: View {
    let threadId: String
    let targetId: String?    // set → comment on that post; nil → DM / thread message
    let to: String
    var onDone: () -> Void
    @EnvironmentObject private var client: WatchConnectivityClient
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Replying to \(to)").font(.caption2).foregroundStyle(.secondary)
                TextField("Message", text: $text).submitLabel(.send).onSubmit(send)
                Button(action: send) { Label("Send", systemImage: "paperplane.fill") }
                    .buttonStyle(WatchBrandButton())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Divider()
                Text("Quick").font(.caption2).foregroundStyle(.secondary)
                ForEach(WatchQuickReplies.all, id: \.self) { canned in
                    Button {
                        client.sendReply(threadId: threadId, body: canned, targetId: targetId)
                        onDone()
                    } label: { Text(canned).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 4)
        }
        .background(WatchBackground())
        .navigationTitle("Reply")
    }

    private func send() {
        client.sendReply(threadId: threadId, body: text, targetId: targetId)
        onDone()
    }
}

// MARK: - Reaction picker (emoji menu)

struct WatchReactionPicker: View {
    var onPick: (String) -> Void
    private let columns = [GridItem(.adaptive(minimum: 44))]

    var body: some View {
        ScrollView {
            Text("React").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WatchQuickReplies.reactions, id: \.self) { emoji in
                    Button { onPick(emoji) } label: { Text(emoji).font(.title2) }
                        .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .background(WatchBackground())
    }
}
