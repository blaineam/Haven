import Intents
import UIKit
import UniformTypeIdentifiers

/// A no-UI share extension: it extracts the shared text / link / photo / video / document, drops it
/// into the shared App Group inbox, opens the main app (`haven://share`), and completes. The app
/// shows the DM / post / story routing — the extension process is too short-lived to run the P2P
/// stack.
///
/// When the user taps one of Haven's **conversation suggestions** in the share sheet's top row, iOS
/// hands us the `INSendMessageIntent` we donated for that thread (see `ShareSuggestions.swift`);
/// its `conversationIdentifier` is the `dm:` circle id, which rides along in the payload so the app
/// opens straight into that conversation instead of asking where the content should go.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await process() }
    }

    private func process() async {
        ShareInbox.ensureDir()
        var payload = ShareInbox.Payload()
        payload.targetCircleId = chosenConversationId() ?? ""
        var fileIdx = 0
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            for provider in item.attachments ?? [] {
                // Order matters, and the two subtle rules are:
                //   • concrete media before the URL/text fallback the same item may also vend, and
                //   • `public.file-url` BEFORE `public.url` — a document shared from Files conforms to
                //     both, and the URL branch would have turned a real attachment into a `file:///…`
                //     string nobody can open.
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    if let src = await loadFile(provider, UTType.movie.identifier) {
                        let ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
                        let name = "vid-\(fileIdx).\(ext)"; fileIdx += 1
                        if let dst = ShareInbox.fileURL(name) {
                            try? FileManager.default.removeItem(at: dst)
                            try? FileManager.default.copyItem(at: src, to: dst)
                            payload.items.append(.init(kind: .video, file: name))
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadData(provider, UTType.image.identifier) {
                        let name = "img-\(fileIdx).dat"; fileIdx += 1
                        if let dst = ShareInbox.fileURL(name) {
                            try? data.write(to: dst)
                            payload.items.append(.init(kind: .image, file: name))
                        }
                    }
                } else if let type = fileType(of: provider) {
                    if let item = await stashDocument(provider, type: type, index: &fileIdx) {
                        payload.items.append(item)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(provider) {
                        payload.items.append(.init(kind: .text, text: url.absoluteString))
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    if let s = await loadText(provider), !s.isEmpty {
                        payload.items.append(.init(kind: .text, text: s))
                    }
                }
            }
        }
        ShareInbox.writePayload(payload)
        await MainActor.run { openHost() }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The `dm:` circle id behind a tapped conversation suggestion, if the share sheet started us
    /// from one. Anything that isn't one of our donated DM ids is ignored — the app falls back to
    /// the normal "where should this go" sheet rather than trusting a foreign identifier.
    private func chosenConversationId() -> String? {
        guard let intent = extensionContext?.intent as? INSendMessageIntent,
              let id = intent.conversationIdentifier, id.hasPrefix("dm:") else { return nil }
        return id
    }

    /// The type identifier to pull a *document* out of this provider with, or nil when it isn't a
    /// document at all. `public.file-url` first (it names a real file on disk), then anything that
    /// is `public.data`-backed — PDFs, zips, .docx, source files, whatever the source app vends.
    private func fileType(of p: NSItemProvider) -> String? {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return UTType.fileURL.identifier }
        // A web link is a link, not a download: it conforms to public.url but never to
        // public.file-url, and it belongs in the message body.
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) { return nil }
        // Plain text also conforms to public.data; let the text branch keep it so a shared snippet
        // stays a message body instead of becoming a .txt attachment.
        if p.hasItemConformingToTypeIdentifier(UTType.text.identifier) { return nil }
        if p.hasItemConformingToTypeIdentifier(UTType.data.identifier) { return UTType.data.identifier }
        return nil
    }

    /// Copy a shared document into the App Group inbox under a collision-proof name, remembering the
    /// name the source app gave it so the attachment arrives called what the sender saw.
    private func stashDocument(_ p: NSItemProvider, type: String, index: inout Int) async
        -> ShareInbox.Item?
    {
        // A `public.file-url` provider vends the URL itself; everything else is pulled as a file
        // representation. Going through `loadFileRepresentation` for a file-url is not reliable —
        // ask for what the provider actually registered.
        let src: URL?
        if type == UTType.fileURL.identifier {
            let vended = await loadURL(p)
            src = copyOutOfPlace(vended)
        } else {
            src = await loadFile(p, type)
        }
        guard let src else { return nil }
        defer { try? FileManager.default.removeItem(at: src) }
        let original = p.suggestedName ?? src.lastPathComponent
        let ext = src.pathExtension
        let stored = "doc-\(index)" + (ext.isEmpty ? "" : ".\(ext)")
        index += 1
        guard let dst = ShareInbox.fileURL(stored) else { return nil }
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: src, to: dst) } catch { return nil }
        return .init(kind: .file, file: stored, name: original)
    }

    // MARK: - Provider loaders

    private func loadData(_ p: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { cont in
            p.loadDataRepresentation(forTypeIdentifier: type) { d, _ in cont.resume(returning: d) }
        }
    }

    private func loadFile(_ p: NSItemProvider, _ type: String) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                // The vended URL is reclaimed when this callback returns — copy out first.
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dest)
                cont.resume(returning: dest)
            }
        }
    }

    /// Copy a vended file URL into our own temp dir under security scope. The original may live in
    /// another app's container and is only readable for the length of this call.
    private func copyOutOfPlace(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        return dest
    }

    private func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }

    private func loadText(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.text.identifier) { item, _ in
                cont.resume(returning: (item as? String) ?? (item as? NSString) as String?)
            }
        }
    }

    /// Open the host app. Extensions can't touch `UIApplication.shared`, so walk the responder chain
    /// for an object that implements `openURL:`.
    private func openHost() {
        guard let url = URL(string: "haven://share") else { return }
        let sel = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: sel) { _ = r.perform(sel, with: url); return }
            responder = r.next
        }
    }
}
