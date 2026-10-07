import Foundation

/// The pure half of the move from the app's earlier identities to Fluence (FLU-11).
///
/// Clement's own build (bundle `ai.pivotstudio.murmur-youtube`) kept its files in three
/// places: history and dictionary in `Application Support/MurmurYouTube/`, snippets in
/// `Application Support/ai.pivotstudio.murmur-youtube/snippets.json`, Whisper models in
/// `Application Support/Fluence/WhisperModels/`. So `Fluence/` already exists on his Mac,
/// and a "move the old folder if the new one isn't there" migration would skip everything.
///
/// The migration therefore goes **file by file**: a file the new folder doesn't have is
/// moved; one it has is merged. Plaintext is only ever removed by the app after the merged
/// result is safely written (sealed, for history and snippets). The decisions live here so
/// they are tested with synthetic files; the app does the disk work.
public enum LegacyMerge {
    // MARK: - Per-file decision

    public enum Step: Equatable, Sendable {
        /// Nothing to bring over.
        case nothing
        /// The new folder has no such file: move the old one in.
        case move
        /// Both exist: merge the old file's contents into the new one, then remove the old.
        case merge
    }

    public static func step(legacyExists: Bool, currentExists: Bool) -> Step {
        guard legacyExists else { return .nothing }
        return currentExists ? .merge : .move
    }

    // MARK: - Dictionary

    /// The current dictionary file with every entry of the legacy one it lacks appended.
    ///
    /// Lines are compared trimmed and case-insensitively, so the same term or correction is
    /// never listed twice; comments and blank lines of the legacy file are not copied (the
    /// current file has its own header). Disabled entries (`# off:`) are entries and are
    /// copied. Returns nil when nothing needs adding.
    public static func mergeDictionary(current: String, legacy: String) -> String? {
        func key(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: "\\s*->\\s*", with: " -> ", options: .regularExpression)
        }
        func isEntry(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            guard trimmed.hasPrefix("#") else { return true }
            return trimmed.dropFirst().trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("off:")
        }

        let currentLines = current.components(separatedBy: "\n")
        var known = Set(currentLines.filter(isEntry).map(key))
        var added: [String] = []
        for line in legacy.components(separatedBy: "\n") where isEntry(line) {
            let k = key(line)
            guard !known.contains(k) else { continue }
            known.insert(k)
            added.append(line.trimmingCharacters(in: .whitespaces))
        }
        guard !added.isEmpty else { return nil }

        var merged = current
        if !merged.isEmpty, !merged.hasSuffix("\n") { merged += "\n" }
        merged += added.joined(separator: "\n") + "\n"
        return merged
    }

    // MARK: - History

    public struct HistoryImport: Equatable, Sendable {
        /// Lines that decode as a run not already in the sealed history, in file order.
        public var fresh: [Data] = []
        /// Lines that don't decode. Sealed as they are rather than dropped: deleting the
        /// plaintext must never cost the user a line this version can't read.
        public var unreadable: [Data] = []
        /// Runs already sealed by an earlier, interrupted attempt.
        public var duplicates = 0
    }

    /// Sorts the lines of a plaintext `runs.jsonl` for sealing.
    ///
    /// - Parameters:
    ///   - identity: a run's identity (date and text) if the line decodes, nil otherwise.
    ///   - alreadySealed: identities of the runs already in the sealed history, so a merge
    ///     that ran halfway before can't duplicate them.
    public static func importHistory(
        _ legacy: Data,
        alreadySealed: Set<String>,
        identity: (Data) -> String?
    ) -> HistoryImport {
        var result = HistoryImport()
        var seen = alreadySealed
        for rawLine in legacy.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let line = Data(rawLine)
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
            guard let id = identity(line) else {
                result.unreadable.append(line)
                continue
            }
            if seen.contains(id) {
                result.duplicates += 1
                continue
            }
            seen.insert(id)
            result.fresh.append(line)
        }
        return result
    }

    // MARK: - Snippets

    /// Clement's snippets file: a JSON array of `{id, cue, expansion, isEnabled, createdAt}`.
    private struct LegacySnippet: Decodable {
        var id: UUID?
        var cue: String
        var expansion: String
        var isEnabled: Bool?
        var createdAt: Date?
    }

    /// Reads Clement's `snippets.json`. Throws when the file isn't that format, so the
    /// caller keeps it rather than deleting something it couldn't import.
    public static func snippets(fromLegacyJSON data: Data) throws -> [Snippet] {
        let decoder = JSONDecoder()
        // JSONEncoder's default, which is what his build wrote with.
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode([LegacySnippet].self, from: data).compactMap { legacy in
            let trigger = legacy.cue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !legacy.expansion.isEmpty else { return nil }
            return Snippet(
                id: legacy.id ?? UUID(),
                trigger: trigger,
                expansion: legacy.expansion,
                isEnabled: legacy.isEnabled ?? true,
                createdAt: legacy.createdAt
            )
        }
    }

    /// The current snippets followed by the imported ones whose trigger (and id) is new.
    public static func mergeSnippets(current: [Snippet], imported: [Snippet]) -> [Snippet] {
        var merged = current
        var triggers = Set(current.map { SnippetMatcher.words(in: $0.trigger).map(\.key) })
        var ids = Set(current.map(\.id))
        for snippet in imported {
            let key = SnippetMatcher.words(in: snippet.trigger).map(\.key)
            guard !triggers.contains(key), !ids.contains(snippet.id) else { continue }
            triggers.insert(key)
            ids.insert(snippet.id)
            merged.append(snippet)
        }
        return merged
    }

    // MARK: - Settings

    /// Clement's build stored the dictation language as "fr-FR", "en-US", "auto" or
    /// "system". "system" becomes Auto, which follows the Mac's language for Apple's engine.
    public static func dictationLanguage(fromLegacy raw: String?) -> DictationLanguage? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "auto", "system": return .auto
        default:
            if let direct = DictationLanguage(rawValue: raw) { return direct }
            let code = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
            return code.flatMap(DictationLanguage.init(rawValue:))
        }
    }
}
