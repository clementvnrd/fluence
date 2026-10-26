import Foundation

/// How `dictionary.txt` is read and written, apart from the file itself (which the app owns).
///
/// One entry per line: a bare line is a term, `hear -> write` a correction, `# off:` in front
/// keeps a disabled entry, and any other `#` line is a comment. The shared vectors'
/// `fileCases` pin this, and the Windows app reads the same files the same way.
public enum DictionaryFileFormat {
    /// The entries of a file, in order. Any line ending ends a line (`\n`, `\r\n`, a lone
    /// `\r`): a file saved by a Windows editor once read as a single comment line, so the
    /// dictionary looked empty and the next save wrote that emptiness back (FLU-53).
    public static func parse(_ text: String) -> [DictionaryEntry] {
        text.split(whereSeparator: \.isNewline).compactMap(entry(from:))
    }

    /// The file for these entries: `header` as given, then one line each, ending in `\n`.
    public static func render(_ entries: [DictionaryEntry], header: String) -> String {
        header + entries.map(\.fileLine).joined(separator: "\n") + "\n"
    }

    /// True when `text` holds lines that are neither blank, nor comments, nor entries: what
    /// a save would silently drop.
    public static func hasUnreadLines(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#") && entry(from: raw) == nil
        }
    }

    private static func entry(from raw: Substring) -> DictionaryEntry? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }
        var isEnabled = true
        if line.hasPrefix("#") {
            // `# off:` keeps a disabled entry; any other `#` line is only a comment.
            let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard rest.prefix(4).lowercased() == "off:" else { return nil }
            line = rest.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            isEnabled = false
        }

        guard let arrow = line.range(of: "->") else {
            return DictionaryEntry(kind: .term, write: line, isEnabled: isEnabled)
        }
        // Only the first arrow splits: `write` may hold more of them.
        let hear = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let write = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        if hear.isEmpty || write.isEmpty { return nil }
        return DictionaryEntry(kind: .correction, write: write, hear: hear, isEnabled: isEnabled)
    }
}
