import Foundation
import MapKit
import CoreLocation

/// Small user preferences, kept in UserDefaults.
final class AppSettings: ObservableObject {
    @Published var tileSourceID: String { didSet { defaults.set(tileSourceID, forKey: "tileSourceID") } }
    /// When off, the map only shows tiles already downloaded and the app makes no network requests at all.
    @Published var useInternetForMaps: Bool { didSet { defaults.set(useInternetForMaps, forKey: "useInternetForMaps") } }
    /// Riders not heard for this many minutes are drawn faded.
    @Published var staleMinutes: Int { didSet { defaults.set(staleMinutes, forKey: "staleMinutes") } }
    @Published var showTracks: Bool { didSet { defaults.set(showTracks, forKey: "showTracks") } }
    /// Imported trail lines (e.g. Hatfield-McCoy trails with numbers).
    @Published var showTrailLines: Bool { didSet { defaults.set(showTrailLines, forKey: "showTrailLines") } }

    private let defaults = UserDefaults.standard

    init() {
        tileSourceID = defaults.string(forKey: "tileSourceID") ?? TileSource.usgsTopo.id
        useInternetForMaps = defaults.object(forKey: "useInternetForMaps") as? Bool ?? true
        staleMinutes = defaults.object(forKey: "staleMinutes") as? Int ?? 10
        showTracks = defaults.object(forKey: "showTracks") as? Bool ?? true
        showTrailLines = defaults.object(forKey: "showTrailLines") as? Bool ?? true
    }

    var tileSource: TileSource { TileSource.all.first { $0.id == tileSourceID } ?? .usgsTopo }
}

/// Shared map camera, so the Riders and Offline Maps tabs can see and move what the map shows.
final class MapState: ObservableObject {
    /// Starts over the Hatfield-McCoy trail area in southern West Virginia.
    static let hatfieldMcCoy = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.70, longitude: -81.85),
        span: MKCoordinateSpan(latitudeDelta: 0.9, longitudeDelta: 1.1))

    /// Last region the user looked at. Updated by the map, not published, to avoid redraw loops.
    var region: MKCoordinateRegion = MapState.hatfieldMcCoy {
        didSet { saveRegion() }
    }

    /// Requests for the map to move. The map view applies and clears it.
    @Published var pendingRegion: MKCoordinateRegion?
    @Published var followUser = false

    init() {
        let d = UserDefaults.standard
        if let lat = d.object(forKey: "mapLat") as? Double, let lon = d.object(forKey: "mapLon") as? Double,
           let dLat = d.object(forKey: "mapDLat") as? Double, let dLon = d.object(forKey: "mapDLon") as? Double {
            region = MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                                        span: .init(latitudeDelta: dLat, longitudeDelta: dLon))
        }
    }

    func show(_ coordinate: CLLocationCoordinate2D) {
        followUser = false
        pendingRegion = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)
    }

    func fit(_ coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else { return }
        followUser = false
        if coordinates.count == 1 { show(coordinates[0]); return }
        let lats = coordinates.map(\.latitude), lons = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, 0.01),
                                    longitudeDelta: max((lons.max()! - lons.min()!) * 1.4, 0.01))
        pendingRegion = MKCoordinateRegion(center: center, span: span)
    }

    private func saveRegion() {
        let d = UserDefaults.standard
        d.set(region.center.latitude, forKey: "mapLat")
        d.set(region.center.longitude, forKey: "mapLon")
        d.set(region.span.latitudeDelta, forKey: "mapDLat")
        d.set(region.span.longitudeDelta, forKey: "mapDLon")
    }
}

/// The phone's own GPS. Works with no cell signal; nothing is sent anywhere.
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLLocationDirection?
    private let manager = CLLocationManager()
    private var started = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start() {
        guard !started else { return }
        started = true
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// Distance and compass direction from the phone to a coordinate, e.g. "1.2 mi NE".
    func describe(to coordinate: CLLocationCoordinate2D) -> String? {
        guard let here = location else { return nil }
        let there = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let miles = here.distance(from: there) / 1609.344
        let distance = miles < 0.2 ? String(format: "%.0f ft", miles * 5280) : String(format: "%.1f mi", miles)
        return "\(distance) \(Self.compass(Self.bearing(from: here.coordinate, to: coordinate)))"
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func compass(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((degrees + 22.5) / 45) % 8]
    }
}
