import Foundation

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

    /// Stories live 24h from `createdAt` (core retention). After that they must not surface as a
    /// playable reply card unless the author kept them — even if a feed quirk still returns the event.
    static let storyLifetimeMs: UInt64 = 24 * 60 * 60 * 1000

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    static func isPastStoryWindow(createdAt: UInt64, now: UInt64 = nowMs()) -> Bool {
        now > createdAt && now &- createdAt > storyLifetimeMs
    }
}

extension DeepLink {
    /// Pull `p/<circle>.<post>` out of an https link's fragment. Anything else (an invite's
    /// bare `<id>.<verify>`, a plain visit to the site) returns nil and falls through.
    static func webPost(_ url: URL) -> (circleId: String, postId: String)? {
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
}

/// What a URL means to the router, decided before any store is consulted. Pure, so the whole
/// routing table (every `haven://` host + both web forms) is covered without an engine.
enum DeepLinkTarget: Equatable {
    case profile(nodeHex: String)
    case post(circleId: String, postId: String)
    case story(circleId: String, postId: String)
    /// A DM thread; the optional message id scrolls the thread to that message.
    case dm(circleId: String, messageId: String?)
    case circle(circleId: String)
    /// One of OUR links (`haven://…`) that is malformed or incomplete: the caller swallows it
    /// (returns "handled") rather than letting the invite path try to read it.
    case ignored

    /// `nil` = not a deep link at all (another scheme, an unknown `haven://` host, an invite link):
    /// the caller must fall through to its other handlers.
    static func classify(_ url: URL) -> DeepLinkTarget? {
        if let web = DeepLink.webPost(url) { return .post(circleId: web.circleId, postId: web.postId) }
        // Story web form (`#s/<c>.<p>`) before falling through — same privacy rule as posts.
        if let s = DeepLink.parseStory(url), url.scheme?.lowercased() == "https" {
            return .story(circleId: s.circleId, postId: s.postId)
        }
        guard url.scheme == "haven" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
        switch url.host {
        case "u":
            guard let id = parts.first, id.count >= 6 else { return .ignored }
            return .profile(nodeHex: id)
        case "p":
            guard parts.count >= 2 else { return .ignored }
            return .post(circleId: parts[0], postId: parts[1])
        case "m":
            guard let cid = parts.first, cid.hasPrefix("dm:") else { return .ignored }
            return .dm(circleId: cid, messageId: parts.count >= 2 ? parts[1] : nil)
        case "s":
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return .ignored }
            return .story(circleId: parts[0], postId: parts[1])
        case "c":
            guard let cid = parts.first, !cid.isEmpty else { return .ignored }
            return .circle(circleId: cid)
        default:
            return nil
        }
    }

    /// Map a `dm:` id from a notification onto the id this device actually stores the thread under:
    /// exact match first, then the same PARTICIPANTS however the id spells them (hex case, short vs
    /// full prefix order). Falls back to the id as given — a thread we genuinely haven't synced.
    static func resolveDMCircle(_ circleId: String, known allCircleIds: [String]) -> String {
        let known = allCircleIds.filter { $0.hasPrefix("dm:") }
        if known.contains(circleId) { return circleId }
        let wanted = participantSet(circleId)
        guard !wanted.isEmpty else { return circleId }
        if let match = known.first(where: { participantSet($0) == wanted }) { return match }
        return circleId
    }

    /// The participants a `dm:` id names, lowercased and order-independent.
    static func participantSet(_ circleId: String) -> Set<String> {
        guard circleId.hasPrefix("dm:") else { return [] }
        return Set(circleId.dropFirst(3).split(separator: "-").map { $0.lowercased() })
    }
}

/// The matching rules for recovering which story a pre-1.4.5 DM reply was about (the reply resealed
/// the media with no pointer). Pure so the window/author arithmetic is covered.
enum LegacyStoryMatch {
    struct Candidate: Equatable { let circleId: String; let id: String; let createdAt: UInt64 }

    static let dayMs: UInt64 = 24 * 60 * 60 * 1000
    /// A kept snapshot may be older than the live window: the author pinned it.
    static let keptWindowMs: UInt64 = dayMs * 7

    /// A story must already exist when the reply was sent, and still be inside the window then
    /// (otherwise it would not have been on the tray).
    static func storyWasLive(createdAt: UInt64, replyAt: UInt64, windowMs: UInt64 = dayMs) -> Bool {
        createdAt <= replyAt && replyAt &- createdAt <= windowMs
    }

    /// Does a story author (short or full hex prefix, any case) belong to this DM's peer?
    static func authorIsPeer(_ authorShort: String, peerHex: String?) -> Bool {
        guard let peerHex = peerHex?.lowercased() else { return false }
        let a = authorShort.lowercased()
        let peerShort = String(peerHex.prefix(12))
        if a.hasPrefix(peerShort) || peerShort.hasPrefix(a) { return true }
        if peerHex.hasPrefix(a) || a.hasPrefix(String(peerHex.prefix(a.count))) { return true }
        return false
    }

    /// The most recent story before the reply = the one they were almost certainly watching.
    static func best(_ cands: [Candidate]) -> Candidate? {
        cands.max(by: { $0.createdAt < $1.createdAt })
    }
}

/// Where Haven's web links live. The landing page resolves the URL fragment — `/#<id>.<verify>` for an
/// invite, `/#p/<circle>.<post>` for a shared post — into an "open in Haven" page. Everything sensitive
/// stays in the fragment, which the browser never sends to the host; see DeepLink.swift.
///
/// Note the split between EMITTING (`inviteDomain`) and MATCHING (`sitePath`).
///
/// Links are emitted under a dedicated `/open` page, and that page alone is what the apps claim as a
/// Universal Link / App Link. The rest of the site — the marketing home page, /features/, /docs/,
/// /relay/ — is ordinary web content and must stay in the browser. Claiming the whole `/apps/haven`
/// subtree made every one of those pages offer to open Haven, which is what people were seeing:
///
///   • iOS matched on "any non-empty fragment", and the site is full of its OWN in-page anchors
///     (`#main` on every page, `#download`, `#privacy`, `#circles`, …). Every anchor tap looked like
///     a payload.
///   • Android App Links cannot match a fragment AT ALL — only scheme/host/path — so the fragment
///     gate that saved iOS did not exist there, and the whole subtree was claimed outright.
///
/// A distinct path is the only thing both platforms can agree on. The payload STAYS in the fragment;
/// `/open` is a constant, so the host still never learns which post or circle — only that some Haven
/// link was opened, which is what it already learned from the bare page load.
enum HavenSite {
    static let host = "wemiller.com"
    /// MATCHING prefix. Deliberately the whole site path: every link form ever emitted — including the
    /// pre-`/open` ones already pasted into people's chat histories — starts here, and those keep
    /// resolving once the app has the URL. Only which links AUTO-OPEN the app got narrower.
    static let sitePath = "/apps/haven"
    /// EMITTING. The dedicated deep-link landing page, and the only path the apps claim.
    static let inviteDomain = "\(host)\(sitePath)/open"
    static var path: String { sitePath }
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

