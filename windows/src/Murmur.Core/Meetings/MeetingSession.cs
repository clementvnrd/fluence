using System.Security.Cryptography;
using System.Threading.Channels;
using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>What a recording needs from the rest of the app.</summary>
public sealed record MeetingSessionDependencies
{
    /// <summary>A fresh microphone capture, separate from dictation's.</summary>
    public required IAudioCapture Microphone { get; init; }

    /// <summary>Process / system loopback, or null where there is none.</summary>
    public ILoopbackCapture? Loopback { get; init; }

    /// <summary>The Windows build, which decides whether process loopback is tried.</summary>
    public int WindowsBuild { get; init; }

    /// <summary>Parakeet with token timings.</summary>
    public required ITimedTranscriber Transcriber { get; init; }

    /// <summary>A voice detector per channel (Silero when installed, energy otherwise).</summary>
    public required Func<IVoiceActivityDetector> CreateVoiceActivity { get; init; }

    /// <summary>The dictionary's correction pass.</summary>
    public required Func<string, string> Correct { get; init; }

    /// <summary>The meeting clock (100-ns ticks).</summary>
    public required IHostClock Clock { get; init; }

    /// <summary>Counts and timings only.</summary>
    public required IDiagnosticLog Log { get; init; }
}

/// <summary>
/// One recording in progress: the two captures, their pipelines and spools, and the live
/// segments. Port of <c>MeetingSession.swift</c>; owned by <see cref="MeetingController"/>.
/// </summary>
/// <remarks>
/// <para>
/// Each channel is fed by a single consumer, so a pipeline never runs on two threads. The
/// system channel's consumer also takes heartbeats (<see cref="Heartbeat"/>): loopback delivers
/// nothing while nobody speaks, and the heartbeat pads its timeline with silence up to half a
/// second ago, so the spool stays on meeting time and the next packet lands in place.
/// </para>
/// <para>
/// A marker file sits in the meeting folder until the final pass completes, so a crash is
/// noticed and the meeting finished from its spool at the next launch.
/// </para>
/// </remarks>
public sealed class MeetingSession : IAsyncDisposable
{
    /// <summary>How far behind "now" the heartbeat pads the system channel, seconds.</summary>
    public const double HeartbeatLag = 0.5;

    private readonly MeetingSessionDependencies _deps;
    private readonly MeetingStore _store;
    private readonly AesGcm _key;
    private readonly int? _loopbackProcessId;
    private readonly CancellationTokenSource _stopMic = new();
    private readonly CancellationTokenSource _abort = new();
    private readonly Channel<TimedSamples> _systemQueue = Channel.CreateUnbounded<TimedSamples>(
        new UnboundedChannelOptions { SingleReader = true });
    private readonly Lock _sync = new();
    private readonly List<TranscriptSegment> _mic = [];
    private readonly List<TranscriptSegment> _system = [];
    private readonly HashSet<Guid> _hiddenEchoes = [];
    private readonly List<Task> _consumers = [];
    private MeetingAudioSpool? _micSpool;
    private MeetingAudioSpool? _systemSpool;
    private ChannelPipeline? _micPipeline;
    private ChannelPipeline? _systemPipeline;
    private SystemAudioSource? _systemSource;
    private CancellationTokenSource? _stopSystem;
    private long _start;
    private double? _lastSpeech;
    private bool _finished;
    /// <summary>Host time the loopback last delivered a packet; <see cref="long.MinValue"/> before the first.</summary>
    private long _lastSystemPacketAt = long.MinValue;

    /// <summary>Creates the session; nothing runs until <see cref="StartAsync"/>.</summary>
    /// <param name="meetingId">The meeting being recorded.</param>
    /// <param name="store">Where its folder, key and marker live.</param>
    /// <param name="key">The meeting's key; owned by the session from here.</param>
    /// <param name="loopbackProcessId">The call's process tree, or null for the whole system.</param>
    /// <param name="dependencies">Captures, models and clock.</param>
    public MeetingSession(Guid meetingId, MeetingStore store, AesGcm key, int? loopbackProcessId, MeetingSessionDependencies dependencies)
    {
        ArgumentNullException.ThrowIfNull(dependencies);
        MeetingId = meetingId;
        _store = store;
        _key = key;
        _loopbackProcessId = loopbackProcessId;
        _deps = dependencies;
    }

    /// <summary>The meeting being recorded.</summary>
    public Guid MeetingId { get; }

    /// <summary>The meeting's folder.</summary>
    public string Directory => _store.DirectoryFor(MeetingId);

    /// <summary>Whether the call's audio is being captured (not only the microphone).</summary>
    public bool HasSystemAudio => _systemPipeline is not null;

    /// <summary>What was captured: the call's processes, or everything the computer played.</summary>
    public LoopbackScope? SystemScope => _systemSource?.Opened?.Scope;

    /// <summary>Seconds since recording started.</summary>
    public double Elapsed => (_deps.Clock.Now - _start) / 10_000_000.0;

    /// <summary>Meeting time speech was last heard on either channel.</summary>
    public double? LastSpeech
    {
        get
        {
            lock (_sync) return _lastSpeech;
        }
    }

    /// <summary>Set when the microphone failed; the controller stops the meeting.</summary>
    public bool CaptureFailed { get; private set; }

    /// <summary>Raised on a pipeline thread whenever a live segment arrives.</summary>
    public event EventHandler? SegmentsChanged;

    /// <summary>Opens the spools and captures and starts both channels.</summary>
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var directory = Directory;
        System.IO.Directory.CreateDirectory(directory);
        await File.WriteAllBytesAsync(_store.MarkerPath(MeetingId), [], cancellationToken).ConfigureAwait(false);
        _start = _deps.Clock.Now;

        _micSpool = new MeetingAudioSpool(MeetingAudioSpool.PathFor(directory, AudioSource.Microphone), _key, MeetingId, AudioSource.Microphone);
        _micPipeline = Pipeline(AudioSource.Microphone, _micSpool);

        if (_deps.Loopback is { } loopback)
        {
            var source = new SystemAudioSource(loopback, _deps.Log);
            if (await source.OpenAsync(LoopbackPlanner.Plan(_loopbackProcessId, _deps.WindowsBuild), cancellationToken).ConfigureAwait(false))
            {
                _systemSource = source;
                _systemSpool = new MeetingAudioSpool(MeetingAudioSpool.PathFor(directory, AudioSource.System), _key, MeetingId, AudioSource.System);
                _systemPipeline = Pipeline(AudioSource.System, _systemSpool);
                _stopSystem = new CancellationTokenSource();
                _consumers.Add(Task.Run(() => ReadSystemAsync(source, _stopSystem.Token), CancellationToken.None));
                _consumers.Add(Task.Run(() => ConsumeSystemAsync(_systemPipeline, _abort.Token), CancellationToken.None));
            }
            else
            {
                await source.DisposeAsync().ConfigureAwait(false);
                _deps.Log.Warning("meeting.loopback_unavailable");
            }
        }

        _consumers.Add(Task.Run(() => ConsumeMicAsync(_micPipeline, _abort.Token), CancellationToken.None));
        _deps.Log.Info("meeting.session_started", new Dictionary<string, object?>
        {
            ["system"] = HasSystemAudio,
            ["scope"] = SystemScope?.ToString(),
            ["vad"] = _micPipeline.VadKind,
        });
    }

    /// <summary>Called about once a second: keeps the silent system channel on meeting time.</summary>
    public void Heartbeat()
    {
        if (_systemPipeline is null || _finished) return;
        // Packets still arriving keep the timeline themselves. Padding then would queue silence
        // ahead of audio that is merely late (a stalled capture thread), and the aligner trims
        // that audio as an overlap: remote speech lost.
        if (!ShouldPad(_deps.Clock.Now, Volatile.Read(ref _lastSystemPacketAt))) return;
        var until = Elapsed - HeartbeatLag;
        if (until > 0) _systemQueue.Writer.TryWrite(new TimedSamples(until, []));
    }

    /// <summary>
    /// Whether a heartbeat may pad the system channel: only once the loopback has been quiet for
    /// <see cref="HeartbeatLag"/> (host time, 100-ns units; <see cref="long.MinValue"/> = no packet yet).
    /// </summary>
    public static bool ShouldPad(long now, long lastPacketAt) =>
        lastPacketAt == long.MinValue || (now - lastPacketAt) / 10_000_000.0 >= HeartbeatLag;

    /// <summary>Both channels, time-ordered, echoes included (the final pass decides).</summary>
    public IReadOnlyList<TranscriptSegment> AllSegments
    {
        get
        {
            lock (_sync) return TranscriptMerger.Sorted([.. _mic, .. _system]);
        }
    }

    /// <summary>What the live view shows: microphone echoes of the remote side hidden.</summary>
    public IReadOnlyList<TranscriptSegment> VisibleSegments
    {
        get
        {
            lock (_sync) return TranscriptMerger.Sorted([.. _mic.Where(s => !_hiddenEchoes.Contains(s.Id)), .. _system]);
        }
    }

    /// <summary>
    /// Stops both captures and drains the pipelines: every utterance is transcribed and the
    /// spools are closed when this returns.
    /// </summary>
    public async Task<IReadOnlyList<TranscriptSegment>> FinishAsync(CancellationToken cancellationToken)
    {
        if (_finished) return AllSegments;
        _finished = true;

        // Stop requests, not aborts: the captures still deliver what they hold.
        await _stopMic.CancelAsync().ConfigureAwait(false);
        if (_stopSystem is not null) await _stopSystem.CancelAsync().ConfigureAwait(false);
        await using (cancellationToken.Register(_abort.Cancel))
        {
            await Task.WhenAll(_consumers).ConfigureAwait(false);
        }

        if (_systemSource is not null) await _systemSource.DisposeAsync().ConfigureAwait(false);
        _micSpool?.Dispose();
        _systemSpool?.Dispose();
        return AllSegments;
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (!_finished)
        {
            await _abort.CancelAsync().ConfigureAwait(false);
            await FinishAsync(CancellationToken.None).ConfigureAwait(false);
        }

        _micPipeline?.Dispose();
        _systemPipeline?.Dispose();
        _stopMic.Dispose();
        _stopSystem?.Dispose();
        _abort.Dispose();
        _key.Dispose();
    }

    private ChannelPipeline Pipeline(AudioSource source, IAudioSpoolWriter spool)
    {
        var pipeline = new ChannelPipeline(source, _deps.Transcriber, _deps.CreateVoiceActivity(), _deps.Correct, spool, _deps.Log);
        pipeline.SegmentProduced += (_, segment) => Add(segment);
        pipeline.SpeechHeard += (_, time) =>
        {
            lock (_sync) _lastSpeech = Math.Max(_lastSpeech ?? 0, time);
        };
        return pipeline;
    }

    private async Task ConsumeMicAsync(ChannelPipeline pipeline, CancellationToken abort)
    {
        var timeline = new MicTimeline(_start, _deps.Clock);
        try
        {
            await foreach (var chunk in _deps.Microphone.CaptureAsync(_stopMic.Token).WithCancellation(abort).ConfigureAwait(false))
            {
                await pipeline.AcceptAsync(timeline.Stamp(chunk.Samples.ToArray()), abort).ConfigureAwait(false);
            }

            await pipeline.FinishAsync(abort).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (abort.IsCancellationRequested)
        {
            // Aborted: what was transcribed so far stays.
        }
        catch (Exception e)
        {
            _deps.Log.Error("meeting.mic_failed", e);
            CaptureFailed = true;
        }
    }

    private async Task ReadSystemAsync(SystemAudioSource source, CancellationToken stop)
    {
        try
        {
            await foreach (var samples in source.ReadAsync(_start, stop).ConfigureAwait(false))
            {
                Volatile.Write(ref _lastSystemPacketAt, _deps.Clock.Now);
                await _systemQueue.Writer.WriteAsync(samples, CancellationToken.None).ConfigureAwait(false);
            }
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            // The call goes on with the microphone alone; the final pass still has what was spooled.
            _deps.Log.Error("meeting.loopback_failed", e);
        }
        finally
        {
            _systemQueue.Writer.TryComplete();
        }
    }

    private async Task ConsumeSystemAsync(ChannelPipeline pipeline, CancellationToken abort)
    {
        try
        {
            await foreach (var item in _systemQueue.Reader.ReadAllAsync(abort).ConfigureAwait(false))
            {
                if (item.Samples.Length == 0) await pipeline.PadUntilAsync(item.Time, abort).ConfigureAwait(false);
                else await pipeline.AcceptAsync(item, abort).ConfigureAwait(false);
            }

            await pipeline.FinishAsync(abort).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (abort.IsCancellationRequested)
        {
            // Aborted.
        }
    }

    private void Add(TranscriptSegment segment)
    {
        lock (_sync)
        {
            if (segment.Source == AudioSource.Microphone)
            {
                _mic.Add(segment);
                if (TranscriptMerger.IsEcho(segment, Near(segment))) _hiddenEchoes.Add(segment.Id);
            }
            else
            {
                _system.Add(segment);

                // A remote segment can arrive after the microphone's echo of it.
                foreach (var mic in _mic)
                {
                    if (!_hiddenEchoes.Contains(mic.Id) && Math.Abs(mic.Start - segment.Start) < 30
                        && TranscriptMerger.IsEcho(mic, Near(mic)))
                    {
                        _hiddenEchoes.Add(mic.Id);
                    }
                }
            }
        }

        SegmentsChanged?.Invoke(this, EventArgs.Empty);
    }

    private List<TranscriptSegment> Near(TranscriptSegment segment) =>
        [.. _system.Where(s => s.End >= segment.Start - 30 && s.Start <= segment.End + 30)];
}
