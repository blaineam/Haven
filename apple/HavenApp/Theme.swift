import SwiftUI

/// Haven's design system — the single source of brand color, depth, motion, and
/// tactile feel. Keeping it here makes the look consistent and portable to other
/// platforms' UIs.
enum HavenTheme {
    static let violet = Color(red: 0.486, green: 0.227, blue: 0.929) // #7C3AED
    static let pink = Color(red: 0.925, green: 0.282, blue: 0.600)   // #EC4899
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)  // #F59E0B

    /// The signature sunset gradient (matches the app icon).
    static let brand = LinearGradient(
        colors: [violet, pink, amber],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let brandHorizontal = LinearGradient(
        colors: [violet, pink, amber],
        startPoint: .leading, endPoint: .trailing
    )

    // Motion vocabulary — a small set of springs used everywhere for cohesion.
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)
    static let smooth = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
}

/// Soft branded backdrop: grouped-background base with two gentle brand glows.
struct HavenBackground: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(
                colors: [HavenTheme.pink.opacity(0.22), .clear],
                center: UnitPoint(x: 0.85, y: -0.05), startRadius: 0, endRadius: 460
            )
            RadialGradient(
                colors: [HavenTheme.violet.opacity(0.20), .clear],
                center: UnitPoint(x: 0.05, y: 0.18), startRadius: 0, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

/// A floating, slightly-bordered card with soft depth.
struct HavenCard: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
    }
}

extension View {
    func havenCard(padding: CGFloat = 18) -> some View { modifier(HavenCard(padding: padding)) }
}

/// Tactile press feedback: gentle scale + dim on press.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(HavenTheme.snappy, value: configuration.isPressed)
    }
}

/// Icon buttons: on macOS a modern circular GLASS chip (material + hairline ring + press
/// feedback) — the platform's default chrome rendered bare `Image` buttons as barely-visible
/// rounded rectangles. On iOS the label passes through untouched (toolbars already tint glyphs
/// correctly there, and the shipped look must not shift).
struct HavenGlassIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 34, height: 34)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(HavenTheme.snappy, value: configuration.isPressed)
        #else
        configuration.label
        #endif
    }
}

/// A prominent brand-gradient pill button.
struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(HavenTheme.brandHorizontal, in: Capsule())
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(color: HavenTheme.pink.opacity(0.35), radius: 10, x: 0, y: 5)
            .animation(HavenTheme.snappy, value: configuration.isPressed)
    }
}

/// The Haven mark: a little constellation of connected people (matches the app icon).
struct ConstellationMark: View {
    var color: Color = .white
    private let nodes: [CGPoint] = [
        CGPoint(x: 50, y: 53), CGPoint(x: 50, y: 24), CGPoint(x: 23, y: 46),
        CGPoint(x: 77, y: 46), CGPoint(x: 34, y: 75), CGPoint(x: 66, y: 75),
    ]
    private let edges = [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (1, 2), (1, 3), (2, 4), (3, 5)]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 100
            ZStack {
                Path { p in
                    for (a, b) in edges {
                        p.move(to: pt(nodes[a], s)); p.addLine(to: pt(nodes[b], s))
                    }
                }
                .stroke(color.opacity(0.65), lineWidth: 1.6 * s)
                ForEach(nodes.indices, id: \.self) { i in
                    let r = (i == 0 ? 7.0 : 5.0) * s
                    Circle().fill(color).frame(width: r * 2, height: r * 2).position(pt(nodes[i], s))
                }
            }
        }
    }
    private func pt(_ p: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
}

/// Gradient title text helper.
struct BrandText: View {
    let text: String
    var font: Font = .largeTitle.bold()
    var body: some View {
        Text(text).font(font).foregroundStyle(HavenTheme.brand)
    }
}
