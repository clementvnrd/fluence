import Foundation

/// « Scanner un projet… »: the words a code folder suggests, shown to the user, who ticks what
/// to add (FLU-138). The folder's name, the package's and its first 20 dependencies in
/// alphabetical order, scopes dropped. No git branch: it names people and tickets, and on a
/// detached HEAD it is a commit hash.
public enum ProjectVocabulary {
    /// The candidates of three characters or more, each once, minus spellings already `known`.
    public static func candidates(folderName: String, packageJSON: Data?, known: [DictionaryEntry]) -> [String] {
        func withoutScope(_ name: String) -> String {
            name.replacingOccurrences(of: "@[^/]+/", with: "", options: .regularExpression)
        }
        var words = [folderName]
        if let data = packageJSON, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["name"] as? String { words.append(withoutScope(name)) }
            if let dependencies = json["dependencies"] as? [String: Any] {
                words += dependencies.keys.map(withoutScope).sorted().prefix(20)
            }
        }
        var seen = Set(known.map { $0.write.trimmed.lowercased() })
        return words.map(\.trimmed).filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
    }
}
