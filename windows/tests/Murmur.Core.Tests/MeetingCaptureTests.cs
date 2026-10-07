using Murmur.Abstractions;
using Murmur.Core.Meetings;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>
/// The platform-neutral half of meeting capture: which loopback to try, how raw packets become
/// 16 kHz mono, and how both channels land on the meeting clock. The Windows binding only
/// activates and pumps packets; everything here is what it feeds.
/// </summary>
public sealed class MeetingCaptureTests
{
    private static float[] Sine(double frequency, int sampleRate, double seconds, float amplitude = 0.5f) =>
        [.. Enumerable.Range(0, (int)(sampleRate * seconds))
            .Select(i => amplitude * (float)Math.Sin(2 * Math.PI * frequency * i / sampleRate))];

    private static double Rms(ReadOnlySpan<float> samples)
    {
        double sum = 0;
        foreach (var s in samples) sum += s * s;
        return samples.Length == 0 ? 0 : Math.Sqrt(sum / samples.Length);
    }

    [Fact]
    public void Process_loopback_is_planned_first_only_where_windows_supports_it()
    {
        var modern = LoopbackPlanner.Plan(4242, 22631);
        modern.Take(3).ShouldAllBe(r => r.Scope == LoopbackScope.ProcessTree && r.ProcessId == 4242);
        modern.Skip(3).ShouldAllBe(r => r.Scope == LoopbackScope.WholeSystem);
        modern[0].Format.ShouldBe(PcmFormat.SpeechFloat);

        LoopbackPlanner.Plan(4242, 19045).ShouldAllBe(r => r.Scope == LoopbackScope.WholeSystem);
        LoopbackPlanner.Plan(null, 22631).ShouldAllBe(r => r.Scope == LoopbackScope.WholeSystem);
    }

    [Fact]
    public async Task A_refused_process_loopback_falls_back_to_the_whole_system()
    {
        var capture = new FakeLoopbackCapture(r => r.Scope == LoopbackScope.WholeSystem);
        var log = new RecordingDiagnosticLog();
        await using var source = new SystemAudioSource(capture, log);

        (await source.OpenAsync(LoopbackPlanner.Plan(4242, 22631), CancellationToken.None)).ShouldBeTrue();

        source.Opened.ShouldNotBeNull().Scope.ShouldBe(LoopbackScope.WholeSystem);
        capture.Attempts.Count.ShouldBe(4);
        log.Events.Count(e => e.Name == "meeting.loopback_attempt_failed").ShouldBe(3);
    }

    [Fact]
    public async Task Nothing_opening_is_reported_rather_than_thrown()
    {
        await using var source = new SystemAudioSource(new FakeLoopbackCapture(_ => false));
        (await source.OpenAsync(LoopbackPlanner.Plan(1, 22631), CancellationToken.None)).ShouldBeFalse();
        source.Opened.ShouldBeNull();
    }

    [Fact]
    public void Pcm_layouts_decode_and_channels_average()
    {
        var stereo = FakeLoopbackCapture.Pcm16([0.5f, -0.25f], 48_000, 2, 0);
        PcmConverter.ToMono(stereo).ShouldBe([0.5f, -0.25f], tolerance: 1e-4f);

        // Left 1.0, right 0: averages to 0.5.
        var format = new PcmFormat(16_000, 2, 32, true);
        var bytes = new byte[8];
        BitConverter.TryWriteBytes(bytes.AsSpan(0, 4), 1.0f).ShouldBeTrue();
        PcmConverter.ToMono(new RawAudioPacket(bytes, 1, format, 0, false, false)).ShouldBe([0.5f]);

        // 24-bit: 0x400000 is +0.5.
        var s24 = new PcmFormat(16_000, 1, 24, false);
        PcmConverter.ToMono(new RawAudioPacket(new byte[] { 0x00, 0x00, 0x40 }, 1, s24, 0, false, false))
            .ShouldBe([0.5f]);
    }

    [Fact]
    public void A_packet_flagged_silent_is_zeros_whatever_its_buffer_holds()
    {
        var packet = FakeLoopbackCapture.Pcm16([0.9f, 0.9f, 0.9f], 48_000, 2, 0) with { IsSilent = true };
        PcmConverter.ToMono(packet).ShouldBe([0f, 0f, 0f]);
    }

    [Fact]
    public void Resampling_48k_to_16k_keeps_speech_band_level_and_rejects_what_would_alias()
    {
        var speech = new StreamingResampler(48_000, 16_000);
        var output = speech.Process(Sine(1_000, 48_000, 1.0)).Concat(speech.Flush()).ToArray();
        output.Length.ShouldBe(16_000);
        Rms(output.AsSpan(100, 15_800)).ShouldBe(0.5 / Math.Sqrt(2), 0.01);

        // 12 kHz cannot be represented at 16 kHz; unfiltered it would fold back to 4 kHz.
        var alias = new StreamingResampler(48_000, 16_000);
        var folded = alias.Process(Sine(12_000, 48_000, 1.0)).Concat(alias.Flush()).ToArray();
        Rms(folded.AsSpan(100, 15_800)).ShouldBeLessThan(0.01);
    }

    [Fact]
    public void Resampling_is_independent_of_how_the_input_is_chunked()
    {
        var input = Sine(440, 44_100, 0.5);
        var whole = new StreamingResampler(44_100, 16_000);
        var expected = whole.Process(input).Concat(whole.Flush()).ToArray();

        var chunked = new StreamingResampler(44_100, 16_000);
        var actual = new List<float>();
        for (var offset = 0; offset < input.Length; offset += 441)
        {
            actual.AddRange(chunked.Process(input.AsSpan(offset, Math.Min(441, input.Length - offset))));
        }

        actual.AddRange(chunked.Flush());
        actual.ShouldBe(expected);
    }

    [Fact]
    public void Dc_passes_at_unity_and_16k_passes_through_untouched()
    {
        var dc = new StreamingResampler(44_100, 16_000);
        var output = dc.Process(Enumerable.Repeat(0.25f, 44_100).ToArray());
        output.Skip(50).Take(1000).ShouldAllBe(s => Math.Abs(s - 0.25f) < 1e-4f);

        var same = new StreamingResampler(16_000, 16_000);
        same.IsPassThrough.ShouldBeTrue();
        same.Process([0.1f, 0.2f]).ShouldBe([0.1f, 0.2f]);
    }

    [Fact]
    public async Task Loopback_packets_are_stamped_with_meeting_time_and_silence_gaps_restart_the_filter()
    {
        const long start = 50_000_000;   // 5 s on the host clock
        var tenMs = Sine(1_000, 48_000, 0.01);
        RawAudioPacket[] packets =
        [
            FakeLoopbackCapture.Pcm16(tenMs, 48_000, 2, start + 1_000_000),     // 0.10 s
            FakeLoopbackCapture.Pcm16(tenMs, 48_000, 2, start + 1_100_000),     // 0.11 s, contiguous
            // Two seconds of nothing: loopback delivers no packets while nothing plays.
            FakeLoopbackCapture.Pcm16(tenMs, 48_000, 2, start + 21_200_000),    // 2.12 s
        ];

        var capture = new FakeLoopbackCapture(_ => true, _ => packets);
        await using var source = new SystemAudioSource(capture);
        (await source.OpenAsync(LoopbackPlanner.Plan(7, 22631), CancellationToken.None)).ShouldBeTrue();

        var chunks = new List<TimedSamples>();
        await foreach (var chunk in source.ReadAsync(start, CancellationToken.None)) chunks.Add(chunk);

        chunks.Sum(c => c.Samples.Length).ShouldBeInRange(476, 484);   // 30 ms of audio at 16 kHz
        chunks[0].Time.ShouldBe(0.10, 0.001);
        chunks.ShouldContain(c => Math.Abs(c.Time - 2.12) < 0.001);
        chunks.ShouldAllBe(c => c.Time < 0.13 || c.Time >= 2.12);
    }

    [Fact]
    public async Task Packets_already_at_16k_mono_float_are_passed_through_with_their_time()
    {
        var format = PcmFormat.SpeechFloat;
        var bytes = new byte[160 * 4];
        BitConverter.TryWriteBytes(bytes.AsSpan(0, 4), 0.75f).ShouldBeTrue();
        var packet = new RawAudioPacket(bytes, 160, format, 10_000_000, false, false);

        await using var source = new SystemAudioSource(new FakeLoopbackCapture(_ => true, _ => [packet]));
        (await source.OpenAsync(LoopbackPlanner.Plan(7, 22631), CancellationToken.None)).ShouldBeTrue();

        var chunks = new List<TimedSamples>();
        await foreach (var chunk in source.ReadAsync(0, CancellationToken.None)) chunks.Add(chunk);

        chunks.Single().Time.ShouldBe(1.0);
        chunks.Single().Samples.Length.ShouldBe(160);
        chunks.Single().Samples[0].ShouldBe(0.75f);
    }

    [Fact]
    public void The_microphone_timeline_follows_its_sample_count_not_arrival_jitter()
    {
        var clock = new FakeHostClock { Now = 0 };
        var timeline = new MicTimeline(0, clock);

        clock.Advance(1.02);   // first 20 ms chunk arrives 1.02 s in: it started at 1.00 s
        timeline.Stamp(new float[320]).Time.ShouldBe(1.0, 1e-9);

        clock.Advance(0.5);    // a late arrival does not move the next chunk
        timeline.Stamp(new float[320]).Time.ShouldBe(1.02, 1e-9);
    }

    [Fact]
    public void The_host_clock_converts_counter_ticks_without_overflow()
    {
        HostClock.ToHundredNanoseconds(10_000_000, 10_000_000).ShouldBe(10_000_000L);
        HostClock.ToHundredNanoseconds(3 * 24_000_000L, 24_000_000).ShouldBe(30_000_000L);
        HostClock.ToHundredNanoseconds(long.MaxValue / 2, 1_000_000_000).ShouldBeGreaterThan(0L);
    }
}
