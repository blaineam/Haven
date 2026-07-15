import SwiftUI

// Decentralized moderation (App Review 1.2). Haven circles have no owner and the developer holds
// no keys, so moderation is the members': a report is sealed to the WHOLE circle (like a
// SensitiveFlag) and every member acts with the power they already hold — hide for themselves,
// remove the author from their circle, or block. The only thing that ever leaves the circle is a
// content-free ledger entry: identity vs identity, action, offense category. No PII, no content.

/// Fire-and-forget, content-free entries to the developer ledger on the push Worker. Node ids are
/// opaque public keys — the ledger records only that an identity WAS REPORTED and for which
/// category, never what was said or shown. This is the 1.2 "notify the developer" hook.
///
/// Only an explicit report comes here (audit F1). **Blocking never touches the network**: it is a
/// private, local decision to stop seeing someone, and it stays on the device.
enum ModerationLedger {
    @MainActor
    static func report(subject: String, reason: String) {
        guard !subject.isEmpty, let url = URL(string: PushManager.relay + "/flag") else { return }
        // Signed with the identity key (audit F1): the Terms attach real consequences to a ledger row,
        // so an unsigned POST must not be able to plant one. The signature binds subject + action +
        // category, so a captured flag can't be re-aimed at someone else. Unsigned = we don't send.
        guard let seed = AccountStore.storedSeed(), let acct = try? Account.fromSeed(seed: seed) else { return }
        let category = String(reason.prefix(64))
        let ts = UInt64(Date().timeIntervalSince1970)
        let sig = acct.signPushRegistration(token: "flag-v1:\(subject):report:\(category)", tsSecs: ts)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "actor": acct.nodeIdHex(),
            "subject": subject,
            "action": "report",
            "reason": category,
            "ts": ts,
            "sig": sig.base64EncodedString(),
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
///
/// Layout is a hand-rolled column, NOT a Form: macOS Form renders labeled rows as a two-column
/// grid, so the note field's label pushed the whole sheet's content rightward, and every control
/// hugged the section insets. Each choice is a full-width glass pill; the field and toggle carry
/// exactly one glass surface each (no doubled backgrounds or borders — house rule).
struct ReportSheet: View {
    let item: FeedItemFfi
    let authorName: String
    @ObservedObject private var feed = FeedStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var comment = ""
    @State private var alsoBlock = false

    var body: some View {
        #if os(macOS)
        HavenMacSheet("Report post") {
            formColumn
        } footer: {
            Button("Report") { submit() }
                .buttonStyle(BrandButtonStyle())
                .disabled(reason == nil)
                .opacity(reason == nil ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
        }
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollView { formColumn.padding(20) }
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
        #endif
    }

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's wrong with it?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(ReportReason.allCases) { r in
                Button {
                    withAnimation(HavenTheme.snappy) { reason = r }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: r.icon)
                            .frame(width: 22)
                            .foregroundStyle(reason == r ? HavenTheme.pink : .secondary)
                        Text(r.rawValue).foregroundStyle(.primary)
                        Spacer()
                        if reason == r {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(HavenTheme.pink)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .havenGlass(in: Capsule(), tint: reason == r ? HavenTheme.pink.opacity(0.35) : nil)
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            TextField("Add a note for your circle (optional)", text: $comment, axis: .vertical)
                .lineLimit(2 ... 4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .havenGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.top, 8)

            // Label leading, switch trailing — a bare Toggle keeps them glued together and
            // centered, which looked lost inside the full-width pill.
            HStack {
                Label("Also block \(authorName)", systemImage: "hand.raised")
                Spacer()
                Toggle("", isOn: $alsoBlock)
                    .labelsHidden()
                    #if os(macOS)
                    .toggleStyle(.switch)   // a switch reads modern in the pill; the checkbox looked dated
                    #endif
                    .tint(HavenTheme.pink)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .havenGlass(in: Capsule())

            Text("The post disappears from your feed right away, and everyone in the circle sees your report so they can act too. Only who reported whom and the category are logged — never the content.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.top, 6)
        }
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
            // Borderless or macOS wraps the bare label in a popup-button bezel.
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .fixedSize()
            #endif
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
