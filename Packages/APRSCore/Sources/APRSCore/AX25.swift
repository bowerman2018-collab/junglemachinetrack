import Foundation

/// AX.25 UI frames, as carried inside KISS.
public enum AX25 {
    /// Decodes a UI frame (no FCS) into a packet. Returns nil for anything that isn't an APRS-style UI frame.
    public static func decode(_ frame: [UInt8]) -> APRSPacket? {
        guard frame.count >= 16 else { return nil }
        var calls: [String] = []
        var repeated: [Bool] = []
        var i = 0
        var last = false
        while !last {
            guard i + 7 <= frame.count, calls.count < 10 else { return nil }
            guard let address = decodeAddress(frame[i..<(i + 7)]) else { return nil }
            calls.append(address.call)
            repeated.append(address.hBit)
            last = address.isLast
            i += 7
        }
        guard calls.count >= 2, i + 2 <= frame.count else { return nil }
        let control = frame[i] & 0xEF  // ignore the P/F bit
        let pid = frame[i + 1]
        guard control == 0x03, pid == 0xF0 else { return nil }
        let path = (2..<calls.count).map { repeated[$0] ? calls[$0] + "*" : calls[$0] }
        return APRSPacket(source: calls[1], destination: calls[0], path: path, info: Array(frame[(i + 2)...]))
    }

    /// Builds a UI frame from a packet. Used by tests and the demo feed.
    public static func encode(_ packet: APRSPacket) -> [UInt8] {
        let all = [packet.destination, packet.source] + packet.path
        var out: [UInt8] = []
        for (index, raw) in all.enumerated() {
            var call = raw
            var repeatedFlag = false
            if call.hasSuffix("*") {
                call.removeLast()
                repeatedFlag = true
            }
            let parts = call.split(separator: "-", maxSplits: 1)
            let base = Array(Latin1.bytes(parts.first.map(String.init) ?? "").prefix(6))
            let ssid = parts.count > 1 ? (UInt8(parts[1]) ?? 0) & 0x0F : 0
            for k in 0..<6 {
                out.append((k < base.count ? base[k] : 0x20) << 1)
            }
            var ssidByte: UInt8 = 0x60 | (ssid << 1)
            if index == all.count - 1 { ssidByte |= 0x01 }
            if repeatedFlag { ssidByte |= 0x80 }
            out.append(ssidByte)
        }
        out += [0x03, 0xF0]
        out += packet.info
        return out
    }

    private static func decodeAddress(_ b: ArraySlice<UInt8>) -> (call: String, isLast: Bool, hBit: Bool)? {
        let bytes = Array(b)
        var call = ""
        for k in 0..<6 {
            let c = bytes[k] >> 1
            if c == 0x20 { continue }
            // Callsigns are uppercase letters and digits; anything else means this isn't really AX.25.
            guard (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) else { return nil }
            call.append(Character(Unicode.Scalar(c)))
        }
        guard !call.isEmpty else { return nil }
        let ssid = Int((bytes[6] >> 1) & 0x0F)
        if ssid != 0 { call += "-\(ssid)" }
        return (call, bytes[6] & 0x01 == 1, bytes[6] & 0x80 != 0)
    }
}

/// The plain-text "SRC>DEST,PATH:info" form that many radios and apps print.
public enum TNC2 {
    public static func decode(_ line: String) -> APRSPacket? {
        let trimmed = line.trimmingCharacters(in: .controlCharacters)
        guard let gt = trimmed.firstIndex(of: ">"),
              let colon = trimmed[gt...].firstIndex(of: ":") else { return nil }
        // Some radios prefix lines with things like "[RX] " or a timestamp; the callsign is the last word before ">".
        let beforeGT = trimmed[..<gt]
        let source = beforeGT.split(whereSeparator: { $0 == " " || $0 == "]" }).last.map(String.init) ?? ""
        let header = trimmed[trimmed.index(after: gt)..<colon].split(separator: ",").map(String.init)
        guard isCallsign(source), let destination = header.first, !destination.isEmpty else { return nil }
        let info = Latin1.bytes(trimmed[trimmed.index(after: colon)...])
        guard !info.isEmpty else { return nil }
        return APRSPacket(source: source, destination: destination, path: Array(header.dropFirst()), info: info)
    }

    static func isCallsign(_ s: String) -> Bool {
        guard (1...12).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }
}
