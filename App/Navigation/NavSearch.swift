import Foundation

/// A place you can route to, found by typing a trail number, a road, or "trail & road".
struct NavPlace: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var subtitle: String
    /// Where to drop the pin.
    var center: GeoPoint
    /// Route to whichever of these is closest. A whole trail has many; a junction has one.
    var targets: [GeoPoint]
}

/// Finds trails, roads and junctions by what you type. Works only on the data in the phone.
struct NavSearch {
    let graph: TrailGraph
    /// Named spots such as trailheads.
    var landmarks: [(name: String, point: GeoPoint)] = []

    /// Examples: "73", "Bearwallow 73", "73 & 74", "73 and Bearwallow Rd", "Rockhouse trailhead", "US 52".
    func search(_ query: String, near: GeoPoint?) -> [NavPlace] {
        let parts = Self.split(query)
        guard !parts.isEmpty else { return [] }
        var places: [NavPlace]
        if parts.count >= 2 {
            places = junctions(parts[0], parts[1])
        } else {
            places = groups(for: parts[0]).map(place)
            let q = Self.tokens(parts[0])
            for l in landmarks where !q.isEmpty && Self.matches(q, Self.tokens(l.name)) {
                places.append(NavPlace(title: l.name, subtitle: "Trailhead", center: l.point, targets: [l.point]))
            }
        }
        if let near {
            places.sort { $0.center.distance(to: near) < $1.center.distance(to: near) }
            places = places.map { p in
                var p = p
                p.subtitle += " · " + Self.miles(p.center.distance(to: near)) + " away"
                return p
            }
        }
        return Array(places.prefix(40))
    }

    // MARK: Matching one term

    /// A set of ways that read as one thing: one trail number in one system, or one road near one town.
    struct Group {
        var title: String
        var subtitle: String
        var ways: [Int]
    }

    func groups(for term: String) -> [Group] {
        trailGroups(term) + roadGroups(term)
    }

    func trailGroups(_ term: String) -> [Group] {
        let words = Self.tokens(term)
        guard let number = words.first(where: { $0.first?.isNumber == true }) else { return [] }
        // Everything else should be "trail", "t", "#", or part of a system name.
        let rest = words.filter { $0 != number && !["trail", "trl", "t", "no", "number"].contains($0) }
        var bySystem: [String: [Int]] = [:]
        for (i, w) in graph.ways.enumerated() where w.kind == .trail && w.label.lowercased() == number {
            if !rest.isEmpty && !Self.matches(rest, Self.tokens(w.system)) { continue }
            bySystem[w.system, default: []].append(i)
        }
        return bySystem.sorted { $0.key < $1.key }.map { system, ways in
            let w = graph.ways[ways[0]]
            let miles = ways.reduce(0.0) { $0 + Self.length(graph.ways[$1].points) }
            var sub = system.isEmpty ? "Trail" : "\(system) trail system"
            if !w.difficulty.isEmpty { sub += " · \(w.difficulty)" }
            sub += " · \(Self.miles(miles)) long"
            return Group(title: w.title, subtitle: sub, ways: ways)
        }
    }

    func roadGroups(_ term: String) -> [Group] {
        let q = Self.tokens(term)
        guard !q.isEmpty else { return [] }
        let digits = q.filter { $0.first?.isNumber == true }
        let words = q.filter { $0.first?.isNumber != true }
        let routeWords: Set<String> = ["route", "us", "wv", "highway", "sr", "state", "county", "cr", "co", "i", "interstate"]
        var hits: [String: [Int]] = [:]
        for (i, w) in graph.ways.enumerated() where w.kind == .road {
            let names = [w.label] + w.aliases
            let ok = names.contains { name in
                let t = Self.tokens(name)
                if !digits.isEmpty {
                    // "52", "US 52", "Rt 52", "County Route 5/3": the number must match, the words loosely.
                    guard t.contains(where: { digits.contains($0) }) else { return false }
                    let needed = words.filter { !routeWords.contains($0) }
                    return needed.isEmpty || Self.matches(needed, t)
                }
                return Self.matches(words, t)
            }
            if ok { hits[w.title, default: []].append(i) }
        }
        // Roads of the same name in different towns are listed separately.
        var out: [Group] = []
        for (name, ways) in hits.sorted(by: { $0.key < $1.key }) {
            for cluster in Self.cluster(ways.map { ($0, graph.ways[$0].points) }, within: 1500) {
                out.append(Group(title: name, subtitle: "Road", ways: cluster))
            }
        }
        return out
    }

    private func place(_ g: Group) -> NavPlace {
        let pts = g.ways.flatMap { graph.ways[$0].points }
        // Spread the targets along the way so routing picks the nearest stretch of it.
        let step = max(1, pts.count / 60)
        let targets = stride(from: 0, to: pts.count, by: step).map { pts[$0] } + [pts[pts.count - 1]]
        return NavPlace(title: g.title, subtitle: g.subtitle, center: Self.middle(g.ways.map { graph.ways[$0].points }), targets: targets)
    }

    // MARK: Junctions

    /// Where something matching `a` meets something matching `b`.
    func junctions(_ a: String, _ b: String) -> [NavPlace] {
        let ga = groups(for: a), gb = groups(for: b)
        guard !ga.isEmpty, !gb.isEmpty else { return [] }

        // Which ways touch each node.
        var waysAt: [Int: Set<Int>] = [:]
        for e in graph.edges {
            waysAt[e.a, default: []].insert(e.way)
            waysAt[e.b, default: []].insert(e.way)
        }
        var out: [NavPlace] = []
        for x in ga {
            for y in gb {
                let xs = Set(x.ways), ys = Set(y.ways)
                if xs == ys { continue }
                var meet: [GeoPoint] = []
                for (node, ws) in waysAt where !ws.isDisjoint(with: xs) && !ws.isDisjoint(with: ys) {
                    meet.append(graph.nodes[node])
                }
                var near = false
                if meet.isEmpty, let close = Self.closest(x.ways.map { graph.ways[$0].points }, y.ways.map { graph.ways[$0].points }), close.d < 150 {
                    meet = [close.p]
                    near = true
                }
                for spot in Self.cluster(meet.enumerated().map { ($0.offset, [$0.element]) }, within: 60) {
                    let p = meet[spot[0]]
                    let where_ = [x.subtitle.components(separatedBy: " · ").first, y.subtitle.components(separatedBy: " · ").first]
                        .compactMap { $0 }.filter { $0 != "Road" }
                    var sub = near ? "Close to each other (not quite joined on the map)" : "Junction"
                    if let system = where_.first { sub += " · \(system)" }
                    out.append(NavPlace(title: "\(x.title) & \(y.title)", subtitle: sub, center: p, targets: [p]))
                }
            }
        }
        return out
    }

    // MARK: Text helpers

    /// Splits "73 & Bearwallow Rd" into its two halves.
    static func split(_ query: String) -> [String] {
        let pattern = #"\s*(?:&|\+|@|,|\bat\b|\band\b|\bwith\b|\bmeets\b|\bx\b| / )\s*"#
        let ns = query as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [query] }
        var parts: [String] = []
        var last = 0
        for m in regex.matches(in: query, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static let abbreviations: [String: String] = [
        "rd": "road", "st": "street", "dr": "drive", "ln": "lane", "hwy": "highway", "rt": "route", "rte": "route",
        "ave": "avenue", "av": "avenue", "pkwy": "parkway", "mtn": "mountain", "mt": "mountain", "br": "branch",
        "brch": "branch", "holw": "hollow", "hol": "hollow", "fk": "fork", "frk": "fork", "crk": "creek", "ck": "creek",
        "cir": "circle", "ct": "court", "trl": "trail", "hl": "hill", "rdg": "ridge", "th": "trailhead",
    ]

    /// Generic words that don't have to match ("Bearwallow Road" finds "Bearwallow Dr").
    static let generic: Set<String> = ["road", "street", "drive", "lane", "avenue", "way", "trail", "highway", "route", "the", "of"]

    static func tokens(_ s: String) -> [String] {
        let cleaned = s.lowercased().replacingOccurrences(of: "#", with: " ").replacingOccurrences(of: "'", with: "")
        var out: [String] = []
        for raw in cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var t = String(raw)
            // "t73" -> "t", "73"
            if t.count > 1, t.first == "t", t.dropFirst().allSatisfy(\.isNumber) { out.append("t"); t.removeFirst() }
            out.append(abbreviations[t] ?? t)
        }
        return out
    }

    /// True when every meaningful word of the query starts some word of the name.
    static func matches(_ query: [String], _ name: [String]) -> Bool {
        let needed = query.filter { !generic.contains($0) }
        let required = needed.isEmpty ? query : needed
        guard !required.isEmpty else { return false }
        return required.allSatisfy { q in name.contains { $0.hasPrefix(q) } }
    }

    static func miles(_ meters: Double) -> String {
        let mi = meters / 1609.344
        return mi < 0.1 ? String(format: "%.0f ft", meters * 3.28084) : String(format: "%.1f mi", mi)
    }

    static func length(_ pts: [GeoPoint]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// A point on the lines near their middle, so the pin sits on the trail.
    static func middle(_ lines: [[GeoPoint]]) -> GeoPoint {
        let all = lines.flatMap { $0 }
        let avg = GeoPoint(lat: all.map(\.lat).reduce(0, +) / Double(all.count), lon: all.map(\.lon).reduce(0, +) / Double(all.count))
        return all.min { $0.distance(to: avg) < $1.distance(to: avg) } ?? avg
    }

    /// Groups items whose points come within `within` meters of each other.
    static func cluster(_ items: [(Int, [GeoPoint])], within: Double) -> [[Int]] {
        var groups: [(ids: [Int], pts: [GeoPoint])] = []
        for (id, pts) in items {
            let sample = stride(from: 0, to: pts.count, by: max(1, pts.count / 30)).map { pts[$0] } + pts.suffix(1)
            var joined: [Int] = []
            for (gi, g) in groups.enumerated() where g.pts.contains(where: { gp in sample.contains { $0.distance(to: gp) <= within } }) {
                joined.append(gi)
            }
            var merged = (ids: [id], pts: sample)
            for gi in joined.reversed() {
                merged.ids += groups[gi].ids
                merged.pts += groups[gi].pts
                groups.remove(at: gi)
            }
            groups.append(merged)
        }
        return groups.map { $0.ids.sorted() }
    }

    /// The closest pair of points between two sets of lines.
    static func closest(_ a: [[GeoPoint]], _ b: [[GeoPoint]]) -> (d: Double, p: GeoPoint)? {
        var best: (d: Double, p: GeoPoint)?
        let az = a.flatMap { $0 }, bs = b.flatMap { $0 }
        guard let a0 = az.first, let b0 = bs.first else { return nil }
        // Skip the slow part when the two are nowhere near each other (about 300 m margin).
        let m = 0.003
        let (aLat, aLon) = (az.map(\.lat), az.map(\.lon)), (bLat, bLon) = (bs.map(\.lat), bs.map(\.lon))
        if aLat.min()! - m > bLat.max()! || bLat.min()! - m > aLat.max()!
            || aLon.min()! - m > bLon.max()! || bLon.min()! - m > aLon.max()! {
            return (a0.distance(to: b0), a0)
        }
        for p in az {
            for q in bs {
                let d = p.distance(to: q)
                if d < (best?.d ?? .infinity) {
                    best = (d, GeoPoint(lat: (p.lat + q.lat) / 2, lon: (p.lon + q.lon) / 2))
                }
            }
        }
        return best
    }
}
