import SwiftUI

/// A post or DM queued to send at a future time. Haven is P2P + serverless, so a scheduled item
/// fires while the app is awake — at launch, on foreground, on a 30s timer, or on a background
/// refresh wake — never from a server. The plaintext is kept on-device until then, then sealed +
/// sent through the normal engine (see docs/SCHEDULED-MESSAGES.md).
struct ScheduledItem: Codable, Identifiable {
    let id: String
    let circleId: String
    let isDM: Bool
    let body: String
    let media: [String]
    let fireAt: Double   // epoch seconds

    var fireDate: Date { Date(timeIntervalSince1970: fireAt) }
}

@MainActor
final class ScheduledStore: ObservableObject {
    static let shared = ScheduledStore()
    @Published private(set) var items: [ScheduledItem] = []

    private let key = "haven.scheduled.v1"
    private var timer: Timer?

    private init() { load() }

    /// Begin firing due items (call once networking is up).
    func start() {
        fireDue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireDue() }
        }
    }

    func schedule(circleId: String, isDM: Bool, body: String, media: [String], at date: Date) {
        items.append(ScheduledItem(id: UUID().uuidString, circleId: circleId, isDM: isDM,
                                   body: body, media: media, fireAt: date.timeIntervalSince1970))
        items.sort { $0.fireAt < $1.fireAt }
        save()
    }

    func cancel(_ id: String) { items.removeAll { $0.id == id }; save() }

    /// Items still waiting for a given circle (for the composer's "N scheduled" badge / list).
    func upcoming(forCircle circleId: String) -> [ScheduledItem] {
        items.filter { $0.circleId == circleId }
    }

    /// Send anything whose time has arrived, then drop it from the queue.
    func fireDue() {
        let now = Date().timeIntervalSince1970
        let due = items.filter { $0.fireAt <= now }
        guard !due.isEmpty else { return }
        items.removeAll { $0.fireAt <= now }
        save()
        for item in due {
            if item.isDM {
                FeedStore.shared.sendMessage(to: item.circleId, item.body, media: item.media, music: nil)
            } else {
                FeedStore.shared.postScheduled(circleId: item.circleId, body: item.body, media: item.media)
            }
        }
    }

    /// Encrypted-at-rest store for the queued plaintext (was an unprotected UserDefaults plist).
    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("haven-scheduled.json")
    }
    private func load() {
        // One-time migration off the old unencrypted UserDefaults store.
        if let d = UserDefaults.standard.data(forKey: key) {
            UserDefaults.standard.removeObject(forKey: key)
            if let arr = try? JSONDecoder().decode([ScheduledItem].self, from: d) {
                items = arr.sorted { $0.fireAt < $1.fireAt }
                save()
                return
            }
        }
        guard let d = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([ScheduledItem].self, from: d) else { return }
        items = arr.sorted { $0.fireAt < $1.fireAt }
    }
    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        // Holds queued post/DM PLAINTEXT until it fires — protect it at rest like the feed state.
        try? d.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A compact sheet to pick a future time + a list of already-scheduled items (cancellable).
struct SchedulePicker: View {
    let circleId: String
    let isDM: Bool
    /// Called with the chosen date when the user confirms scheduling.
    var onSchedule: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ScheduledStore.shared
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                Form {
                    Section {
                        DatePicker("Send at", selection: $date, in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                            .tint(HavenTheme.pink)
                    } footer: {
                        Text("Haven sends this when the time comes and the app is awake (it can't send from a server). Keep Haven open or let it wake in the background near then.")
                    }
                    let pending = store.upcoming(forCircle: circleId)
                    if !pending.isEmpty {
                        Section("Already scheduled") {
                            ForEach(pending) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.body.isEmpty ? "\(item.media.count) attachment\(item.media.count == 1 ? "" : "s")" : item.body)
                                            .lineLimit(1).font(.subheadline)
                                        Text(item.fireDate.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { store.cancel(item.id) } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)   // grouped sections (not macOS right-aligned columns)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Schedule")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .havenCancelLeading) { Button("Cancel") { dismiss() }.havenToolbarPill() }
                ToolbarItem(placement: .havenConfirmTrailing) {
                    Button("Schedule") { onSchedule(date); dismiss() }
                        .havenToolbarPill(tint: HavenTheme.pink)
                        .disabled(date <= Date())
                }
            }
        }
    }
}
