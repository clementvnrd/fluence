import Foundation

/// Fits a cleaned dictation to the text around the caret, just before it is typed (FLU-93).
///
/// Cleanup sees one dictation alone, so it starts it with a capital and ends it with a full
/// stop. Typed after « Bonjour. » that gives « Bonjour.Comment ça va ? »; into the middle of a
/// sentence, « …je pense que Le budget est validé. ». This puts back what the field needs:
///
/// - **a space** before the text when the previous character is a letter, a digit or closing
///   punctuation, and after it when a word follows the caret;
/// - **a lower-case first word** when the previous character does not end a sentence — never
///   an acronym, a word with inner capitals (iPhone, GitHub), « I », or a dictionary word;
/// - **no final full stop** when more text follows on the same line, or in a chat (? and !
///   stay).
///
/// Unknown context (the field could not be read) changes nothing but the chat rule. The
/// text around the caret is used once and never kept.
public enum InsertionContext {
    /// - Parameters:
    ///   - text: the cleaned dictation.
    ///   - before: the few characters just before the caret (or the selection); "" at the
    ///     start of the field; nil when unknown.
    ///   - after: the few characters just after it; nil when unknown.
    ///   - chat: a chat app (`AppCategory.personal` / `.work`): no final full stop.
    ///   - spacingOnly: spaces only, never a case or punctuation change (developer tools,
    ///     snippets).
    ///   - names: words that keep their capital (the user's dictionary).
    public static func adjust(
        _ text: String,
        before: String?,
        after: String? = nil,
        chat: Bool = false,
        spacingOnly: Bool = false,
        names: Set<String> = []
    ) -> String {
        guard let first = text.first else { return text }
        var result = text
        if !spacingOnly {
            let line = after?.prefix { !$0.isNewline } ?? ""
            if chat || line.contains(where: { !$0.isWhitespace }) { result = dropFinalStop(result) }
            if let before, !startsSentence(before) { result = lowercaseFirstWord(result, names: names) }
        }
        if let last = before?.last, spaceFollows(last), first.isLetter || first.isNumber || "«(“".contains(first) {
            result = " " + result
        }
        if let next = after?.first, next.isLetter || next.isNumber, let end = result.last, spaceFollows(end) {
            result += " "
        }
        return result
    }

    /// Characters a word is separated from by a space. Not an apostrophe, a hyphen, a slash,
    /// an opening bracket or quote, nor any space (incl. the no-break ones French typography
    /// put before « ? ! : ; »).
    static func spaceFollows(_ character: Character) -> Bool {
        // shortcut: a straight " is taken for an opening quote, so no space after it; count
        // quotes in a longer read if closing ones turn out common.
        character.isLetter || character.isNumber || ".,;:!?…)]}»”%€".contains(character)
    }

    /// Whether text typed after `before` starts a sentence: start of the field, a line break,
    /// or . ! ? … — looking through spaces and closing quotes or brackets. A read made only of
    /// those is taken for the start too, so the capital stays when in doubt.
    static func startsSentence(_ before: String) -> Bool {
        for character in before.reversed() {
            if character.isNewline || ".!?…".contains(character) { return true }
            if character.isWhitespace || "»)]\"”’'".contains(character) { continue }
            return false
        }
        return true
    }

    static func dropFinalStop(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }

    static func lowercaseFirstWord(_ text: String, names: Set<String>) -> String {
        guard let start = text.firstIndex(where: { $0.isLetter || $0.isNumber }), text[start].isUppercase else {
            return text
        }
        let word = text[start...].prefix { $0.isLetter || $0.isNumber }
        if word == "I" || word.dropFirst().contains(where: \.isUppercase) || names.contains(String(word)) {
            return text
        }
        return text.replacingCharacters(in: start...start, with: text[start].lowercased())
    }

    /// Where the last dictation went and how it ended, in memory only: the guess for an app
    /// whose field cannot be read (Electron apps, terminals).
    public struct Memory: Sendable {
        public let bundleID: String
        /// The last few characters typed, nothing more.
        public let tail: String
        /// `ProcessInfo.systemUptime` once the text was typed.
        public let at: TimeInterval

        public static let lifetime: TimeInterval = 120

        public init(bundleID: String, text: String, at: TimeInterval) {
            self.bundleID = bundleID
            self.tail = String(text.suffix(4))
            self.at = at
        }

        /// The characters to assume before the caret: the end of the last dictation, if it
        /// went into the same app less than two minutes ago and no key was typed since (a
        /// Return that sent the message, a deletion).
        public func before(bundleID: String?, now: TimeInterval, lastKeyAt: TimeInterval) -> String? {
            guard bundleID == self.bundleID, now - at < Self.lifetime, lastKeyAt < at else { return nil }
            return tail
        }
    }
}
