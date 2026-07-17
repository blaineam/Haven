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

// MARK: - Glass (Liquid Glass on OS 26+, material below)
//
// The ONE sanctioned way to put a surface behind a control. Rules of the house:
//   • never stack a second background or border on a glassed control (no doubling — a control
//     gets exactly one surface: the glass);
//   • controls are circles or pills, never bare rounded rects;
//   • any Button drawing its own circle/pill MUST use .buttonStyle(.plain) or one of the glass
//     styles below, or macOS paints its default rounded-rect bezel behind the custom shape.

extension View {
    /// One glass surface in `shape` — real Liquid Glass on macOS/iOS 26+, ultra-thin material
    /// with a hairline ring on older systems. (Insettable so the fallback can stroke a border.)
    @ViewBuilder func havenGlass<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// Pill text input: kills the system bezel and gives the field ONE glass capsule surface.
    func havenPillField() -> some View {
        self.textFieldStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .havenGlass(in: Capsule())
    }
}

/// Circular glass icon button — toolbars, sheet close buttons, on-media overlays. 34pt chip
/// (comfortable click target) with press feedback; the glyph is the label.
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 34
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint ?? .primary)
            .frame(width: size, height: size)
            .havenGlass(in: Circle())
            // Clip the glass surface to the circle too — interactive Liquid Glass can bleed past
            // its shape and read as an ellipse/rounded-rect. Square frame + Circle clip = true circle.
            .clipShape(Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(HavenTheme.snappy, value: configuration.isPressed)
    }
}

/// Glass pill button for text actions (sheet Cancel/Done, secondary actions). Prominent
/// confirm actions stay on `BrandButtonStyle` — gradient pill, no glass underneath.
struct GlassPillButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .havenGlass(in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(HavenTheme.snappy, value: configuration.isPressed)
    }
}

extension View {
    /// Sheet toolbar text buttons (Cancel/Done/Save…): a glass PILL on macOS — the platform's
    /// default toolbar chrome renders them as bare text on a system band. iOS passes through
    /// untouched (its toolbar buttons are already correct).
    @ViewBuilder func havenToolbarPill(tint: Color? = nil) -> some View {
        #if os(macOS)
        self.buttonStyle(GlassPillButtonStyle(tint: tint))
        #else
        self
        #endif
    }
}

/// Icon buttons: on macOS a modern circular GLASS chip — the platform's default chrome rendered
/// bare `Image` buttons as barely-visible rounded rectangles. On iOS the label passes through
/// untouched (toolbars already tint glyphs correctly there, and the shipped look must not shift).
struct HavenGlassIcon: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        GlassIconButtonStyle().makeBody(configuration: configuration)
        #else
        configuration.label
        #endif
    }
}

#if os(macOS)
/// macOS sheet scaffold done the Haven way: the brand gradient runs to the sheet's EXTREME
/// edges — never a gray system band above or below the content — with an inline title row, a
/// glass close circle (Esc works too), and an optional prominent footer action. Sheets that
/// need Cancel/Confirm chrome use THIS on macOS instead of NavigationStack toolbars, whose
/// buttons land on a system-styled bottom band we can't restyle.
struct HavenMacSheet<Content: View, Footer: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(_ title: String, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title
        self.content = content
        self.footer = footer
    }

    var body: some View {
        ZStack {
            HavenBackground()
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.title3.weight(.semibold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(GlassIconButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                .padding(EdgeInsets(top: 18, leading: 22, bottom: 10, trailing: 18))
                ScrollView {
                    content()
                        .padding(.horizontal, 22).padding(.bottom, 16)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)   // center the column when the sheet is wider
                }
                .scrollContentBackground(.hidden)
                footer()
                    .padding(EdgeInsets(top: 10, leading: 22, bottom: 18, trailing: 22))
                    .frame(maxWidth: 560)
            }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 560, idealHeight: 680)
    }
}
#endif

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
