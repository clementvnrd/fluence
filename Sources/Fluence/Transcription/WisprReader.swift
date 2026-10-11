import Foundation
import SQLite3

#if !FLUENCE_WITHOUT_WISPR  // FLU-69: compiled out of the builds made for other people

/// Wispr Flow's result for an utterance, for compare mode.
///
/// Wispr Flow is closed and has no API, but it saves every dictation in a local SQLite file,
/// `~/Library/Application Support/Wispr Flow/flow.sqlite`: the recognizer's raw text, the text
/// after its own cleanup, and the end-to-end latency. That is Fluence's own split (engine, then
/// `TextFormatter`), which is what makes a side-by-side fair. The file is Wispr's and is only
/// ever opened read-only.
enum WisprReader {
    /// Wispr cleans up in the cloud, so its row is complete only some time after release, later
    /// than the local engines: the row is polled for.
    private static let pollInterval: Duration = .milliseconds(300)

    /// How far before or after the hold start Wispr's stamp may fall (why: `result(after:timeout:)`).
    private static let window: TimeInterval = 5

    private static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wispr Flow/flow.sqlite")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    /// Waits for Wispr's row for the utterance whose hold started at `holdStarted`.
    ///
    /// Nil when Wispr is not installed, was not triggered for this utterance, or had not finished
    /// by `timeout`. When only Fluence's own key was held there is no row, which is normal.
    static func result(after holdStarted: Date, timeout: TimeInterval) async -> ComparisonResult? {
        guard isInstalled else { return nil }

        // Wispr stamps a row with the moment its utterance began. The two keys never go down in
        // the same millisecond, so that stamp often falls just before our hold start, and a search
        // running forward from the hold start missed the row every time. Widening only towards
        // the past would not do either: Wispr inserts the row as the utterance starts, text still
        // null, and fills it in later, so the first poll would find the previous dictation's
        // row. Hence a window bounded on both sides.
        let lower = stamp(holdStarted.addingTimeInterval(-window))
        let upper = stamp(holdStarted.addingTimeInterval(window))
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let found = latestRow(between: lower, and: upper) { return found }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        // Wispr's fixed text format: it must not follow the user's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private static func latestRow(between lower: String, and upper: String) -> ComparisonResult? {
        // The read-only flag and `mode=ro` together keep this connection from ever writing.
        // No `immutable=1`: SQLite would take the file as frozen and miss the rows Wispr adds
        // while we poll.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2("file:\(databaseURL.path)?mode=ro", &db, flags, nil) == SQLITE_OK else {
            // A failed open can still allocate a handle.
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Wispr's cleanup may still be running, so its raw text stands in until the cleaned
        // text is there.
        let sql = """
            SELECT COALESCE(NULLIF(formattedText, ''), asrText), e2eLatency
            FROM History
            WHERE substr(timestamp, 1, 23) > ?
              AND substr(timestamp, 1, 23) < ?
              AND COALESCE(NULLIF(formattedText, ''), asrText) IS NOT NULL
            ORDER BY timestamp DESC
            LIMIT 1
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT, which Swift does not import: SQLite copies each string before the
        // call returns, so the temporary C strings may go away.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, lower, -1, transient)
        sqlite3_bind_text(statement, 2, upper, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let column = sqlite3_column_text(statement, 0) else { return nil }

        let text = String(cString: column).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Milliseconds, end to end: a network round trip and Wispr's cleanup are in it, so it is
        // not comparable with the local engines' compute time (the UI says so).
        return ComparisonResult(
            engine: "Wispr Flow",
            text: text,
            seconds: sqlite3_column_double(statement, 1) / 1000
        )
    }
}

#endif
