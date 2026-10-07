import Foundation

/// The notes half of the Notetaker, started once at launch from `AppDelegate`.
@MainActor
enum NotetakerNotes {
    static func launch() {
        MeetingNotesGenerator.shared.start()
    }
}
