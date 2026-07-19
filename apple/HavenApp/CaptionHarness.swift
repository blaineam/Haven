#if DEBUG
import SwiftUI

/// Debug-only check that the Open Graph link card stays inside the DM bubble / screen edge (it kept
/// bleeding off the right because LPLinkView ignores the SwiftUI frame). A red strip marks the right
/// screen edge — the card must not touch it. Launch with `HAVEN_OG_HARNESS=1`.
struct OGHarness: View {
    private let url = URL(string: "https://wemiller.com/apps/haven/")!
    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.ignoresSafeArea()
            VStack(alignment: .trailing, spacing: 8) {
                Spacer()
                // autoLoad: this harness exists to check the poster's layout, so it needs the fetch
                // to happen without a tap. Safe here and only here — DEBUG-only, first-party URL.
                LinkPreviewCard(url: url, autoLoad: true)
                    .frame(maxWidth: 260)
                    .padding(8)
                    .background(HavenTheme.brand, in: RoundedRectangle(cornerRadius: 18))
                Text("wemiller.com").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 60)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
            Rectangle().fill(.red).frame(width: 3).ignoresSafeArea()   // right screen-edge marker
        }
    }
}

/// Debug-only check that the story bottom scrim covers the FULL bottom of a near-white image
/// (down through the home-indicator strip). Launch with `HAVEN_SCRIM_HARNESS=1`.
struct ScrimHarness: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()   // simulate a story image that's near-white at the bottom
            VStack {
                Spacer()
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note").font(.caption)
                        Text("Treat People With Kindness · Harry Styles").font(.caption.weight(.medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.bottom, 8)
                    HStack {
                        Text("Reply to Sam…").foregroundStyle(.white.opacity(0.7)); Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.white.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                    .padding(.horizontal, 16).padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 64)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                )
            }
        }
    }
}

/// Debug-only side-by-side of the LIVE editing caption preview vs the FINAL rendered StyledCaption,
/// so the highlight pill can be made to actually match. Launch with `HAVEN_CAPTION_HARNESS=1`.
struct CaptionHarness: View {
    @State private var text = "Geeze"
    @State private var spec: StoryCaptions.Spec = {
        var s = StoryCaptions.Spec()
        s.styleRaw = StoryCaptions.Style.highlight.rawValue
        s.color = 2   // a pink
        return s
    }()
    @FocusState private var focused: Bool

    private var highlightActive: Bool { StoryCaptions.bgColor(spec) != nil && !text.isEmpty }

    var body: some View {
        ZStack {
            Color(white: 0.55).ignoresSafeArea()
            VStack(spacing: 56) {
                Group {
                    Text("EDITING (live, in a Spacer/Spacer box like the composer)").font(.caption.bold()).foregroundStyle(.black)
                    // Mirror the composer's exact container so we test the real layout context.
                    VStack { Spacer(); editingPreview; Spacer() }.frame(height: 120)
                }
                Group {
                    Text("FINAL (StyledCaption, what viewers see)").font(.caption.bold()).foregroundStyle(.black)
                    StyledCaption(text: text, spec: spec)
                }
                TextField("type here", text: $text).focused($focused)
                    .padding(8).background(.white).cornerRadius(8).padding(.horizontal, 40)
            }
        }
    }

    /// Overlay approach: the REAL StyledCaption is the visible render; an invisible TextField on
    /// top captures input + shows the caret. Guarantees editing == final for every style.
    private var editingPreview: some View {
        ZStack {
            StyledCaption(text: text.isEmpty ? " " : text, spec: spec)
            TextField("", text: $text, axis: .vertical)
                .focused($focused)
                .multilineTextAlignment(.center)
                .font(StoryCaptions.font(spec))
                .foregroundStyle(.clear)   // glyphs invisible (StyledCaption shows them); caret stays
                .tint(.white)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
#endif
