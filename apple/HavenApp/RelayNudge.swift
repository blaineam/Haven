import SwiftUI

/// The "your circle is big enough to want a relay" nudge.
///
/// A circle with a handful of people stops being a two-phones-both-online proposition: the more
/// members, the less often everyone overlaps, and the more a post has to wait for its author to
/// come back. A relay is the fix — see `RelayHost` / `relay/README.md`. This file is the whole
/// nudge: a per-circle dismissable banner, a short walkthrough sheet, and the one-call gate the
/// feed uses to decide whether to show it.
///
/// The bar is deliberately conservative: >2 OTHER members AND the circle has no relay of its OWN.
/// The all-circles default relay does NOT satisfy it — the point is to get this circle a mailbox
/// somebody in it actually runs, and the default is a global setting the user may never revisit.

// MARK: - Dismissal state

/// Per-circle "I dismissed the relay nudge" flags. Same shape as `CircleSettingsStore`: a
/// `[circleId: Bool]` dictionary in UserDefaults, published so the banner disappears at once.
/// Dismissal is final for that circle — nothing here ever un-dismisses.
@MainActor
final class RelayNudgeStore: ObservableObject {
    static let shared = RelayNudgeStore()

    @Published private var dismissed: [String: Bool]
    private let d = UserDefaults.standard
    private let key = "haven.circle.relayNudgeDismissed"

    private init() { dismissed = (d.dictionary(forKey: key) as? [String: Bool]) ?? [:] }

    /// Members beyond which a circle is "several people" rather than a pair — >2 OTHERS, i.e. at
    /// least four people counting you.
    static let connectionThreshold = 2

    func dismiss(_ circleId: String) {
        dismissed[circleId] = true
        d.set(dismissed, forKey: key)
    }

    func isDismissed(_ circleId: String) -> Bool { dismissed[circleId] ?? false }

    /// Factory-reset (mirrors `CircleSettingsStore.wipe`).
    func wipe() { dismissed = [:]; d.removeObject(forKey: key) }

    /// The single gate the call site needs. True when this circle has grown past a pair, has no
    /// relay of its own, isn't already served by this device, and the user hasn't waved it away.
    func shouldShow(for circleId: String) -> Bool {
        guard !circleId.isEmpty, !isDismissed(circleId) else { return false }
        // This device relaying for the circle already counts as having one.
        let host = RelayHost.shared
        if host.enabled || host.serving { return false }
        // ACTIVE + explicitly associated only: an inherited default isn't this circle's own relay.
        guard RelayMailboxStore.shared.activeExplicitRelays(forCircle: circleId).isEmpty else { return false }
        return FeedStore.shared.memberHexes(circleId: circleId).count > Self.connectionThreshold
    }
}

// MARK: - Banner

/// The nudge itself: a brand-gradient card in the feed, matching the pending-requests banner.
/// Tapping it opens the walkthrough; the glass ✕ dismisses it for this circle for good.
/// Renders nothing at all when the gate says no, so the call site is one line.
struct RelayNudgeBanner: View {
    let circleId: String
    // All four feed the gate — observed so adopting a relay, hosting one, or a member joining
    // re-evaluates it without the feed having to know any of that.
    @ObservedObject private var nudge = RelayNudgeStore.shared
    @ObservedObject private var relays = RelayMailboxStore.shared
    @ObservedObject private var host = RelayHost.shared
    @ObservedObject private var store = FeedStore.shared
    @State private var showWalkthrough = false

    var body: some View {
        if nudge.shouldShow(for: circleId) {
            HStack(spacing: 12) {
                Button { showWalkthrough = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2).foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Give this circle a relay")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text("A few of you are here now — a relay holds your sealed posts so nobody has to be online at the same time.")
                                .font(.caption).foregroundStyle(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(HavenTheme.smooth) { nudge.dismiss(circleId) }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(GlassIconButtonStyle(size: 26, tint: .white))
                .accessibilityLabel("Dismiss")
            }
            .padding(14)
            .background(HavenTheme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .sheet(isPresented: $showWalkthrough) { RelayWalkthroughSheet(circleId: circleId) }
        }
    }
}

// MARK: - Walkthrough

/// Why a relay helps, how to get one, and the plain-language version of Haven's encryption. Every
/// claim here is bounded by what the code does: the relay stores/forwards ciphertext, and can't
/// read it (`relay/README.md`, `docs/SECURITY.md`).
struct RelayWalkthroughSheet: View {
    let circleId: String
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    var body: some View {
        #if os(macOS)
        HavenMacSheet("Set up a relay") {
            column
        } footer: {
            Button("Use this Mac as the relay") { enableHere() }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .sheet(isPresented: $showAdd) { AddRelaySheet() }
        .havenPausesPostAudio()
        #else
        NavigationStack {
            ZStack {
                HavenBackground()
                ScrollView { column.padding(20) }
            }
            .navigationTitle("Set up a relay")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
            }
        }
        .sheet(isPresented: $showAdd) { AddRelaySheet() }
        .havenPausesPostAudio()
        #endif
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 14) {
            why
            how
            promises
            actions
        }
    }

    private var why: some View {
        VStack(alignment: .leading, spacing: 14) {
            point("tray.and.arrow.down.fill", "Nobody has to be online at once",
                  "Posts upload sealed; friends pick them up next time they open Haven.")
            point("photo.on.rectangle.angled", "Photos and videos actually arrive",
                  "Media comes from the relay, not the sender — it lands even on tricky networks.")
            point("point.3.connected.trianglepath.dotted", "It routes around home routers",
                  "The relay forwards sealed messages when a member can't be dialed directly.")
            point("lock.shield.fill", "The relay can't read a thing",
                  "It only holds sealed blobs and routing info — never a key, so it can never read anything.")
        }
    }

    private var how: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to set one up")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4).padding(.leading, 4)

            point("desktopcomputer", "The easy way — a device you leave on",
                  hostBlurb)
            point("terminal", "Or a spare machine",
                  "On a Mac, Linux box, or Raspberry Pi, one line installs it:\ncurl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh\n\nOn Windows, in PowerShell:\nirm https://wemiller.com/apps/haven/relay/install.ps1 | iex\n\nIt sets itself to start on every reboot. “Add a relay I'm running” below hands you this circle's link to start it with, then takes back the node id it prints.")
        }
    }

    private var promises: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What everyone in the circle can count on")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 4).padding(.leading, 4)

            // "Remove", NOT "add or remove": rotate_epoch fires on removal (purge_member_from_circle),
            // on device-roster changes, and on the periodic rotate_circle — never on adding a member.
            // Claiming add rotates would imply a new member is fenced off from earlier posts. They aren't.
            point("key.fill", "Only the people you added can read it",
                  "Everything you post is sealed on your device to your circle's members. Remove someone and the circle's key rotates, so they can't read anything posted afterwards.")
            point("atom", "Encrypted for the long haul",
                  "Haven pairs today's proven encryption with post-quantum encryption — X25519 with ML-KEM-768, signed with Ed25519 and ML-DSA-65. An attacker has to break both halves, so ciphertext saved today isn't a bet on a future quantum computer. No promises beyond that: keys live on your devices, and Haven never holds them.")
        }
    }

    /// Both real setup paths, so the sheet isn't a dead end on either platform. iOS gets the host
    /// button here (there's no macOS-style footer to hang it on).
    private var actions: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if !os(macOS)
            Button { enableHere() } label: { Text("Use this device as the relay") }
                .buttonStyle(BrandButtonStyle())
                .padding(.top, 6)
            #endif
            Button { showAdd = true } label: {
                Label("Add a relay I'm running", systemImage: "plus.circle")
            }
            .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
            .frame(maxWidth: .infinity)
        }
    }

    /// Honest about lifetime: a Mac serves as long as Haven is open; iOS suspends background apps,
    /// so the phone relays while Haven is foregrounded (RelayHost's own platform note).
    private var hostBlurb: String {
        #if os(macOS)
        return "One tap below and this Mac holds the circle's sealed mailbox for as long as Haven is open. A Mac that stays awake is ideal. You can turn it off any time under Settings ▸ Relays."
        #else
        return "One tap below and this device serves the circle's sealed mailbox while Haven is open and awake — fine on a charger, but a Mac or a spare machine left running is the real fix. Turn it off any time under Settings ▸ Relays."
        #endif
    }

    private func enableHere() {
        RelayHost.shared.setEnabled(true)   // hosting announces itself to the circles — see RelayHost.start
        dismiss()
    }

    private func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HavenTheme.pink)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .havenGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
