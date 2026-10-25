import FluenceCore
import Foundation

/// Where Fluence keeps its files, and the one-time move from the app's previous identity.
///
/// Everything personal (history, dictionary, meetings) lives under one directory that is
/// owner-only and never indexed by Spotlight. Everything in it is excluded from Time Machine
/// except the dictionary (FLU-36, `SupportFolder`), so a transcript cannot leak through a
/// backup disk or a system-wide search while the words the user typed by hand survive a
/// restore.
enum AppPaths {
    /// `~/Library/Application Support`.
    static let applicationSupport: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// Development only: `FLUENCE_SUPPORT_DIRECTORY` points the app at a scratch folder (for
    /// screenshots of a fresh install). Legacy data is then never touched — the migration
    /// below works on the real folders only.
    static let override: URL? = ProcessInfo.processInfo.environment["FLUENCE_SUPPORT_DIRECTORY"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    /// The identity of the app Clement uses. TCC grants, the Keychain item and the data folder
    /// all belong to it.
    static let productionBundleID = "io.github.clementvnrd.fluence"

    /// A copy built under another bundle ID — an update test (FLU-26), a screenshot build. It
    /// keeps its data in its own folder for good, even after Sparkle relaunches it without the
    /// environment `FLUENCE_SUPPORT_DIRECTORY` came from. Settings and the Keychain item are
    /// already per bundle ID.
    static let isolatedBundleID: String? = Bundle.main.bundleIdentifier
        .flatMap { $0 == productionBundleID ? nil : $0 }

    /// This copy must never read, move or merge the production app's files.
    static var isIsolated: Bool { override != nil || isolatedBundleID != nil }

    /// `~/Library/Application Support/Fluence`.
    static let support: URL = {
        if let override {
            protectSupport(override)
            return override
        }
        if let isolatedBundleID {
            let directory = applicationSupport.appendingPathComponent("Fluence-\(isolatedBundleID)", isDirectory: true)
            protectSupport(directory)
            return directory
        }
        let directory = applicationSupport.appendingPathComponent("Fluence", isDirectory: true)
        protectSupport(directory)
        LegacyMigration.mergeSupportFiles(into: directory)
        SupportFolder.applyBackupPolicy(to: directory)
        return directory
    }()

    /// A subdirectory of `support`, created and protected on first use.
    static func directory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        protect(url)
        return url
    }

    /// The support folder itself: owner-only and no Spotlight like the rest, but backed up,
    /// with every item in it excluded except the dictionary (FLU-36). Earlier versions
    /// excluded the whole folder; this lifts that once and for all.
    private static func protectSupport(_ directory: URL) {
        prepare(directory)
        SupportFolder.applyBackupPolicy(to: directory)
    }

    /// A top-level file of the support folder, written by replacing it: put back out of
    /// Time Machine (an atomic write drops the exclusion). The dictionary is left in.
    static func keepOutOfBackup(_ url: URL) {
        SupportFolder.keepOutOfBackup(url)
    }

    /// Owner-only permissions, no backup, no Spotlight. Idempotent.
    static func protect(_ directory: URL) {
        prepare(directory)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Created, owner-only, never indexed.
    private static func prepare(_ directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // Spotlight honours this marker file for the directory it sits in.
        let marker = directory.appendingPathComponent(".metadata_never_index")
        if !manager.fileExists(atPath: marker.path) {
            manager.createFile(atPath: marker.path, contents: nil)
        }
    }
}

/// The app was called "Murmur YouTube" (`ai.pivotstudio.murmur-youtube`), and Clement's own
/// build kept that identity. Renaming changed both its preferences domain and where its
/// files live; without this the user would lose their dictionary, history, snippets and
/// settings on the first launch as Fluence.
///
/// File by file, not folder by folder (FLU-11): on Clement's Mac `Fluence/` already exists —
/// it holds his Whisper models — so moving the old folder only "when the new one doesn't
/// exist" would silently skip everything. The decisions are `FluenceCore.LegacyMerge`'s.
enum LegacyMigration {
    static let legacyBundleID = "ai.pivotstudio.murmur-youtube"
    /// Set by the first Fluence builds, which copied settings once and then never again.
    private static let firstDoneKey = "migratedFromMurmurYouTube"
    /// This version's copy: also brings over the keys Clement's build added.
    private static let doneKey = "migratedFromMurmurYouTube.v2"

    /// `MurmurYouTube/`: history (`runs.jsonl`, plaintext) and `dictionary.txt`.
    static var legacySupport: URL {
        AppPaths.applicationSupport.appendingPathComponent("MurmurYouTube", isDirectory: true)
    }

    /// `ai.pivotstudio.murmur-youtube/`: Clement's `snippets.json`, plaintext.
    static var legacySnippetsDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent(legacyBundleID, isDirectory: true)
    }

    static var legacySnippetsFile: URL {
        legacySnippetsDirectory.appendingPathComponent("snippets.json")
    }

    /// The plaintext history files still waiting to be sealed, oldest location first.
    /// `HistoryFile` seals them and removes each only once its runs are written.
    static func legacyRunFiles(in support: URL) -> [URL] {
        var files = [support.appendingPathComponent("runs.jsonl")]
        if !AppPaths.isIsolated {
            files.insert(legacySupport.appendingPathComponent("runs.jsonl"), at: 0)
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Brings `MurmurYouTube/dictionary.txt` into `Fluence/` (moved, or merged entry by entry
    /// when Fluence already has one) and drops the rendered dashboard, a copy of the history
    /// in plaintext HTML. History is left where it is for `HistoryFile` to seal; snippets
    /// for `SnippetStore`, which seals them. Runs before anything reads `AppPaths.support`.
    static func mergeSupportFiles(into support: URL) {
        let manager = FileManager.default
        let legacy = legacySupport
        guard manager.fileExists(atPath: legacy.path) else { return }

        try? manager.removeItem(at: legacy.appendingPathComponent("dashboard.html"))

        let oldDictionary = legacy.appendingPathComponent("dictionary.txt")
        let newDictionary = support.appendingPathComponent("dictionary.txt")
        switch LegacyMerge.step(
            legacyExists: manager.fileExists(atPath: oldDictionary.path),
            currentExists: manager.fileExists(atPath: newDictionary.path)
        ) {
        case .nothing:
            break
        case .move:
            do {
                try manager.moveItem(at: oldDictionary, to: newDictionary)
                Log.app.info("migration: dictionary moved into Fluence")
            } catch {
                Log.app.error("migration: dictionary not moved — \(error.localizedDescription)")
            }
        case .merge:
            do {
                let current = try String(contentsOf: newDictionary, encoding: .utf8)
                let old = try String(contentsOf: oldDictionary, encoding: .utf8)
                if let merged = LegacyMerge.mergeDictionary(current: current, legacy: old) {
                    try merged.write(to: newDictionary, atomically: true, encoding: .utf8)
                }
                try manager.removeItem(at: oldDictionary)
                Log.app.info("migration: dictionary merged into Fluence")
            } catch {
                // Both files stay as they are; the merge is tried again next launch.
                Log.app.error("migration: dictionary not merged — \(error.localizedDescription)")
            }
        }
        removeIfEmpty(legacy)
    }

    /// Removes a legacy folder once nothing but Finder or Spotlight litter is left in it.
    static func removeIfEmpty(_ directory: URL) {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let litter: Set<String> = [".DS_Store", ".metadata_never_index"]
        guard contents.allSatisfy(litter.contains) else { return }
        try? manager.removeItem(at: directory)
    }

    /// Copies settings the user had set under the old identity. Never overwrites a value
    /// already set under the new one, and runs once per version of the copy.
    static func migrateDefaults(into defaults: UserDefaults = .standard) {
        guard !AppPaths.isIsolated else { return }
        guard !defaults.bool(forKey: doneKey) else { return }
        defer {
            defaults.set(true, forKey: doneKey)
            defaults.set(true, forKey: firstDoneKey)
        }

        guard let legacy = UserDefaults(suiteName: legacyBundleID)?
            .persistentDomain(forName: legacyBundleID) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
