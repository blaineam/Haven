import SwiftUI
import MapKit
import CoreLocation

/// A shared pinned location, carried inside a post's media array as a `geo:<lat>,<lon>,<label>`
/// ref (so it travels with no wire/engine change) and rendered inline as a map.
enum SharedLocation {
    static let prefix = "geo:"

    static func ref(lat: Double, lon: Double, label: String) -> String {
        // Commas delimit the ref, so strip them from the free-text label.
        "\(prefix)\(lat),\(lon),\(label.replacingOccurrences(of: ",", with: " "))"
    }

    static func parse(_ ref: String) -> (lat: Double, lon: Double, label: String)? {
        guard ref.hasPrefix(prefix) else { return nil }
        let parts = ref.dropFirst(prefix.count).split(separator: ",", maxSplits: 2,
                                                       omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return (lat, lon, parts.count > 2 ? parts[2] : "")
    }

    /// Human-readable coordinates, e.g. `37.7749° N, 122.4194° W`.
    ///
    /// This is the OFF-GRID fallback, and off-grid is exactly when a shared location matters most.
    /// The inline map is an `MKMapSnapshotter` render and snapshotting needs network tiles, so with
    /// no service the map cannot draw — and the one thing worth having, the actual position, was the
    /// thing that vanished with it.
    static func coordinateText(lat: Double, lon: Double) -> String {
        let ns = lat >= 0 ? "N" : "S"
        let ew = lon >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), ns, abs(lon), ew)
    }

    /// Reverse-geocode a coordinate into a short, friendly place name (city / POI), for tagging a
    /// post from a photo's GPS. Falls back to a generic label if geocoding is unavailable.
    static func placeName(_ coord: CLLocationCoordinate2D) async -> String {
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        if let pm = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
            return pm.areasOfInterest?.first ?? pm.locality ?? pm.name
                ?? pm.administrativeArea ?? "Pinned location"
        }
        return "Pinned location"
    }
}

/// Renders a `geo:` ref as a static map with a pin; tap "Open in Maps" to launch Apple Maps.
/// Renders a map region as a cached still image via `MKMapSnapshotter`, off the main thread. Scrolling a
/// feed past several live `Map` views is expensive (each is a real MKMapView doing tile work); a snapshot
/// is just a bitmap. Cached by coordinate so scrolling back is instant and never re-renders.
private struct MapSnapshotView: View {
    let coord: CLLocationCoordinate2D

    @State private var image: PlatformImage?
    /// Set when the snapshot could not be rendered — almost always no network. Distinct from "still
    /// loading", because the two must not look the same: one resolves on its own, the other never
    /// will, and the second needs to hand the viewer the coordinates instead.
    @State private var failed = false
    /// Reported upward so the surrounding card can show the coordinates in place of a dead map.
    var onUnavailable: ((Bool) -> Void)?
    private static let cache = NSCache<NSString, PlatformImage>()
    private var key: String { String(format: "%.5f,%.5f", coord.latitude, coord.longitude) }

    var body: some View {
        ZStack {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))   // reserves the frame while it renders
            }
            if !failed {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2).foregroundStyle(HavenTheme.pink)
                    .shadow(color: .black.opacity(0.35), radius: 2)
            }
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        let k = key as NSString
        if let cached = Self.cache.object(forKey: k) { image = cached; return }
        let opts = MKMapSnapshotter.Options()
        opts.region = MKCoordinateRegion(center: coord, latitudinalMeters: 700, longitudinalMeters: 700)
        opts.size = CGSize(width: 600, height: 400)
        let snapshotter = MKMapSnapshotter(options: opts)
        let snap: MKMapSnapshotter.Snapshot? = await withCheckedContinuation { cont in
            snapshotter.start(with: .global(qos: .userInitiated)) { s, _ in cont.resume(returning: s) }
        }
        guard let snap else {
            // No tiles — offline, or the snapshotter failed. Say so, so the card can fall back to
            // the coordinates rather than showing an empty grey rectangle forever.
            failed = true
            onUnavailable?(true)
            return
        }
        failed = false
        onUnavailable?(false)
        Self.cache.setObject(snap.image, forKey: k)
        image = snap.image
    }
}

struct LocationMapView: View {
    let lat: Double
    let lon: Double
    let label: String

    /// True once the map snapshot has failed — i.e. there is no network. Off-grid is precisely when
    /// a shared position matters, so the card degrades to text rather than to nothing.
    @State private var mapUnavailable = false

    private var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    private var title: String { label.isEmpty ? "Pinned location" : label }

    var body: some View {
        // A STATIC snapshot image, not a live Map. A `Map` spins up a full MKMapView per post — tile
        // rendering plus network fetches running while you scroll past it, which showed up as jitter on
        // location posts. The feed only ever showed a non-interactive preview, so render it once and
        // cache the image. (The interactive map is still one tap away via "Open in Maps".)
        MapSnapshotView(coord: coord, onUnavailable: { mapUnavailable = $0 })
        // macOS: even with interactionModes:[] the Map's NSView eats scroll-wheel events, so the feed
        // couldn't scroll while the cursor was over a map. Ignore hits on the map itself (the "Open in
        // Maps" button is a separate overlay below, so it stays clickable) → scroll passes to the feed.
        .allowsHitTesting(false)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            Label(title, systemImage: "mappin.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule()).padding(8)
        }
        // OFF-GRID FALLBACK. With no service the snapshot never draws and this used to be a blank
        // grey box with a pin on it — the position, the only part that matters when you are off the
        // grid, was the part that disappeared. The coordinates always travel with the post (a `geo:`
        // ref is text inside the event, not a blob), so they can always be shown.
        .overlay(alignment: .center) {
            if mapUnavailable { OfflineCoordinates(lat: lat, lon: lon) }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: openInMaps) {
                Label("Open in Maps", systemImage: "arrow.up.forward.app.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    // Real glass over the map, not a hand-rolled black scrim; .plain keeps macOS
                    // from painting a bezel behind the pill.
                    .havenGlass(in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = title
        item.openInMaps()
    }
}

/// Pan the map so the centre pin sits on the spot you want, add an optional label, share it.
struct LocationPicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition =
        .userLocation(fallback: .region(MKCoordinateRegion(
            center: .init(latitude: 37.7749, longitude: -122.4194),
            latitudinalMeters: 6000, longitudinalMeters: 6000)))
    @State private var center = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    @State private var label = ""
    private let mgr = CLLocationManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $position)
                        .onMapCameraChange { ctx in center = ctx.region.center }
                    // Centre pin — its tip marks the chosen point.
                    Image(systemName: "mappin")
                        .font(.system(size: 34)).foregroundStyle(HavenTheme.pink)
                        .shadow(radius: 3).offset(y: -16)
                        .allowsHitTesting(false)
                }
                VStack(spacing: 12) {
                    TextField("Add a label (optional) — e.g. \"My place\"", text: $label)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .havenGlass(in: Capsule())
                    Button {
                        onPick(SharedLocation.ref(lat: center.latitude, lon: center.longitude, label: label))
                        dismiss()
                    } label: {
                        Label("Share this spot", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(HavenTheme.pink)
                }
                .padding()
            }
            .navigationTitle("Pin a location")
            .havenInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.havenToolbarPill() }
                ToolbarItem(placement: .havenTrailing) {
                    Button { position = .userLocation(fallback: .automatic) } label: {
                        Image(systemName: "location.fill")
                    }
                    .buttonStyle(HavenGlassIcon())
                }
            }
            .onAppear { mgr.requestWhenInUseAuthorization() }
        }.havenPausesPostAudio()
    }
}


/// Shown in place of the map when the snapshot cannot render.
///
/// Kept as its own `View` rather than inlined into `LocationMapView`'s modifier chain: nested in
/// there it pushed the expression past what the type checker would solve ("failed to produce
/// diagnostic for expression"), which is a compile failure, not a style question.
private struct OfflineCoordinates: View {
    let lat: Double
    let lon: Double

    var body: some View {
        let coords = SharedLocation.coordinateText(lat: lat, lon: lon)
        return VStack(spacing: 4) {
            Image(systemName: "mappin.and.ellipse")
                .font(.title3)
                .foregroundStyle(HavenTheme.pink)
            Text(coords)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                // Off-grid, copying these into a downloaded map is the whole recovery path.
                .textSelection(.enabled)
            Text("Map unavailable offline")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }
}
