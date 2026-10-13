import CoreGraphics

/// How wide the main post feed's single column may be. The feed stays ONE column (the centered-media
/// audio-autoplay logic depends on it), but on wide canvases (iPad, a Mac window, a folded-open
/// dual-screen phone) a full-width post makes every image/video enormous and forces constant scrolling.
/// Above `maxColumn` the column is capped and centered; at or below it nothing changes, so phones are
/// untouched. Decided from the width the view is GIVEN, never from a size class.
enum FeedColumnWidth {
    /// Comfortable reading/media width in points. Keep in sync with Android/desktop (600dp / 600px).
    static let maxColumn: CGFloat = 600

    /// The width the column should occupy inside `available` points.
    static func column(forAvailable available: CGFloat) -> CGFloat {
        guard available.isFinite, available > 0 else { return maxColumn }
        return min(available, maxColumn)
    }

    /// True when the canvas is wide enough that the cap actually bites.
    static func isCapped(forAvailable available: CGFloat) -> Bool { available > maxColumn }
}
