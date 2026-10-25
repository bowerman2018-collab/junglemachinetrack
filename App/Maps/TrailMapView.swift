import SwiftUI
import MapKit

/// The main map: offline tiles, the phone's own location, and a marker plus trail line for each rider.
struct TrailMapView: UIViewRepresentable {
    @ObservedObject var riders: RiderStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var mapState: MapState
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

        c.syncRiders(on: map, riders: riders.visible, showTracks: settings.showTracks)

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
        private var annotations: [String: RiderAnnotation] = [:]
        private var tracks: [String: (line: RiderTrack, count: Int, color: Int)] = [:]

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
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? RiderAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "rider", for: a) as! MKMarkerAnnotationView
            style(view, a)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
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

final class RiderTrack: MKPolyline {
    var color: UIColor = .systemRed
}
