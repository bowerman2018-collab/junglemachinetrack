import SwiftUI
import MapKit

struct MapScreen: View {
    @EnvironmentObject var riders: RiderStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var radio: RadioLink
    @EnvironmentObject var demo: DemoFeed
    @EnvironmentObject var location: LocationTracker
    @EnvironmentObject var trails: TrailStore
    @State private var clock = Date()
    private let minuteTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TrailMapView(riders: riders, settings: settings, mapState: mapState, trails: trails, clock: clock)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 10) {
                MapButton(systemImage: mapState.followUser ? "location.north.line.fill" : "location") {
                    if mapState.followUser {
                        mapState.followUser = false
                    } else if location.location != nil {
                        mapState.followUser = true
                    }
                }
                MapButton(systemImage: "person.3.fill") {
                    var coords = riders.visible.compactMap(\.coordinate)
                    if let me = location.location?.coordinate { coords.append(me) }
                    mapState.fit(coords)
                }
                MapButton(systemImage: settings.showTracks ? "point.topleft.down.curvedto.point.bottomright.up.fill" : "point.topleft.down.curvedto.point.bottomright.up") {
                    settings.showTracks.toggle()
                }
            }
            .padding(.trailing, 12)
            .padding(.top, 60)

            VStack {
                Spacer()
                StatusChip()
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
        }
        .onReceive(minuteTimer) { clock = $0 }
    }
}

private struct MapButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// One-line summary at the bottom of the map: radio state and how many riders are being heard.
private struct StatusChip: View {
    @EnvironmentObject var radio: RadioLink
    @EnvironmentObject var demo: DemoFeed
    @EnvironmentObject var riders: RiderStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let recent = riders.riders.values.filter {
            guard let t = $0.lastHeard else { return false }
            return Date().timeIntervalSince(t) < Double(settings.staleMinutes * 60)
        }.count
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(demo.running ? "Demo mode" : radio.state.label)
            Text("·")
            Text("\(recent) heard recently")
            if !settings.useInternetForMaps {
                Image(systemName: "wifi.slash")
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var dotColor: Color {
        if demo.running { return .purple }
        switch radio.state {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        default: return .red
        }
    }
}
