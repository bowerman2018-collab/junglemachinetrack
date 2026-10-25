import Foundation
import CoreLocation

/// Plans a route along the trails to a searched or tapped place and follows it as you ride.
/// Everything runs on the phone from the imported trail map and the bundled road list; no signal needed.
final class Navigator: ObservableObject {
    @Published private(set) var graph: TrailGraph?
    @Published private(set) var building = false
    @Published var options: RouteOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: "routeOptions") }
            if options != oldValue { replan() }
        }
    }
    @Published private(set) var destination: NavPlace?
    /// Where the route starts when it isn't your own GPS position (picked on the map).
    @Published private(set) var customStart: GeoPoint?
    @Published private(set) var route: Route?
    /// Changes every time the route is replaced, so the map knows to redraw.
    @Published private(set) var routeVersion = 0
    @Published private(set) var problem: String?
    /// Following the route turn by turn.
    @Published var active = false { didSet { offRouteCount = 0 } }
    @Published private(set) var progress: Progress?

    struct Progress {
        var remaining: Double
        var next: RouteStep?
        var toNext: Double
        var offRoute: Double
        var arrived: Bool
    }

    let roads: [NavWay] = RoadData.load()
    private var builtFrom: [UUID]?
    private var lastLocation: CLLocation?
    private var offRouteCount = 0
    private var lastReplan = Date.distantPast
    private var progressIndex = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: "routeOptions"), let saved = try? JSONDecoder().decode(RouteOptions.self, from: data) {
            options = saved
        } else {
            options = RouteOptions()
        }
    }

    var hasTrails: Bool { !(builtFrom ?? []).isEmpty }

    // MARK: Network

    /// Rebuilds the trail network when a new trail map is imported. Takes a second or two, off the main thread.
    func rebuild(trails: [TrailLine]) {
        let ids = trails.map(\.id)
        guard ids != builtFrom else { return }
        builtFrom = ids
        building = true
        let roads = self.roads
        DispatchQueue.global(qos: .userInitiated).async {
            var ways: [NavWay] = []
            for t in trails {
                let system = t.details["Trail_Syst"] ?? t.details.first(where: { $0.key.lowercased().contains("syst") })?.value ?? ""
                let difficulty = t.details["Difficulty"] ?? t.details.first(where: { $0.key.lowercased().contains("diffic") })?.value ?? ""
                for seg in t.segments where seg.count >= 2 {
                    ways.append(NavWay(kind: .trail, label: t.label == t.name ? "" : t.label, system: system,
                                       difficulty: difficulty, points: seg.map { GeoPoint(lat: $0[1], lon: $0[0]) }))
                }
            }
            // Only roads near the trails matter, and fewer roads keeps the network quick to build.
            if !ways.isEmpty {
                let near = NearTrails(ways)
                ways += roads.filter { near.contains($0.points) }
            }
            let graph = ways.isEmpty ? nil : TrailGraph(ways: ways)
            DispatchQueue.main.async {
                guard self.builtFrom == ids else { return }
                self.graph = graph
                self.building = false
                self.replan()
            }
        }
    }

    var search: NavSearch? {
        guard let graph else { return nil }
        let landmarks = TrailheadAnnotation.all.map { (name: $0.title ?? "Trailhead", point: GeoPoint($0.coordinate)) }
        return NavSearch(graph: graph, landmarks: landmarks)
    }

    // MARK: Planning

    func navigate(to place: NavPlace) {
        destination = place
        active = false
        replan()
    }

    /// Long-press on the map: route there.
    func pick(_ coordinate: CLLocationCoordinate2D) {
        let p = GeoPoint(coordinate)
        var title = "Dropped pin"
        if let graph, let snap = graph.snap(p, options: options, maxDistance: 60) {
            title = "On \(graph.ways[graph.edges[snap.edge].way].title)"
        }
        navigate(to: NavPlace(title: title, subtitle: "Picked on the map", center: p, targets: [p]))
    }

    func startHere(_ coordinate: CLLocationCoordinate2D?) {
        customStart = coordinate.map(GeoPoint.init)
        replan()
    }

    func clear() {
        destination = nil
        route = nil
        progress = nil
        problem = nil
        active = false
        routeVersion += 1
    }

    func update(location: CLLocation?) {
        guard let location, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { return }
        let first = lastLocation == nil
        lastLocation = location
        if first && route == nil && destination != nil { replan(); return }
        track(location)
    }

    private var startPoint: GeoPoint? {
        customStart ?? lastLocation.map { GeoPoint($0.coordinate) }
    }

    func replan() {
        guard let destination else { return }
        guard let graph else {
            route = nil
            problem = building ? "Getting the trail network ready…" : "Import the Hatfield-McCoy trail map first (Offline Maps tab)."
            routeVersion += 1
            return
        }
        guard let start = startPoint else {
            route = nil
            problem = "Waiting for GPS. Or long-press the map and pick \"Start here\"."
            routeVersion += 1
            return
        }
        if let r = graph.route(from: start, to: destination.targets, options: options) {
            route = r
            problem = r.leadIn > 1600 ? "You're \(NavSearch.miles(r.leadIn)) from the nearest trail; the dashed line is a straight line, not a trail." : nil
        } else {
            route = nil
            problem = graph.snap(start, options: options) == nil
                ? "You're too far from the trails to plan a route. Long-press the map and pick \"Start here\" to plan from somewhere else."
                : "No route with these settings. Try allowing roads or harder trails."
        }
        progressIndex = 0
        offRouteCount = 0
        lastReplan = Date()
        routeVersion += 1
        if let lastLocation { track(lastLocation) }
    }

    // MARK: Following

    private func track(_ location: CLLocation) {
        guard let route, route.points.count >= 2 else { progress = nil; return }
        let here = GeoPoint(location.coordinate)
        // Look a little behind and well ahead of the last match so a trail that doubles back doesn't confuse it.
        let lo = max(0, progressIndex - 20), hi = min(route.points.count - 2, progressIndex + 400)
        var best = (d: Double.infinity, i: progressIndex, along: 0.0)
        for i in lo...hi {
            let a = route.points[i], b = route.points[i + 1]
            let segLen = route.distances[i + 1] - route.distances[i]
            let t = Self.fraction(here, a, b)
            let p = GeoPoint(lat: a.lat + t * (b.lat - a.lat), lon: a.lon + t * (b.lon - a.lon))
            let d = here.distance(to: p)
            if d < best.d { best = (d, i, route.distances[i] + t * segLen) }
        }
        progressIndex = best.i
        let remaining = max(0, route.length - best.along)
        let next = route.steps.first { $0.startsAt > best.along + 10 }
        progress = Progress(remaining: remaining, next: next, toNext: (next?.startsAt ?? route.length) - best.along,
                            offRoute: best.d, arrived: remaining < 30)

        // Off the route for a while: plan again from here (only when following it, and not from a picked start).
        guard active, customStart == nil else { return }
        offRouteCount = best.d > 60 ? offRouteCount + 1 : 0
        if offRouteCount >= 3, Date().timeIntervalSince(lastReplan) > 20 { replan() }
    }

    /// How far along ab the closest point to p is, 0...1.
    private static func fraction(_ p: GeoPoint, _ a: GeoPoint, _ b: GeoPoint) -> Double {
        let k = cos(p.lat * .pi / 180)
        let ax = a.lon * k, ay = a.lat, bx = b.lon * k, by = b.lat, px = p.lon * k, py = p.lat
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        return len2 == 0 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
    }

    /// Rough ride time: trails at about 8 mph, roads at about 25 mph.
    static func minutes(_ route: Route) -> Int {
        let trail = max(0, route.length - route.roadMeters) / 1609.344 / 8 * 60
        let road = route.roadMeters / 1609.344 / 25 * 60
        return max(1, Int((trail + road).rounded()))
    }
}

extension GeoPoint {
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// Quick "is this within about a mile of any trail" test, on a coarse grid.
private struct NearTrails {
    private var cells = Set<Int64>()
    private static let size = 0.015 // degrees, about a mile

    init(_ ways: [NavWay]) {
        for w in ways {
            for p in w.points {
                let x = Int(floor(p.lon / Self.size)), y = Int(floor(p.lat / Self.size))
                for dx in -1...1 { for dy in -1...1 { cells.insert(Self.key(x + dx, y + dy)) } }
            }
        }
    }

    func contains(_ pts: [GeoPoint]) -> Bool {
        pts.contains { cells.contains(Self.key(Int(floor($0.lon / Self.size)), Int(floor($0.lat / Self.size)))) }
    }

    private static func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }
}

/// Road names and lines near the trails, from OpenStreetMap, bundled in the app (App/Resources/Roads.json).
enum RoadData {
    private struct File: Decodable {
        struct Road: Decodable {
            var n: String
            var k: String?
            var r: String?
            var a: String?
            var p: [Double]
        }
        var roads: [Road]
    }

    static func load(_ url: URL? = Bundle.main.url(forResource: "Roads", withExtension: "json")) -> [NavWay] {
        guard let url, let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.roads.compactMap { r in
            var pts: [GeoPoint] = []
            var i = 0
            while i + 1 < r.p.count { pts.append(GeoPoint(lat: r.p[i + 1], lon: r.p[i])); i += 2 }
            guard pts.count >= 2 else { return nil }
            var aliases = (r.a ?? "").split(separator: ";").map(String.init)
            if let ref = r.r { aliases.insert(contentsOf: ref.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }, at: 0) }
            return NavWay(kind: .road, label: r.n, system: "", aliases: aliases, difficulty: r.k ?? "", points: pts)
        }
    }
}
