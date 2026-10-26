import SwiftUI

/// Settings ▸ Appearance: pick Haven's colour palette (and the matching app icon).
struct AppearanceSection: View {
    @ObservedObject private var store = PaletteStore.shared
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 14)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(HavenPalette.all) { p in
                    swatch(p)
                }
            }
            .padding(.vertical, 6)
        } header: { Text("Appearance") }
        footer: {
            #if os(iOS)
            Text("Colors and the app icon follow your choice. iOS shows its own “icon changed” notice. Neutral removes color.")
            #else
            Text("Colors and the Dock icon follow your choice (Finder keeps the original icon). Neutral removes color.")
            #endif
        }
        .onDisappear { store.commit() }
    }

    private func swatch(_ p: HavenPalette) -> some View {
        let selected = store.palette == p
        return Button { store.select(p) } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(LinearGradient(colors: [p.first, p.tint, p.last], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .overlay {
                        if selected { Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(.white) }
                    }
                    .padding(3)
                    .overlay(Circle().strokeBorder(selected ? p.tint : .clear, lineWidth: 2))
                Text(LocalizedStringKey(p.name)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(p.name)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.palette.\(p.id)")
    }
}
