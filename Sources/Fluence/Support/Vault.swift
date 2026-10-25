import CryptoKit
import Foundation
import Security

/// Encryption at rest for everything personal Fluence writes to disk.
///
/// One 256-bit master key lives in the login Keychain, readable only while the Mac is
/// unlocked and never synced to iCloud. Data is sealed with AES-256-GCM, which also
/// authenticates it: a tampered or truncated file fails to open instead of decoding into
/// garbage.
///
/// Meetings get their own data key, stored *wrapped* by the master key beside the meeting.
/// Deleting a meeting deletes its wrapped key, which makes any copy of its files left on an
/// SSD (where overwriting is not reliable) permanently unreadable.
///
/// A caveat for development: the legacy Keychain trusts the code signature that created
/// the item. An ad-hoc signature changes on every build, so macOS asks once per rebuild
/// whether Fluence may read its own key ("Always Allow"). A stable Developer ID signature —
/// which the Makefile already prefers — does not.
enum Vault {
    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        case corrupt

        var description: String {
            switch self {
            case .keychain(let status):
                "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            case .corrupt:
                "Encrypted data failed authentication"
            }
        }
    }

    private static let service = (Bundle.main.bundleIdentifier ?? "fluence") + ".vault"
    private static let account = "master-key"

    /// Cached after the first read: the Keychain round trip is slow, and it can prompt.
    nonisolated(unsafe) private static var cachedKey: SymmetricKey?
    private static let lock = NSLock()

    // MARK: - Sealing

    static func seal(_ plaintext: Data, with key: SymmetricKey? = nil) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key ?? masterKey())
        guard let combined = box.combined else { throw Failure.corrupt }
        return combined
    }

    static func open(_ sealed: Data, with key: SymmetricKey? = nil) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key ?? masterKey())
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.corrupt
        }
    }

    // MARK: - Per-item keys

    static func newDataKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func wrap(_ key: SymmetricKey) throws -> Data {
        try seal(key.withUnsafeBytes { Data($0) })
    }

    static func unwrap(_ wrapped: Data) throws -> SymmetricKey {
        SymmetricKey(data: try open(wrapped))
    }

    // MARK: - Files

    /// Seals and writes atomically, owner-only.
    static func write(_ plaintext: Data, to url: URL, with key: SymmetricKey? = nil) throws {
        try seal(plaintext, with: key).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        AppPaths.keepOutOfBackup(url)
    }

    static func read(_ url: URL, with key: SymmetricKey? = nil) throws -> Data {
        try open(Data(contentsOf: url), with: key)
    }

    // MARK: - Master key

    static func masterKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }

        let key = try readMasterKey() ?? createMasterKey()
        cachedKey = key
        return key
    }

    private static func readMasterKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw Failure.corrupt }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keychain(status)
        }
    }

    private static func createMasterKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Fluence encryption key",
            // Only while unlocked, and never migrated to another Mac or synced to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return key
    }
}
