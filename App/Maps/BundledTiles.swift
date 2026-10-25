import Foundation
import SQLite3

/// Map tiles that ship inside the app (BundledMaps/maps.sqlite, built by scripts/build_map_bundle.py):
/// USGS topo and satellite for every Hatfield-McCoy trail system, so the maps work right after install.
final class BundledTiles {
    static let shared = BundledTiles()

    private var db: OpaquePointer?
    private var query: OpaquePointer?
    private let lock = NSLock()

    var isAvailable: Bool { db != nil }

    private init() {
        guard let url = Bundle.main.url(forResource: "maps", withExtension: "sqlite"),
              sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        if sqlite3_prepare_v2(db, "SELECT data FROM tiles WHERE source = ? AND z = ? AND x = ? AND y = ?", -1, &query, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
        }
    }

    func data(_ source: TileSource, _ key: TileKey) -> Data? {
        guard let query else { return nil }
        lock.lock()
        defer { lock.unlock() }
        sqlite3_reset(query)
        sqlite3_bind_text(query, 1, source.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(query, 2, Int32(key.z))
        sqlite3_bind_int(query, 3, Int32(key.x))
        sqlite3_bind_int(query, 4, Int32(key.y))
        guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
    }
}
