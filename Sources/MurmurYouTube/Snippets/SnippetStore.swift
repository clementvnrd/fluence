import Foundation
import Observation

/// A voice snippet — a short spoken cue that expands into a full block of pre-written text.
public struct SnippetEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var cue: String
    public var expansion: String
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        cue: String,
        expansion: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.cue = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expansion = expansion
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

@MainActor
@Observable
public final class SnippetStore {
    public static let shared = SnippetStore()

    public private(set) var entries: [SnippetEntry] = []

    public let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ai.pivotstudio.murmur-youtube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("snippets.json")

        load()
    }

    // MARK: - Matching

    /// Checks whether the spoken transcript contains or matches any enabled snippet cue.
    /// Returns the expanded text if a match is found. Longest cues take priority.
    public func expandSnippet(in transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Strip trailing punctuation for clean cue matching
        let cleanText = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        let normalized = cleanText.lowercased().precomposedStringWithCanonicalMapping

        let active = entries.filter(\.isEnabled).sorted { $0.cue.count > $1.cue.count }

        for entry in active {
            let cue = entry.cue.lowercased().precomposedStringWithCanonicalMapping
            guard !cue.isEmpty else { continue }

            // 1. Exact match (e.g. user just said the cue)
            if normalized == cue {
                return entry.expansion
            }

            // 2. Common verbal prefixes: "insert [cue]", "add [cue]", "paste [cue]"
            for prefix in ["insert ", "paste ", "add ", "type ", "insère ", "colle "] {
                if normalized == prefix + cue {
                    return entry.expansion
                }
            }

            // 3. Localized inline replacement if cue appears as a standalone phrase within speech
            let inlinePattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: cue))\\b"
            if let regex = try? NSRegularExpression(pattern: inlinePattern) {
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                let matches = regex.matches(in: trimmed, range: range)
                if !matches.isEmpty {
                    return regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: entry.expansion)
                }
            }
        }

        return nil
    }

    // MARK: - Mutations

    public func add(cue: String, expansion: String) {
        let entry = SnippetEntry(cue: cue, expansion: expansion)
        entries.insert(entry, at: 0)
        save()
    }

    public func update(_ entry: SnippetEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    public func delete(_ entry: SnippetEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    public func toggle(_ entry: SnippetEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isEnabled.toggle()
        save()
    }

    public func filtered(by query: String) -> [SnippetEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.cue.lowercased().contains(trimmed) || $0.expansion.lowercased().contains(trimmed)
        }
    }

    // MARK: - Persistence

    private func load() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([SnippetEntry].self, from: data)
                self.entries = decoded
                return
            } catch {
                // If decoding fails, back up corrupted file to avoid accidental data loss
                let backupURL = fileURL.deletingPathExtension().appendingPathExtension("corrupted.json")
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
                return
            }
        }

        // Seed with practical default snippets only if file does not exist
        self.entries = [
            SnippetEntry(
                cue: "my calendly",
                expansion: "Here is my scheduling link: https://calendly.com/meeting"
            ),
            SnippetEntry(
                cue: "bug report template",
                expansion: """
                **Steps to reproduce:**
                1. 
                2. 

                **Expected result:**

                **Actual result:**
                """
            ),
            SnippetEntry(
                cue: "sign off",
                expansion: "Best regards,\nSent with Murmur"
            )
        ]
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Log failure
        }
    }
}
