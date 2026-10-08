import MurmurDictionary
import Foundation
import Observation

/// The dictionary, persisted as a plain text file you can edit by hand.
///
/// A text file rather than JSON, because the spec asks for something editable outside the UI
/// and JSON is only nominally that — quoting, escaping and a trailing-comma trap for anyone
/// adding a line in a hurry. The format is one entry per line:
///
/// ```
/// Anthropic
/// Vercel
/// cloud code -> Claude Code
/// # off: whisper flow -> Wispr Flow
/// ```
///
/// A bare line is a term. `X -> Y` is a correction. `#` starts a comment, and a disabled
/// entry is written as a `# off:` comment so it survives a round trip through the file
/// without silently disappearing.
///
/// The file is watched, so editing it in a text editor updates the UI live and vice versa.
@MainActor
@Observable
final class DictionaryStore {
    static let shared = DictionaryStore()

    private(set) var entries: [DictionaryEntry] = []

    /// Bumped whenever entries change, so the engine can rebuild its bias list lazily
    /// instead of on every transcription.
    private(set) var revision = 0

    /// Watches the file itself: catches editors that write in place.
    private var fileWatcher: DispatchSourceFileSystemObject?
    /// Watches the directory: catches editors that save by writing a new file and renaming
    /// it over the old one (the old inode — and a watcher on it — simply goes away), and a
    /// dictionary created after launch.
    private var directoryWatcher: DispatchSourceFileSystemObject?

    /// The file's contents as last loaded or saved. An event after which the file reads back
    /// as exactly this is our own save, or nothing at all — so it changes nothing. Comparing
    /// contents replaces an `isSaving` flag, which was already reset by the time the
    /// watcher's event arrived, so every in-app save re-read the file it had just written.
    private var lastText: String?
    private var pendingReload: Task<Void, Never>?

    static var fileURL: URL {
        AppPaths.support.appendingPathComponent("dictionary.txt")
    }

    private init() {
        switch Self.read() {
        case .text(let text):
            lastText = text
            entries = Self.parse(text)
            revision += 1
        case .missing:
            // First run (a legacy dictionary has already been moved or merged in by then):
            // start with Clement's tech and franglais lexicon rather than an empty file.
            entries = TechLexicon.defaultEntries
            save()
        case .failed:
            break
        }
        watchDirectory()
        watchFile()
    }

    // MARK: - Editing

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func delete(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Case- and diacritic-insensitive search across both sides of an entry.
    func filtered(by query: String) -> [DictionaryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.write.localizedStandardContains(trimmed) || $0.hear.localizedStandardContains(trimmed)
        }
    }

    /// A corrector over the current entries. Rebuilt on demand — compiling a few dozen small
    /// regexes is cheap next to transcription, and caching it invites staleness.
    var corrector: DictionaryCorrector { DictionaryCorrector(entries: entries) }

    var biasPhrases: [String] { DictionaryCorrector.biasPhrases(from: entries) }

    /// The user's own spellings for Whisper's prompt, newest first (FLU-20). The built-in
    /// tech lexicon is left out: it is generic, the corrections still fix its spellings after
    /// transcription, and a prompt full of it is what made Whisper loop.
    var promptTerms: [String] {
        let lexicon = Set(TechLexicon.defaultEntries.map { $0.write.lowercased() })
        return entries.reversed()
            .filter { $0.isEnabled && !lexicon.contains($0.write.lowercased()) }
            .map(\.write)
    }

    /// How many of the tech lexicon's entries the dictionary lacks.
    var missingTechLexiconCount: Int {
        DictionaryEntry.missing(TechLexicon.defaultEntries, from: entries).count
    }

    /// Clement's "Lexique Tech" button: adds the lexicon's entries the dictionary lacks and
    /// returns how many, so the button can say so (FLU-17).
    @discardableResult
    func importTechLexicon() -> Int {
        let newEntries = DictionaryEntry.missing(TechLexicon.defaultEntries, from: entries)
        if !newEntries.isEmpty {
            entries.append(contentsOf: newEntries)
            save()
        }
        return newEntries.count
    }

    // MARK: - Persistence

    private enum ReadResult {
        case text(String)
        case missing
        case failed(Error)
    }

    private static func read() -> ReadResult {
        do {
            return .text(try String(contentsOf: fileURL, encoding: .utf8))
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return .missing
        } catch {
            return .failed(error)
        }
    }

    /// Re-reads the file after an external change.
    ///
    /// A failed read never empties the dictionary. Between an editor's delete and its rename
    /// the file briefly doesn't exist, and an unreadable file is not an empty one; replacing
    /// the entries with `[]` there would let the next in-app edit write `[]` over the user's
    /// file. The entries in memory stand until a read actually succeeds.
    ///
    /// - Returns: false if the file couldn't be read, so the caller can try again.
    private func reload() -> Bool {
        switch Self.read() {
        case .text(let text):
            guard text != lastText else { return true }
            lastText = text
            entries = Self.parse(text)
            revision += 1
            return true
        case .missing:
            return false
        case .failed(let error):
            Log.app.error("dictionary unreadable, keeping the current entries: \(error.localizedDescription)")
            return false
        }
    }

    static func parse(_ text: String) -> [DictionaryEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }

            // `# off:` is a disabled entry; any other comment is just a comment.
            var isEnabled = true
            if line.hasPrefix("#") {
                let stripped = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard stripped.lowercased().hasPrefix("off:") else { return nil }
                line = stripped.dropFirst(4).trimmingCharacters(in: .whitespaces)
                isEnabled = false
                guard !line.isEmpty else { return nil }
            }

            if let arrow = line.range(of: "->") {
                let hear = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let write = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !hear.isEmpty, !write.isEmpty else { return nil }
                return DictionaryEntry(kind: .correction, write: write, hear: hear, isEnabled: isEnabled)
            }

            return DictionaryEntry(kind: .term, write: line, isEnabled: isEnabled)
        }
    }

    private func save() {
        revision += 1

        let body = entries.map(\.fileLine).joined(separator: "\n")
        let text = Self.header + body + "\n"
        do {
            try text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
            lastText = text
        } catch {
            Log.app.error("dictionary not saved: \(error.localizedDescription)")
        }
        // The atomic write replaced the file, so the old watcher is on a dead inode.
        watchFile()
    }

    private static let header = """
        # Fluence dictionary
        #
        #   Anthropic                 a term — the engine is told this word exists
        #   cloud code -> Claude Code a correction — when you hear X, write Y
        #   # off: some rule -> Rule  a disabled entry
        #
        # Edit this file directly if you like; the app picks up changes immediately.

        """

    // MARK: - External edits

    /// Any change to the file or its directory schedules a reload, a beat later so the
    /// editor has finished; a file that's missing at that moment (mid-rename) is retried a
    /// few times. Then the file watcher is re-armed on whatever inode is at the path now.
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            for attempt in 0..<5 {
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 50 : 100))
                guard !Task.isCancelled, let self else { return }
                if self.reload() { break }
            }
            guard !Task.isCancelled else { return }
            self?.watchFile()
        }
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        // Not there (yet): the directory watcher will see it arrive.
        fileWatcher = watch(Self.fileURL, events: [.write, .extend, .delete, .rename, .attrib])
    }

    private func watchDirectory() {
        directoryWatcher?.cancel()
        directoryWatcher = watch(AppPaths.support, events: [.write])
    }

    private func watch(
        _ url: URL,
        events: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: events,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
