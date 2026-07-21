import SwiftUI
import WebKit
import LinkPresentation
import UniformTypeIdentifiers

/// Drives the in-app browser. Anywhere in the app, call `LinkPresenter.shared.open(...)` to
/// open a link inside Haven (so people can share links freely without leaving the app).
@MainActor
final class LinkPresenter: ObservableObject {
    static let shared = LinkPresenter()
    @Published var presented: PresentedURL?

    /// Open a link string, normalizing a bare host into https://.
    ///
    /// A HAVEN link never reaches the browser. Haven's own post/profile links are web-routed so they
    /// survive being shared anywhere, but that meant tapping one INSIDE Haven loaded the web page in
    /// the in-app browser — which then offers an "Open in Haven" button that can't do anything,
    /// because you are already in Haven looking at a web view of your own content. The link's whole
    /// purpose is the destination it names, and in here we can just go there.
    func open(_ string: String) {
        if let url = Self.normalized(string) ?? URL(string: string), routeInApp(url) { return }
        guard let url = Self.normalized(string) else { return }
        presented = PresentedURL(url: url)
    }

    /// True if this URL is a Haven route and has been handled in-app.
    @discardableResult
    func routeInApp(_ url: URL) -> Bool {
        var scratchTab = ""
        return DeepLinkRouter.shared.handle(url, tab: &scratchTab)
    }

    /// Turn user/profile text into a real URL: add https:// if no scheme, reject non-web.
    static func normalized(_ string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct PresentedURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Find the http(s) links inside a block of body text (for inline previews + tappable text).
enum LinkScanner {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Remove one URL's text from a body, tidying the whitespace it leaves behind so the remaining
    /// sentence doesn't keep a hole where the link was.
    ///
    /// Lives here rather than on a view because MORE THAN ONE surface renders a body next to a
    /// preview card: the feed and comments go through `LinkedText`, but a DM bubble draws
    /// `Text(m.body)` itself and adds the card separately — so a strip that lived only in
    /// `LinkedText` left the raw URL sitting in every DM, which is exactly what "Message the author"
    /// produces. Any new surface that shows a card should strip through this too.
    static func stripping(_ url: URL, from text: String) -> String {
        guard let range = text.range(of: url.absoluteString) else { return text }
        var out = text
        out.removeSubrange(range)
        // Collapse the doubled spaces / stranded blank lines the removal can leave mid-sentence.
        while let r = out.range(of: "  ") { out.replaceSubrange(r, with: " ") }
        while let r = out.range(of: "\n\n\n") { out.replaceSubrange(r, with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func urls(in text: String) -> [URL] {
        guard let detector else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap { match -> URL? in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }
}

// MARK: - In-app browser

/// A WKWebView wrapper with navigation state surfaced for the chrome (back/forward/address).
#if !os(macOS)
struct WebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var model: WebViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // ephemeral: no cookies/cache/localStorage on disk
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator
        model.bind(web)
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: WebViewModel
        init(_ model: WebViewModel) { self.model = model }
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { model.refresh(w, loading: true) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { model.refresh(w, loading: false) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { model.refresh(w, loading: false) }
    }
}
#else
struct WebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var model: WebViewModel

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // ephemeral: no cookies/cache/localStorage on disk
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator
        model.bind(web)
        web.load(URLRequest(url: url))
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: WebViewModel
        init(_ model: WebViewModel) { self.model = model }
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { model.refresh(w, loading: true) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { model.refresh(w, loading: false) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { model.refresh(w, loading: false) }
    }
}
#endif

@MainActor
final class WebViewModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentHost = ""
    private weak var web: WKWebView?

    func bind(_ web: WKWebView) { self.web = web }
    func goBack() { web?.goBack() }
    func goForward() { web?.goForward() }
    func reload() { web?.reload() }

    func refresh(_ web: WKWebView, loading: Bool) {
        canGoBack = web.canGoBack
        canGoForward = web.canGoForward
        isLoading = loading
        currentHost = web.url?.host ?? web.url?.absoluteString ?? currentHost
    }
}

/// The in-app browser sheet: an address bar showing the current site, back/forward, reload,
/// open-in-Safari, and a close button.
struct InAppBrowserView: View {
    let url: URL
    @StateObject private var model = WebViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            #if !os(macOS)
            WebView(url: url, model: model)
                // Don't draw under the bottom toolbar — that made the nav controls sit on top of
                // the page content. Respecting the bottom safe area keeps the page above the bar.
                .havenInlineNavTitle()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Image(systemName: model.currentHost.isEmpty ? "globe" : "lock.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(model.currentHost.isEmpty ? url.host ?? url.absoluteString : model.currentHost)
                                .font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    ToolbarItem(placement: .havenLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                            .disabled(!model.canGoBack)
                        Spacer()
                        Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!model.canGoForward)
                        Spacer()
                        if model.isLoading { ProgressView() } else {
                            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                        }
                        Spacer()
                        Button { openURL(url) } label: { Image(systemName: "safari") }
                        Spacer()
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .tint(HavenTheme.pink)
            #else
            // macOS sheet toolbars rendered unreliably here (no Done, no address), so use an explicit
            // header bar instead: back/forward/reload on the left, a non-editable address pill in the
            // middle (shows the host like iOS), and open-in-Safari/share + a clear Done on the right.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { model.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack)
                    Button { model.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward)
                    if model.isLoading { ProgressView().controlSize(.small) }
                    else { Button { model.reload() } label: { Image(systemName: "arrow.clockwise") } }
                    HStack(spacing: 6) {
                        Image(systemName: model.currentHost.isEmpty ? "globe" : "lock.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(model.currentHost.isEmpty ? (url.host ?? url.absoluteString) : model.currentHost)
                            .font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)   // selectable but not editable — just shows where you are
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .havenGlass(in: Capsule())
                    Button { openURL(url) } label: { Image(systemName: "safari") }
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    Button("Done") { dismiss() }
                        .buttonStyle(GlassPillButtonStyle(tint: HavenTheme.pink))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .buttonStyle(GlassIconButtonStyle())   // nav/share chips: glass circles, no bare glyphs
                Divider()
                WebView(url: url, model: model)
            }
            // WKWebView reports no intrinsic size, so without a frame the sheet collapses to a sliver.
            .frame(minWidth: 820, idealWidth: 1040, minHeight: 600, idealHeight: 740)
            .tint(HavenTheme.pink)
            #endif
        }.havenPausesPostAudio()
    }
}

// MARK: - Rich link preview (Open Graph) card

/// Fetches Open Graph metadata (title / poster image / host) for a URL on-device.
@MainActor
final class LinkMetaLoader: ObservableObject {
    @Published var title = ""
    @Published var host = ""
    @Published var image: PlatformImage?
    @Published var isLoading = false
    /// True once a fetch has been asked for, whatever came back — the card stops offering to load.
    @Published var didAttempt = false
    private var started = false

    func load(_ url: URL) {
        guard !started else { return }
        started = true
        host = url.host ?? ""
        isLoading = true
        didAttempt = true
        // Vet the destination BEFORE handing it to LPMetadataProvider, off the main thread because
        // resolution blocks. See LinkSafety for what this does and does not cover on Apple.
        Task.detached(priority: .utility) { [weak self] in
            guard LinkSafety.resolvesPublicly(url) else {
                await MainActor.run { [weak self] in self?.isLoading = false }
                return
            }
            await MainActor.run { [weak self] in self?.beginFetch(url) }
        }
    }

    private func beginFetch(_ url: URL) {
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { [weak self] meta, _ in
            Task { @MainActor in self?.isLoading = false }
            guard let meta else { return }
            let title = meta.title ?? ""
            let host = meta.url?.host ?? meta.originalURL?.host ?? ""
            let imageProvider = meta.imageProvider
            if let imageProvider, imageProvider.canLoadObject(ofClass: PlatformImage.self) {
                imageProvider.loadObject(ofClass: PlatformImage.self) { [weak self] obj, _ in
                    let img = obj as? PlatformImage
                    Task { @MainActor in
                        self?.title = title
                        if !host.isEmpty { self?.host = host }
                        self?.image = img
                    }
                }
            } else {
                Task { @MainActor in
                    self?.title = title
                    if !host.isEmpty { self?.host = host }
                }
            }
        }
    }
}

/// A tappable Open Graph preview for a URL. Renders the fetched poster image at its NATURAL aspect
/// ratio above the title + host in a custom card (the system `LPLinkView` cropped the image to a
/// thin band and overflowed the bubble). Tapping opens it in the in-app browser.
///
/// NOTHING IS FETCHED UNTIL YOU ASK FOR IT. The metadata fetch used to fire from `.onAppear`, which
/// handed any circle member a network primitive aimed at the RECIPIENT's device: putting a link in a
/// message made the reader's device connect to it on render, with no tap. That leaks the reader's IP
/// and the moment they read — a read receipt nobody consented to — and points their device at
/// whatever host the sender named. Loading is now behind an explicit "Load preview" tap, and
/// `LinkSafety` vets the destination before the fetch starts.
///
/// `autoLoad` exists for the DEBUG layout harness, which needs a poster on screen to check bubble
/// geometry and uses a first-party URL. Do not set it on a surface that renders peer content.
struct LinkPreviewCard: View {
    let url: URL
    var autoLoad: Bool = false
    @StateObject private var meta = LinkMetaLoader()

    var body: some View {
        Button { LinkPresenter.shared.open(url.absoluteString) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let img = meta.image {
                    Image(platformImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)   // keep the poster's real proportions
                        .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !meta.host.isEmpty {
                        Text(meta.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    // Its own tap target inside the card, so the card's tap still means "open the
                    // link" — one control, one meaning.
                    if !meta.didAttempt {
                        Button { meta.load(url) } label: {
                            Text("Load preview").font(.caption).foregroundStyle(HavenTheme.pink)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    } else if meta.isLoading {
                        Text("Loading preview…").font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onAppear { if autoLoad { meta.load(url) } }
    }

    private var displayTitle: String {
        if !meta.title.isEmpty { return meta.title }
        if !meta.host.isEmpty { return meta.host }
        return url.absoluteString
    }

    private var cardSurface: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemBackground)
        #endif
    }
}

/// Body text that makes any http(s) links tappable (opening the in-app browser) and renders a
/// rich Open Graph preview card for the first link. Use anywhere a post/comment body is shown.
struct LinkedText: View {
    let text: String
    var font: Font = .body
    var showsPreview: Bool = true

    var body: some View {
        let urls = LinkScanner.urls(in: text)
        let previewed = showsPreview ? urls.first : nil
        // When a preview card IS shown, the raw URL is redundant copy — the card already names the
        // destination, more legibly. A message that is only a link collapsed to just the card
        // already; one with anything typed around it kept the bare URL sitting in the sentence.
        // Strip the previewed URL from the text, not every URL: a second link has no card of its
        // own, so removing it would lose it entirely.
        let shown = previewed.map { Self.stripping($0, from: text) } ?? text
        VStack(alignment: .leading, spacing: 8) {
            if !shown.isEmpty {
                Text(Self.attributed(shown))
                    .font(font)
                    // Route link taps in-app: a Haven link goes straight to the post/profile, and
                    // anything else opens in the in-app browser rather than leaving Haven.
                    .environment(\.openURL, OpenURLAction { url in
                        LinkPresenter.shared.open(url.absoluteString); return .handled
                    })
            }
            if let previewed {
                LinkPreviewCard(url: previewed)
            }
        }
    }

    private static func stripping(_ url: URL, from text: String) -> String {
        LinkScanner.stripping(url, from: text)
    }

    private static func attributed(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        let ns = s as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attr }
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let r = Range(m.range, in: attr) else { continue }
            attr[r].link = url
            attr[r].foregroundColor = HavenTheme.pink
            attr[r].underlineStyle = .single
        }
        return attr
    }
}
