using System.Text.Json;
using Murmur.Meeting;
using Shouldly;
using Xunit;

namespace Murmur.MeetingTests;

/// <summary>
/// Runs the shared contract in <c>shared/meeting-test-vectors.json</c> — the identical file the
/// macOS side runs through FluenceMeetingCore (<c>MeetingVectorTests.swift</c>).
/// </summary>
/// <remarks>
/// Comparisons are on values, not on formatted strings: Swift prints <c>10.0</c> where .NET
/// prints <c>10</c>, and the contract is about the numbers.
/// </remarks>
public sealed class MeetingVectorTests
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private static readonly Vectors TheVectors = Load();

    public sealed record Vectors(
        int Version,
        NormalizationCase[] Normalization,
        MergeCase[] Merge,
        WordSpeakerCase[] WordSpeaker,
        AttributionCase[] Attribution,
        NamingCase[] Naming);

    public sealed record NormalizationCase(string Name, string Input, string[] Tokens);

    public sealed record VectorWord(string Text, double Start, double End)
    {
        public Word ToWord() => new(Text, Start, End);
    }

    public sealed record VectorSegment(string Source, string SpeakerID, double Start, double End, string Text, VectorWord[]? Words)
    {
        public TranscriptSegment ToSegment() => new()
        {
            Source = Source switch
            {
                "microphone" => AudioSource.Microphone,
                "system" => AudioSource.System,
                _ => throw new InvalidDataException($"unknown source {Source}"),
            },
            SpeakerId = SpeakerID,
            Start = Start,
            End = End,
            Text = Text,
            Words = [.. (Words ?? []).Select(w => w.ToWord())],
        };
    }

    public sealed record MergeExpected(string Source, double Start, string Text);

    public sealed record MergeCase(string Name, VectorSegment[] Mic, VectorSegment[] System, MergeExpected[] Expected);

    public sealed record VectorTurn(string Speaker, double Start, double End)
    {
        public SpeakerTurn ToTurn() => new(Speaker, Start, End);
    }

    public sealed record WordSpeakerCase(string Name, VectorTurn[] Turns, VectorWord[] Words, string?[] Expected);

    public sealed record AttributionExpected(string SpeakerID, double Start, double End, string Text);

    public sealed record AttributionCase(
        string Name,
        string FallbackID,
        VectorTurn[] Turns,
        VectorSegment[] Segments,
        AttributionExpected[] Expected,
        Dictionary<string, string> Labels);

    public sealed record VectorSpeaker(string Id, string? Name, string? NameSource);

    public sealed record NamingCase(
        string Name,
        VectorSpeaker[] Speakers,
        string[] WindowParticipants,
        string[] Attendees,
        Dictionary<string, Dictionary<string, double>> VoicePrintSimilarity,
        VectorSpeaker[] Expected);

    private static Vectors Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "meeting-test-vectors.json");
        return JsonSerializer.Deserialize<Vectors>(File.ReadAllText(path), JsonOptions)
               ?? throw new InvalidOperationException("Meeting vectors failed to deserialize.");
    }

    public static TheoryData<string> NormalizationNames() => [.. TheVectors.Normalization.Select(c => c.Name)];

    public static TheoryData<string> MergeNames() => [.. TheVectors.Merge.Select(c => c.Name)];

    public static TheoryData<string> WordSpeakerNames() => [.. TheVectors.WordSpeaker.Select(c => c.Name)];

    public static TheoryData<string> AttributionNames() => [.. TheVectors.Attribution.Select(c => c.Name)];

    public static TheoryData<string> NamingNames() => [.. TheVectors.Naming.Select(c => c.Name)];

    [Fact]
    public void The_contract_is_version_1_and_every_section_has_cases()
    {
        TheVectors.Version.ShouldBe(1);
        TheVectors.Normalization.ShouldNotBeEmpty();
        TheVectors.Merge.ShouldNotBeEmpty();
        TheVectors.WordSpeaker.ShouldNotBeEmpty();
        TheVectors.Attribution.ShouldNotBeEmpty();
        TheVectors.Naming.ShouldNotBeEmpty();
    }

    [Theory]
    [MemberData(nameof(NormalizationNames))]
    public void Normalisation(string name)
    {
        var testCase = TheVectors.Normalization.Single(c => c.Name == name);
        TextTokens.Normalize(testCase.Input).ShouldBe(testCase.Tokens, name);
    }

    [Theory]
    [MemberData(nameof(MergeNames))]
    public void Merge(string name)
    {
        var testCase = TheVectors.Merge.Single(c => c.Name == name);
        var merged = TranscriptMerger.Merge(
            [.. testCase.Mic.Select(s => s.ToSegment())],
            [.. testCase.System.Select(s => s.ToSegment())]);

        var actual = merged.Select(s => (Source: s.Source == AudioSource.Microphone ? "microphone" : "system", s.Start, s.Text));
        var expected = testCase.Expected.Select(e => (e.Source, e.Start, e.Text));
        actual.ShouldBe(expected, name);
    }

    [Theory]
    [MemberData(nameof(WordSpeakerNames))]
    public void Word_speaker(string name)
    {
        var testCase = TheVectors.WordSpeaker.Single(c => c.Name == name);
        var actual = SpeakerAssignment.SpeakersFor(
            [.. testCase.Words.Select(w => w.ToWord())],
            [.. testCase.Turns.Select(t => t.ToTurn())]);
        actual.ShouldBe(testCase.Expected, name);
    }

    [Theory]
    [MemberData(nameof(AttributionNames))]
    public void Attribution(string name)
    {
        var testCase = TheVectors.Attribution.Single(c => c.Name == name);
        var result = SpeakerAssignment.Attribute(
            [.. testCase.Segments.Select(s => s.ToSegment())],
            [.. testCase.Turns.Select(t => t.ToTurn())],
            testCase.FallbackID);

        result.Segments.Select(s => (s.SpeakerId, s.Start, s.End, s.Text))
            .ShouldBe(testCase.Expected.Select(e => (e.SpeakerID, e.Start, e.End, e.Text)), name);
        result.Labels.OrderBy(p => p.Key, StringComparer.Ordinal)
            .ShouldBe(testCase.Labels.OrderBy(p => p.Key, StringComparer.Ordinal), name);
    }

    [Theory]
    [MemberData(nameof(NamingNames))]
    public void Naming(string name)
    {
        var testCase = TheVectors.Naming.Single(c => c.Name == name);
        var speakers = testCase.Speakers.Select(s => new Speaker(s.Id, s.Name, ParseSource(s.NameSource))).ToList();

        var named = SpeakerNaming.Name(speakers, new NamingCandidates
        {
            WindowParticipants = testCase.WindowParticipants,
            Attendees = testCase.Attendees,
            VoicePrintSimilarity = testCase.VoicePrintSimilarity.ToDictionary(
                p => p.Key, p => (IReadOnlyDictionary<string, double>)p.Value),
        });

        named.Select(s => (s.Id, s.Name, Source: FormatSource(s.NameSource)))
            .ShouldBe(testCase.Expected.Select(e => (e.Id, e.Name, Source: e.NameSource)), name);
    }

    private static NameSource? ParseSource(string? raw) => raw switch
    {
        null => null,
        "user" => NameSource.User,
        "meetingWindow" => NameSource.MeetingWindow,
        "voicePrint" => NameSource.VoicePrint,
        "calendar" => NameSource.Calendar,
        _ => throw new InvalidDataException($"unknown name source {raw}"),
    };

    private static string? FormatSource(NameSource? source) => source switch
    {
        null => null,
        NameSource.User => "user",
        NameSource.MeetingWindow => "meetingWindow",
        NameSource.VoicePrint => "voicePrint",
        NameSource.Calendar => "calendar",
        _ => throw new InvalidDataException($"unknown name source {source}"),
    };
}
