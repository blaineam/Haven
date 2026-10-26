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
}
