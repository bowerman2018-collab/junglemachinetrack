import SwiftUI
import APRSCore

@main
struct TrailTrackerApp: App {
    @StateObject private var riders = RiderStore()
    @StateObject private var radio = RadioLink()
    @StateObject private var demo = DemoFeed()
    @StateObject private var settings = AppSettings()
    @StateObject private var mapState = MapState()
    @StateObject private var location = LocationTracker()
    @StateObject private var downloader = TileDownloader()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(riders)
                .environmentObject(radio)
                .environmentObject(demo)
                .environmentObject(settings)
                .environmentObject(mapState)
                .environmentObject(location)
                .environmentObject(downloader)
                .onAppear(perform: wire)
        }
    }

    /// Every packet, from the radio or the demo feed, goes through the same decoder into the rider list.
    private func wire() {
        let handle: (APRSPacket) -> Void = { [riders, radio] packet in
            guard let report = APRSParser.parse(packet) else {
                radio.note("Not a position: \(packet.tnc2)")
                return
            }
            riders.ingest(report)
        }
        radio.onPacket = handle
        demo.onPacket = handle
        location.start()
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            MapScreen()
                .tabItem { Label("Map", systemImage: "map") }
            RidersScreen()
                .tabItem { Label("Riders", systemImage: "person.3") }
            RadioScreen()
                .tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }
            OfflineMapsScreen()
                .tabItem { Label("Offline Maps", systemImage: "square.and.arrow.down") }
        }
    }
}
