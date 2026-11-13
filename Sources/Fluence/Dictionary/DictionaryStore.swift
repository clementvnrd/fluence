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

    /// The entries in file order.
    private(set) var entries: [DictionaryEntry] = []

    /// Why the file is not being saved, shown in the panel. Nil when all is well.
    private(set) var problem: String?

    /// The `mergeKey`s of the lexicon entries the user deleted or rewrote: « Lexique Tech »
    /// does not put them back (FLU-138). Built-in words only, nothing the user typed.
    private var declinedLexicon = Set(AppPaths.defaults.stringArray(forKey: DictionaryStore.declinedKey) ?? [])
    private static let declinedKey = "declinedLexiconEntries"

    /// Watches the file itself: catches editors that write in place.
    private var fileWatcher: DispatchSourceFileSystemObject?
    /// Watches the directory: catches editors that save by writing a new file and renaming
    /// it over the old one (the old inode — and a watcher on it — simply goes away), and a
    /// dictionary created after launch.
    private var directoryWatcher: DispatchSourceFileSystemObject?

    /// The file's contents as last loaded or saved; nil until the file was read once. An event
    /// after which the file reads back as exactly this is our own save, or nothing at all — so
    /// it changes nothing. Comparing contents replaces an `isSaving` flag, which was already
    /// reset by the time the watcher's event arrived, so every in-app save re-read the file it
    /// had just written.
    private var lastText: String?
    private var pendingReload: Task<Void, Never>?

    static var fileURL: URL {
        AppPaths.support.appendingPathComponent("dictionary.txt")
    }

    private init() {
        switch Self.read() {
        case .text(let text, _):
            adopt(text)
        case .missing:
            // First run (a legacy dictionary has already been moved or merged in by then):
            // start with Clement's tech and franglais lexicon rather than an empty file.
            entries = TechLexicon.defaultEntries
            save()
        case .failed(let error):
            noteUnreadable(error)
        }
        watchDirectory()
        watchFile()
    }

    // MARK: - Editing

    func add(_ entry: DictionaryEntry) {
        add(contentsOf: [entry])
    }

    /// Adds in one save. An entry its own line would not read back as (« #general », « C->D »)
    /// is left out: the next read would lose it or turn it into a correction (FLU-138).
    func add(contentsOf new: [DictionaryEntry]) {
        let storable = new.filter(DictionaryFileFormat.canStore)
        guard !storable.isEmpty else { return }
        entries.append(contentsOf: storable)
        save()
    }

    /// Replaces the entry with the same id where it stands. An id that is gone (its line was
    /// changed outside the app while the sheet was open) adds the edit instead of losing it.
    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return add(entry) }
        guard DictionaryFileFormat.canStore(entry) else { return }
        if entries[index].mergeKey != entry.mergeKey { decline([entries[index]]) }
        entries[index] = entry
        save()
    }

    func delete(_ entry: DictionaryEntry) {
        delete(ids: [entry.id])
    }

    func delete(ids: Set<UUID>) {
        decline(entries.filter { ids.contains($0.id) })
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Remembers the lexicon entries among `removed`, so « Lexique Tech » leaves them out.
    private func decline(_ removed: [DictionaryEntry]) {
        let keys = TechLexicon.declinedKeys(removed)
        guard !keys.isSubset(of: declinedLexicon) else { return }
        declinedLexicon.formUnion(keys)
        AppPaths.defaults.set(declinedLexicon.sorted(), forKey: Self.declinedKey)
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
    var biasPhrases: [String] { biasPhrases(upTo: DictionaryCorrector.biasLimit) }

    /// The same list, longer for the cloud, which takes up to `CloudProvider.termLimit` (A2-2).
    func biasPhrases(upTo capacity: Int) -> [String] {
        DictionaryCorrector.biasPhrases(from: entries, seeded: Self.lexiconSpellings, capacity: capacity)
    }

    /// The user's own spellings for Whisper's prompt, newest first (FLU-20). The built-in
    /// tech lexicon is left out: it is generic, the corrections still fix its spellings after
    /// transcription, and a prompt full of it is what made Whisper loop.
    var promptTerms: [String] {
        entries.reversed()
            .filter { $0.isEnabled && !Self.lexiconSpellings.contains($0.write.lowercased()) }
            .map(\.write)
    }

    /// The lexicon's spellings, retired ones included: a dictionary seeded before FLU-30 still
    /// holds them, and they are not the user's own words.
    private static let lexiconSpellings = Set((TechLexicon.defaultEntries + TechLexicon.retired).map { $0.write.lowercased() })

    /// Retired lexicon entries still in the dictionary exactly as seeded (FLU-30).
    var retiredLexiconEntries: [DictionaryEntry] { TechLexicon.retiredEntries(in: entries) }

    /// « Retirer de mon dictionnaire »: removes the retired lexicon entries the user never
    /// touched, on their click only, and returns how many.
    @discardableResult
    func removeRetiredLexiconEntries() -> Int {
        let retired = Set(retiredLexiconEntries.map(\.id))
        guard !retired.isEmpty else { return 0 }
        delete(ids: retired)
        return retired.count
    }

    /// How many of the tech lexicon's entries the dictionary lacks, deleted ones apart.
    var missingTechLexiconCount: Int {
        TechLexicon.missing(from: entries, declined: declinedLexicon).count
    }

    /// Clement's "Lexique Tech" button: adds the lexicon's entries the dictionary lacks, except
    /// those the user deleted, and returns how many, so the button can say so (FLU-17).
    @discardableResult
    func importTechLexicon() -> Int {
        let newEntries = TechLexicon.missing(from: entries, declined: declinedLexicon)
        add(contentsOf: newEntries)
        return newEntries.count
    }

    // MARK: - File

    private enum ReadResult {
        /// The text, and the bytes it was decoded from.
        case text(String, Data)
        case missing
        case failed(Error)
    }

    private static func read() -> ReadResult {
        do {
            let bytes = try Data(contentsOf: fileURL)
            guard let text = DictionaryFileFormat.decode(bytes) else {
                return .failed(CocoaError(.fileReadInapplicableStringEncoding))
            }
            return .text(text, bytes)
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
        case .text(let text, _):
            problem = nil
            if text != lastText { adopt(text) }
            return true
        case .missing:
            return false
        case .failed(let error):
            noteUnreadable(error)
            return false
        }
    }

    /// Takes the file's text as the truth, keeping the ids of unchanged lines. If the file had
    /// never been read (it failed at launch), what was added since stays, after it.
    private func adopt(_ text: String) {
        let read = DictionaryFileFormat.parse(text, keepingIDsOf: entries)
        entries = lastText == nil ? read + DictionaryEntry.missing(entries, from: read) : read
        lastText = text
        problem = nil
    }

    /// The file is there but cannot be read: nothing is written over it until it can (FLU-138).
    private func noteUnreadable(_ error: Error) {
        problem = "dictionary.txt n'a pas pu être lu : vos changements ne sont pas enregistrés."
        Log.app.error("dictionary unreadable, nothing saved over it: \(error.localizedDescription)")
        Diagnostics.error("dictionary.read", error)
    }

    private func save() {
        // Never write over a file that could not be read: it may hold the whole dictionary.
        switch Self.read() {
        case .failed(let error):
            return noteUnreadable(error)
        case .text(let current, let bytes):
            if lastText == nil { adopt(current) }
            keepCopy(of: current, bytes: bytes)
        case .missing:
            break
        }
        let text = DictionaryFileFormat.render(entries, header: Self.header)
        do {
            try text.write(to: Self.fileURL, atomically: true, encoding: .utf8)
            lastText = text
        } catch {
            Log.app.error("dictionary not saved: \(error.localizedDescription)")
            Diagnostics.error("dictionary.save", error)
        }
        // The atomic write replaced the file, so the old watcher is on a dead inode.
        watchFile()
    }

    /// The file on disk is about to be replaced. If it holds lines the parser could not read
    /// (a format it does not know yet), if its entries are about to be replaced by none (how
    /// the line-ending bug erased dictionaries), or if it was not UTF-8 (FLU-138), copy its
    /// bytes to `dictionary.txt.bak` first, so nothing the user typed is ever lost (FLU-53).
    private func keepCopy(of current: String, bytes: Data) {
        let unread = DictionaryFileFormat.hasUnreadLines(current)
        let emptied = entries.isEmpty && !DictionaryFileFormat.parse(current).isEmpty
        let converted = Data(current.utf8) != bytes
        guard unread || emptied || converted else { return }
        let backup = Self.fileURL.appendingPathExtension("bak")
        do {
            try bytes.write(to: backup, options: .atomic)
            Log.app.error("dictionary copied to dictionary.txt.bak before saving (unreadable lines: \(unread), emptied: \(emptied), converted: \(converted))")
            Diagnostics.recovery("dictionary.backup")
        } catch {
            Log.app.error("dictionary backup failed: \(error.localizedDescription)")
            Diagnostics.error("dictionary.backup.failed", error)
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
