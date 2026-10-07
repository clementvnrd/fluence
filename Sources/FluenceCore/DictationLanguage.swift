import Foundation
import NaturalLanguage

/// The language a dictation is spoken in.
///
/// The list is Parakeet v3's: the 25 European languages it transcribes. Apple's transcriber
/// supports most of them too; one it doesn't falls back to its nearest supported locale.
/// Cleanup has rules for English and French; every other language gets the language-neutral
/// rules (spacing, capitals, final full stop) and a model prompt told to keep the language.
public enum DictationLanguage: String, CaseIterable, Sendable, Codable {
    case auto
    case english = "en"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case polish = "pl"
    case swedish = "sv"
    case danish = "da"
    case finnish = "fi"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case hungarian = "hu"
    case romanian = "ro"
    case bulgarian = "bg"
    case greek = "el"
    case estonian = "et"
    case latvian = "lv"
    case lithuanian = "lt"
    case maltese = "mt"
    case russian = "ru"
    case ukrainian = "uk"

    /// Every concrete language, without `.auto`.
    public static var spoken: [DictationLanguage] { allCases.filter { $0 != .auto } }

    /// The language's own name: a French speaker looks for "Français", not "French".
    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .english: "English"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .dutch: "Nederlands"
        case .polish: "Polski"
        case .swedish: "Svenska"
        case .danish: "Dansk"
        case .finnish: "Suomi"
        case .czech: "Čeština"
        case .slovak: "Slovenčina"
        case .slovenian: "Slovenščina"
        case .croatian: "Hrvatski"
        case .hungarian: "Magyar"
        case .romanian: "Română"
        case .bulgarian: "Български"
        case .greek: "Ελληνικά"
        case .estonian: "Eesti"
        case .latvian: "Latviešu"
        case .lithuanian: "Lietuvių"
        case .maltese: "Malti"
        case .russian: "Русский"
        case .ukrainian: "Українська"
        }
    }

    /// The English name, for the model's instructions (which are written in English for
    /// every language but French).
    public var englishName: String {
        switch self {
        case .auto: "the speaker's language"
        default: Locale(identifier: "en").localizedString(forLanguageCode: rawValue) ?? rawValue
        }
    }

    /// The BCP-47 language code, nil for `.auto`.
    public var code: String? { self == .auto ? nil : rawValue }

    /// The locale to ask Apple's transcriber for.
    ///
    /// The user's own region wins when it speaks this language (a Belgian user choosing
    /// French gets fr-BE, a British user English gets en-GB); otherwise the language's main
    /// region. `.auto` is the system locale, which is what the app always used before.
    public func appleLocaleIdentifier(current: Locale) -> String {
        guard let code else { return current.identifier }
        if current.language.languageCode?.identifier == code { return current.identifier }
        return Self.defaultRegions[code].map { "\(code)-\($0)" } ?? code
    }

    /// The language a locale speaks, if it is one of ours.
    public init?(locale: Locale) {
        guard let code = locale.language.languageCode?.identifier,
              let language = DictationLanguage(rawValue: code), language != .auto else { return nil }
        self = language
    }

    private static let defaultRegions: [String: String] = [
        "en": "US", "fr": "FR", "de": "DE", "es": "ES", "it": "IT", "pt": "PT", "nl": "NL",
        "pl": "PL", "sv": "SE", "da": "DK", "fi": "FI", "cs": "CZ", "sk": "SK", "sl": "SI",
        "hr": "HR", "hu": "HU", "ro": "RO", "bg": "BG", "el": "GR", "et": "EE", "lv": "LV",
        "lt": "LT", "mt": "MT", "ru": "RU", "uk": "UA",
    ]
}

// MARK: - Detection

public extension DictationLanguage {
    /// The language of one transcript.
    ///
    /// A language the user picked is taken at their word. In Auto, English and French — the
    /// two this app is used in — are told apart by function words, which works on a single
    /// short sentence where statistical recognisers guess; anything else goes to
    /// `NLLanguageRecognizer`, limited to the languages above. When neither is confident the
    /// answer is `fallback` (the system language, in practice).
    static func detect(
        _ text: String,
        selected: DictationLanguage,
        fallback: DictationLanguage
    ) -> DictationLanguage {
        guard selected == .auto else { return selected }

        var french = 0
        var english = 0
        for word in markerWords(text) {
            if frenchMarkers.contains(word) { french += 1 }
            if englishMarkers.contains(word) { english += 1 }
        }
        // Decisive only with two hits and a clear lead: "le" alone, or "on" in either
        // language, proves nothing.
        if french >= 2, french >= english * 2 { return .french }
        if english >= 2, english >= french * 2 { return .english }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = spoken.map { NLLanguage($0.rawValue) }
        recognizer.processString(text)
        if let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
           probability >= 0.6,
           let match = DictationLanguage(rawValue: language.rawValue) {
            return match
        }
        return fallback == .auto ? .english : fallback
    }

    private static func markerWords(_ text: String) -> [Substring] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && $0 != "'" }
    }

    // Function words frequent in one language and rare in the other. Shared spellings ("on",
    // "a", "en", "plus") are left out on purpose.
    private static let frenchMarkers: Set<Substring> = [
        "le", "la", "les", "des", "est", "et", "je", "vous", "nous", "que", "qui", "pas",
        "une", "du", "c'est", "ça", "dans", "avec", "sur", "mais", "il", "elle", "cette",
        "oui", "alors", "donc", "aussi", "très", "bien", "faire", "j'ai", "pour", "euh",
        "suis", "sont", "au", "aux", "ce", "mon", "ma", "mes", "ton", "tu", "moi", "demain",
    ]
    private static let englishMarkers: Set<Substring> = [
        "the", "is", "and", "i", "you", "we", "that", "it", "to", "of", "for", "with",
        "but", "this", "yes", "so", "are", "have", "be", "not", "what", "it's", "i'm",
        "will", "can", "they", "do", "just", "my", "your", "tomorrow", "um", "uh",
    ]
}
