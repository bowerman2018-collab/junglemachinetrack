import Foundation

/// A latitude/longitude pair. Kept free of MapKit so the route finder can be checked on its own in CI.
struct GeoPoint: Hashable, Codable {
    var lat: Double
    var lon: Double

    /// Meters, using a flat-earth approximation that is plenty accurate over a few miles.
    func distance(to p: GeoPoint) -> Double {
        let k = cos((lat + p.lat) / 2 * .pi / 180)
        return hypot((p.lon - lon) * GeoPoint.metersPerDegree * k, (p.lat - lat) * GeoPoint.metersPerDegree)
    }

    /// Compass bearing in degrees, 0 = north.
    func bearing(to p: GeoPoint) -> Double {
        let k = cos((lat + p.lat) / 2 * .pi / 180)
        let deg = atan2((p.lon - lon) * k, p.lat - lat) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    static let metersPerDegree = 111_320.0
}

/// One line the route finder can travel along: a trail from the imported map, or a road.
struct NavWay {
    enum Kind { case trail, road }
    var kind: Kind
    /// Trail number (e.g. "73") or road name (e.g. "Bearwallow Rd").
    var label: String
    /// Trail system, e.g. "Bearwallow". Empty for roads.
    var system: String
    /// Other names to search by: road refs like "US 52", alternate names.
    var aliases: [String] = []
    /// Trail difficulty ("More Difficult"), or the OpenStreetMap road class for roads ("residential").
    var difficulty: String = ""
    var points: [GeoPoint]

    var title: String {
        switch kind {
        case .trail:
            if label.isEmpty { return system.isEmpty ? "Trail" : "\(system) trail" }
            return "Trail \(label)"
        case .road:
            return label.isEmpty ? (aliases.first ?? "Road") : label
        }
    }
}

/// Which trails the route may use.
struct RouteOptions: Equatable, Codable {
    /// Skip "Most Difficult" trails.
    var avoidMostDifficult = false
    /// Single track is for dirt bikes only, so it's skipped unless you turn this off.
    var avoidSingleTrack = true
    /// Allow public roads to link trails together. Roads count as 3x longer so trails win when they can.
    var useRoads = true

    static let roadPenalty = 3.0

    /// The cost of one meter on this way, or nil when the route may not use it.
    func weight(_ way: NavWay) -> Double? {
        switch way.kind {
        case .road:
            // Interstates and four-lane highways are off limits to ATVs/UTVs.
            if way.difficulty.hasPrefix("motorway") || way.difficulty.hasPrefix("trunk") { return nil }
            return useRoads ? Self.roadPenalty : nil
        case .trail:
            let d = way.difficulty.lowercased()
            // Hiking, horse and cabin/campground-guest trails are never open to ATVs/UTVs.
            if d.contains("hiking") || d.contains("horse") || d.contains("guests only") { return nil }
            if avoidSingleTrack && d.contains("single track") { return nil }
            if avoidMostDifficult && d.contains("most") { return nil }
            return 1
        }
    }
}

/// One instruction in a route: "Trail 73 for 1.2 mi".
struct RouteStep: Hashable {
    var title: String
    var kind: NavWay.Kind?
    /// "Start", "Turn left", "Continue", etc. Describes how you get onto this step.
    var turn: String
    var length: Double
    /// Distance along the whole route where this step begins.
    var startsAt: Double
    var point: GeoPoint
}

struct Route {
    /// The full line to draw and follow, including any off-trail lead in and out.
    var points: [GeoPoint]
    /// Cumulative distance at each point.
    var distances: [Double]
    var steps: [RouteStep]
    /// Straight-line parts at the start and end, where you aren't on a mapped trail or road.
    var leadIn: Double
    var leadOut: Double
    var roadMeters: Double

    var length: Double { distances.last ?? 0 }
}

/// The trail and road network as a graph: nodes at every trail end, junction and road crossing.
final class TrailGraph {
    struct Edge {
        let a: Int
        let b: Int
        let way: Int
        let points: [GeoPoint]
        let cumulative: [Double]
        var length: Double { cumulative.last ?? 0 }
    }

    let ways: [NavWay]
    private(set) var nodes: [GeoPoint] = []
    private(set) var edges: [Edge] = []
    private(set) var adjacency: [[Int]] = []

    /// How close a trail end must be to another trail to count as joined to it.
    static let trailJoin = 15.0
    /// Same, when a road is involved (road lines are less exact).
    static let roadJoin = 25.0

    private let k: Double
    private var edgeGrid: [Int64: [(edge: Int, seg: Int)]] = [:]
    private static let edgeCell = 250.0

    init(ways: [NavWay]) {
        self.ways = ways
        let lats = ways.flatMap { $0.points.map(\.lat) }
        let mid = lats.isEmpty ? 37.7 : (lats.min()! + lats.max()!) / 2
        k = cos(mid * .pi / 180)
        build()
    }

    // MARK: Planar helpers

    private struct XY { var x: Double; var y: Double }

    private func xy(_ p: GeoPoint) -> XY { XY(x: p.lon * GeoPoint.metersPerDegree * k, y: p.lat * GeoPoint.metersPerDegree) }
    private func geo(_ p: XY) -> GeoPoint { GeoPoint(lat: p.y / GeoPoint.metersPerDegree, lon: p.x / GeoPoint.metersPerDegree / k) }

    private static func key(_ gx: Int, _ gy: Int) -> Int64 { Int64(gx) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: gy))) }

    /// Closest point on segment ab to p: (distance, t along ab).
    private static func project(_ p: XY, _ a: XY, _ b: XY) -> (Double, Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return (hypot(p.x - a.x - t * dx, p.y - a.y - t * dy), t)
    }

    // MARK: Building

    private func build() {
        let pts = ways.map { $0.points.map(xy) }
        let cell = 40.0

        // Every segment of every way, bucketed by grid cell: `grid` padded by the join distance (for
        // trail ends), `plain` unpadded (for crossings).
        var grid: [Int64: [(way: Int, seg: Int)]] = [:]
        var plain: [Int64: [(way: Int, seg: Int)]] = [:]
        for (w, line) in pts.enumerated() where line.count >= 2 {
            for s in 0..<(line.count - 1) {
                let a = line[s], b = line[s + 1]
                let pad = Self.roadJoin
                for gx in Int(floor((min(a.x, b.x) - pad) / cell))...Int(floor((max(a.x, b.x) + pad) / cell)) {
                    for gy in Int(floor((min(a.y, b.y) - pad) / cell))...Int(floor((max(a.y, b.y) + pad) / cell)) {
                        grid[Self.key(gx, gy), default: []].append((w, s))
                    }
                }
                for gx in Int(floor(min(a.x, b.x) / cell))...Int(floor(max(a.x, b.x) / cell)) {
                    for gy in Int(floor(min(a.y, b.y) / cell))...Int(floor(max(a.y, b.y) / cell)) {
                        plain[Self.key(gx, gy), default: []].append((w, s))
                    }
                }
            }
        }

        // Places to cut each way into edges: position = segment index + fraction.
        var cuts: [[(pos: Double, p: XY)]] = []
        for line in pts {
            var c: [(pos: Double, p: XY)] = []
            if line.count >= 2 {
                c.append((pos: 0, p: line[0]))
                c.append((pos: Double(line.count - 1), p: line[line.count - 1]))
            }
            cuts.append(c)
        }
        var links: [(end: XY, to: XY, way: Int)] = []

        // 1. Lines that cross each other get a junction where they cross.
        for (cellKey, bucket) in plain where bucket.count > 1 {
            for i in 0..<(bucket.count - 1) {
                for j in (i + 1)..<bucket.count {
                    let (w1, s1) = bucket[i]
                    let (w2, s2) = bucket[j]
                    if w1 == w2 && abs(s1 - s2) < 2 { continue }
                    let p = pts[w1][s1], p2 = pts[w1][s1 + 1], q = pts[w2][s2], q2 = pts[w2][s2 + 1]
                    // Test each pair once: in the cell holding the low corner of where their boxes overlap.
                    let ox = max(min(p.x, p2.x), min(q.x, q2.x)), oy = max(min(p.y, p2.y), min(q.y, q2.y))
                    if Self.key(Int(floor(ox / cell)), Int(floor(oy / cell))) != cellKey { continue }
                    let rx = p2.x - p.x, ry = p2.y - p.y, sx = q2.x - q.x, sy = q2.y - q.y
                    let den = rx * sy - ry * sx
                    if abs(den) < 1e-9 { continue }
                    let qpx = q.x - p.x, qpy = q.y - p.y
                    let t = (qpx * sy - qpy * sx) / den, u = (qpx * ry - qpy * rx) / den
                    guard t >= 0, t <= 1, u >= 0, u <= 1 else { continue }
                    let x = XY(x: p.x + t * rx, y: p.y + t * ry)
                    cuts[w1].append((pos: Double(s1) + t, p: x))
                    cuts[w2].append((pos: Double(s2) + u, p: x))
                }
            }
        }

        // 2. A trail that ends right next to another line is joined to it (mapped lines rarely meet exactly).
        for (w, line) in pts.enumerated() where line.count >= 2 {
            for end in [line[0], line[line.count - 1]] {
                var best: [Int: (d: Double, seg: Int, t: Double)] = [:]
                for (w2, s2) in grid[Self.key(Int(floor(end.x / cell)), Int(floor(end.y / cell)))] ?? [] where w2 != w {
                    let (d, t) = Self.project(end, pts[w2][s2], pts[w2][s2 + 1])
                    let limit = ways[w].kind == .trail && ways[w2].kind == .trail ? Self.trailJoin : Self.roadJoin
                    if d <= limit, d < (best[w2]?.d ?? .infinity) { best[w2] = (d, s2, t) }
                }
                for (w2, hit) in best {
                    let a = pts[w2][hit.seg], b = pts[w2][hit.seg + 1]
                    let q = XY(x: a.x + hit.t * (b.x - a.x), y: a.y + hit.t * (b.y - a.y))
                    cuts[w2].append((pos: Double(hit.seg) + hit.t, p: q))
                    links.append((end: end, to: q, way: w))
                }
            }
        }

        // Nodes: points within 2 m of each other are the same node.
        var nodeGrid: [Int64: [Int]] = [:]
        var nodeXY: [XY] = []
        func node(_ p: XY) -> Int {
            let gx = Int(floor(p.x / 4)), gy = Int(floor(p.y / 4))
            for dx in -1...1 {
                for dy in -1...1 {
                    for n in nodeGrid[Self.key(gx + dx, gy + dy)] ?? [] where hypot(nodeXY[n].x - p.x, nodeXY[n].y - p.y) <= 2 {
                        return n
                    }
                }
            }
            nodeXY.append(p)
            nodeGrid[Self.key(gx, gy), default: []].append(nodeXY.count - 1)
            return nodeXY.count - 1
        }

        var built: [(a: Int, b: Int, way: Int, pts: [XY])] = []
        for (w, line) in pts.enumerated() where line.count >= 2 {
            let sorted = cuts[w].sorted { $0.pos < $1.pos }
            var prev = sorted[0]
            var prevNode = node(prev.p)
            for c in sorted.dropFirst() {
                if c.pos - prev.pos < 1e-9 { continue }
                let n = node(c.p)
                var geom = [prev.p]
                var i = Int(floor(prev.pos)) + 1
                while Double(i) < c.pos { geom.append(line[i]); i += 1 }
                geom.append(c.p)
                if n != prevNode || geom.count > 2 { built.append((a: prevNode, b: n, way: w, pts: geom)) }
                prev = c
                prevNode = n
            }
        }
        // The short joining stretch belongs to the trail that ends there.
        for link in links {
            let a = node(link.end), b = node(link.to)
            if a != b { built.append((a: a, b: b, way: link.way, pts: [link.end, link.to])) }
        }

        nodes = nodeXY.map(geo)
        adjacency = Array(repeating: [], count: nodes.count)
        for e in built {
            var cum = [0.0]
            for i in 1..<e.pts.count { cum.append(cum[i - 1] + hypot(e.pts[i].x - e.pts[i - 1].x, e.pts[i].y - e.pts[i - 1].y)) }
            let id = edges.count
            edges.append(Edge(a: e.a, b: e.b, way: e.way, points: e.pts.map(geo), cumulative: cum))
            adjacency[e.a].append(id)
            if e.b != e.a { adjacency[e.b].append(id) }
        }

        for (id, e) in edges.enumerated() {
            for s in 0..<(e.points.count - 1) {
                let a = xy(e.points[s]), b = xy(e.points[s + 1])
                for gx in Int(floor(min(a.x, b.x) / Self.edgeCell))...Int(floor(max(a.x, b.x) / Self.edgeCell)) {
                    for gy in Int(floor(min(a.y, b.y) / Self.edgeCell))...Int(floor(max(a.y, b.y) / Self.edgeCell)) {
                        edgeGrid[Self.key(gx, gy), default: []].append((id, s))
                    }
                }
            }
        }
    }

    // MARK: Snapping a point onto the network

    struct Snap {
        var edge: Int
        /// Meters from the edge's start node.
        var offset: Double
        var point: GeoPoint
        /// How far the original point was from the network.
        var distance: Double
    }

    /// The closest place on a usable trail or road, searching out to `maxDistance` meters.
    func snap(_ p: GeoPoint, options: RouteOptions, maxDistance: Double = 20_000) -> Snap? {
        let q = xy(p)
        let gx = Int(floor(q.x / Self.edgeCell)), gy = Int(floor(q.y / Self.edgeCell))
        var best: Snap?
        var ring = 0
        while Double(ring - 1) * Self.edgeCell <= min(best?.distance ?? .infinity, maxDistance) {
            for dx in -ring...ring {
                for dy in -ring...ring where max(abs(dx), abs(dy)) == ring {
                    for (id, s) in edgeGrid[Self.key(gx + dx, gy + dy)] ?? [] {
                        let e = edges[id]
                        guard options.weight(ways[e.way]) != nil else { continue }
                        let a = xy(e.points[s]), b = xy(e.points[s + 1])
                        let (d, t) = Self.project(q, a, b)
                        if d < (best?.distance ?? .infinity) {
                            let off = e.cumulative[s] + t * (e.cumulative[s + 1] - e.cumulative[s])
                            best = Snap(edge: id, offset: off, point: geo(XY(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))), distance: d)
                        }
                    }
                }
            }
            ring += 1
            if ring > 200 { break }
        }
        guard let found = best, found.distance <= maxDistance else { return nil }
        return found
    }

    /// The part of an edge between two offsets, in travel order.
    func slice(_ id: Int, from: Double, to: Double) -> [GeoPoint] {
        let e = edges[id]
        let lo = min(from, to), hi = max(from, to)
        func at(_ off: Double) -> GeoPoint {
            var i = 0
            while i < e.cumulative.count - 2 && e.cumulative[i + 1] < off { i += 1 }
            let span = e.cumulative[i + 1] - e.cumulative[i]
            let t = span > 0 ? max(0, min(1, (off - e.cumulative[i]) / span)) : 0
            let a = e.points[i], b = e.points[i + 1]
            return GeoPoint(lat: a.lat + t * (b.lat - a.lat), lon: a.lon + t * (b.lon - a.lon))
        }
        var out = [at(lo)]
        for (i, c) in e.cumulative.enumerated() where c > lo && c < hi { out.append(e.points[i]) }
        out.append(at(hi))
        return from <= to ? out : out.reversed()
    }

    // MARK: Routing

    /// Shortest allowed route from `start` to whichever of `targets` is cheapest to reach.
    func route(from start: GeoPoint, to targets: [GeoPoint], options: RouteOptions) -> Route? {
        guard let s = snap(start, options: options) else { return nil }
        let goals = targets.compactMap { t in snap(t, options: options).map { (target: t, snap: $0) } }
        guard !goals.isEmpty else { return nil }

        var goalsOnEdge: [Int: [Int]] = [:]
        for (i, g) in goals.enumerated() { goalsOnEdge[g.snap.edge, default: []].append(i) }

        func weight(_ edge: Int) -> Double? { options.weight(ways[edges[edge].way]) }

        var dist = Array(repeating: Double.infinity, count: nodes.count)
        var via = Array(repeating: -1, count: nodes.count) // edge used to arrive
        var heap = MinHeap()
        let se = edges[s.edge], sw = weight(s.edge) ?? 1
        dist[se.a] = s.offset * sw
        heap.push(dist[se.a], se.a)
        if se.b != se.a, (se.length - s.offset) * sw < dist[se.b] {
            dist[se.b] = (se.length - s.offset) * sw
            heap.push(dist[se.b], se.b)
        }

        // Best way to finish: (cost, goal index, last node or -1 when staying on the start edge).
        var finish: (cost: Double, goal: Int, node: Int) = (.infinity, -1, -1)
        for gi in goalsOnEdge[s.edge] ?? [] {
            let c = abs(goals[gi].snap.offset - s.offset) * sw + goals[gi].snap.distance
            if c < finish.cost { finish = (c, gi, -1) }
        }

        var done = Array(repeating: false, count: nodes.count)
        while let top = heap.pop() {
            let (d, u) = top
            if d >= finish.cost { break }
            if done[u] { continue }
            done[u] = true
            for id in adjacency[u] {
                guard let w = weight(id) else { continue }
                let e = edges[id]
                for gi in goalsOnEdge[id] ?? [] {
                    let off = goals[gi].snap.offset
                    let c = d + (u == e.a ? off : e.length - off) * w + goals[gi].snap.distance
                    if c < finish.cost { finish = (c, gi, u) }
                }
                let v = e.a == u ? e.b : e.a
                let nd = d + e.length * w
                if nd < dist[v] {
                    dist[v] = nd
                    via[v] = id
                    heap.push(nd, v)
                }
            }
        }
        guard finish.goal >= 0 else { return nil }
        let goal = goals[finish.goal]

        // Walk back from the last node to the start edge.
        var pieces: [(way: Int, points: [GeoPoint])] = []
        if finish.node < 0 {
            pieces.append((se.way, slice(s.edge, from: s.offset, to: goal.snap.offset)))
        } else {
            var chain: [(edge: Int, forward: Bool)] = []
            var n = finish.node
            while via[n] >= 0 {
                let e = edges[via[n]]
                chain.append((via[n], e.b == n))
                n = e.b == n ? e.a : e.b
            }
            chain.reverse()
            pieces.append((se.way, slice(s.edge, from: s.offset, to: n == se.a ? 0 : se.length)))
            for c in chain {
                let e = edges[c.edge]
                pieces.append((e.way, c.forward ? e.points : e.points.reversed()))
            }
            let ge = edges[goal.snap.edge]
            pieces.append((ge.way, slice(goal.snap.edge, from: finish.node == ge.a ? 0 : ge.length, to: goal.snap.offset)))
        }
        return assemble(start: start, startSnap: s, end: goal.target, endSnap: goal.snap, pieces: pieces)
    }

    private func assemble(start: GeoPoint, startSnap: Snap, end: GeoPoint, endSnap: Snap,
                          pieces: [(way: Int, points: [GeoPoint])]) -> Route {
        var points: [GeoPoint] = []
        var distances: [Double] = []
        var steps: [RouteStep] = []
        var roadMeters = 0.0

        func add(_ p: GeoPoint) {
            if let last = points.last {
                let d = last.distance(to: p)
                if d < 0.01 { return }
                distances.append(distances.last! + d)
            } else {
                distances.append(0)
            }
            points.append(p)
        }

        let offStart = startSnap.distance > 20
        add(start)
        if offStart {
            add(startSnap.point)
            steps.append(RouteStep(title: "Head to the trail", kind: nil, turn: "Start", length: distances.last!, startsAt: 0, point: start))
        }

        for piece in pieces where !piece.points.isEmpty {
            let before = distances.last ?? 0
            let way = ways[piece.way]
            if steps.last?.title != way.title {
                let turn = steps.isEmpty ? "Start" : Self.turnText(incoming: points, outgoing: piece.points)
                steps.append(RouteStep(title: way.title, kind: way.kind, turn: turn, length: 0, startsAt: before, point: points.last ?? piece.points[0]))
            }
            for p in piece.points { add(p) }
            let added = (distances.last ?? 0) - before
            steps[steps.count - 1].length += added
            if way.kind == .road { roadMeters += added }
        }
        // A route that starts right at a junction can pick up a few feet of the wrong trail; drop those.
        let kept = steps.filter { $0.kind == nil || $0.length >= 5 }
        if !kept.isEmpty { steps = kept }
        if !steps.isEmpty { steps[0].turn = "Start" }

        let leadIn = offStart ? startSnap.distance : 0
        var leadOut = 0.0
        if endSnap.distance > 20 {
            let before = distances.last ?? 0
            add(end)
            leadOut = (distances.last ?? 0) - before
            steps.append(RouteStep(title: "Leave the trail to the destination", kind: nil, turn: "Then", length: leadOut, startsAt: before, point: endSnap.point))
        }
        if points.count == 1 { add(end) }
        return Route(points: points, distances: distances, steps: steps, leadIn: leadIn, leadOut: leadOut, roadMeters: roadMeters)
    }

    /// "Turn left" etc., comparing the heading coming in to the heading going out.
    static func turnText(incoming: [GeoPoint], outgoing: [GeoPoint]) -> String {
        guard let corner = incoming.last else { return "Continue" }
        // Look about 30 m back and ahead so small wiggles at the junction don't count.
        var back = corner
        for p in incoming.reversed() where p.distance(to: corner) > 1 {
            back = p
            if p.distance(to: corner) >= 30 { break }
        }
        var ahead = corner
        for p in outgoing where p.distance(to: corner) > 1 {
            ahead = p
            if p.distance(to: corner) >= 30 { break }
        }
        guard back != corner, ahead != corner else { return "Continue" }
        var delta = corner.bearing(to: ahead) - back.bearing(to: corner)
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        switch abs(delta) {
        case ..<30: return "Continue"
        case ..<60: return delta > 0 ? "Bear right" : "Bear left"
        case ..<135: return delta > 0 ? "Turn right" : "Turn left"
        default: return delta > 0 ? "Sharp right" : "Sharp left"
        }
    }
}

/// Small binary min-heap for the route search.
struct MinHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ priority: Double, _ value: Int) {
        items.append((priority, value))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if items[p].0 <= items[i].0 { break }
            items.swapAt(p, i)
            i = p
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].0 < items[m].0 { m = l }
                if r < items.count && items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(m, i)
                i = m
            }
        }
        return top
    }
}
