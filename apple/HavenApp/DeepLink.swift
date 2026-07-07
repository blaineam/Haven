import SwiftUI

/// In-app deep links so people can share a pointer to a friend's profile or a specific post:
///   • `haven://u/<nodeIdHex>`            → open that person's profile
///   • `haven://p/<circleId>/<postId>`    → open a specific post shared with that circle
///
/// These are distinct from invite links (`haven://invite#<id>.<verify>` / `https://…/#…`),
/// which carry a fragment. A post link respects the circle's biometric lock — it can never be
/// used to peek into a locked circle.
enum DeepLink {
    static func profileURL(_ nodeHex: String) -> URL? { URL(string: "haven://u/\(nodeHex)") }
    static func postURL(circleId: String, postId: String) -> URL? {
        guard let c = circleId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let p = postId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "haven://p/\(c)/\(p)")
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

    /// Resolve a `haven://u|p/…` URL. Returns true if it was a deep link we handled (so the
    /// caller doesn't also treat it as an invite). For a post in a biometric-locked circle we
    /// switch to that circle (so the lock screen takes over) instead of revealing the post.
    @discardableResult
    func handle(_ url: URL, tab: inout String) -> Bool {
        guard url.scheme == "haven" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "u":
            guard let id = parts.first, id.count >= 6 else { return true }
            route = .profile(nodeHex: id)
            return true
        case "p":
            guard parts.count >= 2 else { return true }
            let circleId = parts[0], postId = parts[1]
            if CircleSettingsStore.shared.biometricRequired(circleId),
               !BiometricGate.shared.unlocked.contains(circleId) {
                // Locked: route the user to the circle's lock screen rather than the post.
                tab = "circle"
                FeedStore.shared.setActiveCircle(circleId)
                BiometricGate.shared.unlock(circleId)
            } else {
                route = .post(circleId: circleId, postId: postId)
            }
            return true
        default:
            return false
        }
    }
}

/// A sheet showing a single post addressed by a deep link.
struct PostLinkView: View {
    let circleId: String
    let postId: String
    @ObservedObject private var store = FeedStore.shared
    @Environment(\.dismiss) private var dismiss

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
                } else {
                    ContentUnavailableView("Post not found", systemImage: "doc.questionmark",
                                           description: Text("It may have been unsent, or you're not in this circle."))
                }
            }
            .navigationTitle("Post")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmLeading) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }
    }
}
