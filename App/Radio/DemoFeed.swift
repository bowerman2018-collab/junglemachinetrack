import Foundation
import APRSCore

/// Fake riders driving around the Hatfield-McCoy area, so the app can be tried before the radios arrive.
/// The packets go through the exact same decoder as real radio data.
final class DemoFeed: ObservableObject {
    @Published private(set) var running = false
    var onPacket: ((APRSPacket) -> Void)?

    private var timer: Timer?
    private var tick = 0

    private struct FakeRider {
        let callsign: String
        let centerLat: Double
        let centerLon: Double
        let radius: Double
        let speed: Double
    }

    private let fakes = [
        FakeRider(callsign: "DEMO-1", centerLat: 37.616, centerLon: -81.866, radius: 0.012, speed: 0.05),
        FakeRider(callsign: "DEMO-2", centerLat: 37.622, centerLon: -81.858, radius: 0.016, speed: 0.035),
        FakeRider(callsign: "DEMO-3", centerLat: 37.605, centerLon: -81.875, radius: 0.009, speed: 0.07),
    ]

    func start() {
        guard !running else { return }
        running = true
        send()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.send() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    private func send() {
        tick += 1
        for (i, f) in fakes.enumerated() {
            let angle = Double(tick) * f.speed + Double(i) * 2
            let lat = f.centerLat + f.radius * sin(angle)
            let lon = f.centerLon + f.radius * 1.3 * cos(angle)
            let course = (Int((angle + .pi / 2) * 180 / .pi) % 360 + 360) % 360
            let line = "\(f.callsign)>APRS,WIDE1-1:!\(Self.lat(lat))/\(Self.lon(lon))j\(String(format: "%03d/%03d", max(course, 1), 12 + i * 3))Demo rider"
            if let packet = TNC2.decode(line) { onPacket?(packet) }
        }
    }

    static func lat(_ v: Double) -> String {
        let a = abs(v), d = Int(a), m = (a - Double(d)) * 60
        return String(format: "%02d%05.2f%@", d, m, v >= 0 ? "N" : "S")
    }

    static func lon(_ v: Double) -> String {
        let a = abs(v), d = Int(a), m = (a - Double(d)) * 60
        return String(format: "%03d%05.2f%@", d, m, v >= 0 ? "E" : "W")
    }
}
