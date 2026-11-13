import Foundation
import SQLite3

/// Another app's SQLite file, opened read-only (FLU-144). `mode=ro` and not `immutable`: the
/// app may be running and writing in WAL mode, and `immutable` would read a torn state.
/// Columns are selected by name, only those the table has, so a column the app dropped reads
/// as nil rather than failing the import, and its audio blobs are never loaded.
final class ReadOnlyDatabase {
    typealias Row = [String: Any]

    private var db: OpaquePointer?

    init(_ url: URL) throws {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.query = "mode=ro"
        guard let uri = components.string,
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            db = nil
            throw ImportFailure.unreadable
        }
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit { sqlite3_close(db) }

    func columns(of table: String) -> Set<String> {
        Set((try? query("PRAGMA table_info(\"\(table)\")"))?.compactMap { $0["name"] as? String } ?? [])
    }

    /// The rows of `table`, with `wanted` columns the table has (an absent table gives none).
    func rows(_ table: String, _ wanted: [String]) throws -> [Row] {
        let present = columns(of: table)
        let names = wanted.filter(present.contains)
        guard !names.isEmpty else { return [] }
        return try query("SELECT \(names.map { "\"\($0)\"" }.joined(separator: ", ")) FROM \"\(table)\"")
    }

    private func query(_ sql: String) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw ImportFailure.unreadable
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ImportFailure.unreadable }
            var row: Row = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, index)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, index))
                default: break  // NULL, and blobs nobody asked for
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String? {
        switch self[key] {
        case let text as String: text
        case let number as Int64: String(number)
        case let number as Double: String(number)
        default: nil
        }
    }

    func number(_ key: String) -> Double? {
        switch self[key] {
        case let number as Int64: Double(number)
        case let number as Double: number
        case let text as String: Double(text)
        default: nil
        }
    }

    func flag(_ key: String) -> Bool { (number(key) ?? 0) != 0 }
}
