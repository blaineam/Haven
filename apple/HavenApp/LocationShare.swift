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
struct LocationMapView: View {
    let lat: Double
    let lon: Double
    let label: String

    private var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    private var title: String { label.isEmpty ? "Pinned location" : label }

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coord, latitudinalMeters: 700, longitudinalMeters: 700)),
            interactionModes: []) {       // static preview — no pan/zoom in the feed
            Marker(title, coordinate: coord).tint(HavenTheme.pink)
        }
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
        .overlay(alignment: .bottomTrailing) {
            Button(action: openInMaps) {
                Label("Open in Maps", systemImage: "arrow.up.forward.app.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
            }.padding(8)
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
        }
    }
}
