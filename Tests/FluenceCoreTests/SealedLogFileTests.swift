import Foundation
import Testing

@testable import FluenceCore

/// R11 (audit 2026-10-08): a crash mid-append leaves a last line without its newline, and
/// the next dictation's line used to be glued onto it — two records lost instead of one.
struct SealedLogFileTests {
    private enum Cipher {
        static let tag = Data("ok:".utf8)
        static func seal(_ data: Data) -> Data { tag + Data(data.reversed()) }
        static func open(_ data: Data) throws -> Data {
            guard data.starts(with: tag) else { throw Failure() }
            return Data(data.dropFirst(tag.count).reversed())
        }
        struct Failure: Error {}
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedLogFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sealed")
    }

    @Test func aTornLastLineDoesNotSwallowTheNextAppend() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // The proven case: one good line, then an append cut short by a crash.
        var file = SealedLines.line(for: Data("kept".utf8), seal: Cipher.seal)
        file.append(SealedLines.line(for: Data("torn".utf8), seal: Cipher.seal).prefix(7))
        try file.write(to: url)

        try SealedLogFile.append(SealedLines.line(for: Data("next".utf8), seal: Cipher.seal), to: url)

        let decoded = SealedLines.decode(try Data(contentsOf: url), open: Cipher.open)
        #expect(decoded.records == [Data("kept".utf8), Data("next".utf8)])
        #expect(decoded.unreadable.count == 1)
    }

    @Test func aWholeFileGetsNoExtraBlankLine() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try SealedLogFile.append(SealedLines.line(for: Data("a".utf8), seal: Cipher.seal), to: url)
        try SealedLogFile.append(SealedLines.line(for: Data("b".utf8), seal: Cipher.seal), to: url)

        let data = try Data(contentsOf: url)
        #expect(!data.contains(Data([0x0A, 0x0A])))
        #expect(SealedLines.decode(data, open: Cipher.open).records == [Data("a".utf8), Data("b".utf8)])
    }

    @Test func createsTheFileOwnerOnly() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try SealedLogFile.append(SealedLines.line(for: Data("a".utf8), seal: Cipher.seal), to: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
