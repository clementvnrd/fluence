import Foundation
import Testing

@testable import FluenceCore

/// R9: a voice print file that failed to open (Keychain refused, key lost) was read as
/// « no prints », and the next enrolment or delete wrote that over it.
struct SealedJSONFileTests {
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
            .appendingPathComponent("SealedJSONFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("prints.enc")
    }

    @Test func anUnreadableFileIsNeverOverwritten() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Sealed under a key this run doesn't have.
        let original = Data("sealed elsewhere".utf8)
        try original.write(to: url)

        #expect(throws: SealedJSONFile.Unreadable.self) {
            try SealedJSONFile.update([String].self, at: url, empty: [], open: Cipher.open, seal: Cipher.seal) {
                $0.append("Alice")
            }
        }
        #expect(throws: SealedJSONFile.Unreadable.self) {
            try SealedJSONFile.update([String].self, at: url, empty: [], open: Cipher.open, seal: Cipher.seal) {
                $0.removeAll { $0 == "Alice" }
            }
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aMissingFileStartsEmpty() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(try SealedJSONFile.read([String].self, at: url, open: Cipher.open) == nil)
        try SealedJSONFile.update([String].self, at: url, empty: [], open: Cipher.open, seal: Cipher.seal) {
            $0.append("Alice")
        }
        #expect(try SealedJSONFile.read([String].self, at: url, open: Cipher.open) == ["Alice"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func aReadableFileIsChangedInPlace() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for name in ["Alice", "Bob"] {
            try SealedJSONFile.update([String].self, at: url, empty: [], open: Cipher.open, seal: Cipher.seal) {
                $0.append(name)
            }
        }
        try SealedJSONFile.update([String].self, at: url, empty: [], open: Cipher.open, seal: Cipher.seal) {
            $0.removeAll { $0 == "Alice" }
        }
        #expect(try SealedJSONFile.read([String].self, at: url, open: Cipher.open) == ["Bob"])
    }
}
