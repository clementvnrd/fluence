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

    /// Case- and accent-insensitive search over both the trigger and the text.
    func filtered(by query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets }
        return snippets.filter {
            $0.trigger.localizedStandardContains(trimmed) || $0.expansion.localizedStandardContains(trimmed)
        }
    }

    // MARK: - Disk

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

    private func loaded(_ result: Result<[Snippet], Error>) {
        switch result {
        case .success(let stored):
            // Anything added while the file was being read is newer than all of it.
            snippets = stored + snippets
            canSave = true
            problem = nil
            Log.app.info("snippets: \(stored.count, privacy: .public) loaded")
            if !snippets.isEmpty, snippets.count != stored.count { save() }
        case .failure(let error):
            problem = "Snippets couldn't be opened: \(Self.describe(error)). Changes are kept until you quit, not saved."
            Log.app.error("snippets: load failed — \(Self.describe(error), privacy: .public)")
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
                SnippetStore.shared.problem = failure.map { "Snippets aren't being saved: \($0)" }
                if let failure { Log.app.error("snippets: save failed — \(failure, privacy: .public)") }
            }
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if let failure = error as? Vault.Failure { return failure.description }
        return error.localizedDescription
    }
}
