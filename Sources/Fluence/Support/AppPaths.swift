import Foundation

/// Where Fluence keeps its files, and the one-time move from the app's previous identity.
///
/// Everything personal (history, dictionary, meetings) lives under one directory that is
/// owner-only, excluded from Time Machine and never indexed by Spotlight — so a transcript
/// cannot leak through a backup disk or a system-wide search.
enum AppPaths {
    /// `~/Library/Application Support/Fluence`.
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Fluence", isDirectory: true)
        LegacyMigration.moveSupportDirectory(from: base.appendingPathComponent("MurmurYouTube"), to: directory)
        protect(directory)
        return directory
    }()

    /// A subdirectory of `support`, created and protected on first use.
    static func directory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        protect(url)
        return url
    }

    /// Owner-only permissions, no backup, no Spotlight. Idempotent.
    static func protect(_ directory: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)

        // Spotlight honours this marker file for the directory it sits in.
        let marker = directory.appendingPathComponent(".metadata_never_index")
        if !manager.fileExists(atPath: marker.path) {
            manager.createFile(atPath: marker.path, contents: nil)
        }
    }
}

/// The app was called "Murmur YouTube" (`ai.pivotstudio.murmur-youtube`). Renaming changed
/// both its preferences domain and its support directory; without this the user would
/// lose their dictionary, history and settings on the first launch as Fluence.
enum LegacyMigration {
    static let legacyBundleID = "ai.pivotstudio.murmur-youtube"
    private static let doneKey = "migratedFromMurmurYouTube"

    static func moveSupportDirectory(from old: URL, to new: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else { return }
        try? manager.moveItem(at: old, to: new)
    }

    /// Copies settings the user had set under the old identity. Never overwrites a value
    /// already set under the new one, and runs once.
    static func migrateDefaults(into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        guard let legacy = UserDefaults(suiteName: legacyBundleID)?
            .persistentDomain(forName: legacyBundleID) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
