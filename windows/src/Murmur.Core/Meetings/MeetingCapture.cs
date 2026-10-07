using System.Runtime.CompilerServices;
using Murmur.Abstractions;

namespace Murmur.Core.Meetings;

/// <summary>16 kHz mono samples and when the first of them was captured.</summary>
/// <param name="Time">Seconds from the meeting start.</param>
/// <param name="Samples">16 kHz mono float. Owned by the receiver.</param>
public readonly record struct TimedSamples(double Time, float[] Samples);

/// <summary>Which loopback requests to try, in order. Pure policy; the platform layer only executes one.</summary>
public static class LoopbackPlanner
{
    /// <summary>
    /// The first Windows build with process loopback (<c>AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK</c>):
    /// Windows 10 build 20348 (Server 2022) and every Windows 11.
    /// </summary>
    public const int ProcessLoopbackMinimumBuild = 20348;

    /// <summary>
    /// Formats to ask for, best first. Exactly what the models want (the engine converts, with
    /// <c>AUTOCONVERTPCM</c>); then 16-bit at the same rate; then 44.1 kHz 16-bit stereo, the format
    /// Microsoft's own process-loopback sample uses — converted and resampled here.
    /// </summary>
    public static IReadOnlyList<PcmFormat> Formats { get; } =
    [
        PcmFormat.SpeechFloat,
        new(AudioChunk.SampleRate, 1, 16, false),
        new(44_100, 2, 16, false),
    ];

    /// <summary>
    /// Every request to try. Process-tree capture of <paramref name="processId"/> first when the
    /// OS supports it, then the whole system: capturing a little too much beats capturing nothing.
    /// </summary>
    /// <param name="processId">The meeting app's root process, or null for a manual recording (whole system).</param>
    /// <param name="windowsBuild">The OS build number (<c>Environment.OSVersion.Version.Build</c> on Windows).</param>
    public static IReadOnlyList<LoopbackRequest> Plan(int? processId, int windowsBuild)
    {
        var plan = new List<LoopbackRequest>();
        if (processId is { } pid && pid > 0 && windowsBuild >= ProcessLoopbackMinimumBuild)
        {
            plan.AddRange(Formats.Select(f => new LoopbackRequest(LoopbackScope.ProcessTree, pid, f)));
        }

        plan.AddRange(Formats.Select(f => new LoopbackRequest(LoopbackScope.WholeSystem, 0, f)));
        return plan;
    }
}

/// <summary>
/// The system channel: opens loopback following <see cref="LoopbackPlanner"/>, and turns raw
/// packets into 16 kHz mono samples stamped with meeting time.
/// </summary>
/// <remarks>
/// Loopback is silent by omission — nothing arrives while nothing plays — so the times this
/// yields have gaps. The channel pipeline's <c>TimelineAligner</c> turns those into silence.
/// </remarks>
public sealed class SystemAudioSource : IAsyncDisposable
{
    private readonly ILoopbackCapture _capture;
    private readonly IDiagnosticLog _log;
    private ILoopbackSession? _stream;
    private StreamingResampler? _resampler;

    /// <summary>Creates the source over a platform loopback binding.</summary>
    public SystemAudioSource(ILoopbackCapture capture, IDiagnosticLog? log = null)
    {
        _capture = capture;
        _log = log ?? NullDiagnosticLog.Instance;
    }

    /// <summary>What was actually opened, once <see cref="OpenAsync"/> succeeded.</summary>
    public LoopbackRequest? Opened => _stream?.Request;

    /// <summary>Tries each request in turn; the first that opens wins.</summary>
    /// <returns>False when nothing could be opened — the meeting continues with the microphone only.</returns>
    public async Task<bool> OpenAsync(IReadOnlyList<LoopbackRequest> plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);

        foreach (var request in plan)
        {
            try
            {
                _stream = await _capture.OpenAsync(request, cancellationToken).ConfigureAwait(false);
                _log.Info("meeting.loopback_opened", new Dictionary<string, object?>
                {
                    ["scope"] = request.Scope.ToString(),
                    ["rate"] = request.Format.SampleRate,
                    ["channels"] = request.Format.Channels,
                    ["bits"] = request.Format.BitsPerSample,
                });
                return true;
            }
            catch (Exception e) when (e is InvalidOperationException or NotSupportedException
                                          or System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
            {
                _log.Warning("meeting.loopback_attempt_failed", e, new Dictionary<string, object?>
                {
                    ["scope"] = request.Scope.ToString(),
                    ["rate"] = request.Format.SampleRate,
                });
            }
        }

        return false;
    }

    /// <summary>16 kHz mono samples on the meeting clock, until <paramref name="stopRequested"/> drains the stream.</summary>
    /// <param name="meetingStart">The meeting's start on the host clock (100-ns units).</param>
    /// <param name="stopRequested">A request to stop; captured audio is still delivered.</param>
    /// <remarks>
    /// Output sample <i>k</i> of a resampler started at time <i>t0</i> is at <i>t0 + k / 16 000</i>,
    /// as long as its input is contiguous. A gap in the packets' times (loopback's silence), a
    /// discontinuity or a format change therefore flushes the resampler and starts a new one at
    /// the new packet's time.
    /// </remarks>
    public async IAsyncEnumerable<TimedSamples> ReadAsync(
        long meetingStart, [EnumeratorCancellation] CancellationToken stopRequested)
    {
        var stream = _stream ?? throw new InvalidOperationException("Open the source first.");
        double origin = 0;      // time of the resampler's first input sample
        long fed = 0;           // input samples since then
        long emitted = 0;       // output samples since then

        await foreach (var packet in stream.ReadAsync(stopRequested).ConfigureAwait(false))
        {
            if (packet.Frames <= 0) continue;

            var time = (packet.HostTime - meetingStart) / 10_000_000.0;
            var mono = PcmConverter.ToMono(packet);

            if (packet.Format.SampleRate == AudioChunk.SampleRate)
            {
                yield return new TimedSamples(time, mono);
                continue;
            }

            var rate = packet.Format.SampleRate;
            var expected = origin + ((double)fed / rate);
            if (_resampler is null || _resampler.InputRate != rate || packet.IsDiscontinuity
                || Math.Abs(time - expected) > ContiguityTolerance)
            {
                if (_resampler is not null && _resampler.Flush() is { Length: > 0 } tail)
                {
                    yield return new TimedSamples(origin + ((double)emitted / AudioChunk.SampleRate), tail);
                }

                _resampler = new StreamingResampler(rate, AudioChunk.SampleRate);
                origin = time;
                fed = 0;
                emitted = 0;
            }

            var resampled = _resampler.Process(mono);
            fed += mono.Length;
            if (resampled.Length == 0) continue;

            yield return new TimedSamples(origin + ((double)emitted / AudioChunk.SampleRate), resampled);
            emitted += resampled.Length;
        }

        if (_resampler is not null && _resampler.Flush() is { Length: > 0 } rest)
        {
            yield return new TimedSamples(origin + ((double)emitted / AudioChunk.SampleRate), rest);
        }
    }

    /// <summary>
    /// How far a packet's stamp may stray from where the previous packets put it before it
    /// counts as a gap, seconds. Above packet-to-packet QPC jitter, below anything audible.
    /// </summary>
    public const double ContiguityTolerance = 0.02;

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (_stream is not null) await _stream.DisposeAsync().ConfigureAwait(false);
        _stream = null;
    }
}

/// <summary>
/// Stamps the meeting microphone's chunks with meeting time.
/// </summary>
/// <remarks>
/// A microphone delivers continuously, silence included, so its timeline is its sample count:
/// the first chunk is anchored at its arrival time minus its own length, and every later
/// chunk follows on. Re-stamping each chunk by arrival would import the jitter of the capture
/// thread and the channel in between; the device clock's drift against the host clock
/// (typically under 0.4 s an hour) stays well inside the ±1.5 s the echo dedupe tolerates.
/// </remarks>
public sealed class MicTimeline
{
    private readonly long _meetingStart;
    private readonly IHostClock _clock;
    private double? _next;

    /// <summary>Creates the timeline for a meeting that started at <paramref name="meetingStart"/> (host clock).</summary>
    public MicTimeline(long meetingStart, IHostClock clock)
    {
        _meetingStart = meetingStart;
        _clock = clock;
    }

    /// <summary>Stamps a chunk that has just arrived.</summary>
    public TimedSamples Stamp(float[] samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        var seconds = (double)samples.Length / AudioChunk.SampleRate;
        var time = _next ?? Math.Max(0, ((_clock.Now - _meetingStart) / 10_000_000.0) - seconds);
        _next = time + seconds;
        return new TimedSamples(time, samples);
    }
}
