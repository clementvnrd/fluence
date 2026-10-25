import Foundation

/// One sealed JSON value in one file, read and rewritten whole (voice prints).
///
/// The cipher is injected, as in `SealedLines`; the app passes `Vault`.
public enum SealedJSONFile {
    /// The file exists but could not be opened or decoded: nothing may be written over it.
    public struct Unreadable: Error, CustomStringConvertible {
        public let underlying: Error
        public var description: String { "unreadable sealed file: \(underlying)" }
    }

    /// The stored value, `nil` when there is no file.
    public static func read<Value: Decodable>(
        _ type: Value.Type,
        at url: URL,
        decoder: JSONDecoder = JSONDecoder(),
        open: (Data) throws -> Data
    ) throws -> Value? {
        let sealed: Data
        do {
            sealed = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
        do {
            return try decoder.decode(Value.self, from: try open(sealed))
        } catch {
            throw Unreadable(underlying: error)
        }
    }

    /// Reads, changes and rewrites the value (atomically, owner-only).
    ///
    /// A missing file starts from `empty`. A file that exists but cannot be opened throws
    /// `Unreadable` before `change` runs, and nothing is written: reading it as empty and
    /// saving would erase what it holds (R9, audit 2026-10-08).
    public static func update<Value: Codable>(
        _ type: Value.Type,
        at url: URL,
        empty: Value,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        open: (Data) throws -> Data,
        seal: (Data) throws -> Data,
        change: (inout Value) throws -> Void
    ) throws {
        var value = try read(type, at: url, decoder: decoder, open: open) ?? empty
        try change(&value)
        try seal(try encoder.encode(value)).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
