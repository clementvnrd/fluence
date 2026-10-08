import Foundation

/// The notes half of the Notetaker, started once at launch from `AppDelegate`.
@MainActor
enum NotetakerNotes {
    static func launch() {
        purgeExpired()
        MeetingNotesGenerator.shared.start()
    }

    /// Applies the retention setting: deletes meetings older than it (at launch and when
    /// the setting changes), and forgets per-meeting choices of deleted meetings.
    static func purgeExpired() {
        let store = MeetingStore.shared
        store.purge(olderThan: NotetakerSettings.shared.retentionDays)
        // Every meeting on disk: an unreadable one keeps its choice (FLU-27).
        NotesTemplateChoice.prune(keeping: store.meetingIDs)
        MeetingLibraryModel.shared.reconcile()
    }
}
