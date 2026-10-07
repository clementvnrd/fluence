import Foundation

/// The on-disk shape of an append-only encrypted log: one sealed record per line.
///
/// Each line is the base64 of an authenticated ciphertext. Per-line sealing, rather than
/// one blob for the whole file, is what keeps appending cheap — a new dictation is one
/// seal and one write, never a decrypt-and-rewrite of the entire history — and it means a
/// crash mid-append costs at most the line being written.
///
/// The cipher is injected so this stays pure and testable; the app passes `Vault`.
public enum SealedLines {
    /// One encoded line, newline included, ready to append.
    public static func line(
        for record: Data,
        seal: (Data) throws -> Data
    ) rethrows -> Data {
        var line = try seal(record).base64EncodedData()
        line.append(0x0A)
        return line
    }

    /// A whole file's worth of lines, for an atomic rewrite.
    public static func file(
        records: [Data],
        preserving unreadable: [Data] = [],
        seal: (Data) throws -> Data
    ) rethrows -> Data {
        var file = Data()
        // Lines this key can't open are kept verbatim and first. They are most likely
        // written under a previous Keychain key, and a delete or a retention purge must
        // never be the thing that destroys them.
        for line in unreadable {
            file.append(line)
            file.append(0x0A)
        }
        for record in records {
            file.append(try Self.line(for: record, seal: seal))
        }
        return file
    }

    public struct Decoded: Sendable, Equatable {
        /// Opened records, in file order.
        public var records: [Data] = []
        /// Raw lines that didn't decode or failed authentication, in file order.
        public var unreadable: [Data] = []
    }

    /// Opens every line it can. Never throws: one bad line (a torn append, a stray edit)
    /// must not cost the rest of the history.
    public static func decode(
        _ file: Data,
        open: (Data) throws -> Data
    ) -> Decoded {
        var decoded = Decoded()
        for rawLine in file.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(rawLine)
            guard let sealed = Data(base64Encoded: line),
                  let record = try? open(sealed)
            else {
                decoded.unreadable.append(line)
                continue
            }
            decoded.records.append(record)
        }
        return decoded
    }
}
