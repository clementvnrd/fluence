import CryptoKit
import Foundation
import Testing

@testable import FluenceCore

/// « Sauvegarder mes données » and its restore, between two support folders in the
/// temporary directory with in-memory key stores: one Mac's data comes back on another.
struct DataBackupTests {
    private let passphrase = "brume sur la Seine"

    private func backup(of fixture: VaultFixture, key: SymmetricKey) throws -> Data {
        let contents = DataBackup.Contents(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            masterKey: key.withUnsafeBytes { Data($0) },
            files: try DataBackup.collect(from: fixture.layout)
        )
        return try DataBackup.seal(contents, passphrase: passphrase, rounds: 1_000)
    }

    private func history(_ layout: VaultLayout, key: SymmetricKey) throws -> [String] {
        SealedLines.decode(try Data(contentsOf: layout.history)) { try VaultCipher.open($0, with: key) }
            .records.map { DataRestore.identity(of: $0) }
    }

    private func snippets(_ layout: VaultLayout, key: SymmetricKey) throws -> [String] {
        try SealedJSONFile.read([Snippet].self, at: layout.snippets) { try VaultCipher.open($0, with: key) }?
            .map(\.trigger) ?? []
    }

    private func meetingTitles(_ layout: VaultLayout, key: SymmetricKey) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: layout.meetings.path).filter { UUID(uuidString: $0) != nil }
        return try names.map { name in
            let directory = layout.meetings.appendingPathComponent(name)
            let meetingKey = SymmetricKey(data: try VaultCipher.open(Data(contentsOf: directory.appendingPathComponent("key.wrapped")), with: key))
            let meeting = try VaultCipher.open(Data(contentsOf: directory.appendingPathComponent("meeting.enc")), with: meetingKey)
            return (try JSONSerialization.jsonObject(with: meeting) as? [String: String])?["title"] ?? ""
        }.sorted()
    }

    /// The acceptance case: a fresh account gets history, snippets, dictionary and meetings.
    @Test func aBackupComesBackOnANewMac() throws {
        let macA = try VaultFixture()
        defer { macA.remove() }
        let keyA = SymmetricKey(size: .bits256)
        try macA.seal(with: keyA, runs: [
            VaultFixture.run("bonjour", date: "2026-10-01T10:00:00Z"),
            VaultFixture.run("au revoir", date: "2026-10-02T10:00:00Z"),
        ])
        try Data("# Fluence dictionary\nOllivault\nnova tec -> Novatek\n".utf8)
            .write(to: macA.root.appendingPathComponent("dictionary.txt"))
        // Audio and voice prints never leave the Mac.
        try Data("audio".utf8).write(to: try FileManager.default.contentsOfDirectory(at: macA.layout.meetings, includingPropertiesForKeys: nil)[0].appendingPathComponent("audio-mic.enc"))
        let archive = try backup(of: macA, key: keyA)
        #expect(!archive.contains(Data("Ollivault".utf8)))
        #expect(!archive.contains(Data("bonjour".utf8)))

        let macB = try VaultFixture()
        defer { macB.remove() }
        let storeB = MemoryKeyStore()
        let keyringB = VaultKeyring(store: storeB, layout: macB.layout)
        let summary = try DataRestore.restore(try DataBackup.open(archive, passphrase: passphrase), keyring: keyringB)

        #expect(summary.dictations == 2)
        #expect(summary.snippets == 1)
        #expect(summary.dictionaryLines == 2)
        #expect(summary.meetings == 1)
        let keyB = try keyringB.masterKey()
        #expect(try history(macB.layout, key: keyB).count == 2)
        #expect(try snippets(macB.layout, key: keyB) == ["mon adresse"])
        #expect(try String(contentsOf: macB.root.appendingPathComponent("dictionary.txt"), encoding: .utf8).contains("nova tec -> Novatek"))
        #expect(try meetingTitles(macB.layout, key: keyB) == ["Point hebdo"])
        let restoredMeeting = try FileManager.default.contentsOfDirectory(at: macB.layout.meetings, includingPropertiesForKeys: nil)
            .first { UUID(uuidString: $0.lastPathComponent) != nil }!
        #expect(!FileManager.default.fileExists(atPath: restoredMeeting.appendingPathComponent("audio-mic.enc").path))
    }

    @Test func aRestoreMergesIntoAMacThatAlreadyHasData() throws {
        let macA = try VaultFixture()
        defer { macA.remove() }
        let keyA = SymmetricKey(size: .bits256)
        try macA.seal(with: keyA, runs: [
            VaultFixture.run("ancienne", date: "2026-09-01T10:00:00Z"),
            VaultFixture.run("commune", date: "2026-10-01T10:00:00Z"),
        ], meetingTitle: "Réunion A")
        try Data("Ollivault\n".utf8).write(to: macA.root.appendingPathComponent("dictionary.txt"))
        let archive = try backup(of: macA, key: keyA)

        let macB = try VaultFixture()
        defer { macB.remove() }
        let keyB = SymmetricKey(size: .bits256)
        try macB.seal(with: keyB, runs: [
            VaultFixture.run("commune", date: "2026-10-01T10:00:00Z"),
            VaultFixture.run("récente", date: "2026-10-20T10:00:00Z"),
        ], snippets: [Snippet(trigger: "ma signature", expansion: "Clément")], meetingTitle: "Réunion B")
        try Data("Brumeware\n".utf8).write(to: macB.root.appendingPathComponent("dictionary.txt"))
        let storeB = MemoryKeyStore(keyB)
        let keyringB = VaultKeyring(store: storeB, layout: macB.layout)

        let contents = try DataBackup.open(archive, passphrase: passphrase)
        let summary = try DataRestore.restore(contents, keyring: keyringB)

        #expect(!summary.adoptedKey)
        #expect(storeB.stored == keyB.withUnsafeBytes { Data($0) })
        #expect(summary.dictations == 1)
        #expect(try history(macB.layout, key: keyB).map { $0.components(separatedBy: "|")[1] } == ["ancienne", "commune", "récente"])
        #expect(try snippets(macB.layout, key: keyB) == ["ma signature", "mon adresse"])
        #expect(try String(contentsOf: macB.root.appendingPathComponent("dictionary.txt"), encoding: .utf8) == "Brumeware\nOllivault\n")
        #expect(try meetingTitles(macB.layout, key: keyB) == ["Réunion A", "Réunion B"])

        // The same file a second time adds nothing.
        let again = try DataRestore.restore(contents, keyring: keyringB)
        #expect(again.dictations == 0 && again.snippets == 0 && again.dictionaryLines == 0 && again.meetings == 0)
        #expect(try history(macB.layout, key: keyB).count == 3)
    }

    /// The same Mac after a Keychain reset: the backup's key reopens everything on disk,
    /// even what was written after the backup.
    @Test func aRestoreAfterAKeychainResetReopensEverything() throws {
        let mac = try VaultFixture()
        defer { mac.remove() }
        let key = SymmetricKey(size: .bits256)
        try mac.seal(with: key, runs: [VaultFixture.run("avant", date: "2026-10-01T10:00:00Z")])
        _ = try VaultKeyring(store: MemoryKeyStore(key), layout: mac.layout).masterKey()
        let archive = try backup(of: mac, key: key)
        try SealedLogFile.append(SealedLines.line(for: VaultFixture.run("après", date: "2026-10-10T10:00:00Z")) {
            try VaultCipher.seal($0, with: key)
        }, to: mac.layout.history)

        let reset = MemoryKeyStore()
        let keyring = VaultKeyring(store: reset, layout: mac.layout)
        #expect(throws: VaultKeyError.keyLost) { try keyring.masterKey() }
        let summary = try DataRestore.restore(try DataBackup.open(archive, passphrase: passphrase), keyring: keyring)

        #expect(summary.adoptedKey)
        #expect(summary.setAside == nil)
        #expect(try history(mac.layout, key: try keyring.masterKey()).count == 2)
    }

    @Test func aWrongPassphraseOpensNothing() throws {
        let mac = try VaultFixture()
        defer { mac.remove() }
        let archive = try backup(of: mac, key: SymmetricKey(size: .bits256))
        #expect(throws: DataBackup.Failure.wrongPassphrase) { try DataBackup.open(archive, passphrase: "brume sur la seine") }
    }

    @Test func aTamperedFileOpensNothing() throws {
        let mac = try VaultFixture()
        defer { mac.remove() }
        try mac.seal(with: SymmetricKey(size: .bits256))
        var archive = try backup(of: mac, key: SymmetricKey(size: .bits256))
        archive[archive.count - 40] ^= 0x01
        #expect(throws: DataBackup.Failure.wrongPassphrase) { try DataBackup.open(archive, passphrase: passphrase) }

        var header = try backup(of: mac, key: SymmetricKey(size: .bits256))
        header[DataBackup.headerLength - 1] ^= 0x01  // the salt, authenticated
        #expect(throws: DataBackup.Failure.wrongPassphrase) { try DataBackup.open(header, passphrase: passphrase) }

        #expect(throws: DataBackup.Failure.notABackup) { try DataBackup.open(Data("hello".utf8), passphrase: passphrase) }
    }

    @Test func theAccentedPassphraseIsTheSameWhicheverWayItWasTyped() throws {
        let mac = try VaultFixture()
        defer { mac.remove() }
        let contents = DataBackup.Contents(createdAt: Date(), masterKey: Data(repeating: 1, count: 32), files: [])
        let archive = try DataBackup.seal(contents, passphrase: "Cl\u{E9}ment-2026", rounds: 1_000)
        #expect(try DataBackup.open(archive, passphrase: "Cle\u{301}ment-2026").masterKey == contents.masterKey)
    }

    @Test func aShortPassphraseIsRefused() {
        let contents = DataBackup.Contents(createdAt: Date(), masterKey: Data(repeating: 1, count: 32), files: [])
        #expect(throws: DataBackup.Failure.passphraseTooShort) { try DataBackup.seal(contents, passphrase: "court", rounds: 1_000) }
    }

    @Test func onlyKnownPathsAreRestored() throws {
        let contents = DataBackup.Contents(createdAt: Date(), masterKey: Data(repeating: 1, count: 32), files: [
            .init(path: "../../.zshrc", data: Data("x".utf8)),
            .init(path: "/etc/hosts", data: Data("x".utf8)),
            .init(path: "Meetings/not-a-uuid/meeting.enc", data: Data("x".utf8)),
            .init(path: "Meetings/\(UUID().uuidString)/../../x", data: Data("x".utf8)),
            .init(path: "VoicePrints/prints.enc", data: Data("x".utf8)),
            .init(path: "dictionary.txt", data: Data("x".utf8)),
        ])
        let archive = try DataBackup.seal(contents, passphrase: passphrase, rounds: 1_000)
        #expect(try DataBackup.open(archive, passphrase: passphrase).files.map(\.path) == ["dictionary.txt"])
    }

    @Test func unreadableSnippetsHereAreNeverOverwritten() throws {
        let macA = try VaultFixture()
        defer { macA.remove() }
        let keyA = SymmetricKey(size: .bits256)
        try macA.seal(with: keyA)
        let archive = try backup(of: macA, key: keyA)

        let macB = try VaultFixture()
        defer { macB.remove() }
        let keyB = SymmetricKey(size: .bits256)
        try macB.seal(with: keyB, meetingTitle: nil)
        let foreign = Data("sealed under a key that is gone".utf8)
        try foreign.write(to: macB.layout.snippets)

        let summary = try DataRestore.restore(try DataBackup.open(archive, passphrase: passphrase),
                                              keyring: VaultKeyring(store: MemoryKeyStore(keyB), layout: macB.layout))
        #expect(summary.skipped.count == 1)
        #expect(try Data(contentsOf: macB.layout.snippets) == foreign)
    }
}
