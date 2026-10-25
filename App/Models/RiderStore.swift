import Foundation
import SwiftUI
import CoreLocation
import APRSCore

struct TrackPoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var time: Date

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct Rider: Codable, Identifiable, Hashable {
    /// Callsign with SSID, e.g. "KD8ABC-7". This is how riders are matched to packets.
    var id: String
    var name: String
    var colorIndex: Int
    var hidden = false
    var latitude: Double?
    var longitude: Double?
    var lastHeard: Date?
    var courseDegrees: Int?
    var speedKnots: Double?
    var altitudeFeet: Double?
    var comment = ""
    var symbolCode = ">"
    var track: [TrackPoint] = []

    var callsign: String { id }
    var displayName: String { name.isEmpty ? id : name }
    var color: Color { Color(uiColor: uiColor) }
    var uiColor: UIColor { RiderPalette.colors[colorIndex % RiderPalette.colors.count] }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }

    var speedMPH: Double? { speedKnots.map { $0 * 1.15078 } }

    var initials: String {
        let words = displayName.split(separator: " ")
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(displayName.prefix(2)).uppercased()
    }
}

enum RiderPalette {
    static let colors: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange,
                                    .systemPurple, .systemPink, .systemTeal, .systemYellow, .systemBrown, .systemIndigo]
}

/// Everyone the app has heard, saved on the phone. Anyone with a radio on the same frequency
/// shows up automatically the first time they beacon, so adding a rider needs no setup.
final class RiderStore: ObservableObject {
    @Published private(set) var riders: [String: Rider] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("riders.json")
    }()
    private var saveWork: DispatchWorkItem?

    static let maxTrackPoints = 3000

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Rider].self, from: data) {
            riders = saved
        }
    }

    var sorted: [Rider] {
        riders.values.sorted { ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast) }
    }

    var visible: [Rider] { riders.values.filter { !$0.hidden && $0.coordinate != nil } }

    func ingest(_ report: APRSReport) {
        let key = report.station.uppercased()
        let p = report.position
        var rider = riders[key] ?? Rider(id: key, name: "", colorIndex: nextColor())
        let now = Date()
        rider.latitude = p.latitude
        rider.longitude = p.longitude
        rider.lastHeard = now
        rider.courseDegrees = p.courseDegrees
        rider.speedKnots = p.speedKnots
        if let alt = p.altitudeFeet { rider.altitudeFeet = alt }
        if !p.comment.isEmpty { rider.comment = p.comment }
        rider.symbolCode = String(p.symbolCode)

        let point = TrackPoint(latitude: p.latitude, longitude: p.longitude, time: now)
        if let last = rider.track.last {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
            if moved > 10 { rider.track.append(point) }
        } else {
            rider.track.append(point)
        }
        if rider.track.count > Self.maxTrackPoints {
            rider.track.removeFirst(rider.track.count - Self.maxTrackPoints)
        }
        riders[key] = rider
        scheduleSave()
    }

    /// Pre-registers a rider so they have a name and color before their first beacon.
    func add(callsign: String, name: String) {
        let key = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !key.isEmpty else { return }
        var rider = riders[key] ?? Rider(id: key, name: "", colorIndex: nextColor())
        rider.name = name
        riders[key] = rider
        scheduleSave()
    }

    func update(_ rider: Rider) {
        riders[rider.id] = rider
        scheduleSave()
    }

    func remove(_ id: String) {
        riders[id] = nil
        scheduleSave()
    }

    func clearTracks() {
        for key in riders.keys { riders[key]?.track.removeAll() }
        scheduleSave()
    }

    private func nextColor() -> Int {
        let used = Set(riders.values.map(\.colorIndex))
        return (0..<RiderPalette.colors.count).first { !used.contains($0) } ?? riders.count
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = riders
        let url = fileURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }
}
