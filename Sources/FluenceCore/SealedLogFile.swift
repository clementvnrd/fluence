import Foundation

/// The disk half of `SealedLines`: appending one line to an append-only sealed log.
public enum SealedLogFile {
    /// Appends `line` (newline included, as `SealedLines.line` makes it), creating the file
    /// owner-only when it does not exist yet.
    ///
    /// A crash mid-append leaves a last line without its newline. Appending straight after
    /// it glued the next record onto the torn one, and both were lost (R11, audit
    /// 2026-10-08). So when the file does not end with a newline, one is written first: the
    /// torn line stays alone (kept, unreadable, as `SealedLines.decode` does) and the new
    /// record opens.
    public static func append(_ line: Data, to url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var bytes = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                bytes.append(0x0A)
            }
            try handle.seekToEnd()
        }
        bytes.append(line)
        // One write, so the repair and the record land together or not at all.
        try handle.write(contentsOf: bytes)
    }
}
