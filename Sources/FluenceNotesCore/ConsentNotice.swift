import Foundation

/// The one-click notice the user pastes into the meeting chat before recording.
///
/// Recording a private conversation without consent is an offence in France (Code pénal
/// art. 226-1) and needs a lawful basis under the GDPR; telling people, and offering to stop,
/// is the minimum. The wording is plain on purpose: it says what happens (notes, locally),
/// what does not (nothing goes online), and how to object.
public enum ConsentNotice {
    public static func text(_ language: NotesLanguage) -> String {
        switch language {
        case .french:
            "Je prends des notes de cette réunion avec Fluence, en local sur mon ordinateur : "
                + "rien n'est envoyé sur Internet. Dites-le-moi si vous préférez que je n'enregistre pas."
        case .english:
            "I'm taking notes of this meeting with Fluence, locally on my computer: nothing is "
                + "sent over the Internet. Let me know if you'd rather I didn't record."
        }
    }

    /// French then English, for meetings where both are spoken.
    public static var bilingual: String {
        text(.french) + "\n\n" + text(.english)
    }
}
