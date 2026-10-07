import AppKit
import FluenceNotesCore
import Foundation

// Integration points between the notes/library half and the capture half of the Notetaker.

extension Notification.Name {
    /// Posted on the main actor when the user turns voice prints off in Settings (after
    /// confirming). The capture side must observe it and call `VoicePrintStore.deleteAll()`:
    /// decision FLU-9 #3 says turning the feature off deletes every enrolled print.
    static let voicePrintsDisabled = Notification.Name("FluenceVoicePrintsDisabled")
}

@MainActor
enum NotetakerHooks {
    /// Optional direct hook, for a caller that prefers a closure to the notification. Set
    /// once at launch by the capture side, e.g.
    /// `NotetakerHooks.deleteAllVoicePrints = { VoicePrintStore.shared.deleteAll() }`.
    static var deleteAllVoicePrints: (() -> Void)?

    /// Called by Settings when voice prints are turned off.
    static func voicePrintsDisabled() {
        deleteAllVoicePrints?()
        NotificationCenter.default.post(name: .voicePrintsDisabled, object: nil)
    }
}

/// The consent notice the user pastes into the meeting chat. Reusable from anywhere — the
/// library, Settings, and the capture side's recording panel.
@MainActor
enum NotetakerConsent {
    /// The notice in one language, or French then English when `language` is nil.
    static func text(_ language: NotesLanguage?) -> String {
        language.map(ConsentNotice.text) ?? ConsentNotice.bilingual
    }

    /// Puts the notice on the pasteboard, ready to paste into the meeting chat. Kept off
    /// Universal Clipboard like every other Notetaker copy.
    static func copyNotice(_ language: NotesLanguage?) {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text(language), forType: .string)
    }
}
