using Murmur.Speech;
using Shouldly;
using Xunit;

namespace Murmur.SpeechTests;

/// <summary>Token timings from sherpa-onnx's arrays, and the meeting models' manifests.</summary>
public sealed class MeetingSpeechTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fluence-meeting-models-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    [Fact]
    public void Durations_bound_tokens_when_the_model_reports_them()
    {
        var timed = SherpaTokens.Timed(["▁Bon", "jour"], [0.0f, 0.24f], [0.16f, 0.24f], 1.0);
        timed.Select(t => (t.Text, Math.Round(t.Start, 2), Math.Round(t.End, 2)))
            .ShouldBe([("▁Bon", 0.0, 0.16), ("jour", 0.24, 0.48)]);
    }

    [Fact]
    public void Without_durations_a_token_ends_where_the_next_begins_and_the_last_is_capped()
    {
        var timed = SherpaTokens.Timed(["▁a", "▁b", "▁c"], [0.0f, 0.4f, 0.9f], [], 1.0);
        timed.Select(t => Math.Round(t.End, 2)).ShouldBe([0.4, 0.9, 1.0]);

        SherpaTokens.Timed(["▁x"], [0.5f], null, 2.0).Single().End.ShouldBe(0.5 + SherpaTokens.FallbackTokenSeconds, 1e-6);
    }

    [Fact]
    public void Mismatched_or_missing_arrays_never_throw()
    {
        SherpaTokens.Timed(null, null, null, 1).ShouldBeEmpty();
        SherpaTokens.Timed(["▁a", "▁b"], [0.1f], null, 1).Count.ShouldBe(1);
        SherpaTokens.Timed(["▁a"], [0.5f], [-1f], 0.2).Single().End.ShouldBe(0.5);   // never before its start
    }

    [Fact]
    public void Meeting_models_are_pinned_with_sizes_and_hashes()
    {
        foreach (var manifest in new[] { MeetingModels.SileroVad, MeetingModels.Segmentation, MeetingModels.Embedding })
        {
            manifest.Revision.Length.ShouldBe(40);
            manifest.Files.ShouldAllBe(f => f.Size > 0 && f.Sha256.Length == 64);
        }
    }

    [Fact]
    public void A_truncated_meeting_model_is_refused_before_native_code_sees_it()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllBytes(Path.Combine(_dir, "silero_vad.onnx"), new byte[1000]);

        var check = MeetingModels.Verify(_dir, [MeetingModels.SileroVad], CancellationToken.None);
        check.IsUsable.ShouldBeFalse();
        check.Problem.ShouldNotBeNull().ShouldContain("should be 1,807,522");
    }

    [Fact]
    public void Missing_meeting_models_are_simply_absent()
    {
        MeetingModels.LocateVad(_dir).ShouldBeNull();
        MeetingModels.LocateDiarization(_dir).ShouldBeNull();
    }
}
