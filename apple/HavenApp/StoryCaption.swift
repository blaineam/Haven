import SwiftUI

/// Instagram-style story captions: pick a color, cycle typography, and cycle a "style" —
/// plain, glow, shadow, neon, or a per-line highlight. The choice is encoded into the story
/// body so every viewer renders it identically.
enum StoryCaptions {
    static let colors: [Color] = [
        .white, .black, HavenTheme.pink, HavenTheme.violet, HavenTheme.amber,
        .red, .orange, .green, .blue, .cyan, .yellow, .mint,
    ]
    /// Typography choices (design + weight); the point size is scaled by `Spec.size`.
    static let fontStyles: [(design: Font.Design, weight: Font.Weight)] = [
        (.default, .bold), (.serif, .bold), (.rounded, .heavy), (.monospaced, .bold), (.default, .black),
    ]
    static let minSize = 0.6
    static let maxSize = 1.9

    /// The "highlight" styles the user toggles through (like the font cycle).
    enum Style: Int, CaseIterable {
        case plain      // colored text, subtle shadow for legibility
        case glow       // colored text with a soft glow in its own color
        case shadow     // colored text with a strong drop shadow
        case neon       // bright text with a double colored glow
        case highlight  // color block behind the text, hugging each line

        var label: String {
            switch self {
            case .plain: return "Plain"
            case .glow: return "Glow"
            case .shadow: return "Shadow"
            case .neon: return "Neon"
            case .highlight: return "Highlight"
            }
        }
        var icon: String {
            switch self {
            case .plain: return "textformat"
            case .glow: return "sun.max"
            case .shadow: return "shadow"
            case .neon: return "sparkles"
            case .highlight: return "highlighter"
            }
        }
    }

    struct Spec: Equatable {
        var color = 0
        var font = 0
        var styleRaw = Style.glow.rawValue
        /// Normalized caption position (0…1) so the viewer renders it where the author
        /// dragged it. Defaults to centred.
        var x = 0.5
        var y = 0.5
        /// Caption size scale the author sets while composing (base 28pt × size).
        var size = 1.0
        /// How the author framed the media in the story: a zoom scale and a normalized
        /// translation (fraction of the canvas). Travels so viewers see the same framing
        /// without re-encoding the photo/video.
        var mediaScale = 1.0
        var mediaOffX = 0.0
        var mediaOffY = 0.0
        /// Rotation the author applied while framing, in RADIANS. Travels with the scale and offset so
        /// a viewer sees the same composition. Pairs with scales BELOW 1: shrinking a landscape photo
        /// and tilting it slightly is how it sits over the blurred backdrop instead of being cropped
        /// to a portrait keyhole.
        var mediaRotation = 0.0

        var style: Style { Style(rawValue: styleRaw) ?? .glow }
        var hasMediaTransform: Bool {
            mediaScale != 1.0 || mediaOffX != 0 || mediaOffY != 0 || mediaRotation != 0
        }
        mutating func cycleFont() { font = (font + 1) % fontStyles.count }
        mutating func cycleStyle() { styleRaw = (styleRaw + 1) % Style.allCases.count }
    }

    static func textColor(_ s: Spec) -> Color { s.style == .highlight ? contrast(s.color) : colors[idx(s.color)] }
    static func bgColor(_ s: Spec) -> Color? { s.style == .highlight ? colors[idx(s.color)] : nil }
    static func font(_ s: Spec) -> Font {
        let style = fontStyles[min(max(0, s.font), fontStyles.count - 1)]
        return .system(size: 28 * s.size, weight: style.weight, design: style.design)
    }

    private static func idx(_ i: Int) -> Int { min(max(0, i), colors.count - 1) }
    private static func contrast(_ i: Int) -> Color {
        // Light highlight colors get dark text; everything else gets white.
        [0, 9, 10, 11].contains(idx(i)) ? .black : .white   // white, cyan, yellow, mint
    }

    static func encode(_ caption: String, _ s: Spec) -> String {
        let t = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // Encode even with no caption when the author reframed the media (so the zoom travels).
        guard !t.isEmpty || s.hasMediaTransform else { return "" }
        // color,font,style,x,y,size,mediaScale,mediaOffX,mediaOffY,mediaRotation
        // Rotation is APPENDED, so a client that only knows the 9-field form reads everything it
        // understands and ignores the tail rather than failing to decode the story at all.
        let extra = String(format: "%.3f,%.3f,%.3f,%.3f,%.4f,%.4f,%.4f",
                           s.x, s.y, s.size, s.mediaScale, s.mediaOffX, s.mediaOffY, s.mediaRotation)
        return "\u{1}\(s.color),\(s.font),\(s.styleRaw),\(extra)\u{1}\(t)"
    }
    /// Was this story COMPOSED IN HAVEN?
    ///
    /// The composer always encodes a spec — it carries the media framing even when there is no
    /// caption — so the marker's presence is a reliable "an author framed this against our canvas".
    /// A story that arrived any other way (an Instagram import) never was, which is the difference
    /// that decides whether the viewer may crop it. See `StoryViewer.fillsCanvas`.
    static func hasSpec(_ body: String) -> Bool { body.hasPrefix("\u{1}") }

    static func decode(_ body: String) -> (text: String, spec: Spec) {
        if body.hasPrefix("\u{1}") {
            let parts = body.dropFirst().split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                let n = parts[0].split(separator: ",")
                if n.count >= 3, let c = Int(n[0]), let f = Int(n[1]), let st = Int(n[2]) {
                    // Back-compat: older stories stored a 0/1 highlight bit here (exactly 6 fields).
                    let styleRaw = (st == 0 || st == 1) && n.count == 6 ? (st == 1 ? Style.highlight.rawValue : Style.glow.rawValue) : st
                    var spec = Spec(color: c, font: f, styleRaw: styleRaw)
                    if n.count >= 5, let x = Double(n[3]), let y = Double(n[4]) { spec.x = x; spec.y = y }
                    if n.count >= 6, let sz = Double(n[5]) { spec.size = sz }
                    if n.count >= 9, let ms = Double(n[6]), let mx = Double(n[7]), let my = Double(n[8]) {
                        spec.mediaScale = ms; spec.mediaOffX = mx; spec.mediaOffY = my
                    }
                    if n.count >= 10, let rot = Double(n[9]) { spec.mediaRotation = rot }
                    return (String(parts[1]), spec)
                }
            }
        }
        return (body, Spec())
    }
}

/// Renders a caption in its chosen style. For the highlight style each line gets its own
/// background hugging that line's text (not a single block spanning the full width).
struct StyledCaption: View {
    let text: String
    let spec: StoryCaptions.Spec

    var body: some View {
        Group {
            if spec.style == .highlight {
                highlighted
            } else {
                styledText(Text(text.isEmpty ? " " : text))
            }
        }
        .font(StoryCaptions.font(spec))
        .multilineTextAlignment(.center)
    }

    /// Per-line highlight: split on line breaks and give each line its own hugging pill.
    private var highlighted: some View {
        let lines = (text.isEmpty ? " " : text).components(separatedBy: "\n")
        let bg = StoryCaptions.bgColor(spec) ?? .clear
        return VStack(spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .foregroundStyle(StoryCaptions.textColor(spec))
                    .fixedSize(horizontal: true, vertical: false)   // hug the line's text width
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
            }
        }
    }

    /// Apply the non-highlight styling (color + glow/shadow) to the text.
    @ViewBuilder private func styledText(_ t: Text) -> some View {
        let color = StoryCaptions.textColor(spec)
        switch spec.style {
        case .plain:
            t.foregroundStyle(color).shadow(color: .black.opacity(0.5), radius: 4)
        case .glow:
            t.foregroundStyle(color).shadow(color: color.opacity(0.9), radius: 8)
                .shadow(color: .black.opacity(0.35), radius: 3)
        case .shadow:
            t.foregroundStyle(color).shadow(color: .black.opacity(0.85), radius: 2, x: 1.5, y: 2)
        case .neon:
            t.foregroundStyle(color)
                .shadow(color: color, radius: 6).shadow(color: color, radius: 14)
                .shadow(color: .black.opacity(0.3), radius: 2)
        case .highlight:
            t.foregroundStyle(color)   // handled by `highlighted`, but keep total
        }
    }
}

/// A row of color dots for the composer.
struct CaptionColorRow: View {
    @Binding var spec: StoryCaptions.Spec
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(StoryCaptions.colors.enumerated()), id: \.offset) { i, c in
                    Button { spec.color = i } label: {
                        Circle().fill(c).frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(.white, lineWidth: spec.color == i ? 3 : 1))
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// The glow/shadow/neon look for a caption, as a reusable modifier so the live editor preview and
/// the final `StyledCaption` render identically (#88). Mirrors `StyledCaption.styledText`'s shadows.
struct CaptionStyleEffect: ViewModifier {
    let spec: StoryCaptions.Spec
    func body(content: Content) -> some View {
        let color = StoryCaptions.textColor(spec)
        switch spec.style {
        case .plain:
            content.shadow(color: .black.opacity(0.5), radius: 4)
        case .glow:
            content.shadow(color: color.opacity(0.9), radius: 8).shadow(color: .black.opacity(0.35), radius: 3)
        case .shadow:
            content.shadow(color: .black.opacity(0.85), radius: 2, x: 1.5, y: 2)
        case .neon:
            content.shadow(color: color, radius: 6).shadow(color: color, radius: 14)
        case .highlight:
            content   // highlight uses per-line background pills, no text shadow
        }
    }
}
