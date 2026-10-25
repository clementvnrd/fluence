import Foundation

/// The notes half of the Notetaker, started once at launch from `AppDelegate`.
@MainActor
enum NotetakerNotes {
    static func launch() {
        purgeExpired()
        MeetingNotesGenerator.shared.start()
        // FLU-54: notes cut short by the last quit, or failed on a timeout or a busy model.
        // After the launch's own work (models warming, interrupted meetings recovered).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            MeetingNotesGenerator.shared.resumePending()
        }
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
