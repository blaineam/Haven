// Platform.swift — cross-platform shims for the native macOS port.
//
// During the parallel-port phase the same `HavenApp` sources compile for BOTH the Catalyst
// `Haven` target (UIKit) and the native `HavenMac` target (AppKit). This file gives the AppKit
// build the small slice of UIKit-shaped API the app actually uses, so call sites can stay
// platform-agnostic instead of being littered with `#if`s.
//
// Keep `#if os(macOS)` (native) vs `#if targetEnvironment(macCatalyst)` (Catalyst, still UIKit)
// straight: Catalyst gets the UIKit branch here because `canImport(UIKit)` is true there.

import SwiftUI

#if canImport(UIKit)
import UIKit

/// `UIImage` on iOS / Catalyst, `NSImage` on native macOS.
typealias PlatformImage = UIImage
/// `UIColor` on iOS / Catalyst, `NSColor` on native macOS.
typealias PlatformColor = UIColor

#else
import AppKit
import UniformTypeIdentifiers
import IOKit.pwr_mgt

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

// MARK: - NSImage gains the UIImage-shaped API the app relies on.

extension NSImage {
    /// Mirror `UIImage(cgImage:)` (NSImage's own initializer requires an explicit size).
    convenience init(cgImage cg: CGImage) {
        self.init(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The backing `CGImage`, matching `UIImage.cgImage`.
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func bitmapRep() -> NSBitmapImageRep? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    /// Matches `UIImage.jpegData(compressionQuality:)`.
    func jpegData(compressionQuality quality: CGFloat) -> Data? {
        bitmapRep()?.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Matches `UIImage.pngData()`.
    func pngData() -> Data? {
        bitmapRep()?.representation(using: .png, properties: [:])
    }
}

// MARK: - iOS semantic UIColor names, mapped to NSColor equivalents.
//
// Lets call sites like `Color(.secondarySystemBackground)` compile unchanged on macOS
// (SwiftUI infers `Color(_ nsColor:)`, so these resolve as NSColor members).
extension NSColor {
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemFill: NSColor { .quaternaryLabelColor }
    static var tertiarySystemFill: NSColor { .quaternaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
}
#endif

// MARK: - Image rendering / resizing (replaces UIGraphicsImageRenderer)

extension PlatformImage {
    /// Pixel size, normalized across platforms.
    var pixelSize: CGSize {
        #if canImport(UIKit)
        return size
        #else
        if let cg = cgImage { return CGSize(width: cg.width, height: cg.height) }
        return size
        #endif
    }

    /// Downscale so the longest edge is at most `maxDimension` (aspect preserved). Returns self
    /// when already small enough. Replaces the `UIGraphicsImageRenderer` downscale path.
    func downscaled(maxDimension: CGFloat) -> PlatformImage {
        let dim = max(pixelSize.width, pixelSize.height)
        guard dim > maxDimension, dim > 0 else { return self }
        let scale = maxDimension / dim
        let target = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return resized(to: target)
    }

    /// Redraw into a bitmap of `target` size (1x, opaque-agnostic).
    func resized(to target: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        #else
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: CGRect(origin: .zero, size: target),
             from: CGRect(origin: .zero, size: pixelSize),
             operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
        #endif
    }
}

// MARK: - SwiftUI representable typealiases

#if canImport(UIKit)
typealias PlatformViewRepresentable = UIViewRepresentable
typealias PlatformViewControllerRepresentable = UIViewControllerRepresentable
#else
typealias PlatformViewRepresentable = NSViewRepresentable
typealias PlatformViewControllerRepresentable = NSViewControllerRepresentable
#endif

// MARK: - Pasteboard

enum PlatformPasteboard {
    static var string: String? {
        get {
            #if canImport(UIKit)
            return UIPasteboard.general.string
            #else
            return NSPasteboard.general.string(forType: .string)
            #endif
        }
        set {
            #if canImport(UIKit)
            UIPasteboard.general.string = newValue ?? ""
            #else
            let pb = NSPasteboard.general
            pb.clearContents()
            if let v = newValue { pb.setString(v, forType: .string) }
            #endif
        }
    }

    /// Copy a SECRET (e.g. the identity transfer code, which IS the full identity). Local to THIS
    /// device only — never synced to other devices via Universal Clipboard — and auto-expiring so it
    /// doesn't linger on the pasteboard for other apps to read.
    static func setSecret(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        #endif
    }
}

// MARK: - Idle timer (prevent display sleep during playback / capture)

/// `UIApplication.isIdleTimerDisabled` on iOS; an `IOPMAssertion` on macOS.
enum PlatformIdle {
    #if !canImport(UIKit)
    private static var assertion: IOPMAssertionID = 0
    private static var held = false
    #endif

    static var disabled: Bool = false {
        didSet {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = disabled
            #else
            setMacAssertion(disabled)
            #endif
        }
    }

    #if !canImport(UIKit)
    private static func setMacAssertion(_ on: Bool) {
        if on, !held {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Haven media playback" as CFString,
                &id)
            if ok == kIOReturnSuccess { assertion = id; held = true }
        } else if !on, held {
            IOPMAssertionRelease(assertion); held = false
        }
    }
    #endif
}

// MARK: - Application-level helpers

enum PlatformApp {
    /// Is the app currently foreground/active?
    static var isActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return NSApplication.shared.isActive
        #endif
    }

    /// Register for APNs (both `UIApplication` and `NSApplication` expose this).
    static func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

// MARK: - SwiftUI cross-platform shims (iOS nav/toolbar/text modifiers that don't exist on macOS)

extension Image {
    /// `Image(uiImage:)` on iOS / `Image(nsImage:)` on macOS.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS; no-op on macOS (no title-bar mode there).
    @ViewBuilder func havenInlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Cross-platform text auto-capitalization (`TextInputAutocapitalization` is iOS-only).
enum HavenAutocap { case never, sentences, words, characters }

extension View {
    @ViewBuilder func havenAutocap(_ mode: HavenAutocap) -> some View {
        #if os(iOS)
        switch mode {
        case .never: self.textInputAutocapitalization(.never)
        case .sentences: self.textInputAutocapitalization(.sentences)
        case .words: self.textInputAutocapitalization(.words)
        case .characters: self.textInputAutocapitalization(.characters)
        }
        #else
        self
        #endif
    }
}

extension View {
    /// macOS sheets paint a flat gray window background above and below the content, so a view
    /// whose gradient lives INSIDE its own ZStack shows dull bands at the sheet's top/bottom.
    /// This extends the brand gradient across the WHOLE sheet (and hides Form/List's default
    /// scroll background, the other gray-band source). No-op on iOS — full-screen covers are
    /// already immersive and the shipped look must not shift.
    @ViewBuilder
    func havenSheetBackground() -> some View {
        #if os(macOS)
        self
            .scrollContentBackground(.hidden)
            .background(HavenBackground().ignoresSafeArea())
        #else
        self
        #endif
    }

    /// `.fullScreenCover` on iOS; falls back to `.sheet` on macOS (no full-screen cover there).
    @ViewBuilder
    func havenFullScreenCover<Content: View>(isPresented: Binding<Bool>,
                                             onDismiss: (() -> Void)? = nil,
                                             @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        // A macOS sheet sizes to its content; iOS full-screen content carries no size, so it would
        // collapse to a useless sliver. Give it a roomy default frame so every sheet is usable.
        self.sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().frame(minWidth: 460, idealWidth: 540, minHeight: 560, idealHeight: 680)
                .havenSheetBackground()
        }
        #endif
    }

    @ViewBuilder
    func havenFullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>,
                                                                 wide: Bool = false,
                                                                 onDismiss: (() -> Void)? = nil,
                                                                 @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
        // Pickers/forms get a phone-ish frame; the MEDIA VIEWER (wide:true) gets a roomy landscape frame so
        // wide photos/videos aren't crammed into a narrow portrait sliver on macOS.
        self.sheet(item: item, onDismiss: onDismiss) { it in
            if wide {
                content(it).frame(minWidth: 720, idealWidth: 1040, maxWidth: .infinity,
                                  minHeight: 520, idealHeight: 760, maxHeight: .infinity)
                    .havenSheetBackground()
            } else {
                content(it).frame(minWidth: 460, idealWidth: 540, minHeight: 560, idealHeight: 680)
                    .havenSheetBackground()
            }
        }
        #endif
    }
}

extension View {
    /// Consistent settings-form look on every platform. macOS's default `Form` style is `.columns`
    /// (right-aligned labels in a cramped column) — `.grouped` gives the iOS-like grouped sections
    /// with proper padding. `.scrollContentBackground(.hidden)` makes the form transparent so the
    /// brand gradient behind it shows through cleanly instead of stacking a second background.
    @ViewBuilder func havenSettingsForm() -> some View {
        self.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    /// `.statusBarHidden()` on iOS; no-op on macOS (no status bar).
    @ViewBuilder func havenStatusBarHidden(_ hidden: Bool = true) -> some View {
        #if os(iOS)
        self.statusBarHidden(hidden)
        #else
        self
        #endif
    }

    /// `.keyboardType(.URL)` on iOS; no-op on macOS (hardware keyboard, no soft-keyboard type).
    @ViewBuilder func havenURLKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }

    /// Paged `TabView` style on iOS; plain `TabView` on macOS (no `.page` style there).
    @ViewBuilder func havenPagedTabViewStyle(showsIndex: Bool) -> some View {
        #if os(iOS)
        self.tabViewStyle(.page(indexDisplayMode: showsIndex ? .automatic : .never))
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    // Persistent nav actions (call / add / gear / etc.).
    /// iOS `.topBarTrailing` → macOS `.primaryAction`.
    static var havenTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .automatic
        #endif
    }
    /// iOS `.topBarLeading` → macOS `.automatic`.
    static var havenLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .automatic
        #endif
    }

    // Sheet / dialog DISMISS buttons. On macOS these route to the confirmation/cancellation
    // slots so they render as proper sheet buttons (Return/Esc) instead of floating in the
    // title-bar toolbar OVER the content (which collided with the gear and doubled "Done").
    // The iOS side keeps the button's original edge so iOS layout is unchanged.
    static var havenConfirmTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .confirmationAction
        #endif
    }
    static var havenConfirmLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .confirmationAction
        #endif
    }
    static var havenCancelTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .cancellationAction
        #endif
    }
    static var havenCancelLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .cancellationAction
        #endif
    }
}

// MARK: - Screen

enum PlatformScreen {
    /// Main screen bounds. `UIScreen.main.bounds` on iOS; the main `NSScreen`'s frame on macOS.
    static var bounds: CGRect {
        #if canImport(UIKit)
        return UIScreen.main.bounds
        #else
        return NSScreen.main?.frame ?? .zero
        #endif
    }
}

// MARK: - Haptics (no-op on macOS — there's no Taptic Engine)

enum PlatformHaptics {
    static func success() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
