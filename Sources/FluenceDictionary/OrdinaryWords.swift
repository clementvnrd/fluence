import Foundation

/// Everyday words, in lower case, that make a poor trigger on their own: a correction from one
/// of them rewrites every use of it, not only the one the user had in mind. English and French,
/// because Clement dictates in French and hears tech words in the middle of it. The list only
/// feeds a warning, so it aims at the obvious, not at completeness.
enum OrdinaryWords {
    static let all = Set(english + french)

    static let english = [
        // Function words.
        "a", "an", "the", "and", "or", "but", "if", "so", "of", "to", "in", "on", "at", "by",
        "for", "with", "from", "as", "about", "up", "out", "off", "then", "not", "no", "yes",
        "ok", "is", "are", "was", "were", "be", "do", "have", "has", "had", "will", "can", "it",
        "its", "this", "that", "there", "here", "what", "which", "who", "when", "where", "why",
        "how", "i", "you", "he", "she", "we", "they", "me", "her", "us", "my", "your", "our",
        "all", "some", "any", "one", "new", "now", "just", "also", "more", "good", "like",
        // Verbs and nouns of every day, many of them heard in tech speech.
        "get", "go", "make", "see", "use", "work", "time", "day", "cloud",
        "code", "data", "file", "app", "test", "build", "run", "open", "page", "link", "text",
        "mail", "team", "chat", "note", "word", "line", "list", "key", "type", "user", "home",
        "view", "start", "stop", "save", "send", "check", "call", "web", "site", "back", "next",
        "message", "client", "point", "base",
    ]

    static let french = [
        // Function words.
        "à", "y", "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "et", "ou", "où",
        "mais", "donc", "car", "ni", "que", "qu", "qui", "ce", "cette", "ces", "ça", "il",
        "elle", "nous", "vous", "ils", "elles", "je", "j", "tu", "te", "se", "lui", "leur",
        "mon", "son", "ma", "sa", "mes", "ses", "notre", "votre", "est", "sont", "suis", "être",
        "avoir", "ai", "ont", "fait", "faire", "va", "peut", "dans", "sur", "sous", "avec",
        "sans", "pour", "par", "en", "au", "aux", "chez", "entre", "vers", "pas", "plus", "très",
        "bien", "tout", "tous", "oui", "non", "si", "comme", "quand", "alors", "aussi", "encore",
        "déjà", "ici", "là", "puis", "après", "avant", "même", "autre",
        // Verbs and nouns of every day, many of them heard in tech speech.
        "chose", "temps", "jour", "fois", "bon", "faut", "dit", "dire", "voir", "petit", "grand",
        "rien", "fichier", "dossier", "lien", "projet", "équipe", "réunion", "mot", "ligne",
        "texte", "compte", "serveur", "données", "nuage", "clé", "liste",
    ]
}
