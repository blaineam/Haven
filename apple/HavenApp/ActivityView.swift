import SwiftUI

/// The bell's sheet: everything that happened across your circles, newest first, grouped by day.
/// Rows in a biometric-locked circle render REDACTED (same rule as the banner path — the list
/// must not spill a locked circle's who/what); their tap still routes through the one deep-link
/// table, so the lock screen takes over exactly as it would for a tapped notification.
struct ActivityView: View {
    @ObservedObject private var store = ActivityStore.shared
    @ObservedObject private var feed = FeedStore.shared
    @Environment(\.dismiss) private var dismiss

    /// How many entries are currently materialised. `LazyVStack` already defers ROW rendering, but
    /// `grouped` ran over the WHOLE store on every body evaluation — dictionary-grouping and sorting
    /// thousands of entries just to draw the dozen on screen. That work is what made opening the
    /// bell feel heavy. We now group only the window and grow it as the user reaches the bottom.
    @State private var visibleCount = Self.pageSize
    private static let pageSize = 40

    /// Newest-first slice we actually render. `store.entries` is already kept sorted descending
    /// (ActivityStore sorts on every insert), so this is a cheap prefix — no re-sort per render.
    private var windowed: ArraySlice<ActivityStore.Entry> {
        store.entries.prefix(visibleCount)
    }

    private var hasMore: Bool { store.entries.count > visibleCount }

    private var grouped: [(day: Date, rows: [ActivityStore.Entry])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: windowed) {
            cal.startOfDay(for: Date(timeIntervalSince1970: Double($0.at) / 1000))
        }
        return groups.map { (day: $0.key, rows: $0.value.sorted { $0.at > $1.at }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                if store.entries.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "bell",
                                           description: Text("Reactions, comments, and new posts across your circles land here."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(grouped, id: \.day) { group in
                                Text(dayLabel(group.day))
                                    .font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 6)
                                ForEach(group.rows) { row($0) }
                            }
                            // Reaching this marker means the user actually scrolled to the end of
                            // what's materialised — only then do we pay for the next page. It sits
                            // inside the LazyVStack so it is not created until it comes into view.
                            if hasMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .onAppear { visibleCount += Self.pageSize }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Activity")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmLeading) { Button("Done") { dismiss() }.havenToolbarPill() } }
            .onAppear {
                feed.pullActivity()   // freshen from the engine on open
                store.markAllSeen()   // opening the list clears the bell — fleet-wide via SelfSync
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder private func row(_ e: ActivityStore.Entry) -> some View {
        let locked = !e.circleId.isEmpty && CircleSettingsStore.shared.biometricRequired(e.circleId)
        Button { open(e) } label: {
            HStack(spacing: 10) {
                Image(systemName: locked ? "lock.fill" : icon(e.kind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HavenTheme.pink)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.ultraThinMaterial))
                VStack(alignment: .leading, spacing: 2) {
                    if locked {
                        // Same redaction as the notification path: never quote a locked circle.
                        Text("New activity in a locked circle").font(.subheadline)
                    } else {
                        Text(actorName(e)).font(.subheadline).fontWeight(.semibold)
                        Text(line(e)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let ctx = context(e) {
                            Text(ctx).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Text(relativeTimeShort(e.at)).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Route the tap through the ONE deep-link table (same rules as a tapped notification — a
    /// locked circle lands on its lock screen, never the content). Dismiss first: the route
    /// presents its own sheet, and two sheets can't stack from one presenter.
    private func open(_ e: ActivityStore.Entry) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let router = DeepLinkRouter.shared
            switch e.kind {
            case "connect":
                router.requestedTab = "circle"   // pending requests surface on the Circle tab banner
            case "device":
                router.requestedTab = "you"
            case "story":
                if let url = URL(string: DeepLink.storyLink(circleId: e.circleId, postId: e.id)) {
                    var t = ""
                    _ = router.handle(url, tab: &t)
                }
            default:
                // circle rows carry no post; reactions/comments/votes open their PARENT post.
                guard !e.circleId.isEmpty else { return }
                let postId = e.kind == "circle" ? nil : (e.targetId ?? e.id)
                if let url = URL(string: DeepLink.interactionLink(circleId: e.circleId, postId: postId)) {
                    var t = ""
                    _ = router.handle(url, tab: &t)
                }
            }
        }
    }

    // MARK: - Copy

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "react":   return "heart.fill"
        case "comment": return "text.bubble.fill"
        case "vote":    return "chart.bar.fill"
        case "story":   return "circle.dashed"
        case "dm":      return "bubble.left.fill"
        case "post":    return "square.and.pencil"
        case "connect": return "person.badge.plus"
        case "circle":  return "person.2.fill"
        case "device":  return "laptopcomputer.and.iphone"
        default:        return "bell.fill"
        }
    }

    private func actorName(_ e: ActivityStore.Entry) -> String {
        switch e.kind {
        case "connect": return "New connection"
        case "circle":  return "Added to a circle"
        case "device":  return "Device linked"
        default: break
        }
        if !e.actorShort.isEmpty, let n = ContactsStore.shared.name(forNodePrefix: e.actorShort) {
            return n
        }
        return "Someone"
    }

    private func line(_ e: ActivityStore.Entry) -> String {
        switch e.kind {
        case "react":   return "Reacted \(e.emoji ?? "👍")"
        case "comment": return e.snippet.isEmpty ? "Left a comment" : "Commented: \(e.snippet)"
        case "vote":    return "Voted on your poll"
        case "story":   return "Shared a story"
        case "dm":      return e.snippet.isEmpty ? "Sent you a message" : e.snippet
        case "post":    return e.snippet.isEmpty ? "Shared something" : e.snippet
        default:        return e.snippet
        }
    }

    /// "in <circle name>" for circle rows — a DM's partner name is already the title.
    private func context(_ e: ActivityStore.Entry) -> String? {
        guard !e.circleId.isEmpty, !e.circleId.hasPrefix("dm:"),
              let name = feed.circles.first(where: { $0.id == e.circleId })?.name else { return nil }
        return "in \(name)"
    }
}
