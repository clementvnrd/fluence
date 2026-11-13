import Foundation

/// The one-click notice the user pastes into the meeting chat before recording.
///
/// Recording a private conversation without consent is an offence in France (Code pénal
/// art. 226-1) and needs a lawful basis under the GDPR; telling people, and offering to stop,
/// is the minimum. The wording is plain on purpose: it says what happens (notes, locally),
/// what does not (nothing goes online), and how to object. In Précis (`cloud`, FLU-132) the
/// call's voices are transcribed by ElevenLabs after the call, and the notice says so.
public enum ConsentNotice {
    public static func text(_ language: NotesLanguage, cloud: Bool = false) -> String {
        switch (language, cloud) {
        case (.french, false):
            "Je prends des notes de cette réunion avec Fluence, en local sur mon ordinateur : "
                + "rien n'est envoyé sur Internet. Dites-le-moi si vous préférez que je n'enregistre pas."
        case (.french, true):
            "Je prends des notes de cette réunion avec Fluence : après l'appel, vos voix sont transcrites "
                + "par ElevenLabs, et les notes sont écrites sur mon ordinateur. Dites-le-moi si vous préférez que je n'enregistre pas."
        case (.english, false):
            "I'm taking notes of this meeting with Fluence, locally on my computer: nothing is "
                + "sent over the Internet. Let me know if you'd rather I didn't record."
        case (.english, true):
            "I'm taking notes of this meeting with Fluence: after the call, your voices are transcribed "
                + "by ElevenLabs, and the notes are written on my computer. Let me know if you'd rather I didn't record."
        }
    }

    /// French then English, for meetings where both are spoken.
    public static func bilingual(cloud: Bool = false) -> String {
        text(.french, cloud: cloud) + "\n\n" + text(.english, cloud: cloud)
    }
}
