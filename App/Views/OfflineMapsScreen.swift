import SwiftUI
import MapKit

struct OfflineMapsScreen: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var downloader: TileDownloader
    @State private var minZoom = 10
    @State private var maxZoom = 15
    @State private var areaName = ""
    @State private var confirmDeleteAll = false
    /// Snapshot of the map's area, taken when this tab opens.
    @State private var region = MapState.hatfieldMcCoy

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Map style", selection: $settings.tileSourceID) {
                        ForEach(TileSource.all) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Use internet for maps", isOn: $settings.useInternetForMaps)
                } footer: {
                    Text("With internet off, the app makes no network connections at all and only shows downloaded maps. Rider positions never use the internet either way.")
                }

                Section {
                    TextField("Area name (e.g. Rockhouse trails)", text: $areaName)
                    Stepper("Least detail: zoom \(minZoom)", value: $minZoom, in: 6...maxZoom)
                    Stepper("Most detail: zoom \(maxZoom)", value: $maxZoom, in: minZoom...settings.tileSource.maxZoom)
                    LabeledContent("Size", value: estimate)
                    if downloader.isRunning {
                        ProgressView(value: downloader.progress) {
                            Text("\(downloader.done) of \(downloader.total) tiles\(downloader.failed > 0 ? ", \(downloader.failed) failed" : "")")
                                .font(.caption)
                        }
                        Button("Stop download", role: .destructive) { downloader.cancel() }
                    } else {
                        Button("Download this area") {
                            downloader.download(name: areaName.isEmpty ? "Area \(downloader.areas.count + 1)" : areaName,
                                                region: region, zooms: minZoom...maxZoom, source: settings.tileSource)
                            areaName = ""
                        }
                        .disabled(tileCount > TileDownloader.maxTilesPerDownload || !settings.useInternetForMaps)
                    }
                } header: {
                    Text("Download what's on the map now")
                } footer: {
                    Text(downloadHelp)
                }

                if !downloader.areas.isEmpty {
                    Section("Saved areas") {
                        ForEach(downloader.areas) { area in
                            Button {
                                mapState.pendingRegion = area.region
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(area.name).foregroundStyle(.primary)
                                    Text("\(area.tileCount) tiles · zoom \(area.minZoom)–\(area.maxZoom) · \(area.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Hide", role: .destructive) { downloader.removeRecord(area) } }
                        }
                    }
                }

                Section {
                    LabeledContent("Maps on this phone", value: ByteCountFormatter.string(fromByteCount: downloader.bytesOnDisk, countStyle: .file))
                    Button("Delete all downloaded maps", role: .destructive) { confirmDeleteAll = true }
                }
            }
            .navigationTitle("Offline Maps")
            .onAppear {
                region = mapState.region
                downloader.refreshSize()
                maxZoom = min(maxZoom, settings.tileSource.maxZoom)
            }
            .confirmationDialog("Delete every downloaded map?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete maps", role: .destructive) { downloader.deleteAllTiles() }
            }
        }
    }

    private var tileCount: Int { TileMath.count(in: region, zooms: minZoom...maxZoom) }

    private var estimate: String {
        let bytes = Int64(tileCount * TileDownloader.averageTileBytes)
        return "\(tileCount) tiles, about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var downloadHelp: String {
        if !settings.useInternetForMaps { return "Turn on \"Use internet for maps\" to download." }
        if tileCount > TileDownloader.maxTilesPerDownload {
            return "That's too much at once. Zoom the map in closer or lower the most-detail level."
        }
        return "Move the Map tab to the area you want first. Zoom 15 shows trails and creeks clearly; 16 is the most detail and roughly 4x the size. Do this on Wi-Fi before the trip."
    }
}
