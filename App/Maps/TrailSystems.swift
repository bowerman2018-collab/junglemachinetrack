import MapKit

/// The Hatfield-McCoy trail systems. Trailhead locations and trail extents come from the official
/// Master Trail Inventory (trailsheaven.com, September 2026). Each download area covers the system's
/// trails plus about two miles around them, and always includes the trailhead.
struct TrailSystem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let trailhead: String
    let trailheadLatitude: Double
    let trailheadLongitude: Double
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    /// Extra margin around the trails, in degrees (about two miles).
    static let margin = 0.03

    var trailheadCoordinate: CLLocationCoordinate2D {
        .init(latitude: trailheadLatitude, longitude: trailheadLongitude)
    }

    var region: MKCoordinateRegion {
        let south = min(minLat, trailheadLatitude) - Self.margin, north = max(maxLat, trailheadLatitude) + Self.margin
        let west = min(minLon, trailheadLongitude) - Self.margin, east = max(maxLon, trailheadLongitude) + Self.margin
        return MKCoordinateRegion(center: .init(latitude: (south + north) / 2, longitude: (west + east) / 2),
                                  span: .init(latitudeDelta: north - south, longitudeDelta: east - west))
    }

    static let hatfieldMcCoy: [TrailSystem] = [
        TrailSystem(name: "Rockhouse", trailhead: "83 Rockhouse Creek Rd, Man", trailheadLatitude: 37.72613, trailheadLongitude: -81.88346,
                    minLat: 37.62, maxLat: 37.769, minLon: -81.996, maxLon: -81.868),
        TrailSystem(name: "Braveheart", trailhead: "83 Rockhouse Creek Rd, Man", trailheadLatitude: 37.72613, trailheadLongitude: -81.88346,
                    minLat: 37.696, maxLat: 37.73, minLon: -81.868, maxLon: -81.805),
        TrailSystem(name: "Bearwallow", trailhead: "247 Bearwallow Dr, Ethel", trailheadLatitude: 37.86405, trailheadLongitude: -81.93206,
                    minLat: 37.84, maxLat: 37.923, minLon: -82.062, maxLon: -81.892),
        TrailSystem(name: "Devil Anse", trailhead: "48 McCoy St, Matewan", trailheadLatitude: 37.62139, trailheadLongitude: -82.16805,
                    minLat: 37.592, maxLat: 37.69, minLon: -82.172, maxLon: -81.996),
        TrailSystem(name: "Buffalo Mountain", trailhead: "1472 Buffalo Mountain, Williamson", trailheadLatitude: 37.69941, trailheadLongitude: -82.20581,
                    minLat: 37.647, maxLat: 37.718, minLon: -82.286, maxLon: -82.17),
        TrailSystem(name: "Pinnacle Creek", trailhead: "2733 Pinnacle Rd, Pineville", trailheadLatitude: 37.55587, trailheadLongitude: -81.50792,
                    minLat: 37.424, maxLat: 37.572, minLon: -81.543, maxLon: -81.341),
        TrailSystem(name: "Indian Ridge", trailhead: "County Rd 17, Ashland", trailheadLatitude: 37.41279, trailheadLongitude: -81.35254,
                    minLat: 37.386, maxLat: 37.459, minLon: -81.428, maxLon: -81.309),
        TrailSystem(name: "Warrior", trailhead: "84 Silcox Ln, War", trailheadLatitude: 37.30372, trailheadLongitude: -81.69275,
                    minLat: 37.299, maxLat: 37.415, minLon: -81.672, maxLon: -81.545),
        TrailSystem(name: "Pocahontas", trailhead: "11110 Coal Heritage Rd, Bramwell (Coaldale)", trailheadLatitude: 37.3645, trailheadLongitude: -81.33435,
                    minLat: 37.327, maxLat: 37.388, minLon: -81.36, maxLon: -81.282),
        TrailSystem(name: "Ivy Branch", trailhead: "4260 Julian Rd, Julian", trailheadLatitude: 38.16642, trailheadLongitude: -81.87782,
                    minLat: 38.166, maxLat: 38.202, minLon: -81.897, maxLon: -81.847),
        TrailSystem(name: "Big Coal River", trailhead: "21868 Daniel Boone Pkwy, Peytona", trailheadLatitude: 38.12862, trailheadLongitude: -81.69154,
                    minLat: 38.095, maxLat: 38.135, minLon: -81.692, maxLon: -81.648),
        TrailSystem(name: "Cabwaylingo", trailhead: "39 Tick Ridge Rd, Wilsondale", trailheadLatitude: 37.98705, trailheadLongitude: -82.37298,
                    minLat: 37.924, maxLat: 38.014, minLon: -82.392, maxLon: -82.332),
        TrailSystem(name: "Tornado", trailhead: "7900 Smith Creek Rd, Tornado", trailheadLatitude: 38.33815, trailheadLongitude: -81.83351,
                    minLat: 38.318, maxLat: 38.338, minLon: -81.834, maxLon: -81.816),
    ]
}
