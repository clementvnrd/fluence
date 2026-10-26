import Foundation

/// The onboarding's « Essayer » step (FLU-37): the user holds the shortcut, speaks, and the
/// real pipeline types into a field on the page. Which of its four looks the page shows.
public enum TryDictation {
    public enum Phase: Equatable, Sendable {
        /// Accessibility or the microphone is still missing: nothing could be typed.
        case blocked
        /// The field is focused, « Maintenez <raccourci> et parlez ».
        case waiting
        /// Blue border, live text, « Relâchez pour écrire ».
        case dictating
        /// « Fluence est prêt », the typed text and « Ça marche ».
        case success
        /// « Aucun son reçu » and « Choisir un micro ».
        case nothingHeard
    }

    /// How the last dictation since the step opened ended.
    public enum Ending: Equatable, Sendable {
        /// Typed where the caret was.
        case typed
        /// Held long enough, nothing above room tone, or no words.
        case nothingHeard
        /// Anything else — left on the clipboard, an error: the capsule says what happened.
        case other
    }

    public static func phase(requiredGranted: Bool, isDictating: Bool, lastEnding: Ending?, fieldHasText: Bool) -> Phase {
        // Shown even without the grants: a dictation the user started is theirs to watch.
        if isDictating { return .dictating }
        guard requiredGranted else { return .blocked }
        switch lastEnding {
        // The proof is the text in the field: emptied since, it is not a success any more.
        case .typed: return fieldHasText ? .success : .waiting
        case .nothingHeard: return .nothingHeard
        case .other, nil: return .waiting
        }
    }

    /// The step counts as done (its circle checked) only once it worked.
    public static func isDone(_ phase: Phase) -> Bool { phase == .success }
}
