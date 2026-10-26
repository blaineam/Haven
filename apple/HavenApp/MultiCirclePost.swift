import Foundation

/// Which circles a post goes to. Pure so it is unit-testable.
enum MultiCirclePost {
    /// The circles to author into: the picked set (never empty, never repeating), else just the active circle.
    /// The active circle always leads so its post appears first.
    static func targets(picked: [String]?, active: String) -> [String] {
        guard let picked, !picked.isEmpty else { return [active] }
        var seen = Set<String>()
        let ordered = ([active] + picked).filter { picked.contains($0) && seen.insert($0).inserted }
        return ordered.isEmpty ? [active] : ordered
    }

    static func buttonTitle(count: Int) -> String {
        count == 1 ? String(localized: "Post to 1 circle") : String(localized: "Post to \(count) circles")
    }

    /// Media (photo, video, file, voice) is sealed to ONE circle's key when it is stored, and the sealed
    /// copy is cached per file — so a second circle would get a blob its members cannot open, and the two
    /// uploads would clash on the shared content-addressed key. Until media is sealed per circle, a post with
    /// an attachment can only go to the circle it was composed in; text, songs and locations can go anywhere.
    static func lockedToActive(attachedMedia: [String], isSynthetic: (String) -> Bool) -> Bool {
        attachedMedia.contains { !isSynthetic($0) }
    }
}
