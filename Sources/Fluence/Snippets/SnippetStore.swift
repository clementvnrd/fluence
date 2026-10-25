import FluenceCore
import Foundation
import Observation

/// Voice snippets (FLU-5), sealed on disk like history: `snippets.sealed` under
/// `AppPaths.support`, one AES-GCM box holding the JSON list.
///
/// Encrypted because what people store as snippets is exactly what they don't want lying
/// around in plaintext: addresses, phone numbers, signatures, canned replies.
///
/// The rule from `HistoryFile` holds here too: if the Vault can't produce a key, nothing is
/// written — and a file that couldn't be read is never overwritten, because writing the
/// in-memory list over it would erase snippets the user still has.
@MainActor
@Observable
final class SnippetStore {
    static let shared = SnippetStore()

    private(set) var snippets: [Snippet] = []

    /// Why snippets aren't being read or saved, shown in the panel. Nil when all is well.
    private(set) var problem: String?

    /// The file was read (or found absent). Until then, and forever after a failed read,
    /// saving is off.
    private var canSave = false

    static var fileURL: URL { AppPaths.support.appendingPathComponent("snippets.sealed") }

    /// All disk work, in submission order, off the main thread: the Keychain round trip can
    /// take a moment and can prompt.
    @ObservationIgnored private let queue = DispatchQueue(label: "snippet-file", qos: .utility)

    private init() {
        load()
    }

    // MARK: - Editing

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        save()
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    // MARK: Clement's panel

    /// The panel's list, newest first, as in his build.
    var entries: [Snippet] { snippets.reversed() }

    func add(cue: String, expansion: String) {
        add(Snippet(trigger: cue, expansion: expansion, createdAt: Date()))
    }

    func toggle(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index].isEnabled.toggle()
        save()
    }

    /// The snippets dictation may expand: the enabled ones, or none when snippets are off.
    var active: [Snippet] {
        Settings.shared.snippetsEnabled ? snippets.filter(\.isEnabled) : []
    }

    /// Case- and accent-insensitive search over both the trigger and the text.
    func filtered(by query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return entries }
        return entries.filter {
            $0.trigger.localizedStandardContains(trimmed) || $0.expansion.localizedStandardContains(trimmed)
        }
    }

    // MARK: - Disk

    /// Reads the file again after a restore or a fresh start (FLU-36). Snippets added while
    /// the file could not be read are kept and saved with it; when everything was saved,
    /// the file is the truth.
    func reload() {
        if canSave { snippets = [] }
        canSave = false
        load()
    }

    private func load() {
        let url = Self.fileURL
        queue.async {
            let result: Result<[Snippet], Error>
            do {
                let sealed = try Data(contentsOf: url)
                result = .success(try JSONDecoder().decode([Snippet].self, from: try Vault.open(sealed)))
            } catch CocoaError.fileReadNoSuchFile {
                result = .success([])
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in SnippetStore.shared.loaded(result) }
        }
    }

    /// Clement's build kept snippets in plaintext, in
    /// `Application Support/ai.pivotstudio.murmur-youtube/snippets.json`. Once the sealed file
    /// has been read they are merged in, sealed, and only then is the plaintext removed — a
    /// failed seal leaves it in place for the next launch (FLU-11).
    private func importLegacySnippets() {
        guard !AppPaths.isIsolated else { return }
        let legacy = LegacyMigration.legacySnippetsFile
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let imported: [Snippet]
        do {
            imported = try LegacyMerge.snippets(fromLegacyJSON: Data(contentsOf: legacy))
        } catch {
            Log.app.error("snippets: the legacy file couldn't be read and was left in place")
            Diagnostics.error("snippets.legacy.read", error)
            return
        }
        let merged = LegacyMerge.mergeSnippets(current: snippets, imported: imported)
        let added = merged.count - snippets.count
        snippets = merged
        let url = Self.fileURL
        queue.async {
            do {
                try Vault.write(try JSONEncoder().encode(merged), to: url)
                try FileManager.default.removeItem(at: legacy)
                LegacyMigration.removeIfEmpty(LegacyMigration.legacySnippetsDirectory)
                Log.app.info("snippets: \(added, privacy: .public) imported from the plaintext file, which was removed")
            } catch {
                Log.app.error("snippets: legacy import not sealed — \(Self.describe(error), privacy: .public)")
                Diagnostics.error("snippets.legacy.seal", error)
            }
        }
    }

    private func loaded(_ result: Result<[Snippet], Error>) {
        switch result {
        case .success(let stored):
            // Anything added while the file was being read is newer than all of it.
            snippets = stored + snippets
            canSave = true
            problem = nil
            Log.app.info("snippets: \(stored.count, privacy: .public) loaded")
            if !snippets.isEmpty, snippets.count != stored.count { save() }
            importLegacySnippets()
        case .failure(let error):
            let cause = Vault.isKeyLost ? Vault.keyLostMessage : "Les snippets n'ont pas pu être ouverts : \(Self.describe(error))."
            problem = "\(cause) Les changements sont gardés jusqu'à ce que vous quittiez, sans être enregistrés."
            Log.app.error("snippets: load failed — \(Self.describe(error), privacy: .public)")
            Diagnostics.error("snippets.load", error)
        }
    }

    private func save() {
        guard canSave else { return }
        let snapshot = snippets
        let url = Self.fileURL
        queue.async {
            var failure: String?
            do {
                try Vault.write(try JSONEncoder().encode(snapshot), to: url)
            } catch {
                failure = Self.describe(error)
            }
            Task { @MainActor in
                SnippetStore.shared.problem = failure.map {
                    Vault.isKeyLost ? Vault.keyLostMessage : "Les snippets ne sont pas enregistrés : \($0)"
                }
                if let failure {
                    Log.app.error("snippets: save failed — \(failure, privacy: .public)")
                    Diagnostics.error("snippets.save")
                }
            }
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if let failure = error as? Vault.Failure { return failure.description }
        return error.localizedDescription
    }
}
