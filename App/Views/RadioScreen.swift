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
                    Text("Turn on Bluetooth in the radio's menu and close the ODmaster app first. The radio only allows one Bluetooth connection at a time. Once connected, the app reconnects on its own.")
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
                    Label("Same APRS frequency on every radio (a quiet simplex frequency keeps you off the public APRS network)", systemImage: "1.circle")
                    Label("Callsign and a different SSID on each radio, e.g. -7 and -9", systemImage: "2.circle")
                    Label("GNSS on, Timed Beacon on (30 to 60 seconds)", systemImage: "3.circle")
                    Label("Path empty or NOGATE, no WIDE digipeating", systemImage: "4.circle")
                    Label("Bluetooth on, ODmaster closed", systemImage: "5.circle")
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
