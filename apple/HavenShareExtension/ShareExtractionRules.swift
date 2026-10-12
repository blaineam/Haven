import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The decisions the Share Extension makes about what it was handed, without NSItemProvider, UIKit or
/// the App Group: which kind of thing each attachment is (the ORDER matters), what the staged file is
/// called, how big a preview is, and which conversation a donated intent names. Lives in its own file
/// so the host-less logic tests can cover it.
enum ShareExtractionRules {
    enum ProviderKind: Equatable {
        case video
        case image
        /// A document: `typeIdentifier` is what to ask the provider for (`public.file-url` vends the
        /// URL itself; `public.data` is pulled as a file representation).
        case document(typeIdentifier: String)
        case url
        case text
        case unsupported
    }

    /// Classify one attachment from what it conforms to. Order matters, and the subtle rules are:
    ///   • concrete media before the URL/text fallback the same item may also vend, and
    ///   • `public.file-url` BEFORE `public.url` — a document shared from Files conforms to both, and the
    ///     URL branch would have turned a real attachment into a `file:///…` string nobody can open.
    static func classify(conforms: (UTType) -> Bool) -> ProviderKind {
        if conforms(.movie) { return .video }
        if conforms(.image) { return .image }
        if let doc = documentTypeIdentifier(conforms: conforms) { return .document(typeIdentifier: doc) }
        if conforms(.url) { return .url }
        if conforms(.text) { return .text }
        return .unsupported
    }

    /// The type to stash a document under, or nil when the attachment is a link / plain text / unknown.
    /// A web link conforms to `public.url` but never to `public.file-url` and belongs in the message
    /// body; plain text also conforms to `public.data` but a shared snippet should stay a message body
    /// instead of becoming a .txt attachment.
    static func documentTypeIdentifier(conforms: (UTType) -> Bool) -> String? {
        if conforms(.fileURL) { return UTType.fileURL.identifier }
        if conforms(.url) { return nil }
        if conforms(.text) { return nil }
        if conforms(.data) { return UTType.data.identifier }
        return nil
    }

    // MARK: Staged file names (collision-proof placeholders inside the share's directory)

    static func videoName(index: Int, pathExtension: String) -> String {
        "vid-\(index).\(pathExtension.isEmpty ? "mov" : pathExtension)"
    }

    /// Images are re-read as data by the app, so the extension is a neutral placeholder.
    static func imageName(index: Int) -> String { "img-\(index).dat" }

    static func documentName(index: Int, pathExtension: String) -> String {
        "doc-\(index)" + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
    }

    /// The sender's name for a document, falling back to the file's own name.
    static func originalDocumentName(suggested: String?, fileName: String) -> String { suggested ?? fileName }

    // MARK: Previews

    static let maxPreviews = 10
    static let previewSide: CGFloat = 200

    static func canAddPreview(currentCount: Int) -> Bool { currentCount < maxPreviews }

    /// Scale that fits the longer edge into `previewSide`, never enlarging.
    static func previewScale(width: CGFloat, height: CGFloat) -> CGFloat {
        min(previewSide / max(width, 1), previewSide / max(height, 1), 1)
    }

    // MARK: Donated conversation

    /// A `INSendMessageIntent` conversation identifier is honoured only if it is a DM thread id.
    static func conversationId(fromIntent id: String?) -> String? {
        guard let id, id.hasPrefix("dm:") else { return nil }
        return id
    }
}
