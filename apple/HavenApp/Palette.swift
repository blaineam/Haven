import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One curated colour set. Stop 2 is the tint (controls, links, the Post pill); stops 1 and 3 only
/// appear in gradients and glows. The table is the same on every client — `docs/PALETTES.md` is the
/// source of truth and `packaging/palette-icons/<id>.png` is rendered from it.
struct HavenPalette: Identifiable, Equatable {
    let id: String
    let name: String
    let stops: [UInt32]   // 0xRRGGBB × 3

    static let `default` = all[0]
    static let all: [HavenPalette] = [
        .init(id: "sunset", name: "Sunset", stops: [0x7C3AED, 0xEC4899, 0xF59E0B]),
        .init(id: "ocean", name: "Ocean", stops: [0x2563EB, 0x06B6D4, 0x14B8A6]),
        .init(id: "forest", name: "Forest", stops: [0x047857, 0x10B981, 0x84CC16]),
        .init(id: "rose", name: "Rose", stops: [0xBE123C, 0xF43F5E, 0xFB923C]),
        .init(id: "ember", name: "Ember", stops: [0xB91C1C, 0xF97316, 0xFACC15]),
        .init(id: "sky", name: "Sky", stops: [0x0EA5E9, 0x6366F1, 0xA78BFA]),
        .init(id: "grape", name: "Grape", stops: [0x6D28D9, 0xA855F7, 0xF472B6]),
        .init(id: "neutral", name: "Neutral", stops: [0x404040, 0x737373, 0xA3A3A3]),
    ]

    /// Unknown / missing id → the default, so a downgrade or a bad value never breaks the UI.
    static func resolve(_ id: String?) -> HavenPalette { all.first { $0.id == id } ?? .default }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    var first: Color { Self.color(stops[0]) }
    var tint: Color { Self.color(stops[1]) }
    var last: Color { Self.color(stops[2]) }
    /// Alternate-icon / asset name for this palette (`sunset` is the primary AppIcon).
    var iconName: String? { id == "sunset" ? nil : "AppIcon-\(id)" }
}

/// The selected palette. DEVICE-LOCAL (`appearance.palette`), applied live: `HavenTheme` reads it, and
/// `epoch` bumps (on `commit`) so the root view re-renders (colours are read at draw time, not
/// observed, so something has to invalidate the tree).
@MainActor
final class PaletteStore: ObservableObject {
    static let shared = PaletteStore()
    nonisolated static let key = "appearance.palette"

    /// Read by `HavenTheme` from any thread (image renders, background tasks) — written only on main,
    /// a single pointer-sized value, so an unsynchronised read is safe. Seeded from the stored choice
    /// (not the default) because `PaletteStore.shared` is only created when the phone's root view is:
    /// a CarPlay launch with no phone UI never touches it, and the car then drew the default (pink)
    /// whatever palette was selected.
    nonisolated(unsafe) static var current = PaletteStore.stored(in: .standard)

    /// The palette saved in `defaults` (the default when none / unknown).
    nonisolated static func stored(in defaults: UserDefaults) -> HavenPalette {
        HavenPalette.resolve(defaults.string(forKey: key))
    }

    @Published private(set) var epoch = 0
    @Published private(set) var palette: HavenPalette { didSet { Self.current = palette } }
    /// A change not yet applied to the rest of the app (see `commit`).
    private var dirty = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let p = Self.stored(in: defaults)
        self.palette = p
        Self.current = p
    }

    func select(_ p: HavenPalette) {
        guard p != palette else { return }
        palette = p
        defaults.set(p.id, forKey: Self.key)
        // Share with the share extension (own tiny source set, can't link the store).
        UserDefaults(suiteName: "group.com.blaineam.kith")?.set(p.id, forKey: Self.key)
        dirty = true
        AppIconSwitcher.apply(p)
        #if os(iOS)
        WatchSessionManager.shared.pushSnapshot()   // the wrist follows
        #endif
    }

    /// Rebuild the app's tree with the new colours. Deferred until the picker is left, because the
    /// rebuild resets navigation — doing it on every swatch tap would bounce you out of Settings.
    func commit() {
        guard dirty else { return }
        dirty = false
        epoch += 1
    }
}

/// Swaps the home-screen / Dock icon to match the palette.
enum AppIconSwitcher {
    @MainActor static func apply(_ p: HavenPalette) {
        #if os(iOS)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != p.iconName else { return }
        // iOS shows its own "You have changed the icon" alert; there is no way to suppress it.
        app.setAlternateIconName(p.iconName) { _ in }
        #elseif os(macOS)
        // Runtime Dock icon only — Finder/Launchpad keep the bundled icon. The palette art is a full-bleed square,
        // so it is drawn into the macOS icon shape here (the bundled default icon already has it).
        NSApp?.applicationIconImage = p.iconName == nil ? nil : NSImage(named: "PaletteIcon-\(p.id)")?.macIconStyled()
        #endif
    }
}

#if os(macOS)
extension NSImage {
    /// The macOS app-icon shape: an 824 pt rounded tile (corner ≈ 22.4 %) centred in a 1024 pt canvas, with the soft
    /// drop shadow system icons carry. Without it a full-bleed square renders in the Dock as a hard-cornered box.
    func macIconStyled() -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            let tile = rect.insetBy(dx: 100, dy: 100)
            let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            self.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}
#endif
