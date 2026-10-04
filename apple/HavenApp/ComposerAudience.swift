import Foundation

/// Who a circle post (or a reply on one) actually reaches — said by the composer itself.
///
/// Why this exists: people posted private things to the WHOLE circle believing they were writing to
/// one person. So the feed composer's own form says it: the placeholder names the circle ("Post to
/// everyone in Family"), the send control is a labeled "Post" pill (not the DM paper plane), and a
/// reply field reads "Reply to everyone in Family…". Passive cues only — no audience menu and no
/// "are you sure?" step in front of a post.
enum ComposerAudience {
    /// Feed composer placeholder: names the circle when it fits, else the plain "Post to everyone…".
    static func postPlaceholder(_ circle: String) -> String {
        circle.count <= 14
            ? String(localized: "Post to everyone in \(circle)")
            : String(localized: "Post to everyone…")
    }

    /// Reply placeholder: names the circle when it fits, else the plain "Reply to everyone…".
    static func replyPlaceholder(_ circle: String) -> String {
        circle.count <= 14
            ? String(localized: "Reply to everyone in \(circle)…")
            : String(localized: "Reply to everyone…")
    }
}
