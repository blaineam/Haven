#if os(iOS)
import UIKit

/// Draws the CarPlay avatar bitmaps decided by `CarPlayAvatar`: square canvas, circle mask, photo
/// aspect-FILLED, or emoji / initials on a palette-tinted gradient disc. Pure drawing - safe off the
/// main thread (UIGraphicsImageRenderer) - plus a small cache so a refresh doesn't redraw every row.
final class CarPlayAvatarRenderer: @unchecked Sendable {
    static let shared = CarPlayAvatarRenderer()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 64 }

    /// `stops` are the active palette's three 0xRRGGBB stops.
    func image(for spec: CarPlayAvatar.Spec, photo: UIImage?, photoStamp: Int, id: String,
               side: CGFloat, scale: CGFloat, paletteId: String, stops: [UInt32]) -> UIImage {
        let key = CarPlayAvatar.cacheKey(id: id, spec: spec, side: side, scale: scale, paletteId: paletteId,
                                         photoStamp: photoStamp) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = draw(spec, photo: photo, id: id, side: side, scale: scale, stops: stops)
        cache.setObject(img, forKey: key)
        return img
    }

    func drop() { cache.removeAllObjects() }

    private func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    private func draw(_ spec: CarPlayAvatar.Spec, photo: UIImage?, id: String, side: CGFloat, scale: CGFloat,
                      stops: [UInt32]) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size, format: fmt).image { ctx in
            UIBezierPath(ovalIn: rect).addClip()
            if case .photo = spec, let photo {
                photo.draw(in: CarPlayAvatar.fillRect(source: photo.size, side: side))
                return
            }
            // Tinted disc: this person's stable stop -> the next, so neighbours differ but stay on palette.
            let i = CarPlayAvatar.tintIndex(id)
            let a = color(stops.indices.contains(i) ? stops[i] : 0x737373)
            let b = color(stops.indices.contains((i + 1) % 3) ? stops[(i + 1) % 3] : 0xA3A3A3)
            if case .generic = spec {
                UIColor(white: 0.45, alpha: 1).setFill()
                ctx.fill(rect)
                return
            }
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space, colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            let text: String, size: CGFloat
            switch spec {
            case .emoji(let e): text = e; size = side * 0.52
            case .initials(let s): text = s; size = side * 0.42
            default: return
            }
            let str = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: UIColor.white,
            ])
            let box = str.size()
            str.draw(at: CGPoint(x: (side - box.width) / 2, y: (side - box.height) / 2))
        }
    }
}
#endif
