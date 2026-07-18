import SwiftUI

/// "Who reacted with what" — lets the receiver of reactions see exactly who used
/// which emoji on their post.
struct ReactionDetailView: View {
    let reactions: [ReactionFfi]
    /// Remove my own reaction of this emoji (nil = read-only roster).
    var onUnreact: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private func mine(_ r: ReactionFfi) -> Bool { r.mine || r.authors.contains(FeedStore.shared.myNodeHex) }

    var body: some View {
        #if os(macOS)
        HavenMacSheet("Who reacted") { rosterColumn } footer: { EmptyView() }
        .havenPausesPostAudio()
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                List {
                    ForEach(reactions, id: \.emoji) { r in
                        Section {
                            ForEach(r.authors, id: \.self) { hex in
                                HStack(spacing: 10) {
                                    avatar(hex)
                                    Text(name(hex)).font(.subheadline)
                                    Spacer()
                                }
                                .listRowBackground(Color.clear)
                            }
                            if mine(r), let onUnreact {
                                Button(role: .destructive) { onUnreact(r.emoji); dismiss() } label: {
                                    Label("Remove my \(r.emoji)", systemImage: "minus.circle")
                                }
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text("\(r.emoji)   \(r.count)").font(.title3)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Who reacted")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmTrailing) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }
        .havenPausesPostAudio()
        #endif
    }

    #if os(macOS)
    /// A hand-rolled column, not a List — HavenMacSheet's content lives in a ScrollView, which
    /// gives a List no height to lay out against. The sheet's glass close circle is the only Done.
    private var rosterColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(reactions, id: \.emoji) { r in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(r.emoji)   \(r.count)").font(.title3)
                    ForEach(r.authors, id: \.self) { hex in
                        HStack(spacing: 10) {
                            avatar(hex)
                            Text(name(hex)).font(.subheadline)
                            Spacer()
                        }
                    }
                    if mine(r), let onUnreact {
                        Button { onUnreact(r.emoji); dismiss() } label: {
                            Label("Remove my \(r.emoji)", systemImage: "minus.circle")
                        }
                        .buttonStyle(GlassPillButtonStyle(tint: .red))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

    private func name(_ hex: String) -> String {
        if hex == FeedStore.shared.myNodeHex { return "You" }
        return ContactsStore.shared.name(forNodePrefix: hex) ?? "Someone in your circle"
    }

    /// Each reactor's real avatar — my own photo/emoji for me, the cached signed-profile
    /// photo/emoji (else initials) for everyone else — matching how the feed renders contacts.
    @ViewBuilder private func avatar(_ hex: String) -> some View {
        if hex == FeedStore.shared.myNodeHex {
            HavenAvatar(image: ProfileStore.shared.avatar, emoji: ProfileStore.shared.emoji, size: 30)
        } else {
            PeerAvatar(nodeHex: hex, name: name(hex), size: 30)
        }
    }
}
