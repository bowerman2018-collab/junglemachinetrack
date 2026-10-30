import Foundation
import CoreBluetooth
import APRSCore

/// Bluetooth Low Energy connection to the radio.
///
/// TIDRADIO doesn't publish what the TD-H9 exposes over BLE, so this is deliberately general:
/// it subscribes to every characteristic that can notify, logs the raw bytes, and runs them through
/// a decoder that accepts both KISS and plain-text packets. Once we see what the H9 actually sends
/// (Radio tab, or an nRF Connect screenshot), the "Listen only to" setting can pin it down.
final class RadioLink: NSObject, ObservableObject {
    struct Found: Identifiable {
        let id: UUID
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
    }

    struct CharacteristicInfo: Identifiable {
        var id: String { uuid }
        let uuid: String
        let serviceUUID: String
        let properties: String
        var subscribed: Bool
        var bytesReceived: Int
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    enum State: Equatable {
        case off, idle, scanning, connecting(String), connected(String)

        var label: String {
            switch self {
            case .off: return "Bluetooth is off"
            case .idle: return "Not connected"
            case .scanning: return "Searching for radios…"
            case .connecting(let name): return "Connecting to \(name)…"
            case .connected(let name): return "Connected to \(name)"
            }
        }
    }

    /// The standard BLE KISS TNC service used by Mobilinkd, BTECH/Benshi radios and LoRa APRS trackers.
    /// If the H9 uses it, we know exactly which characteristic carries packets.
    static let kissService = CBUUID(string: "00000001-BA2A-46C9-AE49-01B0961F68BB")
    static let kissRX = CBUUID(string: "00000003-BA2A-46C9-AE49-01B0961F68BB")

    @Published private(set) var state: State = .idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var characteristics: [CharacteristicInfo] = []
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var packetsDecoded = 0
    @Published private(set) var decoderMode: RadioStreamDecoder.Mode = .unknown
    /// Show every device during a scan, not just ones that look like radios.
    @Published var showAllDevices = false
    /// When set, only this characteristic's data is decoded.
    @Published var listenOnlyTo: String? {
        didSet { UserDefaults.standard.set(listenOnlyTo, forKey: "listenOnlyTo") }
    }

    var onPacket: ((APRSPacket) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var decoders: [CBUUID: RadioStreamDecoder] = [:]
    private var flushWork: [CBUUID: DispatchWorkItem] = [:]
    private var userDisconnected = false

    private var savedID: UUID? {
        get { UserDefaults.standard.string(forKey: "radioID").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "radioID") }
    }

    var hasSavedRadio: Bool { savedID != nil }

    override init() {
        super.init()
        listenOnlyTo = UserDefaults.standard.string(forKey: "listenOnlyTo")
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "TrailTrackerRadio"])
    }

    // MARK: - Actions

    func startScan() {
        guard central.state == .poweredOn else { return }
        found.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.state == .scanning else { return }
            self.central.stopScan()
            self.state = .idle
        }
    }

    func stopScan() {
        central.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ item: Found) {
        central.stopScan()
        savedID = item.id
        connect(item.peripheral)
    }

    func disconnect() {
        userDisconnected = true
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func forgetRadio() {
        disconnect()
        savedID = nil
        listenOnlyTo = nil
    }

    func clearLog() { log.removeAll() }

    func note(_ text: String) {
        log.append(LogLine(text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: - Internals

    private func connect(_ p: CBPeripheral) {
        userDisconnected = false
        peripheral = p
        p.delegate = self
        state = .connecting(p.name ?? "radio")
        central.connect(p, options: nil)
    }

    private func reconnectSaved() {
        guard let id = savedID, peripheral == nil || state == .idle else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            note("Reconnecting to \(p.name ?? "saved radio")")
            connect(p)
        }
    }

    private func handle(_ data: Data, from characteristic: CBCharacteristic) {
        let uuid = characteristic.uuid
        if let index = characteristics.firstIndex(where: { $0.uuid == uuid.uuidString }) {
            characteristics[index].bytesReceived += data.count
        }
        note("RX \(short(uuid)) \(data.count)B: \(Self.hex(data))  |\(Self.printable(data))|")

        if let only = listenOnlyTo, only != uuid.uuidString { return }
        var decoder = decoders[uuid] ?? RadioStreamDecoder()
        let packets = decoder.feed([UInt8](data))
        decoders[uuid] = decoder
        decoderMode = decoder.mode
        deliver(packets)

        // Some radios send one packet per notification with no line ending; decode it once things go quiet.
        flushWork[uuid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, var d = self.decoders[uuid] else { return }
            let late = d.flush()
            self.decoders[uuid] = d
            self.decoderMode = d.mode
            self.deliver(late)
        }
        flushWork[uuid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func deliver(_ packets: [APRSPacket]) {
        for packet in packets {
            packetsDecoded += 1
            note("Packet: \(packet.tnc2)")
            onPacket?(packet)
        }
    }

    private func short(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString
        return s.count > 8 ? String(s.prefix(8)) : s
    }

    static func hex(_ data: Data) -> String {
        data.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ") + (data.count > 48 ? " …" : "")
    }

    static func printable(_ data: Data) -> String {
        String(data.prefix(64).map { (32...126).contains($0) ? Character(Unicode.Scalar($0)) : "." })
    }

    static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("write-no-resp") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ", ")
    }
}

extension RadioLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if state == .off { state = .idle }
            reconnectSaved()
        case .unauthorized:
            state = .off
            note("Bluetooth permission is off. Turn it on in Settings > Trail Tracker.")
        default:
            state = .off
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if name == nil && !showAllDevices { return }
        let item = Found(id: peripheral.identifier, peripheral: peripheral, name: name ?? "Unnamed device", rssi: RSSI.intValue)
        if let index = found.firstIndex(where: { $0.id == item.id }) {
            found[index] = item
        } else {
            found.append(item)
        }
        // The TD-H9's Bluetooth LE entry ("TD-H9xxxx(BLE)") first, then other likely radios, then by signal strength.
        found.sort { a, b in
            let ab = a.name.uppercased().contains("(BLE)"), bb = b.name.uppercased().contains("(BLE)")
            if ab != bb { return ab }
            let ar = Self.looksLikeRadio(a.name), br = Self.looksLikeRadio(b.name)
            return ar != br ? ar : a.rssi > b.rssi
        }
    }

    static func looksLikeRadio(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["TD-", "H9", "TID", "RADIO", "TNC", "KISS"].contains { n.contains($0) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected(peripheral.name ?? "radio")
        characteristics.removeAll()
        decoders.removeAll()
        note("Connected to \(peripheral.name ?? "radio"). Looking at what it offers…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .idle
        note("Couldn't connect: \(error?.localizedDescription ?? "unknown error"). Is the ODmaster app closed?")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .idle
        note("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        // Riding out of range or the radio rebooting shouldn't need a tap to recover.
        if !userDisconnected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.state = .connecting(peripheral.name ?? "radio")
                central.connect(peripheral, options: nil)
            }
        } else {
            self.peripheral = nil
        }
    }
}

extension RadioLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            note("Service \(service.uuid.uuidString)\(service.uuid == Self.kissService ? " (KISS TNC!)" : "")")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            let canNotify = c.properties.contains(.notify) || c.properties.contains(.indicate)
            characteristics.append(CharacteristicInfo(uuid: c.uuid.uuidString, serviceUUID: service.uuid.uuidString,
                                                      properties: Self.describe(c.properties),
                                                      subscribed: false, bytesReceived: 0))
            note("  Characteristic \(c.uuid.uuidString) [\(Self.describe(c.properties))]")
            if canNotify { peripheral.setNotifyValue(true, for: c) }
            if c.uuid == Self.kissRX && listenOnlyTo == nil {
                listenOnlyTo = c.uuid.uuidString
                note("  Found the standard KISS data channel; listening to it only.")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let index = characteristics.firstIndex(where: { $0.uuid == characteristic.uuid.uuidString }) {
            characteristics[index].subscribed = characteristic.isNotifying
        }
        if let error { note("  Couldn't subscribe to \(characteristic.uuid.uuidString): \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        handle(data, from: characteristic)
    }
}
