import FluenceNotesCore
import Foundation

// The only place that translates between the app's meeting model and FluenceNotesCore's
// plain inputs. If the model types move to another module, this file is where an import is
// added; nothing else in the notes code names their fields.

extension Meeting {
    /// The transcript as display-named lines, in time order.
    var notesLines: [TranscriptLine] {
        segments.sorted { $0.start < $1.start }.map { segment in
            TranscriptLine(
                start: segment.start,
                speaker: speaker(segment.speakerID)?.displayName ?? segment.speakerID,
                text: segment.text
            )
        }
    }

    /// Display names of the people who spoke, in order of first appearance; every known
    /// speaker when nothing was said yet.
    var participantNames: [String] {
        var names: [String] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let name = speaker(segment.speakerID)?.displayName ?? segment.speakerID
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? speakers.map(\.displayName) : names
    }

    var notesLanguage: NotesLanguage {
        NotesLanguage.detect(
            bcp47: language,
            sample: segments.prefix(300).map(\.text).joined(separator: " ")
        )
    }

    func notesRequest(template: NotesTemplate) -> NotesRequest {
        NotesRequest(
            lines: notesLines,
            context: NotesContext(
                title: title,
                participants: participantNames,
                userNotes: userNotes,
                language: notesLanguage,
                template: template
            )
        )
    }

    /// The whole meeting as a Markdown document (title, facts, notes, my notes, transcript).
    func markdown(timeZone: TimeZone = .current) -> String {
        MarkdownRenderer.render(MarkdownMeeting(
            title: title,
            startedAt: startedAt,
            duration: duration,
            participants: participantNames,
            language: notesLanguage,
            notes: notes?.draft,
            userNotes: userNotes,
            transcript: notesLines,
            timeZone: timeZone
        ))
    }

    var markdownFilename: String {
        MarkdownRenderer.filename(title: title, date: startedAt)
    }

    /// Renames a speaker everywhere in this meeting. Segments refer to speakers by ID, so
    /// renaming the speaker renames every line; owners in the notes that used the old
    /// display name follow too. The name is marked as the user's, which nothing inferred
    /// may overwrite.
    mutating func renameSpeaker(_ id: String, to newName: String) {
        if !speakers.contains(where: { $0.id == id }) {
            // A segment can name a speaker the list never got (an early live pass).
            speakers.append(Speaker(id: id))
        }
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        let oldName = speakers[index].displayName
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        speakers[index].name = trimmed.isEmpty ? nil : trimmed
        speakers[index].nameSource = trimmed.isEmpty ? nil : .user
        let newDisplayName = speakers[index].displayName
        guard var notes, newDisplayName != oldName else { return }
        for step in notes.nextSteps.indices where notes.nextSteps[step].owner == oldName {
            notes.nextSteps[step].owner = newDisplayName
        }
        self.notes = notes
    }
}

extension MeetingNotes {
    init(_ draft: FinalNotesDraft, generatedAt: Date = Date(), model: String = NotesEngine.modelName) {
        self.init(
            recap: draft.recap,
            nextSteps: draft.nextSteps.map { ActionItem(text: $0.text, owner: $0.owner, due: $0.due) },
            decisions: draft.decisions,
            openQuestions: draft.openQuestions,
            generatedAt: generatedAt,
            model: model
        )
    }

    var draft: FinalNotesDraft {
        FinalNotesDraft(
            recap: recap,
            nextSteps: nextSteps.map { ActionDraft(text: $0.text, owner: $0.owner, due: $0.due) },
            decisions: decisions,
            openQuestions: openQuestions
        )
    }
}

/// The notes template chosen for each meeting. Kept beside the store rather than in
/// `Meeting` so the shared model stays as agreed; it holds meeting IDs and template names
/// only, nothing from the meeting itself.
enum NotesTemplateChoice {
    private static let key = "notetaker.notesTemplates"

    static func template(for id: UUID) -> NotesTemplate {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return all[id.uuidString].flatMap(NotesTemplate.init(rawValue:)) ?? .general
    }

    static func set(_ template: NotesTemplate, for id: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[id.uuidString] = template == .general ? nil : template.rawValue
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(_ id: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[id.uuidString] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Drops choices for meetings that no longer exist.
    static func prune(keeping ids: Set<UUID>) {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let kept = all.filter { UUID(uuidString: $0.key).map(ids.contains) ?? false }
        UserDefaults.standard.set(kept, forKey: key)
    }
}
