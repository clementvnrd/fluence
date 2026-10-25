import Foundation

/// What Time Machine keeps of the support folder (FLU-36).
///
/// The whole folder used to be excluded, so restoring a Mac from Time Machine brought back
/// nothing — not even the dictionary the user wrote by hand. Now the folder itself is
/// backed up and everything in it is excluded item by item, except the dictionary: plain
/// text the user edits, nothing a dictation or a meeting wrote. Sealed files stay out of
/// the backup: without the Keychain key they are noise, and the encrypted backup file
/// (`DataBackup`) is how they move to another Mac.
public enum SupportFolder {
    /// Top-level names Time Machine keeps: the dictionary and the copy made before a save
    /// that would have emptied it (FLU-53).
    public static let backedUpNames: Set<String> = ["dictionary.txt", "dictionary.txt.bak"]

    public static func isBackedUp(_ name: String) -> Bool {
        backedUpNames.contains(name)
    }

    /// Backs the folder up, then excludes every item in it but the dictionary. Idempotent;
    /// run at launch, so an item created since (or an exclusion an atomic write dropped)
    /// is caught.
    public static func applyBackupPolicy(to root: URL) {
        setExcluded(false, root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            setExcluded(!isBackedUp(name), root.appendingPathComponent(name))
        }
    }

    /// For a top-level file written by replacing it (an atomic write makes a new file, which
    /// does not carry the old one's exclusion). Anything inside an excluded folder is
    /// already out.
    public static func keepOutOfBackup(_ url: URL) {
        guard !isBackedUp(url.lastPathComponent) else { return }
        setExcluded(true, url)
    }

    public static func isExcluded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }

    private static func setExcluded(_ excluded: Bool, _ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? url.setResourceValues(values)
    }
}
