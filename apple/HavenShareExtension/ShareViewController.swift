import AVFoundation
import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Haven's share extension: it shows a compose screen, extracts the shared text / link / photo /
/// video / document into the App Group inbox, records where the user wants it to go, and lets the
/// app perform the sealed send.
///
/// **Why it has UI now.** It used to extract, call `openURL` through the responder chain, and
/// complete immediately — so tapping Haven in the share sheet looked like the sheet simply closing.
/// That trick is not a supported way for an extension to launch its host app and cannot be relied
/// on; when it fails there is no feedback at all. Drawing the composer here means the tap always
/// opens something, and the hand-off stops being load-bearing for the UX.
///
/// **Why it still doesn't send.** No identity, no engine, and seconds to live — this process cannot
/// seal and deliver a message. What it writes is a decision; `ShareRouter.ingest` acts on it as soon
/// as the app is frontmost. We still try to open the app so that's immediate, but if the open is
/// refused the share is queued rather than lost, and the composer says so.
///
/// When the user taps one of Haven's **conversation suggestions** in the share sheet's top row, iOS
/// hands us the `INSendMessageIntent` we donated for that thread (see `ShareSuggestions.swift`);
/// its `conversationIdentifier` is the `dm:` circle id, which preselects that conversation here.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var extracted = ShareInbox.Payload()
    private var previews: [UIImage] = []
    /// This share's own directory in the App Group queue.
    private var shareId = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task {
            await process()
            presentComposer()
        }
    }

    /// Swap the blank placeholder for the composer once the attachments are on disk. Extraction is
    /// fast for a photo and slow for a long video, so the UI waits on it rather than showing a
    /// picker for content that might still fail to copy.
    private func presentComposer() {
        let root = ShareComposeView(
            previews: previews,
            attachmentCount: extracted.items.filter { $0.kind != .text }.count,
            sharedText: extracted.items.first(where: { $0.kind == .text })?.text ?? "",
            preselected: extracted.targetCircleId.isEmpty ? nil : extracted.targetCircleId,
            onSend: { [weak self] route, target, caption in
                self?.finish(route: route, target: target, caption: caption)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                // Throw away only THIS share's directory — other queued shares are not ours to drop.
                ShareInbox.discard(self.shareId)
                self.extensionContext?.completeRequest(returningItems: nil)
            })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Commit the decision and get out of the way.
    private func finish(route: ShareInbox.Route, target: String, caption: String) {
        extracted.route = route
        extracted.targetCircleId = target
        extracted.caption = caption
        ShareInbox.commit(extracted, in: shareId)
        ShareInbox.sweepAbandoned()   // tidy anything a previous cancel left mid-extraction
        openHost { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func process() async {
        shareId = ShareInbox.begin()
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
                        if let dst = ShareInbox.fileURL(name, in: shareId) {
                            try? FileManager.default.removeItem(at: dst)
                            try? FileManager.default.copyItem(at: src, to: dst)
                            payload.items.append(.init(kind: .video, file: name))
                            if let poster = videoPoster(dst) { addPreview(poster) }
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await loadData(provider, UTType.image.identifier) {
                        let name = "img-\(fileIdx).dat"; fileIdx += 1
                        if let dst = ShareInbox.fileURL(name, in: shareId) {
                            try? data.write(to: dst)
                            payload.items.append(.init(kind: .image, file: name))
                            if let thumb = UIImage(data: data) { addPreview(thumb) }
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
        // Held in memory, not written yet: the payload is only committed once the user taps Send.
        // Writing here would leave the app a share to deliver even if they cancelled.
        extracted = payload
    }

    /// Downscaled thumbnails for the composer. Capped — a 10-photo share should not hold ten
    /// full-resolution bitmaps in an extension's small memory budget just to draw 64pt tiles.
    private func addPreview(_ image: UIImage) {
        guard previews.count < 10 else { return }
        let side: CGFloat = 200
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        previews.append(small)
    }

    /// First frame of a shared clip, so a video tile shows the video rather than a grey box.
    private func videoPoster(_ url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
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
        guard let dst = ShareInbox.fileURL(stored, in: shareId) else { return nil }
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
    /// Ask iOS to bring Haven up so the share is delivered now instead of on the user's next launch.
    ///
    /// **The responder-chain walk goes FIRST, synchronously, because it is the one that works here.**
    /// A previous build led with `NSExtensionContext.open` — the supported call — and completed the
    /// request on the very next line. `open` is asynchronous, so tearing the context down
    /// immediately meant its completion handler never ran, the fallback never fired, and nothing
    /// launched at all: a share that used to open Haven stopped doing anything. `open` is still
    /// tried, but only as the backstop, and the request is completed from its callback.
    ///
    /// Neither route is guaranteed — a share extension is not entitled to launch its host app — so
    /// the share is committed to the queue BEFORE any of this. Delivery never depends on it.
    private func openHost(then done: @escaping () -> Void) {
        guard let url = URL(string: "haven://share") else { done(); return }
        if openHostViaResponderChain(url) { done(); return }
        guard let context = extensionContext else { done(); return }
        // Nothing on the chain answered — try the official call and complete only once it reports
        // back, so we don't repeat the mistake of killing the context mid-flight.
        var finished = false
        context.open(url) { _ in
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async(execute: done)
        }
        // …and don't hang the sheet open forever if it never calls back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !finished else { return }
            finished = true
            done()
        }
    }

    @discardableResult
    private func openHostViaResponderChain(_ url: URL) -> Bool {
        let sel = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: sel) { _ = r.perform(sel, with: url); return true }
            responder = r.next
        }
        return false
    }
}
