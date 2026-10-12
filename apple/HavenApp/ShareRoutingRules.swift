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

    // MARK: Queue draining

    /// Wait-and-retry rule for a share that arrives before the engine / tab UI exist (a cold launch,
    /// where `onOpenURL` fires before the identity is configured). Draining then would consume the
    /// share and lose the message, so wait — but only when something is actually queued, and only a
    /// bounded number of times, so a device that never configures (no identity yet) doesn't spin.
    static func shouldRetryLater(queued: Int, retriesLeft: Int) -> Bool {
        queued > 0 && retriesLeft > 0
    }

    static let maxReadinessRetries = 10
    static let readinessRetryDelayNs: UInt64 = 1_500_000_000
}

/// What importing one queued share resulted in.
enum ShareConsumeOutcome: Equatable {
    /// Delivered (or nothing usable): the queue entry is finished.
    case done
    /// It is on screen and the router holds the content now; the entry has done its job.
    case needsUser
    /// Nothing was delivered and nothing is on screen: KEEP it. Better a share that arrives late than
    /// one that quietly never arrives.
    case retry
}

enum ShareDrain {
    /// Drain `queue` oldest-first. Every share is processed, not just the newest: a share that only
    /// needs sending goes out immediately and silently; the first one that needs the user, needs the
    /// user, so anything after it stays queued for the next pass rather than fighting over one sheet.
    /// `isBlocked` is checked BEFORE each entry — a composer already up (the sheet, the story editor,
    /// the feed's own with a handed-over draft) must not be clobbered with unsent work.
    @MainActor
    static func run<Q>(_ queue: [Q],
                       isBlocked: () -> Bool,
                       consume: (Q) async -> ShareConsumeOutcome,
                       clear: (Q) -> Void) async {
        for queued in queue {
            if isBlocked() { return }
            switch await consume(queued) {
            case .done:
                clear(queued)
            case .needsUser:
                clear(queued)
                return
            case .retry:
                return
            }
        }
    }
}
