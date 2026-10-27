import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure decisions behind the CarPlay avatar bitmaps: WHICH avatar a row gets, and the geometry that
/// makes a square, aspect-FILL, circle-masked image. Foundation-only so the rules are unit-tested on
/// the host; `CarPlayAvatarRenderer` (UIKit) turns a `Spec` into pixels.
///
/// CarPlay draws a `CPMessageListItem` leading image exactly as given (scaled down if larger than
/// `CPMaximumMessageItemImageSize`) - it applies no circle mask and no aspect fill. A raw contact photo
/// therefore appeared as an uncropped rectangle; we bake the circle and the fill into the bitmap.
enum CarPlayAvatar {
    enum Spec: Equatable {
        /// The person's own photo.
        case photo
        /// Their profile emoji on a palette-tinted circle.
        case emoji(String)
        /// Up to two initials on a palette-tinted circle.
        case initials(String)
        /// Neutral silhouette-less disc: no identity at all. Used for locked and minimal-privacy rows.
        case generic
    }

    /// The avatar a row may show. Locked conversations and the Minimal privacy level reveal nothing
    /// about who this is (the banner for Minimal says only "Haven"), so they get the generic disc.
    /// Otherwise: photo, else emoji, else initials, else generic.
    static func choose(locked: Bool, detail: SharedNotificationPrivacy.Detail, hasPhoto: Bool,
                       emoji: String?, name: String) -> Spec {
        if locked || detail == .minimal { return .generic }
        if hasPhoto { return .photo }
        if let e = emoji.flatMap(firstEmoji) { return .emoji(e) }
        let i = initials(name)
        return i.isEmpty ? .generic : .initials(i)
    }

    // MARK: Text

    /// First emoji grapheme in `s`, if any. Digits and '#'/'*' are "emoji" to Unicode but not to people.
    static func firstEmoji(_ s: String) -> String? {
        s.first { isEmoji($0) }.map(String.init)
    }

    static func isEmoji(_ c: Character) -> Bool {
        guard let first = c.unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && first.value > 0x238C   // skips 0-9 # * (c) (r)
    }

    /// "Tracy Miller" -> "TM", "Tracy" -> "T", "Alice, Bob & Carol" -> "AC", "Maya 🌿" -> "M",
    /// "田中太郎" -> "田", "🌿" -> "".
    static func initials(_ name: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "&,+/"))
        let tokens = name.components(separatedBy: separators).compactMap { token -> String? in
            let letters = token.filter { $0.isLetter && !isEmoji($0) }
            return letters.isEmpty ? nil : String(letters)
        }
        guard let first = tokens.first else { return "" }
        let a = String(first.prefix(1))
        guard tokens.count > 1, let last = tokens.last else { return a.uppercased() }
        return (a + String(last.prefix(1))).uppercased()
    }

    // MARK: Geometry

    /// Side of the square canvas: the largest square CarPlay will not rescale.
    static func side(max size: CGSize) -> CGFloat { Swift.max(1, Swift.min(size.width, size.height)) }

    /// Where to draw a `source`-sized image on a `side` x `side` canvas so it FILLS the square (aspect
    /// preserved, overflow cropped equally on both axes, centred).
    static func fillRect(source: CGSize, side: CGFloat) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(x: 0, y: 0, width: side, height: side) }
        let scale = Swift.max(side / source.width, side / source.height)
        let w = source.width * scale, h = source.height * scale
        return CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
    }

    /// Stable palette stop (0...2) for an id, so a person keeps one colour across launches. FNV-1a, not
    /// `hashValue` (which is randomised per process).
    static func tintIndex(_ id: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % 3)
    }

    /// Cache key: everything that changes the pixels.
    static func cacheKey(id: String, spec: Spec, side: CGFloat, scale: CGFloat, paletteId: String, photoStamp: Int) -> String {
        let s: String
        switch spec {
        case .photo: s = "p\(photoStamp)"
        case .emoji(let e): s = "e\(e)"
        case .initials(let i): s = "i\(i)"
        case .generic: s = "g"
        }
        return "\(id)|\(s)|\(Int(side * 100))|\(Int(scale * 100))|\(paletteId)"
    }
}
