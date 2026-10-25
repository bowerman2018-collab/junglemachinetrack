// Checks the trail importer against a small synthetic KMZ shaped like the official
// Hatfield-McCoy export (ArcGIS: attributes in an HTML table, styles by id, deflated zip).
// Run: swiftc App/Maps/TrailImport.swift Tests/TrailImportCheck/main.swift -o check && ./check
import Foundation

func expect(_ ok: Bool, _ message: String) {
    if !ok { print("FAIL: \(message)"); exit(1) }
}

let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/TrailImportCheck/sample.kmz")
let trails = try TrailImporter.load(url)
for t in trails { print(t.label, "|", t.name, "|", t.colorHex ?? "-", "|", t.segments.map(\.count)) }
expect(trails.count == 2, "expected 2 trails, got \(trails.count)")
expect(trails[0].label == "73", "label should be the trail number, got \(trails[0].label)")
expect(trails[0].name == "Sample System Trail 73", "name was \(trails[0].name)")
expect(trails[0].colorHex == "#000000", "color should come from the KML style, got \(trails[0].colorHex ?? "nil")")
expect(trails[1].colorHex?.uppercased() == "#004DA8", "aabbggrr conversion, got \(trails[1].colorHex ?? "nil")")
expect(trails[0].segments.first?.count == 3, "segment points")
expect(abs(trails[0].segments[0][0][0] - -81.90) < 1e-9 && abs(trails[0].segments[0][0][1] - 37.70) < 1e-9, "lon/lat order")
expect(trails[0].details["Difficulty"] == "Most Difficult", "details parsed from the HTML table")
print("OK")
