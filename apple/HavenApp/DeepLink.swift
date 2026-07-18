import SwiftUI

/// In-app deep links so people can share a pointer to a friend's profile or a specific post:
///   • `haven://u/<nodeIdHex>`            → open that person's profile
///   • `haven://p/<circleId>/<postId>`    → open a specific post (legacy; still accepted forever)
///   • `https://wemiller.com/apps/haven/#p/<circleId>.<postId>` → the same post, shareable
///     "online" — the static landing page bounces it into the app on iOS *and* Android, and
///     shows a "get Haven" card to anyone without it.
///
/// Like invite links (`haven://invite#<id>.<verify>` / `https://…/#<id>.<verify>`), the web post
/// link keeps its payload in the URL **fragment**, and the same `.` delimiter.
///
/// ⚠️ THE FRAGMENT IS NOT COSMETIC — DO NOT "TIDY" IT INTO A PATH. ⚠️
/// A browser never sends the `#fragment` to the server, so wemiller.com's access logs (and every
/// CDN/proxy in between) see only `/apps/haven/` — never *which* post. A path form like
/// `/apps/haven/p/<circle>/<post>` would hand the host a readership map: who fetched which post
/// of which circle, from which IP. That map is exactly what Haven exists to not create. Keep it
/// in the fragment.
///
/// The link is a **pointer, not a capability**: it carries no key. Only a device already in the
/// circle can decrypt the post; everyone else lands on "post not found". A post link also still
/// respects the circle's biometric lock — it can never be used to peek into a locked circle.
enum DeepLink {
    /// Fragment-safe token charset: unreserved characters *minus* `.` and `/`, so those two stay
    /// unambiguous as our delimiters (`p/<circle>.<post>`) no matter what an id contains.
    private static let fragmentToken = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~")

    static func profileURL(_ nodeHex: String) -> URL? { URL(string: "haven://u/\(nodeHex)") }

    /// The link shown in the post's share sheet — web-routed so it crosses the iOS/Android
    /// boundary and survives being pasted anywhere.
    static func postURL(circleId: String, postId: String) -> URL? {
        guard let c = circleId.addingPercentEncoding(withAllowedCharacters: fragmentToken),
              let p = postId.addingPercentEncoding(withAllowedCharacters: fragmentToken) else { return nil }
        return URL(string: "https://\(HavenSite.inviteDomain)/#p/\(c).\(p)")
    }
}

enum DeepLinkRoute: Identifiable {
    case profile(nodeHex: String)
    case post(circleId: String, postId: String)
    var id: String {
        switch self {
        case .profile(let h): return "u:\(h)"
        case .post(let c, let p): return "p:\(c):\(p)"
        }
    }
}

@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var route: DeepLinkRoute?
    /// A tab the root view should switch to. Only `openPost(circleId:postId:)` sets it — a URL arriving
    /// from outside already has the root's `tab` binding in hand, but an in-app caller (the story
    /// viewer's "View post" chip) does not, and a locked circle still has to reach its lock screen.
    @Published var requestedTab: String?

    /// Resolve a `haven://u|p/…` URL *or* the web post link (`https://…/apps/haven/#p/<c>.<p>`).
    /// Returns true if it was a deep link we handled (so the caller doesn't also treat it as an
    /// invite). For a post in a biometric-locked circle we switch to that circle (so the lock
    /// screen takes over) instead of revealing the post.
    @discardableResult
    func handle(_ url: URL, tab: inout String) -> Bool {
        // Both link generations normalize to the same internal route before anything else looks
        // at them, so `haven://p/…` links shared years ago keep working untouched.
        if let (circleId, postId) = Self.webPost(url) {
            openPost(circleId: circleId, postId: postId, tab: &tab)
            return true
        }
        guard url.scheme == "haven" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "u":
            guard let id = parts.first, id.count >= 6 else { return true }
            route = .profile(nodeHex: id)
            return true
        case "p":
            guard parts.count >= 2 else { return true }
            openPost(circleId: parts[0], postId: parts[1], tab: &tab)
            return true
        default:
            return false
        }
    }

    /// Pull `p/<circle>.<post>` out of an https link's fragment. Anything else (an invite's
    /// bare `<id>.<verify>`, a plain visit to the site) returns nil and falls through.
    private static func webPost(_ url: URL) -> (String, String)? {
        // percentEncodedFragment (not .fragment) — we want the raw text so we decode exactly once,
        // after splitting on the delimiters.
        guard url.scheme == "https", url.host?.lowercased() == HavenSite.host,
              url.path.hasPrefix(HavenSite.path),
              let frag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
              frag.hasPrefix("p/") else { return nil }
        let body = String(frag.dropFirst(2))
        guard let dot = body.firstIndex(of: "."), dot > body.startIndex else { return nil }
        let c = String(body[body.startIndex..<dot]).removingPercentEncoding
        let p = String(body[body.index(after: dot)...]).removingPercentEncoding
        guard let c, let p, !c.isEmpty, !p.isEmpty else { return nil }
        return (c, p)
    }

    private func openPost(circleId: String, postId: String, tab: inout String) {
        if let t = resolvePost(circleId: circleId, postId: postId) { tab = t }
    }

    /// Route to a post from INSIDE the app — today, the story viewer's "View post" chip. Identical rules
    /// to a link arriving from outside, biometric lock included: an embedded ref is a pointer, never a
    /// way around a circle's lock.
    func openPost(circleId: String, postId: String) {
        if let t = resolvePost(circleId: circleId, postId: postId) { requestedTab = t }
    }

    /// Shared body of both entry points. Returns a tab for the caller to switch to, if any.
    private func resolvePost(circleId: String, postId: String) -> String? {
        if CircleSettingsStore.shared.biometricRequired(circleId),
           !BiometricGate.shared.unlocked.contains(circleId) {
            // Locked: route the user to the circle's lock screen rather than the post.
            FeedStore.shared.setActiveCircle(circleId)
            BiometricGate.shared.unlock(circleId)
            return "circle"
        }
        route = .post(circleId: circleId, postId: postId)
        return nil
    }
}

/// A sheet showing a single post addressed by a deep link.
struct PostLinkView: View {
    let circleId: String
    let postId: String
    @ObservedObject private var store = FeedStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Gives the post a moment to arrive before we call it missing. A post opened from a story embed is
    /// very often one this device hasn't reduced yet (the story and the post can land in either order),
    /// and flashing "unavailable" at something that shows up 300ms later is the worst of both.
    @State private var settled = false

    private var post: FeedItemFfi? {
        store.messages(in: circleId).first { $0.id == postId }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HavenBackground()
                if let post {
                    ScrollView {
                        PostCard(item: post, friendName: "Friend",
                                 onReact: { e in store.reactMessage(in: circleId, post.id, e) },
                                 onUnreact: { e in store.unreactMessage(in: circleId, post.id, e) },
                                 onComment: { b, m in store.commentMessage(in: circleId, post.id, b, m) },
                                 onEdit: { _ in }, onUnsend: { })
                            .padding(16)
                    }
                } else if settled {
                    // Deliberately one message for every failure mode. Saying WHICH — deleted vs. not
                    // your circle — would answer "does this post exist?" for someone who shouldn't be
                    // able to ask. It reads the same whether the post is gone or was never yours.
                    ContentUnavailableView("Post unavailable", systemImage: "doc.questionmark",
                                           description: Text("It may have been unsent, or it isn't shared with you."))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                settled = true
            }
            .navigationTitle("Post")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmLeading) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }
    }
}
