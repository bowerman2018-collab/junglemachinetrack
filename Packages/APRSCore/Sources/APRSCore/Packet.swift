import Foundation

/// One APRS packet as heard on the air: who sent it, where it was addressed, and the raw info field.
public struct APRSPacket: Equatable {
    public var source: String
    public var destination: String
    public var path: [String]
    /// Raw info field bytes. Mic-E and compressed positions use the full printable byte range,
    /// so this is kept as bytes rather than a String.
    public var info: [UInt8]

    public init(source: String, destination: String, path: [String] = [], info: [UInt8]) {
        self.source = source
        self.destination = destination
        self.path = path
        self.info = info
    }

    public init(source: String, destination: String, path: [String] = [], info: String) {
        self.init(source: source, destination: destination, path: path, info: Latin1.bytes(info))
    }

    /// The packet in the usual "SRC>DEST,PATH:info" text form.
    public var tnc2: String {
        let header = ([destination] + path).joined(separator: ",")
        return "\(source)>\(header):\(Latin1.string(info))"
    }
}

/// A decoded position.
public struct APRSPosition: Equatable {
    public var latitude: Double
    public var longitude: Double
    public var symbolTable: Character
    public var symbolCode: Character
    public var courseDegrees: Int?
    public var speedKnots: Double?
    public var altitudeFeet: Double?
    public var comment: String

    public init(latitude: Double, longitude: Double, symbolTable: Character = "/", symbolCode: Character = ">",
                courseDegrees: Int? = nil, speedKnots: Double? = nil, altitudeFeet: Double? = nil, comment: String = "") {
        self.latitude = latitude
        self.longitude = longitude
        self.symbolTable = symbolTable
        self.symbolCode = symbolCode
        self.courseDegrees = courseDegrees
        self.speedKnots = speedKnots
        self.altitudeFeet = altitudeFeet
        self.comment = comment
    }
}

/// A position report tied to the station it describes.
public struct APRSReport: Equatable {
    /// The sender's callsign, or the object/item name for objects and items.
    public var station: String
    public var position: APRSPosition
    public var isObject: Bool
    public var packet: APRSPacket
}

/// Byte <-> String helpers that map every byte 0-255 to the same code point, so nothing is lost.
public enum Latin1 {
    public static func bytes(_ s: some StringProtocol) -> [UInt8] {
        s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    public static func string(_ b: some Sequence<UInt8>) -> String {
        var s = String.UnicodeScalarView()
        for byte in b { s.append(Unicode.Scalar(byte)) }
        return String(s)
    }
}
