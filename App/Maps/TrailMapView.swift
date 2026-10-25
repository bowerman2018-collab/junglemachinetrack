import SwiftUI
import MapKit

/// The main map: offline tiles, the phone's own location, and a marker plus trail line for each rider.
struct TrailMapView: UIViewRepresentable {
    @ObservedObject var riders: RiderStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var mapState: MapState
    @ObservedObject var trails: TrailStore
    @ObservedObject var nav: Navigator
    /// Long-press on the map, for "route here".
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
    /// The arrow button in a rider's bubble.
    var onRouteToRider: (Rider) -> Void = { _ in }
    /// Changes once a minute so marker fading for stale riders updates even when no packets arrive.
    var clock: Date

    func makeCoordinator() -> Coordinator { Coordinator(mapState: mapState) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(mapState.region, animated: false)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "rider")
        map.register(TrailLabelView.self, forAnnotationViewWithReuseIdentifier: "trailLabel")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "trailhead")
        map.addAnnotations(TrailheadAnnotation.all)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "routeEnd")
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        press.minimumPressDuration = 0.5
        map.addGestureRecognizer(press)
        context.coordinator.installTiles(on: map, source: settings.tileSource, useInternet: settings.useInternetForMaps)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.staleMinutes = settings.staleMinutes
        if c.overlay?.source != settings.tileSource {
            c.installTiles(on: map, source: settings.tileSource, useInternet: settings.useInternetForMaps)
        }
        c.overlay?.useInternet = settings.useInternetForMaps

        c.syncTrails(on: map, trails: settings.showTrailLines ? trails.trails : [])
        c.syncRiders(on: map, riders: riders.visible, showTracks: settings.showTracks)
        c.onLongPress = onLongPress
        c.onRouteToRider = onRouteToRider
        c.syncRoute(on: map, nav: nav)

        if let region = mapState.pendingRegion {
            map.setRegion(region, animated: true)
            DispatchQueue.main.async { mapState.pendingRegion = nil }
        }
        let mode: MKUserTrackingMode = mapState.followUser ? .followWithHeading : .none
        if map.userTrackingMode != mode { map.setUserTrackingMode(mode, animated: true) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let mapState: MapState
        var overlay: CachedTileOverlay?
        var staleMinutes = 10
        var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
        var onRouteToRider: (Rider) -> Void = { _ in }
        private var routeShown = -1
        private var routeOverlays: [MKOverlay] = []
        private var routeMarks: [RouteEndAnnotation] = []
        private var annotations: [String: RiderAnnotation] = [:]
        private var tracks: [String: (line: RiderTrack, count: Int, color: Int)] = [:]
        private var trailLines: [TrailPolyline] = []
        private var trailLabels: [TrailLabelAnnotation] = []
        private var trailsShown: [UUID] = []
        private var labelsVisible = false
        /// Trail numbers appear once zoomed in this far (map height in degrees), so they don't pile up.
        static let labelSpan = 0.12

        init(mapState: MapState) { self.mapState = mapState }

        func installTiles(on map: MKMapView, source: TileSource, useInternet: Bool) {
            if let overlay { map.removeOverlay(overlay) }
            let o = CachedTileOverlay(source: source, useInternet: useInternet)
            map.insertOverlay(o, at: 0, level: .aboveLabels)
            overlay = o
        }

        func syncRiders(on map: MKMapView, riders: [Rider], showTracks: Bool) {
            let ids = Set(riders.map(\.id))
            for (id, a) in annotations where !ids.contains(id) {
                map.removeAnnotation(a)
                annotations[id] = nil
            }
            for (id, t) in tracks where !ids.contains(id) || !showTracks {
                map.removeOverlay(t.line)
                tracks[id] = nil
            }

            for rider in riders {
                guard let coordinate = rider.coordinate else { continue }
                if let a = annotations[rider.id] {
                    let changedLook = a.rider.colorIndex != rider.colorIndex || a.rider.displayName != rider.displayName
                        || a.isStale != isStale(rider)
                    a.rider = rider
                    a.isStale = isStale(rider)
                    if a.coordinate.latitude != coordinate.latitude || a.coordinate.longitude != coordinate.longitude {
                        UIView.animate(withDuration: 0.5) { a.coordinate = coordinate }
                    }
                    if changedLook, let view = map.view(for: a) as? MKMarkerAnnotationView { style(view, a) }
                } else {
                    let a = RiderAnnotation(rider: rider, stale: isStale(rider))
                    annotations[rider.id] = a
                    map.addAnnotation(a)
                }

                guard showTracks, rider.track.count >= 2 else { continue }
                if let t = tracks[rider.id], t.count == rider.track.count, t.color == rider.colorIndex { continue }
                if let old = tracks[rider.id] { map.removeOverlay(old.line) }
                var coords = rider.track.map(\.coordinate)
                let line = RiderTrack(coordinates: &coords, count: coords.count)
                line.color = rider.uiColor
                map.addOverlay(line, level: .aboveLabels)
                tracks[rider.id] = (line, rider.track.count, rider.colorIndex)
            }
        }

        func syncTrails(on map: MKMapView, trails: [TrailLine]) {
            let ids = trails.map(\.id)
            guard ids != trailsShown else { return }
            trailsShown = ids
            map.removeOverlays(trailLines)
            if labelsVisible { map.removeAnnotations(trailLabels) }
            trailLines = []
            trailLabels = []
            for trail in trails {
                let color = trail.colorHex.flatMap(UIColor.init(hex:)) ?? .systemBrown
                for segment in trail.segments {
                    var coords = segment.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                    let line = TrailPolyline(coordinates: &coords, count: coords.count)
                    line.color = color
                    trailLines.append(line)
                    trailLabels.append(TrailLabelAnnotation(coordinate: coords[coords.count / 2], label: trail.label,
                                                            name: trail.name, color: color))
                }
            }
            // Under the rider trail lines, above the map tiles.
            if let overlay {
                for line in trailLines { map.insertOverlay(line, above: overlay) }
            } else {
                map.addOverlays(trailLines, level: .aboveLabels)
            }
            labelsVisible = false
            updateTrailLabels(on: map)
        }

        func updateTrailLabels(on map: MKMapView) {
            let want = map.region.span.latitudeDelta < Self.labelSpan && !trailLabels.isEmpty
            guard want != labelsVisible else { return }
            labelsVisible = want
            if want { map.addAnnotations(trailLabels) } else { map.removeAnnotations(trailLabels) }
        }

        @objc func longPressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            onLongPress(map.convert(g.location(in: map), toCoordinateFrom: map))
        }

        /// The planned route: a bold line on top of the trails, dashed where it leaves them, and pins at the ends.
        func syncRoute(on map: MKMapView, nav: Navigator) {
            guard nav.routeVersion != routeShown else { return }
            routeShown = nav.routeVersion
            map.removeOverlays(routeOverlays)
            map.removeAnnotations(routeMarks)
            routeOverlays = []
            routeMarks = []
            if let route = nav.route {
                let n = route.points.count
                var i0 = 0, i1 = n - 1
                if route.leadIn > 0 { i0 = 1 }
                if route.leadOut > 0 { i1 = n - 2 }
                func line(_ a: Int, _ b: Int, dashed: Bool) {
                    guard b > a else { return }
                    var coords = route.points[a...b].map(\.coordinate)
                    let l = RouteLine(coordinates: &coords, count: coords.count)
                    l.dashed = dashed
                    routeOverlays.append(l)
                }
                line(0, i0, dashed: true)
                line(i0, i1, dashed: false)
                line(i1, n - 1, dashed: true)
                map.addOverlays(routeOverlays, level: .aboveLabels)
            }
            if let place = nav.destination {
                routeMarks.append(RouteEndAnnotation(coordinate: place.center.coordinate, title: place.title, isStart: false))
            }
            if let start = nav.customStart {
                routeMarks.append(RouteEndAnnotation(coordinate: start.coordinate, title: "Start", isStart: true))
            }
            map.addAnnotations(routeMarks)
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let a = view.annotation as? RiderAnnotation { onRouteToRider(a.rider) }
        }

        private func isStale(_ rider: Rider) -> Bool {
            guard let heard = rider.lastHeard else { return true }
            return Date().timeIntervalSince(heard) > Double(staleMinutes * 60)
        }

        private func style(_ view: MKMarkerAnnotationView, _ a: RiderAnnotation) {
            view.markerTintColor = a.rider.uiColor
            view.glyphText = a.rider.initials
            view.titleVisibility = .visible
            view.subtitleVisibility = .adaptive
            view.displayPriority = .required
            view.alpha = a.isStale ? 0.45 : 1
            view.canShowCallout = true
            let go = UIButton(type: .system)
            go.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.circle.fill"), for: .normal)
            go.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            go.accessibilityLabel = "Route to \(a.rider.displayName)"
            view.rightCalloutAccessoryView = go
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let th = annotation as? TrailheadAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "trailhead", for: th) as! MKMarkerAnnotationView
                view.markerTintColor = .systemBrown
                view.glyphImage = UIImage(systemName: "flag.fill")
                view.titleVisibility = .adaptive
                view.displayPriority = .defaultHigh
                view.canShowCallout = true
                return view
            }
            if let end = annotation as? RouteEndAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "routeEnd", for: end) as! MKMarkerAnnotationView
                view.markerTintColor = end.isStart ? .systemGreen : .systemRed
                view.glyphImage = UIImage(systemName: end.isStart ? "figure.wave" : "mappin")
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            if let t = annotation as? TrailLabelAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: "trailLabel", for: t)
            }
            guard let a = annotation as? RiderAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "rider", for: a) as! MKMarkerAnnotationView
            style(view, a)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            if let trail = overlay as? TrailPolyline {
                let r = MKPolylineRenderer(polyline: trail)
                r.strokeColor = trail.color
                r.lineWidth = 3
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            if let route = overlay as? RouteLine {
                let r = MKPolylineRenderer(polyline: route)
                r.strokeColor = UIColor.systemPurple.withAlphaComponent(0.9)
                r.lineWidth = route.dashed ? 4 : 7
                r.lineCap = .round
                r.lineJoin = .round
                if route.dashed { r.lineDashPattern = [6, 8] }
                return r
            }
            if let line = overlay as? RiderTrack {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = line.color.withAlphaComponent(0.8)
                r.lineWidth = 4
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            mapState.region = mapView.region
            updateTrailLabels(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            if mode == .none && mapState.followUser {
                DispatchQueue.main.async { self.mapState.followUser = false }
            }
        }
    }
}

final class RiderAnnotation: NSObject, MKAnnotation {
    var rider: Rider
    var isStale: Bool
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(rider: Rider, stale: Bool) {
        self.rider = rider
        self.isStale = stale
        self.coordinate = rider.coordinate ?? CLLocationCoordinate2D()
    }

    var title: String? { rider.displayName }

    var subtitle: String? {
        guard let heard = rider.lastHeard else { return rider.callsign }
        let ago = RelativeDateTimeFormatter().localizedString(for: heard, relativeTo: Date())
        return "\(rider.callsign) · \(ago)"
    }
}

/// The planned route line.
final class RouteLine: MKPolyline {
    var dashed = false
}

/// The destination pin, and the start pin when you picked one on the map.
final class RouteEndAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let isStart: Bool

    init(coordinate: CLLocationCoordinate2D, title: String, isStart: Bool) {
        self.coordinate = coordinate
        self.title = title
        self.isStart = isStart
    }
}

final class RiderTrack: MKPolyline {
    var color: UIColor = .systemRed
}

/// A Hatfield-McCoy trailhead, always shown so you can find your way back.
final class TrailheadAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(coordinate: CLLocationCoordinate2D, title: String, subtitle: String) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
    }

    /// One marker per trailhead (Rockhouse and Braveheart share one).
    static let all: [TrailheadAnnotation] = {
        var seen = Set<String>()
        return TrailSystem.hatfieldMcCoy.compactMap { s in
            guard seen.insert(s.trailhead).inserted else { return nil }
            let names = TrailSystem.hatfieldMcCoy.filter { $0.trailhead == s.trailhead }.map(\.name).joined(separator: " / ")
            return TrailheadAnnotation(coordinate: s.trailheadCoordinate, title: "\(names) Trailhead", subtitle: s.trailhead)
        }
    }()
}
