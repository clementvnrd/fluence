import Foundation

/// Everything the Markdown export prints, as plain values.
public struct MarkdownMeeting: Sendable, Hashable {
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var participants: [String]
    /// The language of headings and labels; follows the meeting.
    public var language: NotesLanguage
    /// Nil when no notes were generated.
    public var notes: FinalNotesDraft?
    public var userNotes: String
    public var transcript: [TranscriptLine]
    /// The zone the date is printed in. Fixed in tests; the user's own in the app.
    public var timeZone: TimeZone

    public init(
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        participants: [String],
        language: NotesLanguage,
        notes: FinalNotesDraft?,
        userNotes: String,
        transcript: [TranscriptLine],
        timeZone: TimeZone = .current
    ) {
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.participants = participants
        self.language = language
        self.notes = notes
        self.userNotes = userNotes
        self.transcript = transcript
        self.timeZone = timeZone
    }
}

/// Renders a meeting as a standalone Markdown document: title, facts, Recap, Next steps
/// (task-list checkboxes with owners), Decisions, Open questions, My notes, then the full
/// transcript with speakers and timestamps.
public enum MarkdownRenderer {
    public static func render(_ meeting: MarkdownMeeting) -> String {
        let words = Labels(meeting.language)
        var out: [String] = []

        out.append("# " + escapeInline(meeting.title.isEmpty ? words.untitled : meeting.title))
        out.append([
            "- **\(words.date):** " + dateText(meeting.startedAt, meeting.timeZone),
            "- **\(words.duration):** " + DurationText.format(meeting.duration),
            "- **\(words.participants):** "
                + (meeting.participants.isEmpty ? "—" : meeting.participants.map(escapeInline).joined(separator: ", ")),
        ].joined(separator: "\n"))

        if let notes = meeting.notes {
            out.append("## \(words.recap)\n\n" + (notes.recap.isEmpty ? "_\(words.none)_" : escapeBlock(notes.recap)))
            out.append("## \(words.nextSteps)\n\n" + list(notes.nextSteps.map { step in
                var line = "- [ ] " + escapeInline(step.text)
                if let owner = step.owner { line += " — **" + escapeInline(owner) + "**" }
                if let due = step.due { line += " (\(words.due): " + escapeInline(due) + ")" }
                return line
            }, none: words.none))
            out.append("## \(words.decisions)\n\n" + list(notes.decisions.map { "- " + escapeInline($0) }, none: words.none))
            out.append("## \(words.openQuestions)\n\n" + list(notes.openQuestions.map { "- " + escapeInline($0) }, none: words.none))
        } else {
            out.append("_\(words.noNotes)_")
        }

        let userNotes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userNotes.isEmpty {
            // The user's own text, kept as typed: it may already be Markdown.
            out.append("## \(words.myNotes)\n\n" + userNotes)
        }

        out.append("## \(words.transcript)\n\n" + (meeting.transcript.isEmpty
            ? "_\(words.none)_"
            : meeting.transcript.map { line in
                "**[\(Clock.format(line.start))] \(escapeInline(line.speaker)):** " + escapeInline(line.text)
            }.joined(separator: "\n\n")))

        return out.joined(separator: "\n\n") + "\n"
    }

    /// `2026-10-07 Weekly sync.md` — no characters Finder or other systems reject.
    public static func filename(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ").joined(separator: " ")
        let base = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        let day = dateText(date, timeZone).prefix(10)
        return base.isEmpty ? "\(day) Meeting.md" : "\(day) \(base).md"
    }

    // MARK: - Pieces

    static func dateText(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func list(_ lines: [String], none: String) -> String {
        lines.isEmpty ? "_\(none)_" : lines.joined(separator: "\n")
    }

    /// Escapes what would change the structure of one line: emphasis, code, links, HTML,
    /// and line breaks (folded to spaces so an item stays one item).
    static func escapeInline(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\n", "\r": out.append(" ")
            case "\\", "`", "*", "_", "[", "]", "<", ">", "#", "|":
                out.append("\\")
                out.append(character)
            default: out.append(character)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Prose paragraphs: inline escaping per paragraph, paragraph breaks kept.
    static func escapeBlock(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { escapeInline($0.replacingOccurrences(of: "\n", with: " ")) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private struct Labels {
        let date, duration, participants, recap, nextSteps, decisions, openQuestions: String
        let myNotes, transcript, due, none, noNotes, untitled: String

        init(_ language: NotesLanguage) {
            switch language {
            case .english:
                (date, duration, participants) = ("Date", "Duration", "Participants")
                (recap, nextSteps, decisions, openQuestions) = ("Recap", "Next steps", "Decisions", "Open questions")
                (myNotes, transcript, due) = ("My notes", "Transcript", "due")
                (none, noNotes, untitled) = ("None.", "No notes were generated for this meeting.", "Untitled meeting")
            case .french:
                (date, duration, participants) = ("Date", "Durée", "Participants")
                (recap, nextSteps, decisions, openQuestions) = ("Récapitulatif", "Prochaines étapes", "Décisions", "Questions ouvertes")
                (myNotes, transcript, due) = ("Mes notes", "Transcription", "échéance")
                (none, noNotes, untitled) = ("Aucune.", "Aucune note n'a été générée pour cette réunion.", "Réunion sans titre")
            }
        }
    }
}
