import Foundation

/// How `dictionary.txt` is read and written, apart from the file itself (which the app owns).
///
/// One entry per line: a bare line is a term, `hear -> write` a correction, `# off:` in front
/// keeps a disabled entry, and any other `#` line is a comment. The dictionary vectors'
/// `fileCases` pin this.
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

    /// The file's text from its bytes: UTF-8 (a byte-order mark is dropped), UTF-16 when the
    /// file starts with its byte-order mark, else Windows Latin-1 and last Mac Roman. A file
    /// saved by hand in an old encoding once read as nothing, and the next save wrote that
    /// nothing over it (FLU-138); the caller keeps the original bytes before converting it.
    public static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        // shortcut: a Mac Roman file whose bytes are all valid Windows Latin-1 reads with wrong
        // accents (the .bak keeps the original); guess from the bytes if that is ever reported.
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman)
    }

    /// `parse(text)`, with the ids of `previous` kept on the entries whose line is unchanged:
    /// an edit sheet or a review opened before an outside change still finds its entry (FLU-138).
    public static func parse(_ text: String, keepingIDsOf previous: [DictionaryEntry]) -> [DictionaryEntry] {
        var ids = Dictionary(grouping: previous, by: \.fileLine).mapValues { $0.map(\.id) }
        return parse(text).map { entry in
            var entry = entry
            if let id = ids[entry.fileLine]?.first {
                entry.id = id
                ids[entry.fileLine]?.removeFirst()
            }
            return entry
        }
    }

    /// True when `entry`'s line reads back as that entry, enabled or not. A term starting with
    /// `#` would come back as a comment, an arrow in a term or a trigger as another correction,
    /// so the app does not store them (FLU-138).
    public static func canStore(_ entry: DictionaryEntry) -> Bool {
        [true, false].allSatisfy { isEnabled in
            var line = entry
            line.isEnabled = isEnabled
            let back = parse(line.fileLine)
            return back.count == 1 && back[0].kind == line.kind && back[0].isEnabled == isEnabled
                && back[0].fileLine == line.fileLine
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
