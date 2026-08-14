import SwiftUI

/// The app-wide "still importing" strip.
///
/// An archive import takes a long time — hundreds of photos and videos, each re-encoded and
/// encrypted on the device — and holding the user on a modal progress bar for all of it is the
/// wrong trade twice over: they cannot use Haven, and they cannot see the posts arriving, which is
/// the whole point of watching. So the importer runs on `InstagramImporter.shared` (independent of
/// any view) and this strip is what remains on screen: small, tappable to reopen the full sheet,
/// and present wherever the user browses to — including after a relaunch, since the import resumes
/// itself.
struct ImportBanner: View {
    @ObservedObject private var importer = InstagramImporter.shared
    var onTap: () -> Void

    var body: some View {
        if case .importing(let done, let total) = importer.phase {
            Button(action: onTap) {
                HStack(spacing: 11) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.circular)
                        #if os(iOS)
                        .scaleEffect(0.7)
                        #endif
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Importing from Instagram")
                            .font(.footnote.weight(.semibold))
                        Text("\(done) of \(total)")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(HavenTheme.pink.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.snappy, value: done)
        }
    }
}

extension View {
    /// Float the import banner above this tab's content — ABOVE the tab bar, never over it.
    ///
    /// The first cut overlaid it on the `TabView`, which put the pill directly on top of the
    /// Circle / Messages / You bar: the labels were behind it and the app's own navigation was the
    /// thing the progress indicator covered up. A background task must not cost you the tab bar.
    ///
    /// `safeAreaInset` applied INSIDE a tab is what gets this right — the banner sits in that tab's
    /// bottom safe area, above the tab bar, and the tab's scroll content insets around it so
    /// nothing is hidden underneath either.
    func havenImportBanner(onTap: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            ImportBanner(onTap: onTap)
        }
    }
}
