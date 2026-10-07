using System.Text.Json;
using Murmur.Meeting;
using Shouldly;
using Xunit;

namespace Murmur.MeetingTests;

/// <summary>
/// Ports of the macOS unit tests (<c>Tests/FluenceMeetingCoreTests/MeetingCoreTests.swift</c>)
/// for the pieces the shared vectors do not cover. Same inputs, same expected outputs.
/// </summary>
public sealed class UtteranceSegmenterTests
{
    private const int Hop = 4_096;
    private const int Pad = 1_600;

    private static List<Utterance> Run(float[] probabilities, UtteranceSegmenterConfig? config = null)
    {
        var segmenter = new UtteranceSegmenter(config);
        var result = probabilities.SelectMany(segmenter.Push).ToList();
        result.AddRange(segmenter.Finish());
        return result;
    }

    [Fact]
    public void Speech_closes_after_enough_silence_padded_both_sides() =>
        Run([0, 0, 0.9f, 0.9f, 0.9f, 0.1f, 0.1f, 0])
            .ShouldBe([new Utterance((2 * Hop) - Pad, (5 * Hop) + Pad)]);

    [Fact]
    public void A_dip_between_the_two_thresholds_does_not_end_an_utterance() =>
        Run([0.9f, 0.4f, 0.4f, 0.4f, 0.9f, 0.1f, 0.1f])
            .ShouldBe([new Utterance(0, (5 * Hop) + Pad)]);

    [Fact]
    public void Long_speech_is_cut_at_its_least_probable_hop_and_continues()
    {
        // 14.5 s cap = 57 hops. The first cut lands on the dip at hop 40; the second, with no
        // dip, on the latest hop of the second half.
        var probabilities = Enumerable.Repeat(0.9f, 100).ToArray();
        probabilities[40] = 0.5f;
        var utterances = Run(probabilities);

        utterances.ShouldBe(
        [
            new Utterance(0, 40 * Hop),
            new Utterance(40 * Hop, 96 * Hop),
            new Utterance(96 * Hop, 100 * Hop),
        ]);
        utterances.ShouldAllBe(u => u.SampleCount <= 240_000);
    }

    [Fact]
    public void Bursts_shorter_than_the_minimum_are_dropped() =>
        Run([0, 0.9f, 0, 0, 0], new UtteranceSegmenterConfig { MinSpeech = 0.5 }).ShouldBeEmpty();

    [Fact]
    public void An_utterance_open_at_the_end_of_the_stream_is_flushed() =>
        Run([0, 0.9f, 0.9f]).ShouldBe([new Utterance(Hop - Pad, 3 * Hop)]);

    [Fact]
    public void Windows_hop_size_keeps_the_cap_under_one_parakeet_pass()
    {
        // The Windows pipeline feeds sherpa-onnx's Silero in 512-sample windows.
        var config = new UtteranceSegmenterConfig { HopSamples = 512 };
        var utterances = Run([.. Enumerable.Repeat(1f, 1_000)], config);
        utterances.Count.ShouldBeGreaterThan(1);
        utterances.ShouldAllBe(u => u.SampleCount <= 240_000);
    }
}

public sealed class TimelineAlignerTests
{
    [Fact]
    public void Jitter_is_absorbed_gaps_are_padded_overlaps_trimmed()
    {
        var aligner = new TimelineAligner(16_000, 0.12);
        aligner.Place(0, 1_600).ShouldBe(new Placement(0, 0));
        aligner.Place(0.15, 1_600).ShouldBe(new Placement(0, 0));
        aligner.Written.ShouldBe(3_200);
        aligner.Place(1.0, 1_600).ShouldBe(new Placement(12_800, 0));
        aligner.Written.ShouldBe(17_600);
        aligner.Place(0.5, 1_600).ShouldBe(new Placement(0, 1_600));
        aligner.Written.ShouldBe(17_600);
        aligner.PadUntil(2.0).ShouldBe(32_000 - 17_600);
        aligner.PadUntil(2.05).ShouldBe(0);
    }
}

public sealed class StopPolicyTests
{
    private readonly StopPolicy _policy = new(3 * 3600);

    [Fact]
    public void Call_ended_after_30_s_without_the_app_on_the_mic()
    {
        _policy.Reason(100, 99, 75).ShouldBeNull();
        _policy.Reason(105, 104, 75).ShouldBe(StopReason.CallEnded);
        _policy.Reason(105, 104, null).ShouldBeNull();
    }

    [Fact]
    public void Ten_minutes_of_silence_and_the_hard_cap()
    {
        _policy.Reason(700, 99, 700).ShouldBe(StopReason.Silence);
        _policy.Reason(599, null, null).ShouldBeNull();
        _policy.Reason(600, null, null).ShouldBe(StopReason.Silence);
        _policy.Reason(3 * 3600, 3 * 3600, null).ShouldBe(StopReason.MaxDuration);
    }
}

public sealed class HungarianTests
{
    private static IReadOnlyList<int?> Assign(double[][] cost) =>
        Hungarian.Assign([.. cost.Select(r => (IReadOnlyList<double>)r)]);

    [Fact]
    public void Square_matrix_finds_the_global_optimum_not_greedy() =>
        Assign([[4, 1, 3], [2, 0, 5], [3, 2, 2]]).ShouldBe([1, 0, 2]);

    [Fact]
    public void More_rows_than_columns_leaves_the_worst_row_out() =>
        Assign([[1, 9], [9, 1], [5, 5]]).ShouldBe([0, 1, null]);

    [Fact]
    public void More_columns_than_rows() => Assign([[3, 1, 2]]).ShouldBe([1]);

    [Fact]
    public void Empty_input()
    {
        Assign([]).ShouldBeEmpty();
        Assign([[]]).ShouldBe([null]);
    }
}

public sealed class WordBuilderTests
{
    [Fact]
    public void Sub_word_tokens_join_on_the_boundary_marker_with_the_offset_applied()
    {
        TimedToken[] tokens =
        [
            new("▁Bon", 0.0, 0.2, 0.9f),
            new("jour", 0.2, 0.4, 0.7f),
            new("<blank>", 0.4, 0.4, 1),
            new("▁à", 0.5, 0.6, 0.95f),
            new(" tous", 0.6, 0.9, 0.8f),
            new(".", 0.9, 0.95, 0.99f),
        ];
        var words = WordBuilder.Words(tokens, 10);

        words.Select(w => w.Text).ShouldBe(["Bonjour", "à", "tous."]);
        words[0].Start.ShouldBe(10.0);
        words[0].End.ShouldBe(10.4);
        words[0].Confidence.ShouldBe(0.7f);
        words[2].End.ShouldBe(10.95);
    }
}

public sealed class MeetingTitlesTests
{
    [Fact]
    public void Browser_window_titles_that_are_calls()
    {
        MeetingTitles.MeetingService("Meet – abc-defg-hij").ShouldBe("Google Meet");
        MeetingTitles.MeetingService("Meeting with Ada | Microsoft Teams").ShouldBe("Microsoft Teams");
        MeetingTitles.MeetingService("Inbox (3) - Gmail").ShouldBeNull();
        MeetingTitles.MeetingService("YouTube").ShouldBeNull();
    }

    [Fact]
    public void Windows_browser_titles_carry_the_browser_suffix_and_still_match()
    {
        MeetingTitles.MeetingService("Meet – abc-defg-hij - Google Chrome").ShouldBe("Google Meet");
        MeetingTitles.MeetingService("Chat | Microsoft Teams - Microsoft Edge").ShouldBe("Microsoft Teams");
        MeetingTitles.MeetingService("Zoom Meeting - Mozilla Firefox").ShouldBe("Zoom");
        MeetingTitles.MeetingService("Inbox - Outlook - Microsoft Edge").ShouldBeNull();
    }

    [Fact]
    public void Conferencing_links_in_calendar_events()
    {
        MeetingTitles.ConferencingService("Join: https://us02web.zoom.us/j/123456").ShouldBe("Zoom");
        MeetingTitles.ConferencingService("https://meet.google.com/abc-defg-hij").ShouldBe("Google Meet");
        MeetingTitles.ConferencingService("Room 4B").ShouldBeNull();
    }

    [Fact]
    public void Participant_lists_are_cleaned_of_markers_controls_and_the_user()
    {
        string[] raw = ["Ada Lovelace (Host)", "Mute", "Bob (Guest)", "bob", "12", "Clément Veniard",
                        "Zoé (Hôte, moi)", "Grace Hopper"];
        ParticipantNames.Clean(raw, ["clement veniard"]).ShouldBe(["Ada Lovelace", "Bob", "Grace Hopper"]);
    }
}

public sealed class MeetingModelTests
{
    [Fact]
    public void Display_names()
    {
        Speaker.Me().DisplayName.ShouldBe("You");
        Speaker.Others.DisplayName.ShouldBe("Others");
        new Speaker("S2").DisplayName.ShouldBe("Speaker 2");
        new Speaker("S2", "Ada", NameSource.VoicePrint).DisplayName.ShouldBe("Ada");
        Speaker.Me("Clément").NameSource.ShouldBe(NameSource.User);
    }

    [Fact]
    public void A_meeting_round_trips_through_source_generated_json()
    {
        var meeting = new MeetingRecord
        {
            Title = "Weekly",
            StartedAt = DateTimeOffset.FromUnixTimeSeconds(1_000),
            Speakers = [Speaker.Me(), new Speaker("S1")],
            Segments =
            [
                new TranscriptSegment
                {
                    Source = AudioSource.System,
                    SpeakerId = "S1",
                    Start = 1,
                    End = 2,
                    Text = "Hi",
                    Words = [new Word("Hi", 1, 1.4, 0.9f)],
                },
            ],
        };

        var json = JsonSerializer.Serialize(meeting, MeetingJsonContext.Default.MeetingRecord);
        json.ShouldContain("\"source\":\"system\"");
        var decoded = JsonSerializer.Deserialize(json, MeetingJsonContext.Default.MeetingRecord).ShouldNotBeNull();

        decoded.Id.ShouldBe(meeting.Id);
        decoded.Segments.Single().Words.Single().ShouldBe(meeting.Segments[0].Words[0]);
        decoded.TranscriptText.ShouldBe("[00:01] Speaker 1: Hi");
    }

    [Fact]
    public void Clock_formats_like_a_tape_counter()
    {
        MeetingRecord.Clock(0).ShouldBe("00:00");
        MeetingRecord.Clock(75.9).ShouldBe("01:15");
        MeetingRecord.Clock(3_725).ShouldBe("1:02:05");
        MeetingRecord.Clock(-3).ShouldBe("00:00");
    }
}
