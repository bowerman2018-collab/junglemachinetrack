import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct OfflineMapsScreen: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var downloader: TileDownloader
    @EnvironmentObject var trails: TrailStore
    @State private var importing = false
    @State private var minZoom = 10
    @State private var maxZoom = 15
    @State private var areaName = ""
    @State private var confirmDeleteAll = false
    /// Snapshot of the map's area, taken when this tab opens.
    @State private var region = MapState.hatfieldMcCoy
    @State private var hmTopo = true
    @State private var hmSatellite = true
    @State private var hmMaxZoom = 15
    /// Maps for every trail system up to zoom 15 ship inside the app; downloads only add zoom 16.
    private let builtIn = BundledTiles.shared.isAvailable

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

                if downloader.isRunning {
                    Section {
                        Text(downloader.currentJobName).font(.headline)
                        ProgressView(value: downloader.progress) {
                            Text("\(downloader.done) of \(downloader.total) tiles\(downloader.failed > 0 ? ", \(downloader.failed) failed" : "")")
                                .font(.caption)
                        }
                        if !downloader.queued.isEmpty {
                            Text("Up next: \(downloader.queued.map(\.name).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Stop downloading", role: .destructive) { downloader.cancel() }
                    } header: {
                        Text("Downloading")
                    } footer: {
                        Text("Keep the app open on Wi-Fi with the phone plugged in; the screen stays on while this runs. If it stops, tap download again and it picks up where it left off.")
                    }
                }

                Section {
                    if builtIn {
                        Label("Topo and satellite maps for all \(TrailSystem.hatfieldMcCoy.count) trail systems are built into the app", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Toggle("Topo map", isOn: $hmTopo)
                    Toggle("Satellite map", isOn: $hmSatellite)
                    if !builtIn {
                        Picker("Detail", selection: $hmMaxZoom) {
                            Text("Standard (zoom 15)").tag(15)
                            Text("Most detail (zoom 16)").tag(16)
                        }
                    }
                    LabeledContent("Size", value: hmEstimate)
                    Button(builtIn ? "Download extra detail (optional)" : "Download all \(TrailSystem.hatfieldMcCoy.count) trail systems") {
                        downloader.downloadTrailSystems(TrailSystem.hatfieldMcCoy, sources: hmSources,
                                                        minZoom: builtIn ? 16 : 10, maxZoom: builtIn ? 16 : hmMaxZoom)
                    }
                    .disabled(hmSources.isEmpty || !settings.useInternetForMaps)
                    DisclosureGroup("Trail systems included") {
                        ForEach(TrailSystem.hatfieldMcCoy) { system in
                            Button {
                                mapState.pendingRegion = system.region
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(system.name).foregroundStyle(.primary)
                                    Text(system.trailhead).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Hatfield-McCoy trails")
                } footer: {
                    Text(builtIn
                         ? "Covers every trail in each system plus about 2 miles around it, ready to use offline. The optional extra-detail download adds the closest zoom level; do it on Wi-Fi. Tap a trail system to see it on the Map tab."
                         : "Covers every trail in each system plus about 2 miles around it. Do this on Wi-Fi at home; it takes a while. Tap a trail system to see it on the Map tab.")
                }

                Section {
                    Toggle("Show trail lines", isOn: $settings.showTrailLines)
                    if let source = trails.sourceName {
                        LabeledContent("Loaded", value: "\(trails.trails.count) trails")
                        Text(source).font(.caption).foregroundStyle(.secondary)
                        Button("See all trails on the map") {
                            if let r = trails.boundingRegion { mapState.pendingRegion = r }
                        }
                    }
                    Button(trails.sourceName == nil ? "Import trail map…" : trails.isBuiltIn ? "Import a newer trail map…" : "Replace trail map…") { importing = true }
                    if trails.sourceName != nil && !trails.isBuiltIn {
                        Button("Remove imported trail map", role: .destructive) { trails.removeAll() }
                    }
                    if let error = trails.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Trail lines and numbers")
                } footer: {
                    Text("Import the official Hatfield-McCoy Google Earth (KMZ) file from data.trailsheaven.com, or any KML or GPX file. Trails are drawn in their colors, and trail numbers show when you zoom in. Works offline once imported.")
                }

                Section {
                    TextField("Area name (e.g. Rockhouse trails)", text: $areaName)
                    Stepper("Least detail: zoom \(minZoom)", value: $minZoom, in: 6...maxZoom)
                    Stepper("Most detail: zoom \(maxZoom)", value: $maxZoom, in: minZoom...settings.tileSource.maxZoom)
                    LabeledContent("Size", value: estimate)
                    Button(downloader.isRunning ? "Add this area to the queue" : "Download this area") {
                        downloader.download(name: areaName.isEmpty ? "Area \(downloader.areas.count + 1)" : areaName,
                                            region: region, zooms: minZoom...maxZoom, source: settings.tileSource)
                        areaName = ""
                    }
                    .disabled(tileCount > TileDownloader.maxTilesPerDownload || !settings.useInternetForMaps)
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
                                    Text("\(TileSource.all.first { $0.id == area.sourceID }?.name ?? area.sourceID) · zoom \(area.minZoom)–\(area.maxZoom) · \(area.date.formatted(date: .abbreviated, time: .omitted))")
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
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.trailFileTypes) { result in
                if case .success(let url) = result { trails.importFile(url) }
            }
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

    static let trailFileTypes: [UTType] = {
        let types = ["kmz", "kml", "gpx"].compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types + [.xml]
    }()

    private var hmSources: [TileSource] {
        (hmTopo ? [TileSource.usgsTopo] : []) + (hmSatellite ? [TileSource.usgsImagery] : [])
    }

    private var hmEstimate: String {
        var bytes: Int64 = 0
        var tiles = 0
        for source in hmSources {
            let n = TileDownloader.tileCount(TrailSystem.hatfieldMcCoy, sources: [source],
                                             minZoom: builtIn ? 16 : 10, maxZoom: builtIn ? 16 : hmMaxZoom)
            tiles += n
            // Satellite tiles are photos and run roughly twice the size of topo tiles.
            bytes += Int64(n * (source == .usgsImagery ? 2 : 1) * TileDownloader.averageTileBytes)
        }
        return "\(tiles.formatted()) tiles, about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
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
