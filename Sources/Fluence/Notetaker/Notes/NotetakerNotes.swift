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
        NotesTemplateChoice.prune(keeping: Set(store.summaries.map(\.id)))
        MeetingLibraryModel.shared.reconcile()
    }
}
