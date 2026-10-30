import SwiftUI

struct RadioScreen: View {
    @EnvironmentObject var radio: RadioLink
    @EnvironmentObject var demo: DemoFeed
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status", value: radio.state.label)
                    LabeledContent("Packets decoded", value: "\(radio.packetsDecoded)")
                    LabeledContent("Data format", value: radio.decoderMode.rawValue)
                    switch radio.state {
                    case .connected, .connecting:
                        Button("Disconnect") { radio.disconnect() }
                    case .scanning:
                        Button("Stop searching") { radio.stopScan() }
                    case .idle:
                        Button("Find my radio") { radio.startScan() }
                    case .off:
                        Text("Turn on Bluetooth to connect.").foregroundStyle(.secondary)
                    }
                    if radio.hasSavedRadio {
                        Button("Forget this radio", role: .destructive) { radio.forgetRadio() }
                    }
                } footer: {
                    Text("Turn on Bluetooth in the radio's menu (BT Mode: Receiver) and close the ODmaster app first. Don't pair the radio in iPhone Settings. In this list, pick the name ending in (BLE), e.g. TD-H9xxxx(BLE). The radio only allows one Bluetooth connection at a time. Once connected, the app reconnects on its own.")
                }

                if radio.state == .scanning || !radio.found.isEmpty && !isConnected {
                    Section("Nearby devices") {
                        Toggle("Show unnamed devices", isOn: $radio.showAllDevices)
                        ForEach(radio.found) { item in
                            Button { radio.connect(item) } label: {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Text("\(item.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if !radio.characteristics.isEmpty {
                    Section {
                        ForEach(radio.characteristics) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.uuid).font(.caption.monospaced())
                                Text("\(c.properties)\(c.subscribed ? " · listening" : "") · \(c.bytesReceived) bytes")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if c.subscribed {
                                    Button(radio.listenOnlyTo == c.uuid ? "Listening to this only ✓" : "Listen only to this") {
                                        radio.listenOnlyTo = radio.listenOnlyTo == c.uuid ? nil : c.uuid
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    } header: {
                        Text("What the radio offers")
                    } footer: {
                        Text("Diagnostics. If packets aren't decoding, screenshot this list and the log and send them over.")
                    }
                }

                Section {
                    NavigationLink("Raw data log (\(radio.log.count))") { LogView() }
                }

                Section {
                    Toggle("Demo riders", isOn: Binding(get: { demo.running }, set: { $0 ? demo.start() : demo.stop() }))
                } footer: {
                    Text("Adds three fake riders driving loops near Gilbert, WV, to try the app before the radios arrive. Remove them on the Riders tab afterwards.")
                }

                Section("Radio setup checklist") {
                    Label("APRS → Advanced Set: pick line A or B for APRS, set that line to the same quiet simplex frequency on every radio, and set RX and TX to that line", systemImage: "1.circle")
                    Label("APRS → Callsign plus a different SSID on each radio, e.g. -7 and -9", systemImage: "2.circle")
                    Label("GNSS → GPS on. Beacon Set: Site Type GPS, Beacon Mode Timed, interval 0060 (60 seconds), PTT Linkage off", systemImage: "3.circle")
                    Label("Beacon Set: Route 1 and Route 2 counts set to 0, and Relay Set (digipeater) off, so nothing gets repeated", systemImage: "4.circle")
                    Label("Bluetooth on, BT Mode Receiver, ODmaster closed. Pick the (BLE) entry in this app", systemImage: "5.circle")
                }
                .font(.subheadline)
            }
            .navigationTitle("Radio")
        }
    }

    private var isConnected: Bool {
        if case .connected = radio.state { return true }
        return false
    }
}

private struct LogView: View {
    @EnvironmentObject var radio: RadioLink

    var body: some View {
        List(radio.log.reversed()) { line in
            VStack(alignment: .leading, spacing: 2) {
                Text(line.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Raw data")
        .toolbar {
            ShareLink(item: radio.log.map { "\($0.time.formatted(date: .omitted, time: .standard)) \($0.text)" }.joined(separator: "\n")) {
                Image(systemName: "square.and.arrow.up")
            }
            Button("Clear") { radio.clearLog() }
        }
    }
}
