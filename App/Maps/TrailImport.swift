import Foundation
import Compression
import CoreLocation

/// One trail line from an imported map file, e.g. a Hatfield-McCoy trail with its number.
struct TrailLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Short text drawn on the map, usually the trail number.
    var label: String
    /// "#RRGGBB", from the file's style or the trail's difficulty.
    var colorHex: String?
    /// Each segment is a list of [longitude, latitude] pairs.
    var segments: [[[Double]]]
    var details: [String: String] = [:]
}

enum TrailImportError: LocalizedError {
    case unreadable, unsupported, noTrails

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Couldn't read that file."
        case .unsupported: return "Pick a KMZ, KML or GPX file."
        case .noTrails: return "That file doesn't contain any trail lines."
        }
    }
}

enum TrailImporter {
    static func load(_ url: URL) throws -> [TrailLine] {
        guard let data = try? Data(contentsOf: url) else { throw TrailImportError.unreadable }
        let trails: [TrailLine]
        switch url.pathExtension.lowercased() {
        case "kmz":
            let files = try Zip.entries(data)
            // A KMZ is a zip with one main KML (usually doc.kml) and sometimes more.
            let kmls = files.filter { $0.key.lowercased().hasSuffix(".kml") }.sorted { $0.key < $1.key }
            guard !kmls.isEmpty else { throw TrailImportError.noTrails }
            trails = kmls.flatMap { KMLParser.parse($0.value) }
        case "kml":
            trails = KMLParser.parse(data)
        case "gpx":
            trails = GPXParser.parse(data)
        default:
            throw TrailImportError.unsupported
        }
        guard !trails.isEmpty else { throw TrailImportError.noTrails }
        return trails
    }

    /// Picks the text to print on the map: a trail-number field if the file has one, else the name.
    static func label(name: String, details: [String: String]) -> String {
        let numberKeys = ["trail_num", "trailnum", "trail_no", "trailno", "trail_number", "trailnumber",
                          "number", "num", "ref", "trail_id", "trailid", "trail"]
        for key in numberKeys {
            if let value = details.first(where: { $0.key.lowercased() == key })?.value
                .trimmingCharacters(in: .whitespaces), !value.isEmpty, value.count <= 12 {
                return value
            }
        }
        return name
    }

    /// Standard trail difficulty colors, used when the file doesn't set one.
    static func difficultyColor(_ text: String) -> String? {
        let t = text.lowercased()
        if t.contains("most difficult") || t.contains("extreme") || t.contains("expert") { return "#D32F2F" }
        if t.contains("difficult") || t.contains("hard") || t.contains("black") { return "#212121" }
        if t.contains("moderate") || t.contains("intermediate") || t.contains("blue") { return "#1E63D6" }
        if t.contains("easy") || t.contains("green") { return "#2E8B3A" }
        return nil
    }
}

// MARK: - KML

final class KMLParser: NSObject, XMLParserDelegate {
    private var trails: [TrailLine] = []
    private var styles: [String: String] = [:]
    private var styleMaps: [String: String] = [:]

    private var path: [String] = []
    private var text = ""
    private var styleID: String?
    private var styleMapID: String?
    private var pairKey: String?
    private var inPlacemark = false
    private var name = ""
    private var styleURL = ""
    private var details: [String: String] = [:]
    private var dataName: String?
    private var segments: [[[Double]]] = []

    static func parse(_ data: Data) -> [TrailLine] {
        let delegate = KMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.finish()
    }

    private func finish() -> [TrailLine] {
        trails.map { trail in
            var t = trail
            // The file's own line color wins; otherwise color by difficulty.
            if let key = t.details["_styleUrl"] {
                let id = key.hasPrefix("#") ? String(key.dropFirst()) : key
                if let hex = styles[styleMaps[id] ?? id] { t.colorHex = hex }
            }
            t.details["_styleUrl"] = nil
            return t
        }
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let el = local(element)
        path.append(el)
        text = ""
        switch el {
        case "Placemark":
            inPlacemark = true
            name = ""; styleURL = ""; details = [:]; segments = []
        case "Style" where !inPlacemark:
            styleID = attributes["id"]
        case "StyleMap":
            styleMapID = attributes["id"]
        case "Data", "SimpleData":
            dataName = attributes["name"]
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let el = local(element)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last ?? ""
        switch el {
        case "name" where inPlacemark && parent == "Placemark":
            name = value
        case "styleUrl" where inPlacemark:
            styleURL = value
        case "color" where parent == "LineStyle":
            if let id = styleID, let hex = Self.kmlColor(value) { styles[id] = hex }
        case "key" where styleMapID != nil:
            pairKey = value
        case "styleUrl" where styleMapID != nil && pairKey == "normal":
            styleMaps[styleMapID!] = value.hasPrefix("#") ? String(value.dropFirst()) : value
        case "StyleMap":
            styleMapID = nil
        case "Style":
            if !inPlacemark { styleID = nil }
        case "value" where dataName != nil:
            details[dataName!] = value
        case "SimpleData":
            if let n = dataName { details[n] = value }
            dataName = nil
        case "Data":
            dataName = nil
        case "description" where inPlacemark:
            if !value.isEmpty { details["description"] = value }
        case "coordinates" where inPlacemark && path.contains("LineString"):
            let points = value.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                .compactMap { pair -> [Double]? in
                    let parts = pair.split(separator: ",")
                    guard parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) else { return nil }
                    return [lon, lat]
                }
            if points.count >= 2 { segments.append(points) }
        case "Placemark":
            inPlacemark = false
            if !segments.isEmpty {
                var d = details
                if !styleURL.isEmpty { d["_styleUrl"] = styleURL }
                let title = name.isEmpty ? (d.first { $0.key.lowercased().contains("name") }?.value ?? "Trail") : name
                let color = TrailImporter.difficultyColor(([title] + Array(details.values)).joined(separator: " "))
                trails.append(TrailLine(name: title, label: TrailImporter.label(name: title, details: details),
                                        colorHex: color, segments: segments, details: d))
            }
        default: break
        }
        path.removeLast()
        text = ""
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    /// KML colors are "aabbggrr".
    static func kmlColor(_ s: String) -> String? {
        let hex = s.trimmingCharacters(in: .whitespaces)
        guard hex.count == 8 else { return nil }
        let chars = Array(hex)
        return "#" + String(chars[6...7]) + String(chars[4...5]) + String(chars[2...3])
    }
}

// MARK: - GPX

final class GPXParser: NSObject, XMLParserDelegate {
    private var trails: [TrailLine] = []
    private var name = ""
    private var segments: [[[Double]]] = []
    private var current: [[Double]] = []
    private var text = ""
    private var depthName = ""

    static func parse(_ data: Data) -> [TrailLine] {
        let delegate = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.trails
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "trk", "rte":
            name = ""; segments = []; current = []; depthName = element
        case "trkseg":
            current = []
        case "trkpt", "rtept":
            if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                current.append([lon, lat])
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "name" where name.isEmpty && !depthName.isEmpty:
            name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "trkseg":
            if current.count >= 2 { segments.append(current) }
            current = []
        case "trk", "rte":
            if element == "rte", current.count >= 2 { segments.append(current) }
            if !segments.isEmpty {
                let title = name.isEmpty ? "Trail" : name
                trails.append(TrailLine(name: title, label: title, colorHex: TrailImporter.difficultyColor(title), segments: segments))
            }
            depthName = ""
        default: break
        }
        text = ""
    }
}

// MARK: - Minimal zip reader (KMZ files are zips)

enum Zip {
    static func entries(_ data: Data) throws -> [String: Data] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        // End of central directory record, searched from the end (it may be followed by a comment).
        guard b.count >= 22 else { throw TrailImportError.unreadable }
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 65_557) {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw TrailImportError.unreadable }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)

        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014B50 else { break }
            let method = u16(p + 10)
            let compSize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            guard local + 30 <= b.count, u32(local) == 0x04034B50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compSize <= b.count, !name.hasSuffix("/") else { continue }
            let raw = Array(b[start..<(start + compSize)])
            switch method {
            case 0: out[name] = Data(raw)
            case 8: if let inflated = inflate(raw, size: size) { out[name] = Data(inflated) }
            default: continue
            }
        }
        return out
    }

    /// Raw DEFLATE, which is what Apple's COMPRESSION_ZLIB decodes.
    static func inflate(_ src: [UInt8], size: Int) -> [UInt8]? {
        guard size > 0, !src.isEmpty else { return size == 0 ? [] : nil }
        var dst = [UInt8](repeating: 0, count: size)
        let written = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? dst : nil
    }
}
