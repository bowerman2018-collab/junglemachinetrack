import SwiftUI
import MapKit
import CoreLocation

/// The spot the user calls home, remembered on the phone only.
struct HomeArea: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMiles: Int

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// A square around home, `radiusMiles` from the center to each edge.
    var region: MKCoordinateRegion {
        let meters = Double(radiusMiles) * 1609.34 * 2
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: meters, longitudinalMeters: meters)
    }

    private static let key = "homeArea"

    static func load() -> HomeArea? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HomeArea.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Offline Maps section for downloading the area around home: find it by town or address, or use the phone's GPS.
struct HomeAreaSection: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var downloader: TileDownloader
    @EnvironmentObject var location: LocationTracker
    @State private var home = HomeArea.load()
    @State private var query = ""
    @State private var searching = false
    @State private var searchError: String?
    @State private var radiusMiles = HomeArea.load()?.radiusMiles ?? 10
    @State private var topo = true
    @State private var satellite = true

    static let radii = [5, 10, 25, 50]
    private let zooms = 10...15

    var body: some View {
        Section {
            if let home {
                Label(home.name, systemImage: "house.fill")
                Button("Show home on the map") { mapState.pendingRegion = area(home).region }
            }
            HStack {
                TextField("Town, ZIP code, or address", text: $query)
                    .textContentType(.fullStreetAddress)
                    .submitLabel(.search)
                    .onSubmit(search)
                if searching { ProgressView() }
            }
            Button("Find it", action: search)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching || !settings.useInternetForMaps)
            Button("Use where I am now") { useCurrentLocation() }
                .disabled(location.location == nil)
            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.red)
            }

            if let home {
                Picker("How far around home", selection: $radiusMiles) {
                    ForEach(Self.radii, id: \.self) { Text("\($0) miles").tag($0) }
                }
                Toggle("Topo map", isOn: $topo)
                Toggle("Satellite map", isOn: $satellite)
                LabeledContent("Size", value: estimate(area(home)))
                Button(downloader.isRunning ? "Add home maps to the queue" : "Download maps around home") {
                    download(area(home))
                }
                .disabled(sources.isEmpty || !settings.useInternetForMaps || tileCount(area(home)) > TileDownloader.maxTilesPerDownload)
            }
        } header: {
            Text("Maps where I live")
        } footer: {
            Text(footer)
        }
        .onChange(of: radiusMiles) { _, miles in
            home?.radiusMiles = miles
            home?.save()
        }
    }

    private var footer: String {
        if !settings.useInternetForMaps { return "Turn on \"Use internet for maps\" to find your town and download its maps." }
        if let home, tileCount(area(home)) > TileDownloader.maxTilesPerDownload {
            return "That's too much at once. Pick a smaller distance or just one map style."
        }
        return "Type your town or address and tap Find it, or tap \"Use where I am now\" while you're at home. Finding a town asks Apple's map service; your home is saved only on this phone. Maps are USGS, so they cover the United States. Do this on Wi-Fi."
    }

    private var sources: [TileSource] {
        (topo ? [TileSource.usgsTopo] : []) + (satellite ? [TileSource.usgsImagery] : [])
    }

    private func area(_ home: HomeArea) -> HomeArea {
        var h = home
        h.radiusMiles = radiusMiles
        return h
    }

    private func tileCount(_ home: HomeArea) -> Int {
        TileMath.count(in: home.region, zooms: zooms) * max(sources.count, 1)
    }

    private func estimate(_ home: HomeArea) -> String {
        let perStyle = TileMath.count(in: home.region, zooms: zooms)
        // Satellite tiles are photos and run roughly twice the size of topo tiles.
        let bytes = Int64(perStyle * TileDownloader.averageTileBytes * ((topo ? 1 : 0) + (satellite ? 2 : 0)))
        return "\((perStyle * sources.count).formatted()) tiles, about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private func download(_ home: HomeArea) {
        for source in sources {
            downloader.download(name: "Home · \(home.name)", region: home.region,
                                zooms: zooms.lowerBound...min(zooms.upperBound, source.maxZoom), source: source)
        }
    }

    private func setHome(name: String, coordinate: CLLocationCoordinate2D) {
        let h = HomeArea(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude, radiusMiles: radiusMiles)
        h.save()
        home = h
        mapState.pendingRegion = h.region
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, settings.useInternetForMaps else { return }
        searching = true
        searchError = nil
        CLGeocoder().geocodeAddressString(text) { placemarks, _ in
            searching = false
            guard let place = placemarks?.first, let coordinate = place.location?.coordinate else {
                searchError = "Couldn't find \"\(text)\". Try the town and state, like \"Logan, WV\"."
                return
            }
            setHome(name: Self.label(place) ?? text, coordinate: coordinate)
            query = ""
        }
    }

    private func useCurrentLocation() {
        guard let here = location.location?.coordinate else { return }
        searchError = nil
        // Named locally rather than looked up, so the phone's GPS position never leaves the phone.
        setHome(name: "Home (from my GPS)", coordinate: here)
    }

    /// "Logan, WV" style name for a found place.
    private static func label(_ place: CLPlacemark) -> String? {
        let parts = [place.locality ?? place.subAdministrativeArea ?? place.name, place.administrativeArea].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
