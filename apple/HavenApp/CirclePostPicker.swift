import SwiftUI

/// Long-press Post: toggle which circles this one post goes to. The current circle starts checked.
struct CirclePostPicker: View {
    let activeId: String
    /// An attachment is on the post: only the current circle can take it (see `MultiCirclePost.lockedToActive`).
    var lockedToActive = false
    let onPost: ([String]) -> Void

    @ObservedObject private var store = FeedStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(activeId: String, lockedToActive: Bool = false, onPost: @escaping ([String]) -> Void) {
        self.activeId = activeId; self.lockedToActive = lockedToActive; self.onPost = onPost
        _selected = State(initialValue: [activeId])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.feedCircles, id: \.id) { c in
                        Button { toggle(c.id) } label: {
                            HStack {
                                Text(store.displayName(forCircle: c.id)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(c.id) ? HavenTheme.pink : .secondary)
                                    .imageScale(.large)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(lockedToActive && c.id != activeId)
                        .opacity(lockedToActive && c.id != activeId ? 0.4 : 1)
                        .accessibilityIdentifier("circlePick.\(c.id)")
                        .accessibilityAddTraits(selected.contains(c.id) ? .isSelected : [])
                    }
                } header: { Text("Share this post to") }
                footer: {
                    if lockedToActive {
                        Text("Photos, videos and voice notes can only go to the current circle for now. Text, songs and locations can go to any.")
                    } else {
                        Text("The same post goes to everyone in each circle you tick.")
                    }
                }
            }
            .navigationTitle("Post to circles")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(MultiCirclePost.buttonTitle(count: selected.count)) {
                        let picked = store.feedCircles.map(\.id).filter(selected.contains)
                        dismiss()
                        onPost(picked)
                    }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("circlePick.post")
                }
            }
        }
        .tint(HavenTheme.pink)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
