import SwiftUI

// Decentralized moderation (App Review 1.2). Haven circles have no owner and the developer holds
// no keys, so moderation is the members': a report is sealed to the WHOLE circle (like a
// SensitiveFlag) and every member acts with the power they already hold — hide for themselves,
// remove the author from their circle, or block. The only thing that ever leaves the circle is a
// content-free ledger entry: identity vs identity, action, offense category. No PII, no content.

/// Fire-and-forget, content-free entries to the developer ledger on the push Worker. Node ids are
/// opaque public keys — the ledger records WHO acted against WHOM and WHY (category), never what
/// was said or shown. This is the 1.2 "notify the developer" hook, weighted honestly: it makes
/// abuse patterns (many reporters × one identity) visible without a single byte of content.
enum ModerationLedger {
    @MainActor
    static func record(action: String, subject: String, reason: String) {
        guard let url = URL(string: PushManager.relay + "/flag") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "actor": FeedStore.shared.myAccountHex,
            "subject": subject,
            "action": action,
            "reason": reason,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()   // fire and forget — never blocks moderation
    }
}

/// The offense categories a reporter picks from. The category travels BOTH ways: sealed to the
/// circle (so members can judge) and to the ledger (so patterns are visible) — the free-text
/// comment goes ONLY to the circle.
enum ReportReason: String, CaseIterable, Identifiable {
    case harassment = "Harassment or bullying"
    case sexual = "Nudity or sexual content"
    case violence = "Violence or dangerous acts"
    case spam = "Spam or scam"
    case other = "Something else"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .harassment: return "exclamationmark.bubble"
        case .sexual: return "eye.slash"
        case .violence: return "exclamationmark.triangle"
        case .spam: return "envelope.badge.shield.half.filled"
        case .other: return "flag"
        }
    }
}

/// Report a post/message: pick a category, optionally add a note for the circle, optionally block
/// the author in the same motion. Submitting hides the post for the reporter instantly.
struct ReportSheet: View {
    let item: FeedItemFfi
    let authorName: String
    @ObservedObject private var feed = FeedStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var comment = ""
    @State private var alsoBlock = false

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                Form {
                    Section("What's wrong with it?") {
                        ForEach(ReportReason.allCases) { r in
                            Button {
                                reason = r
                            } label: {
                                HStack {
                                    Label(r.rawValue, systemImage: r.icon).foregroundStyle(.primary)
                                    Spacer()
                                    if reason == r {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(HavenTheme.pink)
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        TextField("Add a note for your circle (optional)", text: $comment, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .listRowBackground(Color.clear)
                        Toggle(isOn: $alsoBlock) {
                            Label("Also block \(authorName)", systemImage: "hand.raised")
                        }
                        .tint(HavenTheme.pink)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("The post disappears from your feed right away, and everyone in the circle sees your report so they can act too. Only who reported whom and the category are logged — never the content.")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Report post")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Report") { submit() }
                        .disabled(reason == nil)
                        .tint(HavenTheme.pink)
                }
            }
        }
        .macSheetFrame()
    }

    private func submit() {
        guard let reason else { return }
        let author = feed.report(circleId: feed.activeCircleId, target: item.id,
                                 reason: reason.rawValue, comment: comment)
        if alsoBlock, let author { feed.blockConnection(author) }
        dismiss()
    }
}

/// Shown on a post that OTHER members reported — the circle's shared moderation signal. Each
/// viewer decides for themselves: hide it, remove the author from their circle, or block. The
/// reporter never sees this (the post is already hidden for them).
struct ReportedBanner: View {
    let item: FeedItemFfi
    let authorName: String
    let reports: [ReportFfi]
    @ObservedObject private var feed = FeedStore.shared
    @State private var confirmRemove = false

    private var reporterNames: String {
        let names = Set(reports.map {
            ContactsStore.shared.name(forNodePrefix: $0.reporterShort) ?? "A member"
        })
        return names.sorted().joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reported by \(reporterNames)").font(.caption.weight(.semibold))
                Text(reports.map(\.reason).uniqued().joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    HiddenStore.shared.hide(item.id)
                    feed.refresh()
                } label: { Label("Hide for me", systemImage: "eye.slash") }
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Remove \(authorName) from circle", systemImage: "person.badge.minus")
                }
                Button(role: .destructive) {
                    if let author = reports.first?.author { feed.blockConnection(author) }
                } label: { Label("Block \(authorName)", systemImage: "hand.raised.fill") }
            } label: {
                Text("Act").font(.caption.weight(.semibold)).foregroundStyle(HavenTheme.pink)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .confirmationDialog("Remove \(authorName) from this circle?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let author = reports.first?.author {
                    feed.removeFromCircle(author, circleId: feed.activeCircleId)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their posts leave your view of the circle and they can't rejoin through you. Your own devices stay in sync.")
        }
    }
}

private extension Array where Element == String {
    /// Order-preserving dedup for the banner's reason line.
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
