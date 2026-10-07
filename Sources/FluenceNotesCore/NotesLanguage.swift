import Foundation

/// The language the notes are written in. The transcription side handles more, but the
/// notes follow the two languages this app is used in.
public enum NotesLanguage: String, Sendable, Codable, CaseIterable, Hashable {
    case english = "en"
    case french = "fr"

    /// Uses the meeting's BCP-47 tag when it names English or French, otherwise counts
    /// function words in the transcript. Ties go to English.
    public static func detect(bcp47: String?, sample: String) -> NotesLanguage {
        if let tag = bcp47?.lowercased() {
            if tag == "fr" || tag.hasPrefix("fr-") || tag.hasPrefix("fr_") { return .french }
            if tag == "en" || tag.hasPrefix("en-") || tag.hasPrefix("en_") { return .english }
        }
        var french = 0
        var english = 0
        for word in words(String(sample.prefix(6_000))) {
            if frenchMarkers.contains(word) { french += 1 }
            if englishMarkers.contains(word) { english += 1 }
        }
        return french > english ? .french : .english
    }

    /// The language's name as written in the instructions to the model.
    public var promptName: String {
        switch self {
        case .english: "English"
        case .french: "French (français)"
        }
    }

    private static func words(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }
    }

    // Function words that are frequent in one language and rare in the other. Words both
    // languages share ("a", "on", "pour" as an English surname…) are left out on purpose.
    private static let frenchMarkers: Set<Substring> = [
        "le", "la", "les", "des", "est", "et", "je", "vous", "nous", "que", "qui", "pas",
        "une", "du", "c'est", "c’est", "ça", "dans", "avec", "sur", "mais", "il", "elle",
        "cette", "oui", "alors", "donc", "aussi", "très", "bien", "faire", "j'ai", "j’ai",
    ]
    private static let englishMarkers: Set<Substring> = [
        "the", "is", "and", "i", "you", "we", "that", "it", "to", "of", "for", "with",
        "but", "this", "yes", "so", "are", "have", "be", "not", "what", "it's", "i'm",
        "will", "can", "they", "do", "just",
    ]
}
