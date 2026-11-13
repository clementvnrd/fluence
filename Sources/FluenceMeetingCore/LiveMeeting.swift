import Foundation

/// The meeting being recorded or finalised has one writer, the controller (FLU-136). The
/// library writes the user's edits to disk between its saves, and each controller save takes
/// them back from there instead of overwriting them with its older copy.
public enum LiveMeeting {
    /// What the controller writes: its own transcript, speakers and timings, with the title,
    /// « Mes notes », the generated notes and the speaker names the user typed taken from
    /// `stored`. Nil when the meeting is no longer on disk: a meeting deleted meanwhile is
    /// never written back. On disk but unreadable (`stored` nil): the live copy, as before.
    public static func toSave(_ live: Meeting, stored: Meeting?, onDisk: Bool) -> Meeting? {
        guard onDisk else { return nil }
        guard let stored else { return live }
        var meeting = live
        meeting.title = stored.title
        meeting.userNotes = stored.userNotes
        meeting.notes = stored.notes
        for index in meeting.speakers.indices {
            let id = meeting.speakers[index].id
            if let named = stored.speakers.first(where: { $0.id == id && $0.nameSource == .user }) {
                meeting.speakers[index] = named
            }
        }
        return meeting
    }
}
