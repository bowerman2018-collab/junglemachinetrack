import MapKit

/// The Hatfield-McCoy trail systems, from the official 2025 trail map (trailsheaven.com).
/// Centers are approximate (near each trailhead and its trail network); each area covers
/// roughly 17 x 17 miles so the whole network around the trailhead is included.
struct TrailSystem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let trailhead: String
    let latitude: Double
    let longitude: Double

    static let spanLat = 0.24
    static let spanLon = 0.30

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: latitude, longitude: longitude),
                           span: .init(latitudeDelta: Self.spanLat, longitudeDelta: Self.spanLon))
    }

    static let hatfieldMcCoy: [TrailSystem] = [
        TrailSystem(name: "Rockhouse", trailhead: "83 Rockhouse Creek Rd, Man", latitude: 37.70, longitude: -81.87),
        TrailSystem(name: "Braveheart", trailhead: "83 Rockhouse Creek Rd, Man", latitude: 37.76, longitude: -81.90),
        TrailSystem(name: "Bearwallow", trailhead: "247 Bearwallow Dr, Ethel", latitude: 37.87, longitude: -81.85),
        TrailSystem(name: "Devil Anse", trailhead: "48 McCoy St, Matewan", latitude: 37.63, longitude: -82.12),
        TrailSystem(name: "Buffalo Mountain", trailhead: "1472 Buffalo Mountain, Williamson", latitude: 37.69, longitude: -82.22),
        TrailSystem(name: "Pinnacle Creek", trailhead: "2733 Pinnacle Rd, Pineville", latitude: 37.60, longitude: -81.48),
        TrailSystem(name: "Indian Ridge", trailhead: "County Rd 17, Ashland", latitude: 37.43, longitude: -81.38),
        TrailSystem(name: "Warrior", trailhead: "84 Silcox Ln, War", latitude: 37.33, longitude: -81.64),
        TrailSystem(name: "Pocahontas", trailhead: "11110 Coal Heritage Rd, Bramwell (Coaldale)", latitude: 37.33, longitude: -81.30),
        TrailSystem(name: "Ivy Branch", trailhead: "4260 Julian Rd, Julian", latitude: 38.10, longitude: -81.87),
        TrailSystem(name: "Big Coal River", trailhead: "21868 Daniel Boone Pkwy, Peytona", latitude: 38.13, longitude: -81.70),
        TrailSystem(name: "Cabwaylingo", trailhead: "39 Tick Ridge Rd, Wilsondale", latitude: 38.00, longitude: -82.36),
        TrailSystem(name: "Tornado", trailhead: "7900 Smith Creek Rd, Tornado", latitude: 38.34, longitude: -81.84),
    ]
}
