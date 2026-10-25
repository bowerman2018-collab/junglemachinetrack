import Foundation

/// Turns the raw bytes a radio sends over Bluetooth into packets.
///
/// We don't yet know exactly what the TD-H9 sends, so this accepts both common shapes and picks
/// whichever shows up first:
/// - KISS frames (binary, start with 0xC0) carrying AX.25
/// - Plain text lines like "N0CALL>APRS,WIDE1-1:!4903.50N/07201.75W-"
public struct RadioStreamDecoder {
    public enum Mode: String {
        case unknown = "Waiting for data"
        case kiss = "KISS (binary)"
        case text = "Text lines"
    }

    public private(set) var mode: Mode = .unknown
    private var kiss = KISSDecoder()
    private var text: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [APRSPacket] {
        if mode == .unknown, bytes.contains(KISS.fend) {
            mode = .kiss
            text.removeAll()
        }
        if mode == .kiss {
            return kiss.feed(bytes).compactMap(AX25.decode)
        }

        text += bytes
        var packets: [APRSPacket] = []
        while let end = text.firstIndex(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x00 }) {
            let line = Array(text[..<end])
            text.removeSubrange(...end)
            if let packet = TNC2.decode(Latin1.string(line)) {
                mode = .text
                packets.append(packet)
            }
        }
        if text.count > 4096 { text.removeAll() }
        return packets
    }

    /// Call after the radio goes quiet for a moment. Some radios send one packet per Bluetooth
    /// notification with no line ending; this decodes whatever is left in the buffer.
    public mutating func flush() -> [APRSPacket] {
        guard mode != .kiss, !text.isEmpty else { return [] }
        defer { text.removeAll() }
        if let packet = TNC2.decode(Latin1.string(text)) {
            mode = .text
            return [packet]
        }
        return []
    }
}
