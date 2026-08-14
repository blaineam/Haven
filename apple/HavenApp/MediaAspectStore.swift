import Foundation
import CoreGraphics

/// Remembers the shape of a piece of media, so a post's height never changes after it is first laid out.
///
/// A feed card's height comes from its media's aspect ratio, and that used to be answered from
/// whatever happened to be on disk at the moment of the render: the true shape when the bytes were
/// there, a 4:3 guess when they were not. So a card drew short, then grew when its thumbnail
/// arrived, then possibly grew again — and every one of those changes pushed the cards below it
/// down. When that happens ABOVE what someone is reading, the page appears to jump under them.
///
/// It is at its worst exactly when the feed is busiest — an import writing hundreds of files, a
/// mailbox pull, a new member backfilling history — which is why the feed felt unusable then.
///
/// One value per ref, written the first time the real shape is known and never contradicted after.
@MainActor
final class MediaAspectStore {
    static let shared = MediaAspectStore()

    private static let key = "haven.media.aspects"
    /// Bounded: this is a layout hint, not a record. Old entries lose nothing but a first render.
    private static let maxEntries = 4000

    private var aspects: [String: Double]
    private var saveScheduled = false

    private init() {
        aspects = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
    }

    func aspect(_ ref: String) -> CGFloat? {
        guard let a = aspects[ref], a > 0 else { return nil }
        return CGFloat(a)
    }

    /// First writer wins. A later reading is not more correct — it is the same picture — and letting
    /// it overwrite would reintroduce the height change this exists to prevent.
    func record(_ ref: String, aspect: CGFloat) {
        guard aspect > 0, aspects[ref] == nil else { return }
        aspects[ref] = Double(aspect)
        if aspects.count > Self.maxEntries {
            aspects = Dictionary(uniqueKeysWithValues: Array(aspects.suffix(Self.maxEntries / 2)))
        }
        scheduleSave()
    }

    /// Coalesced: an import records hundreds of these in a burst, and a UserDefaults write per photo
    /// would be its own source of jank.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveScheduled = false
            UserDefaults.standard.set(aspects, forKey: Self.key)
        }
    }
}
