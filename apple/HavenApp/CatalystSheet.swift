import SwiftUI

/// Mac Catalyst sheets have no built-in way to dismiss (no swipe-down, no nav chrome), so a sheet
/// can trap the user. This overlays a close button in the top-trailing corner — but ONLY on
/// Catalyst, so iOS keeps its native swipe-to-dismiss and we don't double up on a Done button.
private struct MacSheetClose: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        // Native macOS AND Mac Catalyst sheets have no swipe-to-dismiss and (for iOS-authored content)
        // no intrinsic size, so without this they collapse to a sliver with no way to close. Give the
        // sheet a roomy frame + a top-trailing Done button. iOS keeps its native swipe-to-dismiss.
        #if os(macOS) || targetEnvironment(macCatalyst)
        content
            .frame(minWidth: 480, idealWidth: 560, minHeight: 580, idealHeight: 700)
            // The window paints flat gray above/below content whose gradient lives in its own
            // ZStack — extend the brand gradient across the WHOLE sheet (and hide Form/List's
            // default scroll background, the other gray-band source) so it reads as one surface.
            .scrollContentBackground(.hidden)
            .background(HavenBackground().ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(HavenTheme.pink)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc closes it too
            }
        #else
        content
        #endif
    }
}

extension View {
    /// Add a Catalyst-only top-corner close button to a sheet's content.
    func macSheetClose() -> some View { modifier(MacSheetClose()) }

    /// Give a macOS/Catalyst sheet a usable frame WITHOUT adding a Done button — for sheet content that
    /// already has its own toolbar (Cancel/Done/Start). Without a frame these collapse to a sliver (the
    /// "New message" / "Who reacted" bug). iOS is untouched.
    func macSheetFrame() -> some View {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return self.frame(minWidth: 480, idealWidth: 560, minHeight: 580, idealHeight: 700)
            .scrollContentBackground(.hidden)
            .background(HavenBackground().ignoresSafeArea())   // one cohesive gradient surface
        #else
        return self
        #endif
    }
}
