using System.Globalization;
using System.Text;

namespace Murmur.Meeting;

/// <summary>Everything the Markdown export prints, as plain values.</summary>
public sealed record MarkdownMeeting
{
    /// <summary>The meeting's title.</summary>
    public string Title { get; init; } = string.Empty;

    /// <summary>When it started.</summary>
    public DateTimeOffset StartedAt { get; init; }

    /// <summary>How long it lasted, seconds.</summary>
    public double Duration { get; init; }

    /// <summary>Display names.</summary>
    public IReadOnlyList<string> Participants { get; init; } = [];

    /// <summary>The language of headings and labels; follows the meeting.</summary>
    public NotesLanguage Language { get; init; }

    /// <summary>Null when no notes were generated.</summary>
    public FinalNotesDraft? Notes { get; init; }

    /// <summary>What the user typed.</summary>
    public string UserNotes { get; init; } = string.Empty;

    /// <summary>The transcript.</summary>
    public IReadOnlyList<TranscriptLine> Transcript { get; init; } = [];

    /// <summary>The zone the date is printed in. Fixed in tests; the user's own in the app.</summary>
    public TimeZoneInfo TimeZone { get; init; } = TimeZoneInfo.Local;
}

/// <summary>
/// Renders a meeting as a standalone Markdown document: title, facts, Recap, Next steps
/// (task-list checkboxes with owners), Decisions, Open questions, My notes, then the full
/// transcript with speakers and timestamps. Port of <c>MarkdownRenderer.swift</c>, output for
/// output.
/// </summary>
public static class MarkdownRenderer
{
    /// <summary>The whole document.</summary>
    public static string Render(MarkdownMeeting meeting)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        var words = Labels.For(meeting.Language);
        var output = new List<string>
        {
            "# " + EscapeInline(meeting.Title.Length == 0 ? words.Untitled : meeting.Title),
            string.Join("\n",
                $"- **{words.Date}:** " + DateText(meeting.StartedAt, meeting.TimeZone),
                $"- **{words.Duration}:** " + DurationText.Format(meeting.Duration),
                $"- **{words.Participants}:** "
                    + (meeting.Participants.Count == 0 ? "—" : string.Join(", ", meeting.Participants.Select(EscapeInline)))),
        };

        if (meeting.Notes is { } notes)
        {
            output.Add($"## {words.Recap}\n\n" + (notes.Recap.Length == 0 ? $"_{words.None}_" : EscapeBlock(notes.Recap)));
            output.Add($"## {words.NextSteps}\n\n" + List(notes.NextSteps.Select(step =>
            {
                var line = "- [ ] " + EscapeInline(step.Text);
                if (step.Owner is { } owner) line += " — **" + EscapeInline(owner) + "**";
                if (step.Due is { } due) line += $" ({words.Due}: " + EscapeInline(due) + ")";
                return line;
            }), words.None));
            output.Add($"## {words.Decisions}\n\n" + List(notes.Decisions.Select(d => "- " + EscapeInline(d)), words.None));
            output.Add($"## {words.OpenQuestions}\n\n" + List(notes.OpenQuestions.Select(q => "- " + EscapeInline(q)), words.None));
        }
        else
        {
            output.Add($"_{words.NoNotes}_");
        }

        var userNotes = meeting.UserNotes.Trim();
        if (userNotes.Length > 0)
        {
            // The user's own text, kept as typed: it may already be Markdown.
            output.Add($"## {words.MyNotes}\n\n" + userNotes);
        }

        output.Add($"## {words.Transcript}\n\n" + (meeting.Transcript.Count == 0
            ? $"_{words.None}_"
            : string.Join("\n\n", meeting.Transcript.Select(line =>
                $"**[{MeetingRecord.Clock(line.Start)}] {EscapeInline(line.Speaker)}:** " + EscapeInline(line.Text)))));

        return string.Join("\n\n", output) + "\n";
    }

    /// <summary><c>2026-10-07 Weekly sync.md</c>: no characters Windows or other systems reject.</summary>
    public static string Filename(string title, DateTimeOffset date, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(title);
        var cleaned = new StringBuilder(title.Length);
        foreach (var c in title)
        {
            cleaned.Append("/\\:?%*|\"<>".Contains(c, StringComparison.Ordinal) || char.IsControl(c) || c is '\u2028' or '\u2029' ? ' ' : c);
        }

        var collapsed = string.Join(' ', cleaned.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
        var basePart = (collapsed.Length > 80 ? collapsed[..80] : collapsed).Trim().Trim('.').Trim();
        var day = DateText(date, timeZone)[..10];
        return basePart.Length == 0 ? $"{day} Meeting.md" : $"{day} {basePart}.md";
    }

    internal static string DateText(DateTimeOffset date, TimeZoneInfo timeZone) =>
        TimeZoneInfo.ConvertTime(date, timeZone).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);

    private static string List(IEnumerable<string> lines, string none)
    {
        var all = lines.ToList();
        return all.Count == 0 ? $"_{none}_" : string.Join("\n", all);
    }

    /// <summary>
    /// Escapes what would change the structure of one line: emphasis, code, links, HTML, and
    /// line breaks (folded to spaces so an item stays one item).
    /// </summary>
    internal static string EscapeInline(string text)
    {
        var output = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            switch (c)
            {
                case '\n' or '\r':
                    output.Append(' ');
                    break;
                case '\\' or '`' or '*' or '_' or '[' or ']' or '<' or '>' or '#' or '|':
                    output.Append('\\').Append(c);
                    break;
                default:
                    output.Append(c);
                    break;
            }
        }

        return output.ToString().Trim(' ', '\t');
    }

    /// <summary>Prose paragraphs: inline escaping per paragraph, paragraph breaks kept.</summary>
    internal static string EscapeBlock(string text) => string.Join("\n\n",
        text.Split("\n\n").Select(p => EscapeInline(p.Replace('\n', ' '))).Where(p => p.Length > 0));

    private sealed record Labels(
        string Date, string Duration, string Participants, string Recap, string NextSteps, string Decisions,
        string OpenQuestions, string MyNotes, string Transcript, string Due, string None, string NoNotes, string Untitled)
    {
        public static Labels For(NotesLanguage language) => language == NotesLanguage.French
            ? new("Date", "Durée", "Participants", "Récapitulatif", "Prochaines étapes", "Décisions", "Questions ouvertes",
                "Mes notes", "Transcription", "échéance", "Aucune.", "Aucune note n'a été générée pour cette réunion.",
                "Réunion sans titre")
            : new("Date", "Duration", "Participants", "Recap", "Next steps", "Decisions", "Open questions",
                "My notes", "Transcript", "due", "None.", "No notes were generated for this meeting.", "Untitled meeting");
    }
}

/// <summary>
/// The meeting as notes and exports see it. Port of <c>MeetingNotesAdapter.swift</c>: the one
/// place that turns <see cref="MeetingRecord"/> into display-named lines.
/// </summary>
public static class MeetingExport
{
    /// <summary>The transcript as display-named lines, in time order.</summary>
    public static IReadOnlyList<TranscriptLine> Lines(this MeetingRecord meeting)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        return [.. meeting.Segments.OrderBy(s => s.Start).Select(s =>
            new TranscriptLine(s.Start, meeting.SpeakerById(s.SpeakerId)?.DisplayName ?? s.SpeakerId, s.Text))];
    }

    /// <summary>Display names of the people who spoke, in order of first appearance; every known speaker when nothing was said.</summary>
    public static IReadOnlyList<string> ParticipantNames(this MeetingRecord meeting)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        var names = new List<string>();
        foreach (var line in meeting.Lines())
        {
            if (!names.Contains(line.Speaker)) names.Add(line.Speaker);
        }

        return names.Count == 0 ? [.. meeting.Speakers.Select(s => s.DisplayName)] : names;
    }

    /// <summary>The language headings follow.</summary>
    public static NotesLanguage NotesLanguage(this MeetingRecord meeting)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        return NotesLanguages.Detect(meeting.Language, string.Join(' ', meeting.Segments.Take(300).Select(s => s.Text)));
    }

    /// <summary>The whole meeting as a Markdown document.</summary>
    public static string Markdown(this MeetingRecord meeting, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        return MarkdownRenderer.Render(new MarkdownMeeting
        {
            Title = meeting.Title,
            StartedAt = meeting.StartedAt,
            Duration = meeting.Duration.TotalSeconds,
            Participants = meeting.ParticipantNames(),
            Language = meeting.NotesLanguage(),
            Notes = meeting.Notes is { } notes ? FinalNotesDraft.From(notes) : null,
            UserNotes = meeting.UserNotes,
            Transcript = meeting.Lines(),
            TimeZone = timeZone,
        });
    }

    /// <summary>The export's file name.</summary>
    public static string MarkdownFilename(this MeetingRecord meeting, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        return MarkdownRenderer.Filename(meeting.Title, meeting.StartedAt, timeZone);
    }

    /// <summary>
    /// Renames a speaker everywhere in this meeting. Segments refer to speakers by id, so renaming
    /// the speaker renames every line; next-step owners that used the old display name follow.
    /// The name is marked as the user's, which nothing inferred may overwrite. An empty name
    /// clears it.
    /// </summary>
    public static MeetingRecord RenameSpeaker(this MeetingRecord meeting, string id, string newName)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        ArgumentNullException.ThrowIfNull(newName);
        var speakers = meeting.Speakers.ToList();
        var index = speakers.FindIndex(s => s.Id == id);
        if (index < 0)
        {
            // A segment can name a speaker the list never got.
            speakers.Add(new Speaker(id));
            index = speakers.Count - 1;
        }

        var oldName = speakers[index].DisplayName;
        var trimmed = newName.Trim();
        speakers[index] = speakers[index] with
        {
            Name = trimmed.Length == 0 ? null : trimmed,
            NameSource = trimmed.Length == 0 ? null : NameSource.User,
        };
        var newDisplayName = speakers[index].DisplayName;

        var notes = meeting.Notes;
        if (notes is not null && newDisplayName != oldName)
        {
            notes = notes with
            {
                NextSteps = [.. notes.NextSteps.Select(a => a.Owner == oldName ? a with { Owner = newDisplayName } : a)],
            };
        }

        return meeting with { Speakers = speakers, Notes = notes };
    }
}
