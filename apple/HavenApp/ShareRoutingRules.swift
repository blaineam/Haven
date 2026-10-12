import Foundation

/// The decisions behind `ShareRouter` (a share handed over by the Share Extension), without the
/// engine, the media store or SwiftUI: how text items merge, how the caption and text become a body,
/// where each route goes, which suggested thread is still honourable, and how an attachment is named.
/// Foundation only so the whole table is covered by the host-less logic tests.
enum ShareRoutingRules {
    /// Where a decided share goes. `post` and `story` open Haven's own composers (circle picker,
    /// music, location, story layout all live there); only `dm` can be finished without the user.
    enum Delivery: Equatable {
        case askUser
        case storyEditor
        case feedComposer
        case directMessage
    }

    static func delivery(for route: ShareInbox.Route) -> Delivery {
        switch route {
        case .undecided: return .askUser
        case .story: return .storyEditor
        case .post: return .feedComposer
        case .dm: return .directMessage
        }
    }

    /// Text items join with a newline, in arrival order; an empty accumulator takes the first as-is.
    static func appendText(_ existing: String, _ next: String) -> String {
        existing.isEmpty ? next : existing + "\n" + next
    }

    /// The caption typed in the extension, then the shared text, each trimmed, blanks dropped.
    static func body(caption: String, text: String) -> String {
        [caption, text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// A share with neither text nor any imported media has nothing to deliver and is dropped
    /// (rather than retried forever).
    static func hasContent(text: String, importedCount: Int) -> Bool {
        !text.isEmpty || importedCount > 0
    }

    /// A DM destination is honoured only if the thread still exists on this device and is not
    /// biometric-locked — a stale donation falls back to the normal sheet.
    static func isDeliverableDM(_ id: String, existingCircleIds: [String], locked: Bool) -> Bool {
        existingCircleIds.contains(id) && !locked
    }

    /// The suggested thread, or nil when it is not a DM id, no longer exists, or is locked.
    static func validThread(_ id: String, dmCircleIds: [String], locked: Bool) -> String? {
        guard id.hasPrefix("dm:"), dmCircleIds.contains(id), !locked else { return nil }
        return id
    }

    /// `MediaStore.addFile` derives the attachment's name from the file on disk, and the inbox name
    /// is a collision-proof placeholder (`doc-0.pdf`). This is the sender's own filename to put back,
    /// or nil when there is nothing to rename (blank, or identical to what is already on disk).
    static func attachmentName(original: String, storedName: String) -> String? {
        let clean = original
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != storedName else { return nil }
        return clean
    }

    /// The staged-file name used for a document handed over under its original name. The prefix
    /// keeps two shares of `report.pdf` from colliding in the temp directory.
    static func stagedAttachmentName(original clean: String, uniquifier: String) -> String {
        "\(uniquifier.prefix(8))-\(clean)"
    }
}
