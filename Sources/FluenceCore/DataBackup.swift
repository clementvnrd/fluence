import CommonCrypto
import CryptoKit
import Foundation

/// « Sauvegarder mes données » (FLU-36): history, snippets, dictionary and meetings in one
/// file protected by a passphrase, to bring back on a new Mac or after a Keychain reset.
///
/// The file carries the sealed files as they are on disk *and* the master key that seals
/// them, the whole thing sealed under a key derived from the passphrase. Carrying the key is
/// what lets a restore on the same Mac after a Keychain reset reopen everything, including
/// what was written after the backup; anyone with the passphrase could read the data anyway.
///
/// Format, version 1:
/// ```
/// "FLUENCE-BACKUP" | version u8 = 1 | PBKDF2 rounds u32 LE | salt (16 bytes)
/// AES-256-GCM combined box (nonce | ciphertext | tag) of the JSON `Contents`,
///     the header above as authenticated data
/// ```
/// The key is PBKDF2-HMAC-SHA256 of the passphrase (Unicode NFC, UTF-8).
///
/// Not carried: meeting audio (large, and deleted after transcription unless kept), voice
/// prints (biometric, never exported), settings.
public enum DataBackup {
    public static let fileExtension = "fluencebackup"
    public static let minimumPassphraseLength = 8
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256; about half a second on Apple silicon.
    public static let defaultRounds: UInt32 = 600_000
    static let acceptedRounds: ClosedRange<UInt32> = 1_000...20_000_000
    static let magic = Data("FLUENCE-BACKUP".utf8)
    static let version: UInt8 = 1
    static let saltLength = 16
    static var headerLength: Int { magic.count + 1 + 4 + saltLength }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
        case notABackup
        case newerVersion
        case wrongPassphrase
        case passphraseTooShort
        case noKey

        public var description: String {
            switch self {
            case .notABackup: "Ce fichier n'est pas une sauvegarde Fluence."
            case .newerVersion: "Cette sauvegarde vient d'une version plus récente de Fluence."
            case .wrongPassphrase: "Phrase secrète incorrecte, ou fichier abîmé."
            case .passphraseTooShort: "La phrase secrète doit faire au moins \(minimumPassphraseLength) caractères."
            case .noKey: "La sauvegarde ne contient pas de clé valable."
            }
        }

        public var errorDescription: String? { description }
    }

    public struct File: Codable, Equatable, Sendable {
        /// Relative to the support folder, `/`-separated.
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public struct Contents: Codable, Sendable {
        public var format = 1
        public var createdAt: Date
        /// The master key the files are sealed with (32 bytes).
        public var masterKey: Data
        public var files: [File]

        public init(createdAt: Date, masterKey: Data, files: [File]) {
            self.createdAt = createdAt
            self.masterKey = masterKey
            self.files = files
        }

        public func file(_ path: String) -> Data? {
            files.first { $0.path == path }?.data
        }
    }

    // MARK: - What a backup carries

    public static let historyPath = "history.sealed"
    public static let snippetsPath = "snippets.sealed"
    public static let dictionaryPath = "dictionary.txt"

    /// The files a backup carries, read from the support folder.
    public static func collect(from layout: VaultLayout) throws -> [File] {
        let manager = FileManager.default
        var files: [File] = []
        for path in [historyPath, snippetsPath, dictionaryPath] {
            let url = layout.root.appendingPathComponent(path)
            guard manager.fileExists(atPath: url.path) else { continue }
            files.append(File(path: path, data: try Data(contentsOf: url)))
        }
        let names = (try? manager.contentsOfDirectory(atPath: layout.meetings.path)) ?? []
        for name in names.sorted() where UUID(uuidString: name) != nil {
            let directory = layout.meetings.appendingPathComponent(name, isDirectory: true)
            let key = directory.appendingPathComponent("key.wrapped")
            let meeting = directory.appendingPathComponent("meeting.enc")
            guard manager.fileExists(atPath: key.path), manager.fileExists(atPath: meeting.path) else { continue }
            files.append(File(path: "Meetings/\(name)/key.wrapped", data: try Data(contentsOf: key)))
            files.append(File(path: "Meetings/\(name)/meeting.enc", data: try Data(contentsOf: meeting)))
        }
        return files
    }

    /// Only these paths are ever written by a restore.
    static func isAllowed(_ path: String) -> Bool {
        if [historyPath, snippetsPath, dictionaryPath].contains(path) { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "Meetings" && UUID(uuidString: String(parts[1])) != nil
            && (parts[2] == "key.wrapped" || parts[2] == "meeting.enc")
    }

    // MARK: - Sealing

    public static func seal(_ contents: Contents, passphrase: String, rounds: UInt32 = defaultRounds) throws -> Data {
        guard passphrase.count >= minimumPassphraseLength else { throw Failure.passphraseTooShort }
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.noKey }

        var header = magic
        header.append(version)
        withUnsafeBytes(of: rounds.littleEndian) { header.append(contentsOf: $0) }
        header.append(salt)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let key = try deriveKey(passphrase, salt: salt, rounds: rounds)
        let box = try AES.GCM.seal(try encoder.encode(contents), using: key, authenticating: header)
        guard let combined = box.combined else { throw Failure.noKey }
        return header + combined
    }

    public static func open(_ archive: Data, passphrase: String) throws -> Contents {
        let archive = Data(archive)  // zero-based indices
        guard archive.count > headerLength, archive.prefix(magic.count) == magic else { throw Failure.notABackup }
        guard archive[magic.count] == version else { throw Failure.newerVersion }
        let rounds = archive.subdata(in: (magic.count + 1)..<(magic.count + 5))
            .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard acceptedRounds.contains(rounds) else { throw Failure.notABackup }
        let salt = archive.subdata(in: (magic.count + 5)..<headerLength)
        let header = archive.prefix(headerLength)

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: archive.suffix(from: headerLength))
            plaintext = try AES.GCM.open(box, using: try deriveKey(passphrase, salt: salt, rounds: rounds), authenticating: header)
        } catch {
            throw Failure.wrongPassphrase
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var contents = try decoder.decode(Contents.self, from: plaintext)
        guard contents.format == 1 else { throw Failure.newerVersion }
        guard contents.masterKey.count == 32 else { throw Failure.noKey }
        contents.files = contents.files.filter { isAllowed($0.path) }
        return contents
    }

    static func deriveKey(_ passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let password = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.noKey }
        return SymmetricKey(data: derived)
    }
}

/// Puts a backup's contents back, merged with what this Mac already has: nothing here is
/// overwritten or deleted, and restoring the same file twice adds nothing the second time.
public enum DataRestore {
    public struct Summary: Equatable, Sendable {
        public var dictations = 0
        public var snippets = 0
        public var dictionaryLines = 0
        public var meetings = 0
        /// The backup's key became this Mac's key (a new Mac, or the same Mac after a
        /// Keychain reset): what was sealed under it opens again.
        public var adoptedKey = false
        /// Where data no key could open was moved before restoring.
        public var setAside: URL?
        /// Parts left as they were, and why (French, for the UI).
        public var skipped: [String] = []

        public init() {}
    }

    public static func restore(
        _ contents: DataBackup.Contents,
        keyring: VaultKeyring,
        now: Date = Date()
    ) throws -> Summary {
        guard contents.masterKey.count == 32 else { throw DataBackup.Failure.noKey }
        let backupKey = SymmetricKey(data: contents.masterKey)
        let target = try keyring.keyForRestore(backupKey: backupKey, now: now)
        let layout = keyring.layout
        let key = target.key

        var summary = Summary()
        summary.adoptedKey = target.adoptedBackupKey
        summary.setAside = target.setAside

        if let history = contents.file(DataBackup.historyPath) {
            summary.dictations = try mergeHistory(history, backupKey: backupKey, into: layout.history, key: key)
        }
        if let snippets = contents.file(DataBackup.snippetsPath) {
            do {
                summary.snippets = try mergeSnippets(snippets, backupKey: backupKey, into: layout.snippets, key: key)
            } catch SnippetMerge.currentUnreadable {
                summary.skipped.append("Snippets : ceux de ce Mac sont illisibles, ils n'ont pas été remplacés.")
            }
        }
        if let dictionary = contents.file(DataBackup.dictionaryPath) {
            summary.dictionaryLines = try mergeDictionary(dictionary, into: layout.root.appendingPathComponent(DataBackup.dictionaryPath))
        }
        summary.meetings = try restoreMeetings(contents.files, backupKey: backupKey, into: layout.meetings, key: key)
        return summary
    }

    // MARK: - History

    /// A run's identity across Macs and keys: its date and text, as the legacy merge uses.
    static func identity(of record: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              let date = object["date"] as? String, let text = object["text"] as? String
        else { return "raw:" + record.base64EncodedString() }
        return date + "|" + text
    }

    static func date(of record: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: record)) as? [String: Any])?["date"] as? String ?? ""
    }

    /// Adds the backup's runs this file lacks, in date order, re-sealed under `key`.
    static func mergeHistory(_ backup: Data, backupKey: SymmetricKey, into url: URL, key: SymmetricKey) throws -> Int {
        let incoming = SealedLines.decode(backup) { try VaultCipher.open($0, with: backupKey) }
        let current: SealedLines.Decoded
        do {
            current = SealedLines.decode(try Data(contentsOf: url)) { try VaultCipher.open($0, with: key) }
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            current = SealedLines.Decoded()
        }

        var known = Set(current.records.map { identity(of: $0) })
        var fresh: [Data] = []
        for record in incoming.records where known.insert(identity(of: record)).inserted {
            fresh.append(record)
        }
        let unreadableHere = Set(current.unreadable)
        let extraUnreadable = incoming.unreadable.filter { !unreadableHere.contains($0) }
        guard !fresh.isEmpty || !extraUnreadable.isEmpty else { return 0 }

        // Stable by date: the history lists in file order.
        let records = (current.records + fresh).enumerated()
            .sorted { (date(of: $0.element), $0.offset) < (date(of: $1.element), $1.offset) }
            .map(\.element)
        let file = try SealedLines.file(records: records, preserving: current.unreadable + extraUnreadable) {
            try VaultCipher.seal($0, with: key)
        }
        try write(file, to: url)
        return fresh.count
    }

    // MARK: - Snippets

    enum SnippetMerge: Error { case currentUnreadable }

    static func mergeSnippets(_ backup: Data, backupKey: SymmetricKey, into url: URL, key: SymmetricKey) throws -> Int {
        let imported = try JSONDecoder().decode([Snippet].self, from: VaultCipher.open(backup, with: backupKey))
        let current: [Snippet]
        do {
            current = try SealedJSONFile.read([Snippet].self, at: url) { try VaultCipher.open($0, with: key) } ?? []
        } catch {
            // Never written over: they may still open with a key that comes back.
            throw SnippetMerge.currentUnreadable
        }
        let merged = LegacyMerge.mergeSnippets(current: current, imported: imported)
        let added = merged.count - current.count
        guard added > 0 else { return 0 }
        try write(try VaultCipher.seal(try JSONEncoder().encode(merged), with: key), to: url)
        return added
    }

    // MARK: - Dictionary

    /// Plain text: the backup's entries this file lacks are appended. Returns how many.
    static func mergeDictionary(_ backup: Data, into url: URL) throws -> Int {
        let incoming = String(decoding: backup, as: UTF8.self)
        guard let current = try? String(contentsOf: url, encoding: .utf8) else {
            try backup.write(to: url, options: [.atomic])
            return entryCount(incoming)
        }
        guard let merged = LegacyMerge.mergeDictionary(current: current, legacy: incoming) else { return 0 }
        try merged.write(to: url, atomically: true, encoding: .utf8)
        return entryCount(merged) - entryCount(current)
    }

    private static func entryCount(_ text: String) -> Int {
        text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && (!trimmed.hasPrefix("#") || trimmed.dropFirst().trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("off:"))
        }.count
    }

    // MARK: - Meetings

    /// Each meeting this Mac lacks gets its folder back: the meeting's own key re-wrapped
    /// under `key`, the meeting file as it was (sealed with that meeting key). The index is
    /// left to the app, which rebuilds it from the folders.
    static func restoreMeetings(_ files: [DataBackup.File], backupKey: SymmetricKey, into meetings: URL, key: SymmetricKey) throws -> Int {
        var byMeeting: [String: [String: Data]] = [:]
        for file in files where file.path.hasPrefix("Meetings/") {
            let parts = file.path.split(separator: "/")
            byMeeting[String(parts[1]), default: [:]][String(parts[2])] = file.data
        }
        let manager = FileManager.default
        var restored = 0
        for (id, parts) in byMeeting.sorted(by: { $0.key < $1.key }) {
            guard let wrapped = parts["key.wrapped"], let meeting = parts["meeting.enc"] else { continue }
            let directory = meetings.appendingPathComponent(id, isDirectory: true)
            guard !manager.fileExists(atPath: directory.appendingPathComponent("meeting.enc").path) else { continue }
            guard let meetingKey = try? VaultCipher.open(wrapped, with: backupKey) else { continue }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            SupportFolder.keepOutOfBackup(meetings)
            try write(try VaultCipher.seal(meetingKey, with: key), to: directory.appendingPathComponent("key.wrapped"))
            try write(meeting, to: directory.appendingPathComponent("meeting.enc"))
            restored += 1
        }
        return restored
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        SupportFolder.keepOutOfBackup(url)
    }
}
