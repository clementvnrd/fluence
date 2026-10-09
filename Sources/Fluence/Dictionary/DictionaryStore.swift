import FluenceDictionary
import Foundation
import Observation

/// The dictionary, stored as `dictionary.txt` in the support folder.
///
/// Plain text rather than JSON because people edit it by hand, and a line of text needs no
/// quoting or escaping. One entry per line:
///
///     Ollivault                          a term
///     nova tec -> Novatek                a correction: heard -> written
///     # off: brume ware -> Brumeware     a disabled entry
///
/// Any other `#` line is a comment. A disabled entry is written as a `# off:` comment so it
/// comes back intact after a save and a read. The file is watched both ways: an outside edit
/// appears in the app, and an edit in the app rewrites the file.
@MainActor
@Observable
final class DictionaryStore {
    static let shared = DictionaryStore()

    private(set) var entries: [DictionaryEntry] = []

    /// Lets a consumer rebuild what it derives from the entries (a bias list, say) only after
    /// they changed. Bumped on each load from the file and on each save.
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
            entries = DictionaryFileFormat.parse(text)
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

    /// The panel's search: both sides of each entry, blind to case and accents, in file order.
    func filtered(by query: String) -> [DictionaryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.write.localizedStandardContains(needle) || $0.hear.localizedStandardContains(needle)
        }
    }

    /// Built fresh on each access: a few dozen small patterns cost little beside a
    /// transcription, and nothing cached can go stale.
    var corrector: DictionaryCorrector { DictionaryCorrector(entries: entries) }

    /// For Apple and Parakeet: the user's own entries first, newest first, then the tech
    /// lexicon (FLU-27).
    var biasPhrases: [String] { DictionaryCorrector.biasPhrases(from: entries, seeded: Self.lexiconSpellings) }

    /// The user's own spellings for Whisper's prompt, newest first (FLU-20). The built-in
    /// tech lexicon is left out: it is generic, the corrections still fix its spellings after
    /// transcription, and a prompt full of it is what made Whisper loop.
    var promptTerms: [String] {
        entries.reversed()
            .filter { $0.isEnabled && !Self.lexiconSpellings.contains($0.write.lowercased()) }
            .map(\.write)
    }

    private static let lexiconSpellings = Set(TechLexicon.defaultEntries.map { $0.write.lowercased() })

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

    // MARK: - File

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
            entries = DictionaryFileFormat.parse(text)
            revision += 1
            return true
        case .missing:
            return false
        case .failed(let error):
            Log.app.error("dictionary unreadable, keeping the current entries: \(error.localizedDescription)")
            return false
        }
    }

    private func save() {
        revision += 1

        keepUnreadableCopy()
        let text = DictionaryFileFormat.render(entries, header: Self.header)
        do {
            try text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
            lastText = text
        } catch {
            Log.app.error("dictionary not saved: \(error.localizedDescription)")
        }
        // The atomic write replaced the file, so the old watcher is on a dead inode.
        watchFile()
    }

    /// The file on disk is about to be replaced. If it holds lines the parser could not read
    /// (a format it does not know yet), they would vanish with that save: copy the file to
    /// `dictionary.txt.bak` first, so nothing the user typed is ever lost (FLU-53).
    private func keepUnreadableCopy() {
        guard case .text(let current) = Self.read(), DictionaryFileFormat.hasUnreadLines(current) else { return }
        let backup = Self.fileURL.appendingPathExtension("bak")
        do {
            try current.write(to: backup, atomically: true, encoding: .utf8)
            Log.app.error("dictionary had unreadable lines; copied to dictionary.txt.bak before saving")
        } catch {
            Log.app.error("dictionary backup failed: \(error.localizedDescription)")
        }
    }

    private static let header = """
        # Fluence dictionary
        #
        # Ollivault                          un terme : un mot que la dictée doit connaître
        # nova tec -> Novatek                une correction : entendu, puis écrit
        # # off: brume ware -> Brumeware     une entrée désactivée, gardée pour plus tard
        #
        # Vous pouvez modifier ce fichier : Fluence recharge vos changements aussitôt.

        """

    // MARK: - Outside edits

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
        // Re-arming cancels the old source; that is when its descriptor may be released.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
