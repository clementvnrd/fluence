import CryptoKit
import FluenceCore
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
/// If the key goes missing (a new Mac, a Keychain reset) while sealed data is on disk, the
/// Vault stops with `VaultKeyError.keyLost` instead of making a new key over it (FLU-36):
/// the data waits for a restore of the encrypted backup, or for the user to set it aside.
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

    /// The master key and its safeguards (FLU-36, `FluenceCore.VaultKeyring`): read once and
    /// cached; made only when nothing sealed is on disk. Sealed data without its key is
    /// `VaultKeyError.keyLost` — never a silent new key over it.
    ///
    /// FLU-35: the self-test's scratch account lives and dies with a key held in memory; it
    /// never reads, creates or prompts for the Keychain item.
    static let keyring = VaultKeyring(
        store: SelfTest.isRequested
            ? InMemoryMasterKeyStore()
            : KeychainMasterKeyStore(service: service, account: "master-key"),
        layout: VaultLayout(root: AppPaths.support)
    )

    /// True once a read found sealed data and no key that opens it.
    static var isKeyLost: Bool { keyring.isKeyLost }

    /// What the user sees when the key is lost, wherever the data would have shown.
    static let keyLostMessage = "Vos données chiffrées ne peuvent plus être lues sur ce Mac. Réglages › Confidentialité pour restaurer une sauvegarde."

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
        } catch let failure as VaultKeyError {
            // Not a damaged box: no key to open it with.
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
        try keyring.masterKey()
    }
}

/// The master key in the login Keychain, as every version has stored it: same service,
/// account and attributes, so existing installs keep their key. (Moving it to the
/// data-protection keychain is an open question, FLU-36: it depends on the signature.)
struct KeychainMasterKeyStore: MasterKeyStore {
    let service: String
    let account: String

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func readKey() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Vault.Failure.corrupt }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Vault.Failure.keychain(status)
        }
    }

    func addKey(_ key: Data) throws {
        var attributes = query
        attributes[kSecAttrLabel as String] = "Fluence encryption key"
        // Only while unlocked, and never migrated to another Mac or synced to iCloud.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecValueData as String] = key
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Vault.Failure.keychain(status) }
    }

    /// Only when the stored key opens nothing on disk and a backup's key does (a restore).
    func replaceKey(_ key: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        guard status == errSecSuccess else { throw Vault.Failure.keychain(status) }
    }
}

/// The self-test's key store (FLU-35): starts empty, so the keyring makes a key on the first
/// seal of the empty scratch folder, and forgets it when the process exits.
final class InMemoryMasterKeyStore: MasterKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func readKey() throws -> Data? {
        lock.withLock { key }
    }

    func addKey(_ key: Data) throws {
        lock.withLock { self.key = key }
    }

    func replaceKey(_ key: Data) throws {
        lock.withLock { self.key = key }
    }
}
