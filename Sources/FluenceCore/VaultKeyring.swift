import CryptoKit
import Foundation

/// Where the master key is kept. The app's is the Keychain; tests use memory, so no test
/// ever creates a Keychain item.
public protocol MasterKeyStore: Sendable {
    /// The stored key, or nil when there is none (and only then: any other failure throws).
    func readKey() throws -> Data?
    func addKey(_ key: Data) throws
    /// Replaces a stored key. Only ever called when the stored one cannot open the data.
    func replaceKey(_ key: Data) throws
}

public enum VaultKeyError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Sealed data is here and no key this Mac has can open it.
    case keyLost
    /// The stored key is not a 256-bit key.
    case malformedKey

    public var description: String {
        switch self {
        case .keyLost: "Vos données chiffrées ne peuvent plus être lues sur ce Mac."
        case .malformedKey: "La clé de chiffrement de Fluence est illisible."
        }
    }

    public var errorDescription: String? { description }
}

/// The files the master key seals, under the support folder.
public struct VaultLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var history: URL { root.appendingPathComponent("history.sealed") }
    public var snippets: URL { root.appendingPathComponent("snippets.sealed") }
    public var meetings: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
    public var voicePrints: URL { root.appendingPathComponent("VoicePrints", isDirectory: true) }
    /// Which key sealed the data, as `VaultKeyFingerprint` (not secret).
    public var fingerprint: URL { root.appendingPathComponent("vault-key.id") }

    /// What « Repartir de zéro » moves aside.
    public var sealedItems: [URL] { [history, snippets, meetings, voicePrints, fingerprint] }

    /// Something sealed with a master key is on disk.
    public var hasSealedData: Bool { !evidence(limit: 1).isEmpty }

    enum Evidence {
        /// A `SealedLines` file: base64 boxes, one per line.
        case lines(URL)
        /// One AES-GCM box.
        case box(URL)
    }

    /// Files sealed directly with the master key, at most `limit` of them.
    func evidence(limit: Int = .max) -> [Evidence] {
        let manager = FileManager.default
        var found: [Evidence] = []
        if let data = try? Data(contentsOf: history), data.contains(where: { $0 != 0x0A }) {
            found.append(.lines(history))
        }
        for url in [snippets, meetings.appendingPathComponent("index.enc"), voicePrints.appendingPathComponent("prints.enc")]
        where manager.fileExists(atPath: url.path) {
            found.append(.box(url))
        }
        if found.count < limit, let names = try? manager.contentsOfDirectory(atPath: meetings.path) {
            for name in names.sorted() where UUID(uuidString: name) != nil {
                let wrapped = meetings.appendingPathComponent(name).appendingPathComponent("key.wrapped")
                if manager.fileExists(atPath: wrapped.path) { found.append(.box(wrapped)) }
                if found.count >= limit { break }
            }
        }
        return Array(found.prefix(limit))
    }

    /// Whether `key` opens what is on disk: true if anything opens, false if things were
    /// tried and none did, nil when there is nothing to try.
    public func keyOpensData(_ key: SymmetricKey) -> Bool? {
        let evidence = evidence()
        guard !evidence.isEmpty else { return nil }
        for item in evidence {
            switch item {
            case .box(let url):
                if let data = try? Data(contentsOf: url), VaultCipher.canOpen(data, with: key) { return true }
            case .lines(let url):
                // Every line, newest first: a history that once lived through a silent key
                // change starts with lines no key here opens, and the current key's lines
                // follow. A trial per line costs microseconds.
                guard let data = try? Data(contentsOf: url) else { continue }
                for line in data.split(separator: 0x0A).reversed() {
                    if let sealed = Data(base64Encoded: Data(line)), VaultCipher.canOpen(sealed, with: key) { return true }
                }
            }
        }
        return false
    }
}

/// AES-256-GCM, as the Vault seals: `nonce | ciphertext | tag`.
public enum VaultCipher {
    public static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined
    }

    public static func open(_ sealed: Data, with key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    static func canOpen(_ sealed: Data, with key: SymmetricKey) -> Bool {
        (try? open(sealed, with: key)) != nil
    }
}

/// Names a key without revealing it: an HMAC of a constant under the key.
public enum VaultKeyFingerprint {
    public static func of(_ key: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("Fluence vault key fingerprint v1".utf8), using: key)
        return "v1:" + Data(code).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// What to do with the key the store returned (or did not).
public enum VaultKeyPolicy {
    public enum Decision: Equatable, Sendable {
        /// Use the stored key.
        case use
        /// No key and nothing sealed: make one.
        case create
        /// Sealed data that this key cannot open, or no key at all for it: stop. Never make
        /// a new key over existing data (R6).
        case lost
    }

    /// - Parameters:
    ///   - fingerprintMatches: whether the stored key is the one the data was sealed with,
    ///     per the fingerprint file; nil without a key or without the file. A match skips
    ///     the trial; a mismatch does not decide alone, the trial does.
    ///   - keyOpensData: tries the stored key on the data (installs from before the
    ///     fingerprint file, or a fingerprint that disagrees); only called when it matters.
    ///     A key is called lost only when it was tried and opened nothing.
    public static func decide(
        keyInStore: Bool,
        fingerprintMatches: Bool?,
        hasSealedData: Bool,
        keyOpensData: () -> Bool?
    ) -> Decision {
        guard keyInStore else { return hasSealedData ? .lost : .create }
        if fingerprintMatches == true || !hasSealedData { return .use }
        return keyOpensData() == false ? .lost : .use
    }
}

/// The master key: read once, made only when there is nothing it would orphan.
///
/// Before FLU-36 a missing Keychain item (a new Mac, a Keychain reset) silently made a new
/// key: the history looked empty, snippets could never be saved again, nothing said why.
/// Now sealed data without its key is « key lost »: every read and write fails with
/// `VaultKeyError.keyLost` until the user restores a backup or chooses to start again, and
/// starting again moves the old files aside rather than deleting them.
public final class VaultKeyring: @unchecked Sendable {
    public let layout: VaultLayout
    private let store: any MasterKeyStore
    private let lock = NSLock()
    private var cached: SymmetricKey?
    private var lost = false

    public init(store: any MasterKeyStore, layout: VaultLayout) {
        self.store = store
        self.layout = layout
    }

    /// The key, or `VaultKeyError.keyLost`. Store failures (Keychain locked or refused)
    /// are thrown as they are, and retried on the next call.
    public func masterKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        // Never nil when creating: no key and no data makes one.
        guard let key = try resolve(creating: true) else { throw VaultKeyError.keyLost }
        return key
    }

    /// Whether the last look found sealed data without its key. Cheap: does not ask the store.
    public var isKeyLost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }

    // MARK: - Leaving the lost state

    /// « Repartir de zéro »: moves every sealed file into `<root>/Données illisibles <date>/`
    /// (kept, not deleted: if the old key ever comes back they open again), then uses the
    /// stored key or makes one. Returns the folder, nil when there was nothing to move.
    @discardableResult
    public func startFresh(now: Date = Date()) throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if !lost {
            do { _ = try resolve(creating: false) } catch VaultKeyError.keyLost {}
        }
        // Only ever over data no key here can open: never moves readable data away.
        guard lost else { return nil }
        let aside = try moveSealedItemsAside(now: now)
        try acceptStoredOrNewKey()
        return aside
    }

    public struct RestoreKey {
        public let key: SymmetricKey
        /// The backup's key became this Mac's key.
        public let adoptedBackupKey: Bool
        /// Where unreadable data was moved, when it had to be.
        public let setAside: URL?
    }

    /// The key a restore re-seals under. With a working key, that key. With none and
    /// nothing sealed (a new Mac), the backup's. With the key lost, the backup's when it
    /// opens what is on disk (the same Mac after a Keychain reset: everything comes back,
    /// even what was written after the backup), otherwise a fresh start.
    public func keyForRestore(backupKey: SymmetricKey, now: Date = Date()) throws -> RestoreKey {
        lock.lock()
        defer { lock.unlock() }
        if !lost {
            do {
                if let key = try resolve(creating: false) {
                    return RestoreKey(key: key, adoptedBackupKey: false, setAside: nil)
                }
                // No key and nothing sealed.
                try install(backupKey)
                return RestoreKey(key: backupKey, adoptedBackupKey: true, setAside: nil)
            } catch VaultKeyError.keyLost {
                // Handled below.
            }
        }
        let fingerprint = try? String(contentsOf: layout.fingerprint, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let opens = fingerprint.map { $0 == VaultKeyFingerprint.of(backupKey) } ?? (layout.keyOpensData(backupKey) ?? true)
        if opens {
            try install(backupKey)
            return RestoreKey(key: backupKey, adoptedBackupKey: true, setAside: nil)
        }
        // The backup is from another key: the data here stays unreadable, so it goes aside
        // and the backup is re-sealed under this Mac's key.
        let aside = try moveSealedItemsAside(now: now)
        return RestoreKey(key: try acceptStoredOrNewKey(), adoptedBackupKey: false, setAside: aside)
    }

    // MARK: - Private (lock held)

    /// - Returns: nil only when `creating` is false and there is no key and no data.
    private func resolve(creating: Bool) throws -> SymmetricKey? {
        if let cached { return cached }
        if lost { throw VaultKeyError.keyLost }

        let stored = try store.readKey()
        if let stored, stored.count != 32 { throw VaultKeyError.malformedKey }
        let key = stored.map { SymmetricKey(data: $0) }
        let onDisk = try? String(contentsOf: layout.fingerprint, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decision = VaultKeyPolicy.decide(
            keyInStore: key != nil,
            fingerprintMatches: key.flatMap { key in onDisk.map { $0 == VaultKeyFingerprint.of(key) } },
            hasSealedData: layout.hasSealedData,
            keyOpensData: { key.flatMap(layout.keyOpensData) }
        )
        switch decision {
        case .use:
            guard let key else { throw VaultKeyError.keyLost }
            accept(key)
            return key
        case .create:
            guard creating else { return nil }
            let fresh = SymmetricKey(size: .bits256)
            try store.addKey(Self.bytes(of: fresh))
            accept(fresh)
            return fresh
        case .lost:
            lost = true
            throw VaultKeyError.keyLost
        }
    }

    /// After the sealed files went aside: the stored key if it is a key, else a new one.
    @discardableResult
    private func acceptStoredOrNewKey() throws -> SymmetricKey {
        let key: SymmetricKey
        switch try store.readKey() {
        case let data? where data.count == 32:
            key = SymmetricKey(data: data)
        case _?:
            key = SymmetricKey(size: .bits256)
            try store.replaceKey(Self.bytes(of: key))
        case nil:
            key = SymmetricKey(size: .bits256)
            try store.addKey(Self.bytes(of: key))
        }
        accept(key)
        return key
    }

    /// Writes `key` to the store, replacing what is there.
    private func install(_ key: SymmetricKey) throws {
        let bytes = Self.bytes(of: key)
        switch try store.readKey() {
        case bytes?: break
        case _?: try store.replaceKey(bytes)
        case nil: try store.addKey(bytes)
        }
        accept(key)
    }

    private func accept(_ key: SymmetricKey) {
        cached = key
        lost = false
        let fingerprint = VaultKeyFingerprint.of(key)
        let current = try? String(contentsOf: layout.fingerprint, encoding: .utf8)
        guard current?.trimmingCharacters(in: .whitespacesAndNewlines) != fingerprint else { return }
        try? Data((fingerprint + "\n").utf8).write(to: layout.fingerprint, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.fingerprint.path)
        SupportFolder.keepOutOfBackup(layout.fingerprint)
    }

    private func moveSealedItemsAside(now: Date) throws -> URL? {
        let manager = FileManager.default
        let present = layout.sealedItems.filter { manager.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { return nil }
        let aside = layout.root.appendingPathComponent("Données illisibles \(Self.stamp(now))", isDirectory: true)
        try manager.createDirectory(at: aside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        SupportFolder.keepOutOfBackup(aside)
        for item in present {
            try manager.moveItem(at: item, to: aside.appendingPathComponent(item.lastPathComponent))
        }
        return aside
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
