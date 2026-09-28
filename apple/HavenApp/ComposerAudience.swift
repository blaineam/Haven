import SwiftUI

/// Who a circle post (or a reply on one) actually reaches — surfaced right at the composer.
///
/// Why this exists: people posted private things to the WHOLE circle believing they were writing to
/// one person. The feed composer's audience used to be implicit (whatever circle the switcher showed),
/// so every piece here says it out loud: the "Everyone in <Circle>" chip, the placeholder, the labeled
/// Post button, and a one-time per-circle confirmation that offers "Send privately instead…".
enum ComposerAudience {
    /// Long circle names would push the placeholder / button label off the line — keep the start.
    static func shortName(_ name: String, max: Int = 22) -> String {
        name.count > max ? String(name.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    /// Everyone OTHER than me a post in this circle reaches. My Circle is my contacts (the same
    /// list CircleView shows for it); a custom circle is its members minus me, minus anyone I
    /// removed from it or blocked. Read-model only — never touches the engine on the main thread.
    @MainActor static func othersCount(circleId: String) -> Int {
        if circleId == "default" { return ContactsStore.shared.contacts.count }
        let store = FeedStore.shared
        let me = store.myNodeHex
        return Set(store.cachedMembers(circleId)).filter {
            $0 != me
            && !ConnectionsStore.shared.isRemovedFromCircle($0, circleId: circleId)
            && !ConnectionsStore.shared.isBlocked($0)
        }.count
    }

    static func peopleText(_ n: Int) -> String {
        n == 1 ? String(localized: "1 person") : String(localized: "\(n) people")
    }

    /// "Everyone in Family · 6 people" (count dropped while it's unknown / nobody's joined yet).
    static func summary(circle: String, count: Int) -> String {
        count > 0
            ? String(localized: "Everyone in \(circle) · \(peopleText(count))")
            : String(localized: "Everyone in \(circle)")
    }

    // MARK: One-time acknowledgement, per circle

    private static let ackKey = "haven.audienceAck.v1"

    static func isAcknowledged(_ circleId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: ackKey) ?? []).contains(circleId)
    }

    static func acknowledge(_ circleId: String) {
        var ids = UserDefaults.standard.stringArray(forKey: ackKey) ?? []
        guard !ids.contains(circleId) else { return }
        ids.append(circleId)
        UserDefaults.standard.set(ids, forKey: ackKey)
    }

    /// Ask once per circle, and only when the post really fans out (more than one other person) —
    /// a two-person circle already IS the one person, and nagging every post would train people to
    /// tap through it.
    @MainActor static func needsConfirmation(circleId: String) -> Bool {
        !circleId.hasPrefix("dm:") && !isAcknowledged(circleId) && othersCount(circleId: circleId) > 1
    }
}

/// The compact "👥 Everyone in Family · 6 people ⌄" chip above the feed composer. Its menu is the
/// always-there door to a private message, so writing to one person never means hunting for it.
struct ComposerAudienceChip: View {
    let circleName: String
    let count: Int
    let onSendPrivately: () -> Void

    var body: some View {
        Menu {
            Section(ComposerAudience.summary(circle: circleName, count: count)) {
                Button(action: onSendPrivately) {
                    Label("Send privately to someone…", systemImage: "bubble.left.and.bubble.right")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.3.fill").font(.caption2)
                Text(ComposerAudience.summary(circle: ComposerAudience.shortName(circleName), count: count))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .havenGlass(in: Capsule())
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        #if os(macOS)
        .menuStyle(.borderlessButton)   // just the glass capsule — no popup-button bezel around it
        .fixedSize()
        #endif
        .accessibilityIdentifier("composeAudience")
        .accessibilityLabel(Text("Posting to \(ComposerAudience.summary(circle: circleName, count: count))"))
        .accessibilityHint(Text("Opens options, including sending privately to one person"))
    }
}
