// Checks the offline route finder and search on a small made-up trail network.
// Run: swiftc App/Navigation/TrailGraph.swift App/Navigation/NavSearch.swift Tests/NavigationCheck/main.swift -o nav-check && ./nav-check
import Foundation

func expect(_ ok: Bool, _ message: String) {
    if !ok { print("FAIL: \(message)"); exit(1) }
}

func line(_ from: (Double, Double), _ to: (Double, Double), steps: Int = 10) -> [GeoPoint] {
    (0...steps).map { i in
        let t = Double(i) / Double(steps)
        return GeoPoint(lat: from.0 + t * (to.0 - from.0), lon: from.1 + t * (to.1 - from.1))
    }
}

// 73 runs east; 74 runs north and crosses it between vertices; 75 (Most Difficult) starts 8 m from 74's top;
// Bearwallow Rd links 73's east end to 75's east end; 80 is single track.
let ways = [
    NavWay(kind: .trail, label: "73", system: "Test", difficulty: "Easiest", points: line((37.70, -81.90), (37.70, -81.88), steps: 9)),
    NavWay(kind: .trail, label: "74", system: "Test", difficulty: "More Difficult", points: line((37.69, -81.89), (37.71, -81.89), steps: 7)),
    NavWay(kind: .trail, label: "75", system: "Test", difficulty: "Most Difficult", points: line((37.71, -81.88991), (37.71, -81.87))),
    NavWay(kind: .road, label: "Bearwallow Rd", system: "", aliases: ["CR 3"], difficulty: "unclassified",
           points: line((37.70009, -81.88), (37.71, -81.87))),
    NavWay(kind: .trail, label: "80", system: "Test", difficulty: "Single Track Most", points: line((37.70, -81.90), (37.71, -81.87), steps: 3)),
    NavWay(kind: .trail, label: "73", system: "Other Place", difficulty: "Easiest", points: line((37.90, -81.90), (37.90, -81.88))),
]
let graph = TrailGraph(ways: ways)
print("nodes \(graph.nodes.count), edges \(graph.edges.count)")
let search = NavSearch(graph: graph, landmarks: [(name: "Test Trailhead", point: GeoPoint(lat: 37.70, lon: -81.90))])
let home = GeoPoint(lat: 37.70, lon: -81.90)

// Search
let t73 = search.search("73", near: home)
expect(t73.count == 2, "73 should be found in two systems, got \(t73.map(\.subtitle))")
expect(t73[0].subtitle.hasPrefix("Test"), "nearest system first: \(t73[0].subtitle)")
expect(search.search("Test 73", near: home).count == 1, "system name narrows it down")
expect(search.search("trail #73", near: home).count == 2, "'trail #73' works")
expect(search.search("99", near: home).isEmpty, "no trail 99")

let j = search.search("73 & 74", near: home)
expect(j.count == 1, "one junction of 73 and 74, got \(j.count)")
expect(j[0].center.distance(to: GeoPoint(lat: 37.70, lon: -81.89)) < 5, "junction where they cross, off by \(j[0].center.distance(to: GeoPoint(lat: 37.70, lon: -81.89))) m")

for q in ["73 and Bearwallow Rd", "73 at bearwallow road", "Bearwallow & 73", "73, CR 3", "73 @ county route 3"] {
    let r = search.search(q, near: home)
    expect(r.count == 1, "\(q): expected one result, got \(r.map(\.title))")
    expect(r[0].center.distance(to: GeoPoint(lat: 37.70, lon: -81.88)) < 30, "\(q): at 73's east end")
}
expect(search.search("74 & 75", near: home).count == 1, "74 and 75 are joined even with a small gap")
expect(search.search("test trailhead", near: home).count == 1, "trailheads")
expect(NavSearch.split("73 & Bearwallow Rd") == ["73", "Bearwallow Rd"], "split")
expect(NavSearch.tokens("T73 Bearwallow Rd") == ["t", "73", "bearwallow", "road"], "tokens \(NavSearch.tokens("T73 Bearwallow Rd"))")

// Routing
let goal = GeoPoint(lat: 37.71, lon: -81.87)
guard let r1 = graph.route(from: home, to: [goal], options: RouteOptions()) else { expect(false, "no route"); exit(1) }
print("default:", r1.steps.map { "\($0.turn) \($0.title) \(Int($0.length))m" }, Int(r1.length))
expect(r1.steps.map(\.title) == ["Trail 73", "Trail 74", "Trail 75"], "trails 73 -> 74 -> 75, got \(r1.steps.map(\.title))")
expect(r1.steps[1].turn == "Turn left", "east then north is a left turn, got \(r1.steps[1].turn)")
expect(r1.steps[2].turn == "Turn right", "north then east is a right turn, got \(r1.steps[2].turn)")
expect(abs(r1.length - 3770) < 120, "length about 3.77 km, got \(r1.length)")
expect(r1.roadMeters == 0, "no roads needed")

var easy = RouteOptions()
easy.avoidMostDifficult = true
guard let r2 = graph.route(from: home, to: [goal], options: easy) else { expect(false, "no easy route"); exit(1) }
print("avoid most difficult:", r2.steps.map { "\($0.turn) \($0.title) \(Int($0.length))m" })
expect(r2.steps.map(\.title) == ["Trail 73", "Bearwallow Rd"], "uses the road instead of 75, got \(r2.steps.map(\.title))")
expect(r2.roadMeters > 1000, "road part counted")

easy.useRoads = false
expect(graph.route(from: home, to: [goal], options: easy) == nil, "no way there without 75 or roads")

// Starting off-trail draws a lead-in; whole-trail targets pick the nearest bit.
guard let r3 = graph.route(from: GeoPoint(lat: 37.695, lon: -81.895), to: search.search("75", near: home)[0].targets, options: RouteOptions()) else {
    expect(false, "no route to trail 75"); exit(1)
}
print("to 75:", r3.steps.map { "\($0.turn) \($0.title) \(Int($0.length))m" })
expect(r3.leadIn > 400, "lead-in from off trail, got \(r3.leadIn)")
expect(r3.points.last!.distance(to: GeoPoint(lat: 37.71, lon: -81.88991)) < 15, "stops as soon as it reaches 75")
print("OK")
