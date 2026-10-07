using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Meeting;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>One meeting channel, from timed samples to transcript segments.</summary>
public sealed class ChannelPipelineTests
{
    private sealed class Spool : IAudioSpoolWriter
    {
        public List<float> Samples { get; } = [];

        public void Append(ReadOnlySpan<float> samples) => Samples.AddRange(samples.ToArray());
    }

    private static float[] Tone(double seconds) =>
        [.. Enumerable.Range(0, (int)(seconds * AudioChunk.SampleRate)).Select(i => 0.3f * (float)Math.Sin(i * 0.2))];

    [Fact]
    public async Task Loopback_speech_after_a_silent_gap_lands_at_its_meeting_time()
    {
        var transcriber = new FakeTimedTranscriber(_ => "ship it Friday");
        var spool = new Spool();
        var produced = new List<TranscriptSegment>();
        using var pipeline = new ChannelPipeline(
            AudioSource.System, transcriber, new EnergyVoiceActivity(), t => t, spool);
        pipeline.SegmentProduced += (_, s) => produced.Add(s);

        // Loopback delivered nothing for two seconds, then one second of speech.
        await pipeline.AcceptAsync(new TimedSamples(2.0, Tone(1.0)), CancellationToken.None);
        await pipeline.PadUntilAsync(4.0, CancellationToken.None);
        var segments = await pipeline.FinishAsync(CancellationToken.None);

        var segment = segments.ShouldHaveSingleItem();
        produced.ShouldBe(segments);
        segment.Source.ShouldBe(AudioSource.System);
        segment.SpeakerId.ShouldBe(Speaker.OthersId);
        segment.Text.ShouldBe("ship it Friday");
        segment.Words.Select(w => w.Text).ShouldBe(["ship", "it", "Friday"]);
        segment.Start.ShouldBeInRange(1.85, 2.05);   // padded 0.1 s before speech
        segment.End.ShouldBeLessThanOrEqualTo(3.2);
        segment.Words.ShouldAllBe(w => w.Confidence == null);

        // The spool holds the whole timeline, silence included: diarization times line up.
        spool.Samples.Count.ShouldBe(4 * AudioChunk.SampleRate);
    }

    [Fact]
    public async Task The_microphone_is_me_and_the_dictionary_corrects_each_segment()
    {
        var transcriber = new FakeTimedTranscriber(_ => "we use cloud code");
        using var pipeline = new ChannelPipeline(
            AudioSource.Microphone, transcriber, new EnergyVoiceActivity(),
            t => t.Replace("cloud code", "Claude Code", StringComparison.Ordinal), null);
        var heard = new List<double>();
        pipeline.SpeechHeard += (_, t) => heard.Add(t);

        await pipeline.AcceptAsync(new TimedSamples(0, [.. new float[8_000], .. Tone(1.5), .. new float[16_000]]), CancellationToken.None);
        var segment = (await pipeline.FinishAsync(CancellationToken.None)).ShouldHaveSingleItem();

        segment.SpeakerId.ShouldBe(Speaker.MeId);
        segment.Text.ShouldBe("we use Claude Code");
        heard.ShouldNotBeEmpty();
        heard.Min().ShouldBeInRange(0.5, 0.6);
    }

    [Fact]
    public async Task Long_speech_is_cut_into_utterances_that_fit_one_parakeet_pass()
    {
        var transcriber = new FakeTimedTranscriber(i => $"part {i}");
        using var pipeline = new ChannelPipeline(AudioSource.System, transcriber, new EnergyVoiceActivity(), t => t, null);

        await pipeline.AcceptAsync(new TimedSamples(0, Tone(40)), CancellationToken.None);
        var segments = await pipeline.FinishAsync(CancellationToken.None);

        segments.Count.ShouldBeGreaterThanOrEqualTo(3);
        transcriber.Calls.ShouldAllBe(n => n <= 240_000);
        segments.Select(s => s.Start).ShouldBeInOrder();
    }

    [Fact]
    public async Task A_failing_vad_falls_back_to_energy_without_losing_the_channel()
    {
        var log = new RecordingDiagnosticLog();
        var broken = new ThrowingVoiceActivity();
        using var pipeline = new ChannelPipeline(
            AudioSource.System, new FakeTimedTranscriber(_ => "hello"), broken, t => t, null, log);

        await pipeline.AcceptAsync(new TimedSamples(0, [.. Tone(1), .. new float[16_000]]), CancellationToken.None);
        (await pipeline.FinishAsync(CancellationToken.None)).ShouldHaveSingleItem();

        broken.Disposed.ShouldBeTrue();
        pipeline.VadKind.ShouldBe("energy");
        log.Events.ShouldContain(e => e.Name == "meeting.vad_failed");
    }

    [Fact]
    public async Task An_utterance_the_model_cannot_transcribe_is_logged_without_its_text_and_skipped()
    {
        var log = new RecordingDiagnosticLog();
        var transcriber = new FakeTimedTranscriber(_ => "secret") { Failure = new InvalidOperationException("The speech model is not loaded.") };
        using var pipeline = new ChannelPipeline(AudioSource.Microphone, transcriber, new EnergyVoiceActivity(), t => t, null, log);

        await pipeline.AcceptAsync(new TimedSamples(0, [.. Tone(1), .. new float[16_000]]), CancellationToken.None);
        (await pipeline.FinishAsync(CancellationToken.None)).ShouldBeEmpty();

        var logged = log.Events.ShouldHaveSingleItem();
        logged.Name.ShouldBe("meeting.utterance_not_transcribed");
        logged.Fields!.Values.OfType<string>().ShouldNotContain("secret");
    }

    [Fact]
    public async Task Very_short_utterances_are_padded_to_what_the_recogniser_accepts()
    {
        var transcriber = new FakeTimedTranscriber(_ => "yes");
        using var pipeline = new ChannelPipeline(AudioSource.Microphone, transcriber, new EnergyVoiceActivity(), t => t, null);

        await pipeline.AcceptAsync(new TimedSamples(0, [.. Tone(0.3), .. new float[16_000]]), CancellationToken.None);
        await pipeline.FinishAsync(CancellationToken.None);

        transcriber.Calls.ShouldHaveSingleItem().ShouldBe(ChannelPipeline.MinimumRecognitionSamples);
    }

    [Fact]
    public async Task The_host_refuses_timed_transcription_from_an_engine_without_timings()
    {
        await using var untimed = new TranscriberHost(new FakeTranscriber("x"), "/models");
        untimed.SupportsTimings.ShouldBeFalse();
        await Should.ThrowAsync<InvalidOperationException>(
            async () => await untimed.TranscribeTimedAsync(new float[16_000], CancellationToken.None));

        await using var none = new TranscriberHost(null, null);
        await Should.ThrowAsync<InvalidOperationException>(
            async () => await none.TranscribeTimedAsync(new float[16_000], CancellationToken.None));
    }
}
