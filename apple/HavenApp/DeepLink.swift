import SwiftUI

/// In-app deep links so people can share a pointer to a friend's profile or a specific post:
///   • `haven://u/<nodeIdHex>`            → open that person's profile
///   • `haven://p/<circleId>/<postId>`    → open a specific post (legacy; still accepted forever)
///   • `https://wemiller.com/apps/haven/open/#p/<circleId>.<postId>` → the same post, shareable
///     "online" — the static landing page bounces it into the app on iOS *and* Android, and
///     shows a "get Haven" card to anyone without it. `/open` is the DEDICATED landing path and
///     the only one the apps claim; the rest of the site is marketing and stays in the browser
///     (see `HavenSite` for why). Links in the older `/apps/haven/#…` shape are still parsed —
///     matching is on the wider `sitePath` — they just no longer auto-launch the app.
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

    /// Tap-target for a notification: DMs open the Messages thread; circle posts open the post.
    /// Percent-encode path components so `dm:hex-hex` survives URL parsing.
    static func interactionLink(circleId: String, postId: String? = nil) -> String {
        let encCid = circleId.addingPercentEncoding(withAllowedCharacters: fragmentToken) ?? circleId
        if circleId.hasPrefix("dm:") {
            if let postId, !postId.isEmpty,
               let encPid = postId.addingPercentEncoding(withAllowedCharacters: fragmentToken) {
                return "haven://m/\(encCid)/\(encPid)"
            }
            return "haven://m/\(encCid)"
        }
        if let postId, !postId.isEmpty,
           let encPid = postId.addingPercentEncoding(withAllowedCharacters: fragmentToken) {
            return "haven://p/\(encCid)/\(encPid)"
        }
        return "haven://c/\(encCid)"
    }

    /// Tap-target for a STORY notification / activity row: opens the story viewer, not the feed.
    /// Same encoding rules as `interactionLink`; the NSE mirrors this shape (keep in sync).
    static func storyLink(circleId: String, postId: String) -> String {
        let encCid = circleId.addingPercentEncoding(withAllowedCharacters: fragmentToken) ?? circleId
        let encPid = postId.addingPercentEncoding(withAllowedCharacters: fragmentToken) ?? postId
        return "haven://s/\(encCid)/\(encPid)"
    }

    /// Shareable story pointer — same web-routed form as `postURL`, payload in the `#` fragment
    /// (`#s/<circle>.<post>`). Used when a story reply attaches a reference in a DM so the bubble
    /// can open the real story (music, caption framing, progress) instead of resealing a permanent
    /// media copy into the thread. Inverse of `parseStory`.
    static func storyURL(circleId: String, postId: String) -> URL? {
        guard let c = circleId.addingPercentEncoding(withAllowedCharacters: fragmentToken),
              let p = postId.addingPercentEncoding(withAllowedCharacters: fragmentToken) else { return nil }
        return URL(string: "https://\(HavenSite.inviteDomain)/#s/\(c).\(p)")
    }

    /// The link shown in the post's share sheet — web-routed so it crosses the iOS/Android
    /// boundary and survives being pasted anywhere.
    static func postURL(circleId: String, postId: String) -> URL? {
        guard let c = circleId.addingPercentEncoding(withAllowedCharacters: fragmentToken),
              let p = postId.addingPercentEncoding(withAllowedCharacters: fragmentToken) else { return nil }
        return URL(string: "https://\(HavenSite.inviteDomain)/#p/\(c).\(p)")
    }

    /// → (circleId, postId) for either story form (`haven://s/…` or the web `#s/…` link), else nil.
    static func parseStory(_ raw: String) -> (circleId: String, postId: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text) else { return nil }
        return parseStory(url)
    }

    static func parseStory(_ url: URL) -> (circleId: String, postId: String)? {
        if let web = webStory(url) { return web }
        guard url.scheme?.lowercased() == "haven", url.host == "s" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// First story pointer embedded in free-form body text (a story reply's DM body is
    /// `"words\nhttps://…#s/…"`). Scans both the web form and `haven://s/…`.
    static func firstStory(in text: String) -> (circleId: String, postId: String, raw: String)? {
        // Prefer the web form (what we emit) — walk whitespace-separated tokens then substrings.
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init) {
            if let s = parseStory(token) { return (s.circleId, s.postId, token) }
        }
        // Fall back: link may sit mid-string without whitespace (paste).
        for prefix in ["https://", "haven://s/"] {
            guard let r = text.range(of: prefix) else { continue }
            let end = text[r.lowerBound...].firstIndex(where: { $0.isWhitespace || $0.isNewline })
                ?? text.endIndex
            let sub = String(text[r.lowerBound..<end])
            if let s = parseStory(sub) { return (s.circleId, s.postId, sub) }
        }
        return nil
    }

    /// Pull `s/<circle>.<post>` out of an https link's fragment (mirror of `webPost`).
    private static func webStory(_ url: URL) -> (String, String)? {
        guard url.scheme == "https", url.host?.lowercased() == HavenSite.host,
              url.path.hasPrefix(HavenSite.path),
              let frag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
              frag.hasPrefix("s/") else { return nil }
        let body = String(frag.dropFirst(2))
        guard let dot = body.firstIndex(of: "."), dot > body.startIndex else { return nil }
        let c = String(body[body.startIndex..<dot]).removingPercentEncoding
        let p = String(body[body.index(after: dot)...]).removingPercentEncoding
        guard let c, let p, !c.isEmpty, !p.isEmpty else { return nil }
        return (c, p)
    }

    // MARK: Story reply resolution (new deep links + legacy media attaches)

    /// Stories live 24h from `createdAt` (core retention). After that they must not surface as a
    /// playable reply card unless the author kept them — even if a feed quirk still returns the event.
    static let storyLifetimeMs: UInt64 = 24 * 60 * 60 * 1000

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    static func isPastStoryWindow(createdAt: UInt64, now: UInt64 = nowMs()) -> Bool {
        now > createdAt && now &- createdAt > storyLifetimeMs
    }

    /// Resolve which story a DM message is about — explicit deep link, remembered association,
    /// then **retroactive** inference for older replies that resealed media without a pointer.
    ///
    /// Legacy shape (pre-1.4.5): body text + a single visual media blob resealed into the DM.
    /// Those still mean "this story"; we recover the original event by matching the peer's
    /// (or my own) stories that were live when the reply was sent (created ≤ reply, within 24h).
    @MainActor
    static func storyReplyTarget(message: FeedItemFfi, dmCircleId: String) -> (circleId: String, postId: String)? {
        if let s = firstStory(in: message.body) {
            StoryReplyAssociationStore.shared.remember(messageId: message.id, circleId: s.circleId, postId: s.postId)
            return (s.circleId, s.postId)
        }
        if let remembered = StoryReplyAssociationStore.shared.lookup(messageId: message.id) {
            return remembered
        }
        if let inferred = inferLegacyStoryReply(message: message, dmCircleId: dmCircleId) {
            StoryReplyAssociationStore.shared.remember(messageId: message.id, circleId: inferred.circleId, postId: inferred.postId)
            return inferred
        }
        return nil
    }

    /// True when the story can still be opened: live and inside the 24h window, or author-kept.
    @MainActor
    static func storyReplyAvailable(circleId: String, postId: String) -> Bool {
        StoryLinkView.resolve(circleId: circleId, postId: postId) != nil
    }

    /// A DM that is (or was) a story reply: deep link, remembered association, successful
    /// inference, or a legacy single story-shaped visual attach (the pre-1.4.5 shape).
    @MainActor
    static func isStoryReplyMessage(_ message: FeedItemFfi, dmCircleId: String) -> Bool {
        if firstStory(in: message.body) != nil { return true }
        if StoryReplyAssociationStore.shared.lookup(messageId: message.id) != nil { return true }
        if storyReplyTarget(message: message, dmCircleId: dmCircleId) != nil { return true }
        // Legacy: one visual resealed into the DM — after the story window has passed relative to
        // the reply, treat it as a story reply even when we can no longer name the event (so we
        // swap the eternal media thumbnail for "Story no longer available").
        guard singleStoryLikeVisual(in: message.media) != nil,
              let ref = singleStoryLikeVisual(in: message.media),
              prefersStoryCrop(ref: ref, postMedia: message.media) else { return false }
        // Young messages may still be a normal photo share — only lock in "story reply" once the
        // original story would have expired if the reply was to a brand-new story (24h after reply).
        return isPastStoryWindow(createdAt: message.createdAt)
    }

    /// Visual refs only (not audio/file/geo) — a legacy story reply attached exactly one of these.
    @MainActor
    static func singleStoryLikeVisual(in media: [String]) -> String? {
        let visual = MediaVariants.displayRefs(media).filter {
            let k = MediaKind(ref: $0); return k == .image || k == .video
        }
        return visual.count == 1 ? visual[0] : nil
    }

    /// True when a lone DM visual should use the tall story crop even without a recoverable story id
    /// (portrait still / any video — the shape of a story canvas attach).
    @MainActor
    static func prefersStoryCrop(ref: String, postMedia: [String]) -> Bool {
        if MediaKind(ref: ref) == .video { return true }
        let poster = MediaVariants.poster(for: ref, in: postMedia)
        let size = MediaStore.shared.pixelSize(ref)
            ?? poster.flatMap { MediaStore.shared.pixelSize($0) }
        guard let size, size.width > 0, size.height > 0 else { return true } // unknown → story-shaped
        return size.height >= size.width * 0.95 // square-ish or portrait
    }

    /// Recover a story id for a media-only legacy reply. Best-effort; nil means "show tall crop of
    /// the attachment, but don't claim expiry of a specific story".
    @MainActor
    private static func inferLegacyStoryReply(message: FeedItemFfi, dmCircleId: String) -> (circleId: String, postId: String)? {
        guard !message.unsent,
              singleStoryLikeVisual(in: message.media) != nil else { return nil }
        // Don't treat multi-file / multi-photo sends as story replies.
        let display = MediaVariants.displayRefs(message.media)
        let nonVisual = display.filter {
            let k = MediaKind(ref: $0); return k == .audio || k == .file
        }
        guard nonVisual.isEmpty else { return nil }

        let store = FeedStore.shared
        let replyAt = message.createdAt
        let dayMs: UInt64 = 24 * 60 * 60 * 1000

        // I replied → story is the peer's. They replied → story is mine (incl. kept).
        let lookingForMine = !message.isMe
        let peerHex = store.dmPartnerHex(dmCircleId)?.lowercased()
        let peerShort = peerHex.map { String($0.prefix(12)) }

        struct Cand { let circleId: String; let id: String; let createdAt: UInt64 }
        var cands: [Cand] = []

        for circle in store.circles where !circle.id.hasPrefix("dm:") {
            let stories = store.messages(in: circle.id)
                .filter { $0.story && !$0.unsent && !$0.media.isEmpty }
            for s in stories {
                // Story must already exist when the reply was sent, and still be in its 24h window
                // at that moment (otherwise it wouldn't have been on the tray).
                guard s.createdAt <= replyAt, replyAt &- s.createdAt <= dayMs else { continue }
                if lookingForMine {
                    guard s.isMe else { continue }
                } else {
                    // Peer authored: match short prefix or full hex start.
                    let a = s.authorShort.lowercased()
                    let ok: Bool = {
                        if let peerShort, a.hasPrefix(peerShort) || peerShort.hasPrefix(a) { return true }
                        if let peerHex, peerHex.hasPrefix(a) || a.hasPrefix(String(peerHex.prefix(a.count))) { return true }
                        return false
                    }()
                    guard ok else { continue }
                }
                cands.append(Cand(circleId: circle.id, id: s.id, createdAt: s.createdAt))
            }
        }

        // Kept snapshots: only for replies to MY stories after the live event is gone.
        if lookingForMine {
            for k in KeptStoriesStore.shared.kept where !k.media.isEmpty {
                guard k.createdAt <= replyAt, replyAt &- k.createdAt <= dayMs * 7 else { continue }
                // Prefer active circle / default if we can place it; circle id is only needed for
                // resolve — keptItem ignores circle for the snapshot itself.
                let cid = store.activeCircleId.hasPrefix("dm:") ? "default" : store.activeCircleId
                cands.append(Cand(circleId: cid, id: k.id, createdAt: k.createdAt))
            }
        }

        // Most recent story before the reply = the one they were almost certainly watching.
        guard let best = cands.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        return (best.circleId, best.id)
    }
}

enum DeepLinkRoute: Identifiable {
    case profile(nodeHex: String)
    case post(circleId: String, postId: String)
    case story(circleId: String, postId: String)
    var id: String {
        switch self {
        case .profile(let h): return "u:\(h)"
        case .post(let c, let p): return "p:\(c):\(p)"
        case .story(let c, let p): return "s:\(c):\(p)"
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
        // Story web form (`#s/<c>.<p>`) before falling through — same privacy rule as posts.
        if let (circleId, postId) = DeepLink.parseStory(url),
           url.scheme?.lowercased() == "https" {
            openStory(circleId: circleId, postId: postId, tab: &tab)
            return true
        }
        guard url.scheme == "haven" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }.map {
            $0.removingPercentEncoding ?? $0
        }
        switch url.host {
        case "u":
            guard let id = parts.first, id.count >= 6 else { return true }
            route = .profile(nodeHex: id)
            return true
        case "p":
            guard parts.count >= 2 else { return true }
            openPost(circleId: parts[0], postId: parts[1], tab: &tab)
            return true
        case "m":
            // DM thread (optional message id → scroll-to inside the thread).
            guard let cid = parts.first, cid.hasPrefix("dm:") else { return true }
            openDM(circleId: cid, messageId: parts.count >= 2 ? parts[1] : nil, tab: &tab)
            return true
        case "s":
            // Story (haven://s/<cid>/<postId>) — opens the story viewer, not the feed.
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return true }
            openStory(circleId: parts[0], postId: parts[1], tab: &tab)
            return true
        case "c":
            guard let cid = parts.first, !cid.isEmpty else { return true }
            openCircle(circleId: cid, tab: &tab)
            return true
        default:
            return false
        }
    }

    /// Open a DM conversation (Messages tab). Used by notification taps. A message id scrolls the
    /// thread to that exact message (staged via DMDraftStore, consumed by the thread's onAppear) —
    /// NOT a sheet: floating a lone PostLinkView bubble over the conversation it's already in was
    /// pure clutter.
    private func openDM(circleId: String, messageId: String?, tab: inout String) {
        let resolved = Self.resolveDMCircle(circleId)
        tab = "messages"
        requestedTab = "messages"
        if let messageId, !messageId.isEmpty {
            DMDraftStore.shared.stageScroll(circleId: resolved, messageId: messageId)
        }
        // The push waits until the tab switch above has actually been applied.
        //
        // Asking for the tab and the thread in ONE turn makes the Messages tab receive a push while
        // it is still becoming the visible tab, and SwiftUI drops it: instrumented runs show the
        // destination getting BUILT (three times) with the correct circle, its body evaluated once
        // against a healthy thread — and an empty page with a lone navigation bar on screen. Every
        // path that works (a list row, a pinned tile) pushes while Messages is already current;
        // this was the only one that didn't. The thread id was never the problem.
        DispatchQueue.main.async {
            DMDraftStore.shared.openThread = resolved
        }
    }

    /// Map a `dm:` id from a notification onto the id this device actually stores the thread under.
    ///
    /// The id is derived — `dm:` plus the participants' node hexes, sorted and `-`-joined — so the two
    /// ends normally agree exactly, and the exact match is the answer. But a notification can be built
    /// by a different platform, a different app version, or (for a group) a device that knows a roster
    /// this one has only partly synced, and any of those can produce an id whose TEXT differs from ours
    /// while naming the same conversation: a different hex case, or full hexes where we hold the
    /// short-prefix form from an older build. A thread opened under an id nothing is stored against
    /// renders as a conversation with no name and no messages — the blank thread people report from
    /// notification taps.
    ///
    /// So: exact match first, then the same PARTICIPANTS regardless of how the id spells them. Falls
    /// back to the id as given, which is still correct — that's genuinely a thread we haven't synced,
    /// and `DMThreadView` says so rather than pretending.
    static func resolveDMCircle(_ circleId: String) -> String {
        let known = FeedStore.shared.circles.map(\.id).filter { $0.hasPrefix("dm:") }
        if known.contains(circleId) { return circleId }
        let wanted = participantSet(circleId)
        guard !wanted.isEmpty else { return circleId }
        if let match = known.first(where: { participantSet($0) == wanted }) { return match }
        return circleId
    }

    /// The participants a `dm:` id names, lowercased and order-independent.
    private static func participantSet(_ circleId: String) -> Set<String> {
        guard circleId.hasPrefix("dm:") else { return [] }
        return Set(circleId.dropFirst(3).split(separator: "-").map { $0.lowercased() })
    }

    /// Open a feed circle (Circle tab). Used when a notification only carries the circle id.
    /// Deliberately NO `route` — the tab switch + setActiveCircle already show the circle, and the
    /// old `.circle` route only ever presented a blank sheet over it.
    private func openCircle(circleId: String, tab: inout String) {
        FeedStore.shared.setActiveCircle(circleId)
        tab = "circle"
        requestedTab = "circle"
        if CircleSettingsStore.shared.biometricRequired(circleId),
           !BiometricGate.shared.unlocked.contains(circleId) {
            BiometricGate.shared.unlock(circleId)
        }
    }

    /// Open a story in the viewer (haven://s/…). Biometric rules match posts: a locked circle
    /// routes to its lock screen, never to the story.
    private func openStory(circleId: String, postId: String, tab: inout String) {
        if CircleSettingsStore.shared.biometricRequired(circleId),
           !BiometricGate.shared.unlocked.contains(circleId) {
            FeedStore.shared.setActiveCircle(circleId)
            BiometricGate.shared.unlock(circleId)
            tab = "circle"
            requestedTab = "circle"
            return
        }
        route = .story(circleId: circleId, postId: postId)
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
        // Retention-free lookup — see FeedStore.post(_:in:). Tapping a notification is an explicit
        // request for THIS post; a "hide older than N days" display preference must not turn it
        // into "unavailable" for something the feed is still showing. The same lookup resolves an
        // id that names a COMMENT to the post carrying it.
        store.post(postId, in: circleId)
    }

    /// Non-nil when the link named a comment rather than the post itself — a reaction on, or a reply
    /// to, a comment of mine. The post opens with that comment shown and marked.
    private var linkedCommentId: String? {
        guard let post, post.id != postId else { return nil }
        return postId
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
                                 onEdit: { _ in }, onUnsend: { },
                                 expandAllComments: linkedCommentId != nil,
                                 highlightCommentId: linkedCommentId)
                            .padding(16)
                    }
                    // A standalone post has no scroll-centre reporter, so name its own container and
                    // declare this post centred in it. Without this the card's `isActive` — which now
                    // requires the centre to come from ITS OWN feed — would never be true here and the
                    // video would silently never play. It is genuinely the active post: it is the only
                    // thing on screen.
                    .environment(\.havenFeedContainer, "deeplink")
                    .onAppear { AudioCoordinator.shared.center(post.id, container: "deeplink") }
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
                // Poll, don't guess. A notification tapped after the app was killed races the engine:
                // every lookup answers "no such post" for a second or two purely because the engine
                // hasn't opened yet, and the old blind 1.5s timer routinely expired inside that
                // window — hence "Post unavailable" for a post that was sitting in the feed the
                // moment you dismissed the sheet. The grace budget only burns down once the engine
                // is actually up, so a slow cold launch spends startup time instead of the budget.
                var graceLeft = 6.0            // seconds of "engine is up but the post hasn't landed"
                var ticks = 0                  // absolute cap, so a dead engine can't spin forever
                while graceLeft > 0, ticks < 160 {
                    if post != nil { return }  // found it — never show the failure state
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    ticks += 1
                    if store.engineReady { graceLeft -= 0.25 }
                }
                settled = true
            }
            .navigationTitle("Post")
            .havenInlineNavTitle()
            .toolbar { ToolbarItem(placement: .havenConfirmLeading) { Button("Done") { dismiss() }.havenToolbarPill() } }
        }
    }
}

/// Remembers which DM message points at which story so a legacy media-only reply still shows
/// "Story no longer available" after the live event is purged (when inference can no longer match).
@MainActor
final class StoryReplyAssociationStore {
    static let shared = StoryReplyAssociationStore()
    private let key = "haven.storyReply.assoc.v1"
    private var map: [String: String] = [:] // messageId → "circleId\u{1f}postId"

    private init() {
        if let data = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            map = data
        }
    }

    func remember(messageId: String, circleId: String, postId: String) {
        guard !messageId.isEmpty, !circleId.isEmpty, !postId.isEmpty else { return }
        let v = "\(circleId)\u{1f}\(postId)"
        guard map[messageId] != v else { return }
        map[messageId] = v
        // Bound growth — oldest keys drop first.
        if map.count > 2000 {
            map = Dictionary(uniqueKeysWithValues: map.suffix(1500))
        }
        UserDefaults.standard.set(map, forKey: key)
    }

    func lookup(messageId: String) -> (circleId: String, postId: String)? {
        guard let v = map[messageId] else { return nil }
        let parts = v.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let c = String(parts[0]), p = String(parts[1])
        guard !c.isEmpty, !p.isEmpty else { return nil }
        return (c, p)
    }
}

/// A deep-linked story (`haven://s/<cid>/<postId>` or the web `#s/…` form): the story viewer
/// scoped to that circle's stories, starting at the linked one. Stories expire in 24h — "Story
/// no longer available" is normal. An author who **kept** the story still has it on this device
/// after the live window, so a kept snapshot is revived the same way the profile tray does.
struct StoryLinkView: View {
    let circleId: String
    let postId: String
    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var kept = KeptStoriesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var settled = false

    /// The circle's live stories in viewing order (oldest→newest, same as the tray's groups).
    private var liveStories: [FeedItemFfi] {
        store.messages(in: circleId)
            .filter { $0.story && !$0.unsent && !$0.media.isEmpty }
            .filter { !DeepLink.isPastStoryWindow(createdAt: $0.createdAt) || KeptStoriesStore.shared.isKept($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Live first; if the author kept this story past the 24h window, revive that snapshot so a
    /// DM reply still opens the real viewer (music, framing, progress) instead of "expired".
    private var stories: [FeedItemFfi] {
        if liveStories.contains(where: { $0.id == postId }) { return liveStories }
        if let revived = Self.keptItem(postId) { return [revived] }
        return liveStories
    }

    static func keptItem(_ postId: String) -> FeedItemFfi? {
        guard let k = KeptStoriesStore.shared.kept.first(where: { $0.id == postId }),
              !k.media.isEmpty else { return nil }
        let music: TrackRefFfi? = k.musicCatalogId.map {
            TrackRefFfi(catalogId: $0, title: k.musicTitle ?? "", artist: k.musicArtist ?? "",
                        artworkUrl: k.musicArtworkUrl ?? "", durationMs: k.musicDurationMs ?? 0)
        }
        return FeedItemFfi(id: k.id, authorShort: FeedStore.shared.myNodeHex, isMe: true,
                           createdAt: k.createdAt, body: k.body, media: k.media, music: music,
                           edited: false, unsent: false, story: true, muteVideo: false,
                           comments: [], reactions: [], poll: nil)
    }

    /// Live (within 24h) or kept story for a DM reply card — nil once expired and not kept.
    /// Enforces the story lifetime even if the event is still briefly present in a feed cache.
    static func resolve(circleId: String, postId: String) -> FeedItemFfi? {
        if KeptStoriesStore.shared.isKept(postId), let kept = keptItem(postId) { return kept }
        // Prefer retention-free lookup so a story still in the store but past viewer prefs can be
        // found — then apply the hard 24h story window ourselves.
        if let live = FeedStore.shared.post(postId, in: circleId),
           live.story, !live.unsent, !live.media.isEmpty {
            if DeepLink.isPastStoryWindow(createdAt: live.createdAt) { return nil }
            return live
        }
        if let live = FeedStore.shared.messages(in: circleId)
            .first(where: { $0.id == postId && $0.story && !$0.unsent && !$0.media.isEmpty }) {
            if DeepLink.isPastStoryWindow(createdAt: live.createdAt) { return nil }
            return live
        }
        return nil
    }

    var body: some View {
        if let idx = stories.firstIndex(where: { $0.id == postId }) {
            StoryViewer(stories: stories, index: idx, friendName: "Friend")
        } else {
            ZStack {
                HavenBackground()
                if settled {
                    VStack(spacing: 14) {
                        ContentUnavailableView("Story no longer available", systemImage: "clock",
                                               description: Text("Stories disappear after 24 hours, unless the author kept it on their profile."))
                        Button("Done") { dismiss() }.havenToolbarPill()
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .task {
                // Same engine race as PostLinkView — a tap from a cold launch must not be told the
                // story is gone just because the engine hasn't finished coming up.
                var graceLeft = 6.0
                var ticks = 0
                while graceLeft > 0, ticks < 160 {
                    if stories.contains(where: { $0.id == postId }) { return }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    ticks += 1
                    if store.engineReady { graceLeft -= 0.25 }
                }
                settled = true
            }
        }
    }
}

// MARK: - Story reply card (DM)

/// Tall portrait tile for a story reference embedded in a DM (a reply from the story viewer's
/// text field). Matches the story canvas aspect and the author's framing (scale / offset /
/// rotation from the caption spec), and opens the real `StoryLinkView` on tap — same deep-link
/// path as the activity feed. When the story has expired and was not kept, shows "Story expired".
struct StoryReplyCard: View {
    let circleId: String
    let postId: String
    /// ~9:16 story canvas, sized for a DM bubble.
    var width: CGFloat = 128

    @ObservedObject private var store = FeedStore.shared
    @ObservedObject private var kept = KeptStoriesStore.shared
    @State private var settled = false

    private var story: FeedItemFfi? { StoryLinkView.resolve(circleId: circleId, postId: postId) }
    private var height: CGFloat { width * 16.0 / 9.0 }

    var body: some View {
        // When the story is gone, the tile is NOT tappable into a broken viewer — just the status.
        if let story {
            Button {
                DeepLinkRouter.shared.route = .story(circleId: circleId, postId: postId)
            } label: {
                StoryReplyThumb(item: story)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        } else if settled {
            StoryNoLongerAvailableCard(width: width)
        } else {
            ProgressView()
                .frame(width: width, height: height)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .task(id: "\(circleId)/\(postId)") {
                    // Brief settle so a cold open doesn't flash unavailable before the engine is up.
                    if StoryLinkView.resolve(circleId: circleId, postId: postId) != nil {
                        settled = true; return
                    }
                    var grace = 4.0
                    var ticks = 0
                    while grace > 0, ticks < 80,
                          StoryLinkView.resolve(circleId: circleId, postId: postId) == nil {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        ticks += 1
                        if store.engineReady { grace -= 0.25 }
                    }
                    settled = true
                }
        }
    }
}

/// Placeholder tile when the original story is past its 24h window and was not kept.
/// Replaces the eternal resealed media thumbnail for expired story replies.
struct StoryNoLongerAvailableCard: View {
    var width: CGFloat = 128
    private var height: CGFloat { width * 16.0 / 9.0 }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Story no longer available")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
        }
        .padding(12)
        .frame(width: width, height: height)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityLabel("Story no longer available")
    }
}

/// Portrait crop of a story's media with the author's framing applied — same transform order as
/// `StoryViewer` (scale → rotate → offset).
private struct StoryReplyThumb: View {
    let item: FeedItemFfi

    private var displayRef: String? {
        // Prefer the playable clip's poster for video; otherwise first visual ref.
        let media = item.media
        if let v = media.first(where: { MediaKind(ref: $0) == .video }) {
            return MediaVariants.poster(for: v, in: media) ?? v
        }
        return MediaVariants.displayRefs(media).first
    }

    var body: some View {
        let tf = StoryCaptions.decode(StoryEmbed.strip(item.body)).spec
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.85)
                if let ref = displayRef, let img = MediaStore.shared.item(ref)?.image {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(tf.mediaScale)
                        .rotationEffect(.radians(tf.mediaRotation))
                        .offset(x: tf.mediaOffX * geo.size.width, y: tf.mediaOffY * geo.size.height)
                } else if let ref = displayRef {
                    // Bytes not decoded yet — request and show a quiet placeholder.
                    Color(.tertiarySystemFill)
                        .overlay { ProgressView().controlSize(.small) }
                        .onAppear { FeedStore.shared.requestMedia(ref, circleId: FeedStore.shared.activeCircleId) }
                }
                // Soft bottom fade so the tile reads as a story even without chrome.
                LinearGradient(colors: [.clear, .black.opacity(0.35)],
                               startPoint: .center, endPoint: .bottom)
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}
