import CryptoKit
import Foundation
import Testing

@testable import FluenceCore

/// A key store in memory: no test ever touches the Keychain.
final class MemoryKeyStore: MasterKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private(set) var writes = 0
    var failure: Error?

    init(_ key: SymmetricKey? = nil) {
        self.key = key.map { $0.withUnsafeBytes { Data($0) } }
    }

    var stored: Data? { lock.withLock { key } }

    func readKey() throws -> Data? {
        try lock.withLock {
            if let failure { throw failure }
            return key
        }
    }

    func addKey(_ key: Data) throws {
        lock.withLock {
            precondition(self.key == nil, "add over an existing key")
            self.key = key
            writes += 1
        }
    }

    func replaceKey(_ key: Data) throws {
        lock.withLock {
            precondition(self.key != nil, "replace without a key")
            self.key = key
            writes += 1
        }
    }
}

/// A support folder in the temporary directory, with data sealed by a given key.
struct VaultFixture {
    let root: URL
    var layout: VaultLayout { VaultLayout(root: root) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func run(_ text: String, date: String) -> Data {
        Data(#"{"date":"\#(date)","engine":"Apple (streaming)","audioSeconds":1,"processSeconds":0.5,"text":"\#(text)","id":"\#(UUID().uuidString)"}"#.utf8)
    }

    /// History, snippets and one meeting, sealed the way the app seals them.
    func seal(with key: SymmetricKey, runs: [Data] = [run("bonjour", date: "2026-10-01T10:00:00Z")],
              snippets: [Snippet] = [Snippet(trigger: "mon adresse", expansion: "1 rue de la Paix")],
              meetingTitle: String? = "Point hebdo") throws {
        let history = try SealedLines.file(records: runs) { try VaultCipher.seal($0, with: key) }
        try history.write(to: layout.history)
        try VaultCipher.seal(try JSONEncoder().encode(snippets), with: key).write(to: layout.snippets)
        if let meetingTitle {
            let id = UUID()
            let directory = layout.meetings.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let meetingKey = SymmetricKey(size: .bits256)
            try VaultCipher.seal(meetingKey.withUnsafeBytes { Data($0) }, with: key)
                .write(to: directory.appendingPathComponent("key.wrapped"))
            try VaultCipher.seal(Data(#"{"title":"\#(meetingTitle)"}"#.utf8), with: meetingKey)
                .write(to: directory.appendingPathComponent("meeting.enc"))
        }
    }
}

struct VaultKeyPolicyTests {
    @Test func table() {
        typealias P = VaultKeyPolicy
        #expect(P.decide(keyInStore: false, fingerprintMatches: nil, hasSealedData: false) { nil } == .create)
        #expect(P.decide(keyInStore: false, fingerprintMatches: nil, hasSealedData: true) { nil } == .lost)
        #expect(P.decide(keyInStore: true, fingerprintMatches: true, hasSealedData: true) { false } == .use)
        #expect(P.decide(keyInStore: true, fingerprintMatches: false, hasSealedData: true) { false } == .lost)
        // A fingerprint alone never calls a working key lost.
        #expect(P.decide(keyInStore: true, fingerprintMatches: false, hasSealedData: true) { true } == .use)
        #expect(P.decide(keyInStore: true, fingerprintMatches: false, hasSealedData: false) { nil } == .use)
        #expect(P.decide(keyInStore: true, fingerprintMatches: nil, hasSealedData: true) { true } == .use)
        #expect(P.decide(keyInStore: true, fingerprintMatches: nil, hasSealedData: true) { false } == .lost)
    }
}

struct VaultKeyringTests {
    @Test func aFirstLaunchMakesAKey() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let store = MemoryKeyStore()
        let keyring = VaultKeyring(store: store, layout: fixture.layout)

        let key = try keyring.masterKey()
        #expect(store.stored == key.withUnsafeBytes { Data($0) })
        #expect(try String(contentsOf: fixture.layout.fingerprint, encoding: .utf8)
            .trimmingCharacters(in: .newlines) == VaultKeyFingerprint.of(key))
        #expect(try keyring.masterKey() == key)
    }

    /// R6: a missing Keychain item silently made a new key over existing data.
    @Test func sealedDataWithoutItsKeyIsLostNotReplaced() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        try fixture.seal(with: SymmetricKey(size: .bits256))
        let before = try Data(contentsOf: fixture.layout.history)
        let store = MemoryKeyStore()  // a new Mac, a Keychain reset
        let keyring = VaultKeyring(store: store, layout: fixture.layout)

        #expect(throws: VaultKeyError.keyLost) { try keyring.masterKey() }
        #expect(keyring.isKeyLost)
        #expect(store.stored == nil)
        #expect(store.writes == 0)
        #expect(try Data(contentsOf: fixture.layout.history) == before)
        // Asked again (every append, every save): still lost, still no key.
        #expect(throws: VaultKeyError.keyLost) { try keyring.masterKey() }
        #expect(store.stored == nil)
    }

    @Test func onlyAMeetingIsEnoughToCountAsData() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        try fixture.seal(with: SymmetricKey(size: .bits256), runs: [], snippets: [])
        try FileManager.default.removeItem(at: fixture.layout.history)
        try FileManager.default.removeItem(at: fixture.layout.snippets)
        #expect(fixture.layout.hasSealedData)
        #expect(throws: VaultKeyError.keyLost) {
            try VaultKeyring(store: MemoryKeyStore(), layout: fixture.layout).masterKey()
        }
    }

    @Test func anInstallFromBeforeTheFingerprintKeepsItsKey() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let key = SymmetricKey(size: .bits256)
        try fixture.seal(with: key)
        let keyring = VaultKeyring(store: MemoryKeyStore(key), layout: fixture.layout)

        #expect(try keyring.masterKey() == key)
        #expect(FileManager.default.fileExists(atPath: fixture.layout.fingerprint.path))
    }

    /// A history that already lived through a silent key change (before FLU-36): many old
    /// lines first, then the current key's. The current key must not be called lost.
    @Test func oldUnreadableLinesDoNotHideAWorkingKey() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let old = SymmetricKey(size: .bits256)
        let current = SymmetricKey(size: .bits256)
        let oldLines = (0..<200).map { VaultFixture.run("vieux \($0)", date: "2026-01-01T10:00:00Z") }
        try fixture.seal(with: old, runs: oldLines, meetingTitle: nil)  // snippets under the old key too
        try SealedLogFile.append(SealedLines.line(for: VaultFixture.run("récent", date: "2026-10-01T10:00:00Z")) {
            try VaultCipher.seal($0, with: current)
        }, to: fixture.layout.history)

        #expect(try VaultKeyring(store: MemoryKeyStore(current), layout: fixture.layout).masterKey() == current)
    }

    @Test func aKeyThatOpensNothingIsLost() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        try fixture.seal(with: SymmetricKey(size: .bits256))
        let other = MemoryKeyStore(SymmetricKey(size: .bits256))
        #expect(throws: VaultKeyError.keyLost) {
            try VaultKeyring(store: other, layout: fixture.layout).masterKey()
        }
    }

    @Test func aFingerprintMismatchIsLost() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let original = SymmetricKey(size: .bits256)
        try fixture.seal(with: original)
        _ = try VaultKeyring(store: MemoryKeyStore(original), layout: fixture.layout).masterKey()

        #expect(throws: VaultKeyError.keyLost) {
            try VaultKeyring(store: MemoryKeyStore(SymmetricKey(size: .bits256)), layout: fixture.layout).masterKey()
        }
    }

    @Test func aKeychainFailureIsNotKeyLoss() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        try fixture.seal(with: SymmetricKey(size: .bits256))
        struct Locked: Error {}
        let store = MemoryKeyStore()
        store.failure = Locked()
        let keyring = VaultKeyring(store: store, layout: fixture.layout)

        #expect(throws: Locked.self) { try keyring.masterKey() }
        #expect(!keyring.isKeyLost)
    }

    @Test func startingFreshMovesTheOldFilesAsideAndKeepsTheDictionary() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        try fixture.seal(with: SymmetricKey(size: .bits256))
        let dictionary = fixture.root.appendingPathComponent("dictionary.txt")
        try Data("Fluence\n".utf8).write(to: dictionary)
        let store = MemoryKeyStore()
        let keyring = VaultKeyring(store: store, layout: fixture.layout)
        #expect(throws: VaultKeyError.keyLost) { try keyring.masterKey() }

        let aside = try #require(try keyring.startFresh(now: Date(timeIntervalSince1970: 1_800_000_000)))

        #expect(aside.lastPathComponent.hasPrefix("Données illisibles "))
        for name in ["history.sealed", "snippets.sealed", "Meetings"] {
            #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent(name).path), "\(name)")
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path), "\(name)")
        }
        #expect(FileManager.default.fileExists(atPath: dictionary.path))
        #expect(!keyring.isKeyLost)
        let key = try keyring.masterKey()
        #expect(store.stored == key.withUnsafeBytes { Data($0) })
    }

    @Test func startingFreshNeverMovesReadableData() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let key = SymmetricKey(size: .bits256)
        try fixture.seal(with: key)
        let keyring = VaultKeyring(store: MemoryKeyStore(key), layout: fixture.layout)

        #expect(try keyring.startFresh() == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.layout.history.path))
    }

    @Test func restoringTheSameKeyBringsEverythingBack() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let original = SymmetricKey(size: .bits256)
        try fixture.seal(with: original)
        _ = try VaultKeyring(store: MemoryKeyStore(original), layout: fixture.layout).masterKey()  // fingerprint
        let store = MemoryKeyStore()  // Keychain reset
        let keyring = VaultKeyring(store: store, layout: fixture.layout)
        #expect(throws: VaultKeyError.keyLost) { try keyring.masterKey() }

        let restore = try keyring.keyForRestore(backupKey: original)

        #expect(restore.adoptedBackupKey)
        #expect(restore.setAside == nil)
        #expect(store.stored == original.withUnsafeBytes { Data($0) })
        #expect(try keyring.masterKey() == original)
    }

    @Test func restoringAnotherKeySetsTheUnreadableDataAside() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        try fixture.seal(with: SymmetricKey(size: .bits256))
        let keyring = VaultKeyring(store: MemoryKeyStore(), layout: fixture.layout)

        let backupKey = SymmetricKey(size: .bits256)
        let restore = try keyring.keyForRestore(backupKey: backupKey)

        #expect(restore.setAside != nil)
        #expect(!fixture.layout.hasSealedData)
        #expect(try keyring.masterKey() == restore.key)
    }

    @Test func aNewMacTakesTheBackupKey() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let store = MemoryKeyStore()
        let backupKey = SymmetricKey(size: .bits256)

        let restore = try VaultKeyring(store: store, layout: fixture.layout).keyForRestore(backupKey: backupKey)

        #expect(restore.key == backupKey)
        #expect(restore.adoptedBackupKey)
        #expect(store.stored == backupKey.withUnsafeBytes { Data($0) })
    }

    @Test func aWorkingKeyIsKeptForARestore() throws {
        let fixture = try VaultFixture()
        defer { fixture.remove() }
        let key = SymmetricKey(size: .bits256)
        try fixture.seal(with: key)
        let store = MemoryKeyStore(key)

        let restore = try VaultKeyring(store: store, layout: fixture.layout).keyForRestore(backupKey: SymmetricKey(size: .bits256))

        #expect(restore.key == key)
        #expect(!restore.adoptedBackupKey)
        #expect(store.writes == 0)
    }
}

extension SymmetricKey: @retroactive Equatable {
    public static func == (lhs: SymmetricKey, rhs: SymmetricKey) -> Bool {
        lhs.withUnsafeBytes { Data($0) } == rhs.withUnsafeBytes { Data($0) }
    }
}
