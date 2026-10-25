import Foundation
import MapKit
import UIKit

/// A map tile server. USGS maps are US-government public domain, so downloading areas for offline use is allowed.
struct TileSource: Identifiable, Hashable {
    let id: String
    let name: String
    let urlTemplate: String
    let maxZoom: Int
    let attribution: String

    static let usgsTopo = TileSource(
        id: "usgs-topo", name: "Topo (USGS)",
        urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
        maxZoom: 16, attribution: "USGS The National Map")
    static let usgsImagery = TileSource(
        id: "usgs-imagery", name: "Satellite + Topo (USGS)",
        urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}",
        maxZoom: 16, attribution: "USGS The National Map")

    static let all = [usgsTopo, usgsImagery]

    func url(z: Int, x: Int, y: Int) -> URL? {
        URL(string: urlTemplate
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)"))
    }
}

struct TileKey: Hashable {
    let z: Int, x: Int, y: Int
}

/// Tiles saved on the phone, one file per tile: Application Support/tiles/<source>/<z>/<x>/<y>.
final class TileCache {
    static let shared = TileCache()

    let root: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep tiles out of iCloud backups; they can be re-downloaded.
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }()

    func fileURL(_ source: TileSource, _ key: TileKey) -> URL {
        root.appendingPathComponent(source.id)
            .appendingPathComponent("\(key.z)")
            .appendingPathComponent("\(key.x)")
            .appendingPathComponent("\(key.y)")
    }

    func has(_ source: TileSource, _ key: TileKey) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(source, key).path)
    }

    func data(_ source: TileSource, _ key: TileKey) -> Data? {
        try? Data(contentsOf: fileURL(source, key))
    }

    func store(_ data: Data, _ source: TileSource, _ key: TileKey) {
        let url = fileURL(source, key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Total size of saved tiles, in bytes.
    func sizeOnDisk() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func deleteAll() {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
    }

    /// Builds a tile from a lower-zoom tile we do have, so zooming past what was downloaded still shows something.
    func upscaled(_ source: TileSource, _ key: TileKey, maxLevelsUp: Int = 6) -> Data? {
        for up in 1...maxLevelsUp {
            let z = key.z - up
            guard z >= 0 else { return nil }
            let parent = TileKey(z: z, x: key.x >> up, y: key.y >> up)
            guard let data = data(source, parent), let image = UIImage(data: data), let cg = image.cgImage else { continue }
            let parts = 1 << up
            let w = cg.width / parts, h = cg.height / parts
            guard w > 0, h > 0 else { return nil }
            let rect = CGRect(x: (key.x % parts) * w, y: (key.y % parts) * h, width: w, height: h)
            guard let cropped = cg.cropping(to: rect) else { return nil }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
            let scaled = renderer.image { ctx in
                ctx.cgContext.interpolationQuality = .high
                UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
            return scaled.pngData()
        }
        return nil
    }
}

/// Web-Mercator tile math.
enum TileMath {
    static func tileX(_ lon: Double, _ z: Int) -> Int {
        let n = Double(1 << z)
        return min(max(Int(floor((lon + 180) / 360 * n)), 0), (1 << z) - 1)
    }

    static func tileY(_ lat: Double, _ z: Int) -> Int {
        let n = Double(1 << z)
        let r = lat * .pi / 180
        let y = (1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * n
        return min(max(Int(floor(y)), 0), (1 << z) - 1)
    }

    static func tiles(in region: MKCoordinateRegion, zoom: Int) -> [TileKey] {
        let north = min(region.center.latitude + region.span.latitudeDelta / 2, 85)
        let south = max(region.center.latitude - region.span.latitudeDelta / 2, -85)
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2
        let x0 = tileX(west, zoom), x1 = tileX(east, zoom)
        let y0 = tileY(north, zoom), y1 = tileY(south, zoom)
        var out: [TileKey] = []
        out.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for x in x0...x1 { for y in y0...y1 { out.append(TileKey(z: zoom, x: x, y: y)) } }
        return out
    }

    static func count(in region: MKCoordinateRegion, zooms: ClosedRange<Int>) -> Int {
        zooms.reduce(0) { total, z in
            let north = min(region.center.latitude + region.span.latitudeDelta / 2, 85)
            let south = max(region.center.latitude - region.span.latitudeDelta / 2, -85)
            let xs = tileX(region.center.longitude + region.span.longitudeDelta / 2, z)
                - tileX(region.center.longitude - region.span.longitudeDelta / 2, z) + 1
            let ys = tileY(south, z) - tileY(north, z) + 1
            return total + xs * ys
        }
    }
}

/// Map overlay that draws tiles from the phone first, and only goes online if the user allows it.
final class CachedTileOverlay: MKTileOverlay {
    let source: TileSource
    var useInternet: Bool
    private let cache = TileCache.shared

    init(source: TileSource, useInternet: Bool) {
        self.source = source
        self.useInternet = useInternet
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 19
        canReplaceMapContent = true
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let key = TileKey(z: path.z, x: path.x, y: path.y)
        if let data = cache.data(source, key) {
            result(data, nil)
            return
        }
        // Past the server's most detailed level, or offline: stretch a lower-zoom tile we already have.
        if !useInternet || path.z > source.maxZoom {
            result(cache.upscaled(source, key), nil)
            return
        }
        guard let url = source.url(z: path.z, x: path.x, y: path.y) else {
            result(nil, nil)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("TrailTracker/0.1 (offline trail map)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [cache, source] data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil {
                cache.store(data, source, key)  // anything looked at online is kept for offline use
                result(data, nil)
            } else {
                result(cache.upscaled(source, key), nil)
            }
        }.resume()
    }
}
