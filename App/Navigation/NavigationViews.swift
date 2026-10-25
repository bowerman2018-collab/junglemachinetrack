import SwiftUI
import CoreLocation

/// Type a trail number, a road, or "trail & road" to find it and route there.
struct NavSearchScreen: View {
    @EnvironmentObject var nav: Navigator
    @EnvironmentObject var location: LocationTracker
    @EnvironmentObject var mapState: MapState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [NavPlace] = []
    @State private var searched = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if nav.graph == nil {
                    Section {
                        Label(nav.building ? "Getting the trail network ready…" : "Import the Hatfield-McCoy trail map in the Offline Maps tab first. Search and routing use it.",
                              systemImage: nav.building ? "hourglass" : "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("Try") {
                        ForEach(["73", "Bearwallow 73", "73 & 74", "73 and Bearwallow Rd", "Rockhouse trailhead", "US 52"], id: \.self) { example in
                            Button(example) { query = example }
                        }
                    }
                    Section {
                        Text("You can also long-press anywhere on the map to route there, or tap a rider and the arrow button to route to them.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if results.isEmpty && searched {
                    Text("Nothing found for \"\(query)\". Check the trail number, or try just the road's main word, like \"Bearwallow\".")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { place in
                        Button {
                            nav.navigate(to: place)
                            showRoute(place)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.title).font(.body.weight(.semibold))
                                Text(place.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Trail number, road, or 73 & Bearwallow Rd")
            .autocorrectionDisabled()
            .task(id: query) {
                // Wait for a pause in typing before searching.
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let near = location.location.map { GeoPoint($0.coordinate) } ?? GeoPoint(mapState.region.center)
                results = nav.search?.search(query, near: near) ?? []
                searched = true
            }
            .navigationTitle("Go to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func showRoute(_ place: NavPlace) {
        var coords = nav.route?.points.map(\.coordinate) ?? []
        if coords.isEmpty { coords = [place.center.coordinate] }
        mapState.fit(coords)
    }
}

/// Bottom card while a destination is set: distance, time, and start/stop.
struct RoutePanel: View {
    @EnvironmentObject var nav: Navigator
    @EnvironmentObject var mapState: MapState
    @State private var showSteps = false

    var body: some View {
        if let place = nav.destination {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.title).font(.headline).lineLimit(2)
                        if let route = nav.route {
                            Text(summary(route)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { nav.clear() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("End route")
                }
                if let problem = nav.problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    if nav.route != nil {
                        Button {
                            nav.active.toggle()
                            if nav.active { mapState.followUser = true }
                        } label: {
                            Label(nav.active ? "Stop" : "Go", systemImage: nav.active ? "stop.fill" : "location.north.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(nav.active ? .red : .blue)

                        Button { showSteps = true } label: {
                            Label("Steps", systemImage: "list.bullet").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Menu {
                        Toggle("Use roads between trails", isOn: $nav.options.useRoads)
                        Toggle("Avoid Most Difficult trails", isOn: $nav.options.avoidMostDifficult)
                        Toggle("Avoid single track (bikes only)", isOn: $nav.options.avoidSingleTrack)
                        if nav.customStart != nil {
                            Button("Start from my location") { nav.startHere(nil) }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 30)
                    }
                    .buttonStyle(.bordered)
                }
                if nav.customStart != nil {
                    Text("Starting from the point you picked on the map.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
            .sheet(isPresented: $showSteps) { RouteStepsScreen() }
        }
    }

    private func summary(_ route: Route) -> String {
        var s = "\(NavSearch.miles(route.length)) · about \(Navigator.minutes(route)) min"
        if route.roadMeters > 50 { s += " · \(NavSearch.miles(route.roadMeters)) on roads" }
        return s
    }
}

/// Top banner while following a route: the next turn and how far to it.
struct TurnBanner: View {
    @EnvironmentObject var nav: Navigator

    var body: some View {
        if nav.active, let p = nav.progress {
            HStack(spacing: 12) {
                Image(systemName: p.arrived ? "flag.checkered" : icon(p.next?.turn))
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    if p.arrived {
                        Text("You've arrived").font(.title3.weight(.bold))
                    } else if let next = p.next {
                        Text("\(NavSearch.miles(p.toNext))").font(.title3.weight(.bold))
                        Text("\(next.turn) onto \(next.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                    } else {
                        Text("\(NavSearch.miles(p.remaining))").font(.title3.weight(.bold))
                        Text("to the destination").font(.subheadline)
                    }
                    if p.offRoute > 60 && !p.arrived {
                        Text("Off the route by \(NavSearch.miles(p.offRoute))").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    } else if !p.arrived {
                        Text("\(NavSearch.miles(p.remaining)) left").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
        }
    }

    private func icon(_ turn: String?) -> String {
        switch turn ?? "" {
        case "Turn left": return "arrow.turn.up.left"
        case "Turn right": return "arrow.turn.up.right"
        case "Bear left": return "arrow.up.left"
        case "Bear right": return "arrow.up.right"
        case "Sharp left": return "arrow.uturn.left"
        case "Sharp right": return "arrow.uturn.right"
        case "Then": return "mappin.and.ellipse"
        default: return "arrow.up"
        }
    }
}

/// The whole route as a list: "Turn right onto Trail 74 · 1.2 mi".
struct RouteStepsScreen: View {
    @EnvironmentObject var nav: Navigator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let route = nav.route {
                    ForEach(Array(route.steps.enumerated()), id: \.offset) { _, step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.turn == "Start" ? "Start on \(step.title)" : step.turn == "Then" ? step.title : "\(step.turn) onto \(step.title)")
                                .font(.body.weight(.semibold))
                            Text("\(NavSearch.miles(step.length))\(step.kind == .road ? " · road" : step.kind == nil ? " · off trail, straight line" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text("Routes follow the official trail map and avoid trails your settings rule out. Always follow posted trail signs and closures.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(nav.destination?.title ?? "Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
