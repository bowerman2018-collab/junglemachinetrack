import Foundation

/// Pulls a position out of an APRS packet. Handles the formats handheld radios actually send:
/// plain and compressed positions (with or without timestamp), Mic-E, objects, items, raw NMEA
/// and third-party wrapped packets.
public enum APRSParser {
    public static func parse(_ packet: APRSPacket) -> APRSReport? {
        let info = packet.info
        guard let type = info.first else { return nil }
        switch type {
        case ascii("!"), ascii("="):
            return report(packet, parsePosition(info[1...]))
        case ascii("/"), ascii("@"):
            guard info.count > 8 else { return nil }
            return report(packet, parsePosition(info[8...]))
        case ascii(";"):
            return parseObject(packet)
        case ascii(")"):
            return parseItem(packet)
        case ascii("`"), ascii("'"), 0x1C, 0x1D:
            return report(packet, parseMicE(destination: packet.destination, info: info))
        case ascii("$"):
            return report(packet, parseNMEA(Latin1.string(info)))
        case ascii("}"):
            // Third-party traffic: the real packet is wrapped inside in TNC2 form.
            guard let inner = TNC2.decode(Latin1.string(info.dropFirst())) else { return nil }
            return parse(inner)
        default:
            // The spec lets a "!" position start anywhere in the first 40 characters (some old trackers do this).
            if let bang = info.prefix(40).firstIndex(of: ascii("!")) {
                return report(packet, parsePosition(info[(bang + 1)...]))
            }
            return nil
        }
    }

    // MARK: - Plain and compressed positions

    static func parsePosition(_ b: ArraySlice<UInt8>) -> APRSPosition? {
        guard let first = b.first else { return nil }
        if isDigit(first) || first == ascii(" ") {
            return parseUncompressed(Array(b))
        }
        return parseCompressed(Array(b))
    }

    static func parseUncompressed(_ b: [UInt8]) -> APRSPosition? {
        guard b.count >= 19 else { return nil }
        guard let lat = latitude(Array(b[0..<8])), let lon = longitude(Array(b[9..<18])) else { return nil }
        var position = APRSPosition(latitude: lat, longitude: lon,
                                    symbolTable: Character(Unicode.Scalar(b[8])),
                                    symbolCode: Character(Unicode.Scalar(b[18])))
        var rest = Array(b[19...])
        // Optional "ccc/sss" course and speed right after the symbol.
        if rest.count >= 7, rest[3] == ascii("/"),
           let course = Int(Latin1.string(rest[0..<3])), let speed = Int(Latin1.string(rest[4..<7])) {
            if (1...360).contains(course) { position.courseDegrees = course % 360 }
            position.speedKnots = Double(speed)
            rest.removeFirst(7)
        }
        applyComment(Latin1.string(rest), to: &position)
        return position
    }

    static func parseCompressed(_ b: [UInt8]) -> APRSPosition? {
        guard b.count >= 13 else { return nil }
        let table = b[0]
        guard table == ascii("/") || table == ascii("\\") || isUpper(table) || (ascii("a")...ascii("j")).contains(table) else { return nil }
        guard let y = base91(b[1..<5]), let x = base91(b[5..<9]) else { return nil }
        let lat = 90.0 - Double(y) / 380926.0
        let lon = -180.0 + Double(x) / 190463.0
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        var position = APRSPosition(latitude: lat, longitude: lon,
                                    symbolTable: Character(Unicode.Scalar(table)),
                                    symbolCode: Character(Unicode.Scalar(b[9])))
        let c = b[10], s = b[11], t = b[12]
        if c != ascii(" "), c >= 33, s >= 33, t >= 33 {
            let cs = Int(c) - 33, sv = Int(s) - 33
            if (Int(t) - 33) >> 3 & 0x03 == 2 {
                position.altitudeFeet = pow(1.002, Double(cs * 91 + sv))
            } else if (0...89).contains(cs) {
                position.courseDegrees = cs * 4
                position.speedKnots = pow(1.08, Double(sv)) - 1
            }
        }
        applyComment(Latin1.string(b[13...]), to: &position)
        return position
    }

    // MARK: - Objects and items

    static func parseObject(_ packet: APRSPacket) -> APRSReport? {
        let b = packet.info
        guard b.count > 18 else { return nil }
        guard b[10] == ascii("*") else { return nil }  // "_" means the object was killed
        let name = Latin1.string(b[1..<10]).trimmingCharacters(in: .whitespaces)
        guard let position = parsePosition(b[18...]), !name.isEmpty else { return nil }
        return APRSReport(station: name, position: position, isObject: true, packet: packet)
    }

    static func parseItem(_ packet: APRSPacket) -> APRSReport? {
        let b = packet.info
        guard let end = b.prefix(11).dropFirst().firstIndex(where: { $0 == ascii("!") || $0 == ascii("_") }),
              b[end] == ascii("!") else { return nil }
        let name = Latin1.string(b[1..<end]).trimmingCharacters(in: .whitespaces)
        guard let position = parsePosition(b[(end + 1)...]), !name.isEmpty else { return nil }
        return APRSReport(station: name, position: position, isObject: true, packet: packet)
    }

    // MARK: - Mic-E

    static func parseMicE(destination: String, info: [UInt8]) -> APRSPosition? {
        let dest = Array(Latin1.bytes(destination.split(separator: "-").first ?? "").prefix(6))
        guard dest.count == 6, info.count >= 9 else { return nil }

        var digits: [Int] = []
        for ch in dest {
            switch ch {
            case ascii("0")...ascii("9"): digits.append(Int(ch - ascii("0")))
            case ascii("A")...ascii("J"): digits.append(Int(ch - ascii("A")))
            case ascii("P")...ascii("Y"): digits.append(Int(ch - ascii("P")))
            case ascii("K"), ascii("L"), ascii("Z"): digits.append(0)  // position ambiguity
            default: return nil
            }
        }
        let latDeg = Double(digits[0] * 10 + digits[1])
        let latMin = Double(digits[2] * 10 + digits[3]) + Double(digits[4] * 10 + digits[5]) / 100.0
        guard latDeg <= 90, latMin < 60 else { return nil }
        let north = (ascii("P")...ascii("Z")).contains(dest[3])
        let lonOffset = (ascii("P")...ascii("Z")).contains(dest[4])
        let west = (ascii("P")...ascii("Z")).contains(dest[5])

        var lonDeg = Int(info[1]) - 28
        if lonOffset { lonDeg += 100 }
        if (180...189).contains(lonDeg) { lonDeg -= 80 }
        if (190...199).contains(lonDeg) { lonDeg -= 190 }
        var lonMin = Int(info[2]) - 28
        if lonMin >= 60 { lonMin -= 60 }
        let lonHundredths = Int(info[3]) - 28
        guard (0...180).contains(lonDeg), (0..<60).contains(lonMin), (0..<100).contains(lonHundredths) else { return nil }

        let sp = Int(info[4]) - 28, dc = Int(info[5]) - 28, se = Int(info[6]) - 28
        var speed = sp * 10 + dc / 10
        var course = (dc % 10) * 100 + se
        if speed >= 800 { speed -= 800 }
        if course >= 400 { course -= 400 }

        let lat = (latDeg + latMin / 60.0) * (north ? 1 : -1)
        let lon = (Double(lonDeg) + (Double(lonMin) + Double(lonHundredths) / 100.0) / 60.0) * (west ? -1 : 1)
        var position = APRSPosition(latitude: lat, longitude: lon,
                                    symbolTable: Character(Unicode.Scalar(info[8])),
                                    symbolCode: Character(Unicode.Scalar(info[7])),
                                    courseDegrees: (1...360).contains(course) ? course % 360 : nil,
                                    speedKnots: Double(speed))

        var rest = Array(info[9...])
        // Optional base-91 altitude: three chars followed by "}" (meters, offset by 10000).
        if let brace = rest.prefix(5).firstIndex(of: ascii("}")), brace >= 3,
           let meters = base91(rest[(brace - 3)..<brace]) {
            position.altitudeFeet = Double(meters - 10000) * 3.28084
            rest.removeSubrange(0...brace)
        }
        applyComment(Latin1.string(rest), to: &position)
        return position
    }

    // MARK: - Raw NMEA

    static func parseNMEA(_ sentence: String) -> APRSPosition? {
        let body = sentence.split(separator: "*").first.map(String.init) ?? sentence
        let f = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let kind = f.first else { return nil }
        if kind.hasSuffix("RMC"), f.count >= 9, f[2] == "A",
           let lat = nmeaCoordinate(f[3], f[4], degreeDigits: 2),
           let lon = nmeaCoordinate(f[5], f[6], degreeDigits: 3) {
            let course = Double(f[8]).map { Int($0.rounded()) }
            return APRSPosition(latitude: lat, longitude: lon, symbolTable: "/", symbolCode: ">",
                                courseDegrees: course, speedKnots: Double(f[7]))
        }
        if kind.hasSuffix("GGA"), f.count >= 10, f[6] != "0",
           let lat = nmeaCoordinate(f[2], f[3], degreeDigits: 2),
           let lon = nmeaCoordinate(f[4], f[5], degreeDigits: 3) {
            return APRSPosition(latitude: lat, longitude: lon, symbolTable: "/", symbolCode: ">",
                                altitudeFeet: Double(f[9]).map { $0 * 3.28084 })
        }
        return nil
    }

    static func nmeaCoordinate(_ value: String, _ hemisphere: String, degreeDigits: Int) -> Double? {
        guard value.count > degreeDigits,
              let deg = Double(value.prefix(degreeDigits)),
              let min = Double(value.dropFirst(degreeDigits)) else { return nil }
        let v = deg + min / 60.0
        switch hemisphere {
        case "N", "E": return v
        case "S", "W": return -v
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func report(_ packet: APRSPacket, _ position: APRSPosition?) -> APRSReport? {
        guard let position else { return nil }
        return APRSReport(station: packet.source, position: position, isObject: false, packet: packet)
    }

    static func latitude(_ b: [UInt8]) -> Double? {
        // "DDMM.mmN", spaces allowed for position ambiguity.
        let s = Latin1.string(b.map { $0 == ascii(" ") ? ascii("0") : $0 })
        guard s.count == 8, let deg = Double(s.prefix(2)), let min = Double(s.dropFirst(2).prefix(5)),
              deg <= 90, min < 60 else { return nil }
        switch s.last {
        case "N": return deg + min / 60
        case "S": return -(deg + min / 60)
        default: return nil
        }
    }

    static func longitude(_ b: [UInt8]) -> Double? {
        // "DDDMM.mmW"
        let s = Latin1.string(b.map { $0 == ascii(" ") ? ascii("0") : $0 })
        guard s.count == 9, let deg = Double(s.prefix(3)), let min = Double(s.dropFirst(3).prefix(5)),
              deg <= 180, min < 60 else { return nil }
        switch s.last {
        case "E": return deg + min / 60
        case "W": return -(deg + min / 60)
        default: return nil
        }
    }

    static func applyComment(_ text: String, to position: inout APRSPosition) {
        var comment = text
        // Altitude in feet: "/A=001234" anywhere in the comment.
        if let range = comment.range(of: "/A=") {
            let digits = comment[range.upperBound...].prefix(6)
            if digits.count == 6, let feet = Double(digits) {
                position.altitudeFeet = feet
                comment.removeSubrange(range.lowerBound..<comment.index(range.upperBound, offsetBy: 6))
            }
        }
        position.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func base91(_ b: ArraySlice<UInt8>) -> Int? {
        var v = 0
        for c in b {
            guard (33...124).contains(c) else { return nil }
            v = v * 91 + Int(c - 33)
        }
        return v
    }

    @inline(__always) static func ascii(_ c: Unicode.Scalar) -> UInt8 { UInt8(c.value) }
    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { (48...57).contains(b) }
    @inline(__always) static func isUpper(_ b: UInt8) -> Bool { (65...90).contains(b) }
}
