import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Portable photo/video filters. The *look* of each filter is described by a `FilterSpec` — a
/// small set of platform-neutral parameters (white balance, tone, saturation, grain…). iOS
/// renders it with Core Image here; Android/Windows/Linux can render the exact same `FilterSpec`
/// with their own pipelines (GPUImage / shaders), so a photo looks identical on every client.
struct FilterSpec: Equatable, Codable {
    var temperatureK: Double = 6500   // white-balance target (neutral 6500K)
    var tint: Double = 0              // green ↔ magenta, −100…100
    var saturation: Double = 1        // 0 = grayscale, 1 = normal
    var contrast: Double = 1
    var brightness: Double = 0
    var vibrance: Double = 0          // −1…1, protects skin tones
    var highlights: Double = 1        // 0…1, pull highlights down
    var shadows: Double = 0           // −1…1, lift/deepen shadows
    var fade: Double = 0              // 0…1, lifted blacks (matte film look)
    var grain: Double = 0             // 0…1, film grain amount
    var vignette: Double = 0          // 0…1, corner darkening
    var monochrome: MonoTone? = nil   // non-nil = convert to a toned B&W

    enum MonoTone: String, Codable { case neutral, warm, cool }
}

/// The built-in filter set: nine Apple-Photos-style looks plus a realistic Kodak Gold film sim.
enum HavenFilter: String, CaseIterable, Identifiable {
    case original
    case vivid, vividWarm, vividCool
    case dramatic, dramaticWarm, dramaticCool
    case mono, silvertone, noir
    case kodakGold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .vivid: return "Vivid"
        case .vividWarm: return "Vivid Warm"
        case .vividCool: return "Vivid Cool"
        case .dramatic: return "Dramatic"
        case .dramaticWarm: return "Dramatic Warm"
        case .dramaticCool: return "Dramatic Cool"
        case .mono: return "Mono"
        case .silvertone: return "Silvertone"
        case .noir: return "Noir"
        case .kodakGold: return "Kodak Gold"
        }
    }

    /// Next/previous filter in `allCases`, wrapping around — drives swipe-to-change on the live
    /// camera (swipe left = next, right = previous).
    var next: HavenFilter {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
    var prev: HavenFilter {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i - 1 + all.count) % all.count]
    }

    var spec: FilterSpec {
        switch self {
        case .original:
            return FilterSpec()
        case .vivid:
            return FilterSpec(saturation: 1.22, contrast: 1.06, vibrance: 0.25)
        case .vividWarm:
            return FilterSpec(temperatureK: 5200, saturation: 1.2, contrast: 1.05, vibrance: 0.22)
        case .vividCool:
            return FilterSpec(temperatureK: 7800, saturation: 1.2, contrast: 1.05, vibrance: 0.22)
        case .dramatic:
            return FilterSpec(saturation: 0.92, contrast: 1.22, highlights: 0.85, shadows: -0.2)
        case .dramaticWarm:
            return FilterSpec(temperatureK: 5000, saturation: 0.95, contrast: 1.2, highlights: 0.85, shadows: -0.18)
        case .dramaticCool:
            return FilterSpec(temperatureK: 8200, saturation: 0.9, contrast: 1.2, highlights: 0.85, shadows: -0.2)
        case .mono:
            return FilterSpec(contrast: 1.05, monochrome: .neutral)
        case .silvertone:
            return FilterSpec(contrast: 1.1, monochrome: .warm)
        case .noir:
            return FilterSpec(contrast: 1.3, shadows: -0.3, monochrome: .cool)
        case .kodakGold:
            // Warm highlights, gently lifted/faded blacks, soft contrast, a touch of grain +
            // vignette — the classic consumer-film snapshot look.
            return FilterSpec(temperatureK: 5400, tint: 6, saturation: 1.08, contrast: 0.96,
                              vibrance: 0.12, highlights: 0.92, shadows: 0.08, fade: 0.12,
                              grain: 0.22, vignette: 0.18)
        }
    }
}

enum FilterEngine {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Render a `FilterSpec` onto a PlatformImage. Returns the original on any failure.
    static func apply(_ filter: HavenFilter, to image: PlatformImage) -> PlatformImage {
        guard filter != .original, let cg = image.cgImage else { return image }
        let out = apply(filter.spec, to: CIImage(cgImage: cg))
        guard let result = context.createCGImage(out, from: out.extent) else { return image }
        #if canImport(UIKit)
        return PlatformImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
        #else
        return PlatformImage(cgImage: result)
        #endif
    }

    /// The Core Image pipeline for a spec — also reused per-frame by the video compositor.
    static func apply(_ spec: FilterSpec, to input: CIImage) -> CIImage {
        var img = input

        if spec.temperatureK != 6500 || spec.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: spec.temperatureK, y: spec.tint)
            img = f.outputImage ?? img
        }
        if spec.highlights != 1 || spec.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(spec.highlights)
            f.shadowAmount = Float(spec.shadows)
            img = f.outputImage ?? img
        }
        if spec.saturation != 1 || spec.contrast != 1 || spec.brightness != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.saturation = Float(spec.saturation)
            f.contrast = Float(spec.contrast)
            f.brightness = Float(spec.brightness)
            img = f.outputImage ?? img
        }
        if spec.vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(spec.vibrance)
            img = f.outputImage ?? img
        }
        if let tone = spec.monochrome {
            let f = CIFilter.colorMonochrome(); f.inputImage = img; f.intensity = 1
            switch tone {
            case .neutral: f.color = CIColor(red: 0.6, green: 0.6, blue: 0.6)
            case .warm: f.color = CIColor(red: 0.68, green: 0.62, blue: 0.5)
            case .cool: f.color = CIColor(red: 0.5, green: 0.55, blue: 0.62)
            }
            img = f.outputImage ?? img
        }
        if spec.fade > 0 {
            // Lift the black point toward a matte film base.
            let lift = spec.fade * 0.12
            let f = CIFilter.colorClamp()
            f.inputImage = img
            f.minComponents = CIVector(x: lift, y: lift, z: lift, w: 0)
            f.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            img = f.outputImage ?? img
        }
        if spec.grain > 0 {
            img = addGrain(to: img, amount: spec.grain)
        }
        if spec.vignette > 0 {
            let f = CIFilter.vignette(); f.inputImage = img
            f.intensity = Float(spec.vignette); f.radius = Float(1.6)
            img = f.outputImage ?? img
        }
        return img.cropped(to: input.extent)
    }

    private static func addGrain(to image: CIImage, amount: Double) -> CIImage {
        let noise = CIFilter.randomGenerator().outputImage?
            .cropped(to: image.extent) ?? image
        let mono = CIFilter.colorControls()
        mono.inputImage = noise; mono.saturation = 0; mono.brightness = 0; mono.contrast = 1
        guard let grain = mono.outputImage else { return image }
        let blend = CIFilter.sourceOverCompositing()
        // Fade the grain to the requested strength.
        let faded = grain.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount * 0.5),
        ])
        blend.inputImage = faded; blend.backgroundImage = image
        return blend.outputImage ?? image
    }
}

/// A horizontal filter chooser with live thumbnails — drop it under a captured photo.
/// Grid variant of `FilterStrip` for the review screen. When a shot is previewed aspect-FIT (a landscape
/// capture is short + letterboxed), the freed vertical space is better used by a scrollable tile grid than
/// a single swipeable row — you see every look at once.
struct FilterGrid: View {
    let thumbnail: PlatformImage
    @Binding var selection: HavenFilter
    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(HavenFilter.allCases) { f in
                    VStack(spacing: 6) {
                        Image(platformImage: FilterEngine.apply(f, to: thumbnail))
                            .resizable().scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selection == f ? HavenTheme.pink : .clear, lineWidth: 2.5))
                        Text(f.title).font(.caption2).lineLimit(1)
                            .foregroundStyle(selection == f ? HavenTheme.pink : .secondary)
                    }
                    .onTapGesture { withAnimation(HavenTheme.smooth) { selection = f } }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

struct FilterStrip: View {
    let thumbnail: PlatformImage
    @Binding var selection: HavenFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(HavenFilter.allCases) { f in
                    VStack(spacing: 6) {
                        Image(platformImage: FilterEngine.apply(f, to: thumbnail))
                            .resizable().scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(selection == f ? HavenTheme.pink : .clear, lineWidth: 2.5))
                        Text(f.title).font(.caption2).lineLimit(1)
                            .foregroundStyle(selection == f ? HavenTheme.pink : .secondary)
                    }
                    .onTapGesture { withAnimation(HavenTheme.smooth) { selection = f } }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}
