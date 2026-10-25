import Foundation
import MapKit

/// An area the user saved for offline use. Only a record for the list; the tiles themselves live in TileCache.
struct SavedArea: Codable, Identifiable {
    var id = UUID()
    var name: String
    var sourceID: String
    var centerLat: Double
    var centerLon: Double
    var spanLat: Double
    var spanLon: Double
    var minZoom: Int
    var maxZoom: Int
    var tileCount: Int
    var date: Date

    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: centerLat, longitude: centerLon),
                           span: .init(latitudeDelta: spanLat, longitudeDelta: spanLon))
    }
}

/// Downloads every tile in an area so the map works with no signal.
@MainActor
final class TileDownloader: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var failed = 0
    @Published private(set) var areas: [SavedArea] = []
    @Published private(set) var bytesOnDisk: Int64 = 0

    /// Rough average size of one USGS tile, for the estimate shown before downloading.
    static let averageTileBytes = 18_000
    static let maxTilesPerDownload = 150_000

    private var task: Task<Void, Never>?
    private let areasURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("saved-areas.json")
    }()

    init() {
        if let data = try? Data(contentsOf: areasURL), let saved = try? JSONDecoder().decode([SavedArea].self, from: data) {
            areas = saved
        }
        refreshSize()
    }

    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    func download(name: String, region: MKCoordinateRegion, zooms: ClosedRange<Int>, source: TileSource) {
        guard !isRunning else { return }
        let keys = zooms.flatMap { TileMath.tiles(in: region, zoom: $0) }
        isRunning = true
        done = 0
        failed = 0
        total = keys.count
        let cache = TileCache.shared

        task = Task { [weak self] in
            let session = URLSession(configuration: .default)
            var index = 0
            // Six downloads at a time: quick, but gentle on the USGS servers.
            await withTaskGroup(of: Bool.self) { group in
                func addNext() {
                    guard index < keys.count else { return }
                    let key = keys[index]
                    index += 1
                    group.addTask {
                        if cache.has(source, key) { return true }
                        guard let url = source.url(z: key.z, x: key.x, y: key.y) else { return false }
                        var request = URLRequest(url: url, timeoutInterval: 30)
                        request.setValue("TrailTracker/0.1 (offline trail map)", forHTTPHeaderField: "User-Agent")
                        for _ in 0..<3 {
                            if Task.isCancelled { return false }
                            if let (data, response) = try? await session.data(for: request),
                               (response as? HTTPURLResponse)?.statusCode == 200 {
                                cache.store(data, source, key)
                                return true
                            }
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        return false
                    }
                }
                for _ in 0..<6 { addNext() }
                for await ok in group {
                    await self?.record(ok)
                    if Task.isCancelled { group.cancelAll(); break }
                    addNext()
                }
            }
            guard let self else { return }
            if !Task.isCancelled {
                self.areas.insert(SavedArea(name: name, sourceID: source.id,
                                            centerLat: region.center.latitude, centerLon: region.center.longitude,
                                            spanLat: region.span.latitudeDelta, spanLon: region.span.longitudeDelta,
                                            minZoom: zooms.lowerBound, maxZoom: zooms.upperBound,
                                            tileCount: keys.count, date: Date()), at: 0)
                self.saveAreas()
            }
            self.isRunning = false
            self.refreshSize()
        }
    }

    private func record(_ ok: Bool) {
        done += 1
        if !ok { failed += 1 }
    }

    func cancel() {
        task?.cancel()
    }

    func removeRecord(_ area: SavedArea) {
        areas.removeAll { $0.id == area.id }
        saveAreas()
    }

    func deleteAllTiles() {
        TileCache.shared.deleteAll()
        areas.removeAll()
        saveAreas()
        refreshSize()
    }

    func refreshSize() {
        Task.detached(priority: .utility) {
            let size = TileCache.shared.sizeOnDisk()
            await MainActor.run { self.bytesOnDisk = size }
        }
    }

    private func saveAreas() {
        if let data = try? JSONEncoder().encode(areas) { try? data.write(to: areasURL, options: .atomic) }
    }
}
