using System.Globalization;
using System.Text.Json.Serialization;

namespace Murmur.Meeting;

// The Notetaker's data model: a C# port of Sources/FluenceMeetingCore/MeetingModel.swift.
// Plain data — the capture pipeline produces it, the store encrypts it, notes and UI read it.
// Design: docs/NOTETAKER.md.
//
// Swift's `Meeting` is `MeetingRecord` here: a type named Meeting inside the namespace
// Murmur.Meeting would be shadowed by the namespace itself from every other Murmur.* namespace
// (CS0118), and "record" matches the dictation side's TranscriptRecord.

/// <summary>
/// Which physical stream a piece of speech came from. The microphone is the user; the system
/// stream is everyone else. Only the system stream is ever diarized.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<AudioSource>))]
public enum AudioSource
{
    /// <summary>The user's microphone.</summary>
    [JsonStringEnumMemberName("microphone")]
    Microphone,

    /// <summary>What the meeting app plays: the remote participants.</summary>
    [JsonStringEnumMemberName("system")]
    System,
}

/// <summary>Where a speaker's name came from, most trusted first.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<NameSource>))]
public enum NameSource
{
    /// <summary>Typed or confirmed by the user. Never overwritten by an inference.</summary>
    [JsonStringEnumMemberName("user")]
    User,

    /// <summary>Read from the meeting app's window.</summary>
    [JsonStringEnumMemberName("meetingWindow")]
    MeetingWindow,

    /// <summary>Matched against an enrolled voice print (opt-in).</summary>
    [JsonStringEnumMemberName("voicePrint")]
    VoicePrint,

    /// <summary>The only remaining calendar attendee, by elimination.</summary>
    [JsonStringEnumMemberName("calendar")]
    Calendar,
}

/// <summary>One voice in a meeting.</summary>
/// <param name="Id">Stable within one meeting: <c>me</c>, <c>S?</c> (not yet diarized), or <c>S1</c>, <c>S2</c>…</param>
/// <param name="Name">The display name, when known.</param>
/// <param name="NameSource">Where <paramref name="Name"/> came from.</param>
public sealed record Speaker(string Id, string? Name = null, NameSource? NameSource = null)
{
    /// <summary>The user's id.</summary>
    public const string MeId = "me";

    /// <summary>Remote speech before the final pass has diarized it: everyone on the system stream.</summary>
    public const string OthersId = "S?";

    /// <summary>The provisional "everyone else" speaker used by the live pass.</summary>
    public static Speaker Others { get; } = new(OthersId);

    /// <summary>Whether this is the user.</summary>
    [JsonIgnore]
    public bool IsMe => Id == MeId;

    /// <summary>The user, optionally named (then by the user).</summary>
    public static Speaker Me(string? name = null) => new(MeId, name, name is null ? null : Murmur.Meeting.NameSource.User);

    /// <summary>What the UI prints: the name if known, otherwise "You" / "Others" / "Speaker 2".</summary>
    [JsonIgnore]
    public string DisplayName
    {
        get
        {
            if (!string.IsNullOrEmpty(Name)) return Name;
            if (IsMe) return "You";
            if (Id == OthersId) return "Others";
            return "Speaker " + Id[1..];
        }
    }
}

/// <summary>One recognised word, timed in seconds from the meeting start.</summary>
/// <param name="Text">The word as recognised.</param>
/// <param name="Start">Start, seconds from the meeting start.</param>
/// <param name="End">End, seconds from the meeting start.</param>
/// <param name="Confidence">The recogniser's confidence, when it reports one.</param>
public sealed record Word(string Text, double Start, double End, float? Confidence = null);

/// <summary>One utterance from one source, attributed to one speaker.</summary>
public sealed record TranscriptSegment
{
    /// <summary>Stable identity.</summary>
    public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>Which stream it came from.</summary>
    public AudioSource Source { get; init; }

    /// <summary>The speaker's <see cref="Speaker.Id"/>.</summary>
    public string SpeakerId { get; init; } = Speaker.OthersId;

    /// <summary>Seconds from the meeting start.</summary>
    public double Start { get; init; }

    /// <summary>Seconds from the meeting start.</summary>
    public double End { get; init; }

    /// <summary>The text, after the dictionary's corrections.</summary>
    public string Text { get; init; } = string.Empty;

    /// <summary>Word timings, when the recogniser gave them.</summary>
    public IReadOnlyList<Word> Words { get; init; } = [];

    /// <summary>False while the live pass may still revise it; the final pass sets it true.</summary>
    public bool IsFinal { get; init; }
}

/// <summary>A task someone agreed to do.</summary>
/// <param name="Text">What.</param>
/// <param name="Owner">Who, when said.</param>
/// <param name="Due">By when, as said.</param>
public sealed record ActionItem(string Text, string? Owner = null, string? Due = null);

/// <summary>
/// The generated notes. Absent until a summariser has run, and never invented when no
/// model is available.
/// </summary>
public sealed record MeetingNotes
{
    /// <summary>A short prose recap.</summary>
    public string Recap { get; init; } = string.Empty;

    /// <summary>Action items.</summary>
    public IReadOnlyList<ActionItem> NextSteps { get; init; } = [];

    /// <summary>What was decided.</summary>
    public IReadOnlyList<string> Decisions { get; init; } = [];

    /// <summary>What stayed open.</summary>
    public IReadOnlyList<string> OpenQuestions { get; init; } = [];

    /// <summary>When they were written.</summary>
    public DateTimeOffset GeneratedAt { get; init; }

    /// <summary>Which model wrote them.</summary>
    public string Model { get; init; } = string.Empty;
}

/// <summary>How a recording was started.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<MeetingTrigger>))]
public enum MeetingTrigger
{
    /// <summary>From the "Meeting detected" card.</summary>
    [JsonStringEnumMemberName("detected")]
    Detected,

    /// <summary>Started by hand.</summary>
    [JsonStringEnumMemberName("manual")]
    Manual,

    /// <summary>From a calendar event.</summary>
    [JsonStringEnumMemberName("calendar")]
    Calendar,
}

/// <summary>One meeting: who spoke, what was said, and the notes. Swift's <c>Meeting</c>.</summary>
public sealed record MeetingRecord
{
    /// <summary>Stable identity; also names the meeting's files and key.</summary>
    public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>The title the user sees.</summary>
    public string Title { get; init; } = string.Empty;

    /// <summary>
    /// The meeting app: a bundle ID on macOS, a process image name (<c>Zoom.exe</c>) on Windows.
    /// </summary>
    public string? AppId { get; init; }

    /// <summary>How the recording started.</summary>
    public MeetingTrigger Trigger { get; init; } = MeetingTrigger.Manual;

    /// <summary>When recording started.</summary>
    public DateTimeOffset StartedAt { get; init; }

    /// <summary>When recording ended; null while recording.</summary>
    public DateTimeOffset? EndedAt { get; init; }

    /// <summary>Calendar attendees (display names), the user excluded. Empty on Windows for now.</summary>
    public IReadOnlyList<string> Attendees { get; init; } = [];

    /// <summary>The voices, the user first.</summary>
    public IReadOnlyList<Speaker> Speakers { get; init; } = [Speaker.Me()];

    /// <summary>Time-ordered, both sources merged.</summary>
    public IReadOnlyList<TranscriptSegment> Segments { get; init; } = [];

    /// <summary>What the user typed during the meeting.</summary>
    public string UserNotes { get; init; } = string.Empty;

    /// <summary>The generated notes, if any.</summary>
    public MeetingNotes? Notes { get; init; }

    /// <summary>Decision FLU-9 #2: audio is deleted after processing unless this is set.</summary>
    public bool KeepAudio { get; init; }

    /// <summary>BCP-47 code of the dominant language, when known.</summary>
    public string? Language { get; init; }

    /// <summary>How long it lasted; zero while still recording.</summary>
    [JsonIgnore]
    public TimeSpan Duration => (EndedAt ?? StartedAt) - StartedAt;

    /// <summary>The speaker with <paramref name="id"/>, if present.</summary>
    public Speaker? SpeakerById(string id) => Speakers.FirstOrDefault(s => s.Id == id);

    /// <summary>The full transcript as plain text, one line per segment: <c>[mm:ss] Name: text</c>.</summary>
    [JsonIgnore]
    public string TranscriptText => string.Join("\n", Segments.Select(segment =>
    {
        var name = SpeakerById(segment.SpeakerId)?.DisplayName ?? segment.SpeakerId;
        return $"[{Clock(segment.Start)}] {name}: {segment.Text}";
    }));

    /// <summary>Tape-counter time: <c>mm:ss</c>, or <c>h:mm:ss</c> from one hour.</summary>
    public static string Clock(double seconds)
    {
        var total = double.IsFinite(seconds) ? Math.Max(0, (long)Math.Floor(seconds)) : 0;
        var (h, m, s) = (total / 3600, total % 3600 / 60, total % 60);
        return h > 0
            ? string.Create(CultureInfo.InvariantCulture, $"{h}:{m:00}:{s:00}")
            : string.Create(CultureInfo.InvariantCulture, $"{m:00}:{s:00}");
    }
}

/// <summary>What the meetings list needs, without holding every transcript.</summary>
public sealed record MeetingSummary
{
    /// <summary>Builds the summary of <paramref name="meeting"/>.</summary>
    public MeetingSummary(MeetingRecord meeting)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        Id = meeting.Id;
        Title = meeting.Title;
        StartedAt = meeting.StartedAt;
        Duration = meeting.Duration;
        SpeakerNames = [.. meeting.Speakers.Select(s => s.DisplayName)];
        HasNotes = meeting.Notes is not null;
    }

    /// <summary>Rebuilds a summary from the stored index.</summary>
    [JsonConstructor]
    public MeetingSummary(Guid id, string title, DateTimeOffset startedAt, TimeSpan duration,
        IReadOnlyList<string> speakerNames, bool hasNotes)
    {
        Id = id;
        Title = title;
        StartedAt = startedAt;
        Duration = duration;
        SpeakerNames = speakerNames ?? [];
        HasNotes = hasNotes;
    }

    /// <summary>The meeting's id.</summary>
    public Guid Id { get; }

    /// <summary>Its title.</summary>
    public string Title { get; }

    /// <summary>When it started.</summary>
    public DateTimeOffset StartedAt { get; }

    /// <summary>How long it lasted.</summary>
    public TimeSpan Duration { get; }

    /// <summary>Display names, the user first.</summary>
    public IReadOnlyList<string> SpeakerNames { get; }

    /// <summary>Whether notes were generated.</summary>
    public bool HasNotes { get; }
}

/// <summary>Source-generated JSON for the meeting model (trimming- and single-file-safe).</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(MeetingRecord))]
[JsonSerializable(typeof(List<MeetingRecord>))]
[JsonSerializable(typeof(List<MeetingSummary>))]
public sealed partial class MeetingJsonContext : JsonSerializerContext;
