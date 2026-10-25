import Foundation
import MapKit
import UIKit

/// Trail lines imported from a map file (e.g. the official Hatfield-McCoy KMZ), saved on the phone.
final class TrailStore: ObservableObject {
    @Published private(set) var trails: [TrailLine] = []
    @Published private(set) var sourceName: String?
    @Published var lastError: String?

    private let fileURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trails.json")
    }()

    private struct Saved: Codable {
        var sourceName: String
        var trails: [TrailLine]
    }

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            trails = saved.trails
            sourceName = saved.sourceName
        } else {
            loadBuiltIn()
        }
    }

    static let builtInName = "Built-in Hatfield-McCoy trails"

    /// Trails that ship with the app (App/Resources/hmt-trails.json), used until a file is imported.
    private func loadBuiltIn() {
        guard let url = Bundle.main.url(forResource: "hmt-trails", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let builtIn = try? JSONDecoder().decode([TrailLine].self, from: data) else { return }
        trails = builtIn
        sourceName = Self.builtInName
    }

    /// Replaces the current trails with the ones in this file.
    func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let loaded = try TrailImporter.load(url)
            trails = loaded
            sourceName = url.lastPathComponent
            lastError = nil
            let saved = Saved(sourceName: url.lastPathComponent, trails: loaded)
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: fileURL, options: .atomic) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Removes an imported file and goes back to the built-in trails, if the app has them.
    func removeAll() {
        trails = []
        sourceName = nil
        try? FileManager.default.removeItem(at: fileURL)
        loadBuiltIn()
    }

    var isBuiltIn: Bool { sourceName == Self.builtInName }

    var boundingRegion: MKCoordinateRegion? {
        let points = trails.flatMap { $0.segments.flatMap { $0 } }
        guard let first = points.first else { return nil }
        var minLon = first[0], maxLon = first[0], minLat = first[1], maxLat = first[1]
        for p in points {
            minLon = min(minLon, p[0]); maxLon = max(maxLon, p[0])
            minLat = min(minLat, p[1]); maxLat = max(maxLat, p[1])
        }
        return MKCoordinateRegion(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: .init(latitudeDelta: (maxLat - minLat) * 1.1 + 0.01, longitudeDelta: (maxLon - minLon) * 1.1 + 0.01))
    }
}

/// One drawn segment of a trail.
final class TrailPolyline: MKPolyline {
    var color: UIColor = .systemBrown
}

/// A trail-number tag placed partway along a trail.
final class TrailLabelAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let label: String
    let name: String
    let color: UIColor

    init(coordinate: CLLocationCoordinate2D, label: String, name: String, color: UIColor) {
        self.coordinate = coordinate
        self.label = label
        self.name = name
        self.color = color
    }

    var title: String? { name }
}

/// Small rounded tag with the trail number, like the signs at trail junctions.
final class TrailLabelView: MKAnnotationView {
    private let text = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        text.font = .systemFont(ofSize: 11, weight: .bold)
        text.textAlignment = .center
        text.textColor = .white
        addSubview(text)
        layer.cornerRadius = 5
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.cgColor
        canShowCallout = true
        displayPriority = .defaultLow
        collisionMode = .rectangle
    }

    required init?(coder: NSCoder) { fatalError() }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        guard let a = annotation as? TrailLabelAnnotation else { return }
        text.text = a.label
        let size = text.intrinsicContentSize
        let w = min(max(size.width + 10, 22), 120), h: CGFloat = 18
        frame = CGRect(x: 0, y: 0, width: w, height: h)
        text.frame = bounds
        backgroundColor = a.color
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
