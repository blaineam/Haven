import SwiftUI

// Terms of use (App Review 1.2): every user must agree — with zero tolerance for objectionable
// content or abusive behavior spelled out — before they can use Haven. New users agree as the
// final onboarding step; existing users (upgraders, restored identities, linked devices) hit the
// standalone gate in HavenApp until they agree. Acceptance is versioned so revised terms can
// re-prompt. The canonical text lives in docs/TERMS.md (linked below).

/// Persisted, versioned terms acceptance.
@MainActor
final class TermsStore: ObservableObject {
    static let shared = TermsStore()
    /// Bump when the terms change materially — everyone re-agrees on next launch.
    static let currentVersion = 1
    static let fullTermsURL = URL(string: "https://github.com/blaineam/haven/blob/main/docs/TERMS.md")!

    private let d = UserDefaults.standard
    private let key = "haven.terms.acceptedVersion"

    @Published private(set) var accepted: Bool

    private init() { accepted = d.integer(forKey: key) >= Self.currentVersion }

    func accept() {
        d.set(Self.currentVersion, forKey: key)
        withAnimation(HavenTheme.smooth) { accepted = true }
    }
}

/// The terms themselves — shared by the onboarding step and the standalone gate.
struct TermsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The ground rules")
                .font(.title.bold())
                .frame(maxWidth: .infinity, alignment: .center)
            Text("Haven is yours and your people's — nobody else can see inside, so keeping it good is on all of us. **There is zero tolerance for objectionable content or abusive behavior.**")
                .font(.subheadline).foregroundStyle(.secondary)

            rule("🚫", "Never allowed", "Harassment or bullying, hate, threats or violence, sexual content involving minors, non-consensual intimate content, scams, impersonation, or anything illegal.")
            rule("🛡️", "Your circle enforces it", "Anyone can report a post — the whole circle sees the report and can hide it, remove the person, or block them instantly.")
            rule("📒", "Actions are on the record", "Reports and blocks are logged permanently — who acted against whom and the category, never the content itself. Repeated abuse costs an identity its service.")
            rule("💜", "You own what you share", "Everything is end-to-end encrypted, so only your circle sees it — and you're responsible for it.")

            Link(destination: TermsStore.fullTermsURL) {
                Text("Read the full terms of use")
                    .font(.footnote.weight(.medium)).underline()
            }
            .tint(HavenTheme.pink)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func rule(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(icon).font(.system(size: 30))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Standalone agreement gate for users who are already past onboarding (upgraders, restored
/// identities, linked devices). Shown full-screen until they agree; there is no other way in.
struct TermsGateView: View {
    @ObservedObject private var terms = TermsStore.shared

    var body: some View {
        ZStack {
            HavenBackground()
            VStack(spacing: 24) {
                Spacer()
                ScrollView { TermsContent() }
                Spacer(minLength: 0)
                Button { terms.accept() } label: { Text("I agree") }
                    .buttonStyle(BrandButtonStyle())
            }
            .padding(24)
            // One readable column on any window size (macOS windows are arbitrarily wide).
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
