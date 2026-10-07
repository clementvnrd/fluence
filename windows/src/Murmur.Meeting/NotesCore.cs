using System.Globalization;

namespace Murmur.Meeting;

/// <summary>
/// The language notes and exports are written in. Port of <c>NotesLanguage.swift</c>: the notes
/// follow the two languages this app is used in.
/// </summary>
public enum NotesLanguage
{
    /// <summary>English.</summary>
    English,

    /// <summary>French.</summary>
    French,
}

/// <summary>Detects <see cref="NotesLanguage"/>.</summary>
public static class NotesLanguages
{
    // Function words frequent in one language and rare in the other. Words both languages
    // share ("a", "on", "pour" as an English surname…) are left out on purpose.
    private static readonly HashSet<string> FrenchMarkers = new(StringComparer.Ordinal)
    {
        "le", "la", "les", "des", "est", "et", "je", "vous", "nous", "que", "qui", "pas",
        "une", "du", "c'est", "c’est", "ça", "dans", "avec", "sur", "mais", "il", "elle",
        "cette", "oui", "alors", "donc", "aussi", "très", "bien", "faire", "j'ai", "j’ai",
    };

    private static readonly HashSet<string> EnglishMarkers = new(StringComparer.Ordinal)
    {
        "the", "is", "and", "i", "you", "we", "that", "it", "to", "of", "for", "with",
        "but", "this", "yes", "so", "are", "have", "be", "not", "what", "it's", "i'm",
        "will", "can", "they", "do", "just",
    };

    /// <summary>
    /// Uses the meeting's BCP-47 tag when it names English or French, otherwise counts function
    /// words in the first 6,000 characters of <paramref name="sample"/>. Ties go to English.
    /// </summary>
    public static NotesLanguage Detect(string? bcp47, string sample)
    {
        ArgumentNullException.ThrowIfNull(sample);
        if (bcp47?.ToLowerInvariant() is { } tag)
        {
            if (tag == "fr" || tag.StartsWith("fr-", StringComparison.Ordinal) || tag.StartsWith("fr_", StringComparison.Ordinal))
            {
                return NotesLanguage.French;
            }

            if (tag == "en" || tag.StartsWith("en-", StringComparison.Ordinal) || tag.StartsWith("en_", StringComparison.Ordinal))
            {
                return NotesLanguage.English;
            }
        }

        var french = 0;
        var english = 0;
        foreach (var word in Words(sample.Length > 6_000 ? sample[..6_000] : sample))
        {
            if (FrenchMarkers.Contains(word)) french++;
            if (EnglishMarkers.Contains(word)) english++;
        }

        return french > english ? NotesLanguage.French : NotesLanguage.English;
    }

    private static IEnumerable<string> Words(string text)
    {
        var lower = text.ToLowerInvariant();
        var start = -1;
        for (var i = 0; i <= lower.Length; i++)
        {
            var inWord = i < lower.Length && (char.IsLetter(lower[i]) || lower[i] is '\'' or '’');
            if (inWord && start < 0) start = i;
            else if (!inWord && start >= 0)
            {
                yield return lower[start..i];
                start = -1;
            }
        }
    }
}

/// <summary>
/// The one-click notice the user pastes into the meeting chat before recording. Port of
/// <c>ConsentNotice.swift</c>, word for word.
/// </summary>
/// <remarks>
/// Recording a private conversation without consent is an offence in France (Code pénal
/// art. 226-1) and needs a lawful basis under the GDPR; telling people, and offering to stop, is
/// the minimum. The wording is plain on purpose: it says what happens (notes, locally), what does
/// not (nothing goes online), and how to object.
/// </remarks>
public static class ConsentNotice
{
    /// <summary>The notice in <paramref name="language"/>.</summary>
    public static string Text(NotesLanguage language) => language switch
    {
        NotesLanguage.French =>
            "Je prends des notes de cette réunion avec Fluence, en local sur mon ordinateur : "
            + "rien n'est envoyé sur Internet. Dites-le-moi si vous préférez que je n'enregistre pas.",
        _ =>
            "I'm taking notes of this meeting with Fluence, locally on my computer: nothing is "
            + "sent over the Internet. Let me know if you'd rather I didn't record.",
    };

    /// <summary>French then English, for meetings where both are spoken.</summary>
    public static string Bilingual => Text(NotesLanguage.French) + "\n\n" + Text(NotesLanguage.English);
}

/// <summary>One transcript utterance, already attributed to a display name.</summary>
/// <param name="Start">Seconds from the meeting start.</param>
/// <param name="Speaker">Display name: "You", "Marie", "Speaker 2".</param>
/// <param name="Text">What was said.</param>
public sealed record TranscriptLine(double Start, string Speaker, string Text)
{
    /// <summary>The line as a model reads it: <c>[mm:ss] Name: text</c>.</summary>
    public string Rendered => $"[{MeetingRecord.Clock(Start)}] {Speaker}: {Text}";
}

/// <summary>A meeting length in words, for the list and the export: "45 min", "1 h 05 min".</summary>
public static class DurationText
{
    /// <summary>Formats <paramref name="seconds"/>.</summary>
    public static string Format(double seconds)
    {
        var minutes = double.IsFinite(seconds) ? Math.Max(0, (long)Math.Round(seconds / 60, MidpointRounding.AwayFromZero)) : 0;
        if (seconds > 0 && minutes == 0) return "< 1 min";
        if (minutes < 60) return string.Create(CultureInfo.InvariantCulture, $"{minutes} min");
        return string.Create(CultureInfo.InvariantCulture, $"{minutes / 60} h {minutes % 60:00} min");
    }
}

/// <summary>A task someone agreed to do.</summary>
public sealed record ActionDraft(string Text, string? Owner = null, string? Due = null);

/// <summary>What a notes model writes: the final notes, before they become <see cref="MeetingNotes"/>.</summary>
public sealed record FinalNotesDraft
{
    /// <summary>A few short paragraphs.</summary>
    public string Recap { get; init; } = string.Empty;

    /// <summary>Tasks, with owners and due dates when said.</summary>
    public IReadOnlyList<ActionDraft> NextSteps { get; init; } = [];

    /// <summary>What was decided.</summary>
    public IReadOnlyList<string> Decisions { get; init; } = [];

    /// <summary>What was left open.</summary>
    public IReadOnlyList<string> OpenQuestions { get; init; } = [];

    /// <summary>Whether nothing was written at all.</summary>
    public bool IsEmpty => Recap.Length == 0 && NextSteps.Count == 0 && Decisions.Count == 0 && OpenQuestions.Count == 0;

    /// <summary>The draft of stored notes.</summary>
    public static FinalNotesDraft From(MeetingNotes notes)
    {
        ArgumentNullException.ThrowIfNull(notes);
        return new FinalNotesDraft
        {
            Recap = notes.Recap,
            NextSteps = [.. notes.NextSteps.Select(a => new ActionDraft(a.Text, a.Owner, a.Due))],
            Decisions = notes.Decisions,
            OpenQuestions = notes.OpenQuestions,
        };
    }

    /// <summary>Stored notes from this draft.</summary>
    public MeetingNotes ToNotes(DateTimeOffset generatedAt, string model) => new()
    {
        Recap = Recap,
        NextSteps = [.. NextSteps.Select(a => new ActionItem(a.Text, a.Owner, a.Due))],
        Decisions = Decisions,
        OpenQuestions = OpenQuestions,
        GeneratedAt = generatedAt,
        Model = model,
    };
}

/// <summary>How long meetings are kept. Port of <c>RetentionChoice</c>; the value is the number of days.</summary>
public enum RetentionChoice
{
    /// <summary>Never deleted automatically.</summary>
    Forever = 0,

    /// <summary>7 days.</summary>
    Week = 7,

    /// <summary>30 days.</summary>
    Month = 30,

    /// <summary>90 days.</summary>
    Quarter = 90,

    /// <summary>One year.</summary>
    Year = 365,
}

/// <summary>Retention arithmetic. Port of <c>Retention.swift</c>.</summary>
public static class Retention
{
    /// <summary>Every choice, in menu order.</summary>
    public static IReadOnlyList<RetentionChoice> Choices { get; } =
        [RetentionChoice.Forever, RetentionChoice.Week, RetentionChoice.Month, RetentionChoice.Quarter, RetentionChoice.Year];

    /// <summary>Null keeps everything.</summary>
    public static int? Days(this RetentionChoice choice) => choice == RetentionChoice.Forever ? null : (int)choice;

    /// <summary>The choice for a stored value; null when it is not one of the presets.</summary>
    public static RetentionChoice? Choice(int? days) =>
        days is not > 0 ? RetentionChoice.Forever
        : Enum.IsDefined((RetentionChoice)days.Value) ? (RetentionChoice)days.Value
        : null;

    /// <summary>What the settings menu says.</summary>
    public static string Title(this RetentionChoice choice) => choice switch
    {
        RetentionChoice.Week => "7 days",
        RetentionChoice.Month => "30 days",
        RetentionChoice.Quarter => "90 days",
        RetentionChoice.Year => "1 year",
        _ => "Forever",
    };

    /// <summary>Meetings that started before this are deleted: whole 24-hour days back from <paramref name="now"/>.</summary>
    public static DateTimeOffset? Cutoff(int? days, DateTimeOffset now) =>
        days is > 0 ? now.AddSeconds(-days.Value * 86_400.0) : null;

    /// <summary>How many of <paramref name="dates"/> a retention of <paramref name="days"/> would delete now.</summary>
    public static int ExpiredCount(IEnumerable<DateTimeOffset> dates, int? days, DateTimeOffset now) =>
        Cutoff(days, now) is { } cutoff ? dates.Count(d => d < cutoff) : 0;
}
