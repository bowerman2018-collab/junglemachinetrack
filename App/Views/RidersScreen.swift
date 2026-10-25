import SwiftUI

struct RidersScreen: View {
    @EnvironmentObject var riders: RiderStore
    @EnvironmentObject var location: LocationTracker
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var settings: AppSettings
    @State private var editing: Rider?
    @State private var adding = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if riders.riders.isEmpty {
                    Section {
                        Text("No riders yet. Anyone whose radio beacons on your group's frequency shows up here automatically. You can also add a rider by callsign ahead of time so they appear with a name and color.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(riders.sorted) { rider in
                    Button { editing = rider } label: { RiderRow(rider: rider) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if rider.coordinate != nil {
                                Button("Show") { showOnMap(rider) }.tint(.blue)
                            }
                        }
                }
                if !riders.riders.isEmpty {
                    Section {
                        Button("Clear all trail lines", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .navigationTitle("Riders")
            .toolbar {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { rider in
                RiderEditor(rider: rider, onShow: { showOnMap($0) })
            }
            .sheet(isPresented: $adding) { AddRiderSheet() }
            .confirmationDialog("Clear every rider's trail line?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear trails", role: .destructive) { riders.clearTracks() }
            }
        }
    }

    private func showOnMap(_ rider: Rider) {
        guard let c = rider.coordinate else { return }
        mapState.show(c)
    }
}

private struct RiderRow: View {
    @EnvironmentObject var location: LocationTracker
    @EnvironmentObject var settings: AppSettings
    let rider: Rider

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(rider.color)
                Text(rider.initials).font(.caption.bold()).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .opacity(rider.hidden ? 0.35 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(rider.displayName).font(.headline)
                Text(rider.callsign).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let heard = rider.lastHeard {
                    Text(heard, style: .relative)
                        .font(.caption)
                        .foregroundStyle(isStale ? Color.orange : Color.secondary)
                } else {
                    Text("Not heard yet").font(.caption).foregroundStyle(.secondary)
                }
                if let c = rider.coordinate, let d = location.describe(to: c) {
                    Text(d).font(.subheadline.weight(.semibold))
                }
                if let mph = rider.speedMPH, mph >= 1 {
                    Text(String(format: "%.0f mph", mph)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var isStale: Bool {
        guard let t = rider.lastHeard else { return true }
        return Date().timeIntervalSince(t) > Double(settings.staleMinutes * 60)
    }
}

struct RiderEditor: View {
    @EnvironmentObject var riders: RiderStore
    @Environment(\.dismiss) private var dismiss
    @State var rider: Rider
    var onShow: (Rider) -> Void
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name (e.g. Andy)", text: $rider.name)
                    LabeledContent("Callsign", value: rider.callsign)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(RiderPalette.colors.indices, id: \.self) { i in
                            Circle()
                                .fill(Color(uiColor: RiderPalette.colors[i]))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.primary, lineWidth: rider.colorIndex == i ? 3 : 0))
                                .onTapGesture { rider.colorIndex = i }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle("Hide on map", isOn: $rider.hidden)
                }
                Section("Last report") {
                    if let heard = rider.lastHeard {
                        LabeledContent("Heard", value: heard.formatted(date: .abbreviated, time: .standard))
                    }
                    if let c = rider.coordinate {
                        LabeledContent("Position", value: String(format: "%.5f, %.5f", c.latitude, c.longitude))
                    }
                    if let mph = rider.speedMPH { LabeledContent("Speed", value: String(format: "%.0f mph", mph)) }
                    if let course = rider.courseDegrees { LabeledContent("Heading", value: "\(course)°") }
                    if let alt = rider.altitudeFeet { LabeledContent("Altitude", value: String(format: "%.0f ft", alt)) }
                    if !rider.comment.isEmpty { LabeledContent("Comment", value: rider.comment) }
                    LabeledContent("Trail points", value: "\(rider.track.count)")
                }
                Section {
                    if rider.coordinate != nil {
                        Button("Show on map") { save(); onShow(rider); dismiss() }
                    }
                    Button("Clear trail line") { rider.track.removeAll() }
                    Button("Remove rider", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(rider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(); dismiss() } }
            }
            .confirmationDialog("Remove \(rider.displayName)? They'll come back if their radio is heard again.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { riders.remove(rider.id); dismiss() }
            }
        }
    }

    private func save() {
        // Keep any position that arrived while the editor was open.
        var latest = riders.riders[rider.id] ?? rider
        latest.name = rider.name
        latest.colorIndex = rider.colorIndex
        latest.hidden = rider.hidden
        if rider.track.isEmpty { latest.track.removeAll() }
        riders.update(latest)
    }
}

private struct AddRiderSheet: View {
    @EnvironmentObject var riders: RiderStore
    @Environment(\.dismiss) private var dismiss
    @State private var callsign = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Callsign (e.g. KD8ABC-7)", text: $callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Name", text: $name)
                } footer: {
                    Text("Use the exact callsign and SSID set in their radio's APRS menu. You don't have to add riders by hand: anyone heard is added automatically.")
                }
            }
            .navigationTitle("Add rider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { riders.add(callsign: callsign, name: name); dismiss() }
                        .disabled(callsign.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
