using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>Where the Notetaker is.</summary>
public enum MeetingState
{
    /// <summary>Nothing happening.</summary>
    Idle,

    /// <summary>A call was noticed; the card is up with its countdown.</summary>
    Detected,

    /// <summary>Recording.</summary>
    Recording,

    /// <summary>Recording stopped; the final pass is running.</summary>
    Processing,

    /// <summary>Something went wrong; <see cref="MeetingController.Problem"/> says what.</summary>
    Failed,
}

/// <summary>The user's Notetaker preferences, read on every tick.</summary>
public sealed record MeetingOptions
{
    /// <summary>Offer to record when a call starts.</summary>
    public bool DetectMeetings { get; init; } = true;

    /// <summary>Seconds on the card before recording starts by itself; 0 waits for a click.</summary>
    public int CountdownSeconds { get; init; } = 10;

    /// <summary>The "keep audio" checkbox's starting value.</summary>
    public bool KeepAudioByDefault { get; init; }

    /// <summary>Recording stops by itself after this many minutes.</summary>
    public int MaxDurationMinutes { get; init; } = 180;

    /// <summary>Opt-in voice prints (biometric data): off by default.</summary>
    public bool VoicePrints { get; init; }
}

/// <summary>Everything the controller drives.</summary>
public sealed record MeetingServices
{
    /// <summary>The encrypted store.</summary>
    public required MeetingStore Store { get; init; }

    /// <summary>Call detection, or null where there are no signals.</summary>
    public MeetingDetector? Detector { get; init; }

    /// <summary>A fresh microphone capture per recording, or null when there is none.</summary>
    public required Func<IAudioCapture?> CreateMicrophone { get; init; }

    /// <summary>Process / system loopback, or null.</summary>
    public ILoopbackCapture? Loopback { get; init; }

    /// <summary>The Windows build number.</summary>
    public int WindowsBuild { get; init; }

    /// <summary>Parakeet with token timings.</summary>
    public required ITimedTranscriber Transcriber { get; init; }

    /// <summary>A voice detector per channel.</summary>
    public required Func<IVoiceActivityDetector> CreateVoiceActivity { get; init; }

    /// <summary>The diarizer, or null when its models are not installed.</summary>
    public Func<ISpeakerDiarizer?> CreateDiarizer { get; init; } = () => null;

    /// <summary>The embedder for voice prints, or null when its model is not installed.</summary>
    public Func<ISpeakerEmbedder?> CreateEmbedder { get; init; } = () => null;

    /// <summary>Opt-in voice prints, or null.</summary>
    public VoicePrintStore? VoicePrints { get; init; }

    /// <summary>The dictionary's correction pass.</summary>
    public required Func<string, string> Correct { get; init; }

    /// <summary>Notes; <see cref="NoNotesModel"/> by default.</summary>
    public INotesModel Notes { get; init; } = NoNotesModel.Instance;

    /// <summary>The user's preferences.</summary>
    public required Func<MeetingOptions> Options { get; init; }

    /// <summary>The meeting clock.</summary>
    public required IHostClock HostClock { get; init; }

    /// <summary>Wall-clock time, for dates.</summary>
    public required IClock Clock { get; init; }

    /// <summary>Counts and reasons only — never titles, names or text.</summary>
    public required IDiagnosticLog Log { get; init; }
}

/// <summary>
/// The Notetaker's capture half: detection → card → recording → final pass. Port of
/// <c>MeetingController.swift</c>, driven by <see cref="TickAsync"/> once a second instead of
/// its own tasks, so it runs (and is tested) without a UI.
/// </summary>
/// <remarks>
/// <code>
/// Idle ──detected──► Detected ──Record / countdown──► Recording ──stop──► Processing ──► Idle
///   ▲                   │ Not now                                                     │
///   └───────────────────┘◄─────────────────────── Failed (dismissable) ◄──────────────┘
/// </code>
/// <para>
/// <b>Never records silently</b>: a recording starts from the card (Record, or its visible
/// countdown) or from "Take meeting notes". While recording, a small window with a lit record
/// lamp stays on screen.
/// </para>
/// <para>
/// Recording stops on Stop, the call's app releasing the microphone for 30 s, ten minutes of
/// silence, the maximum length, or the session locking / sleeping. The meeting is saved every
/// 30 s, and one found still marked as recording at launch is finished from its spool.
/// </para>
/// </remarks>
public sealed class MeetingController : IAsyncDisposable
{
    private readonly MeetingServices _s;
    private readonly Lock _sync = new();
    private MeetingSession? _session;
    private DetectedMeeting? _recordingApp;
    private Task _processing = Task.CompletedTask;
    private int _ticks;

    /// <summary>Creates the controller.</summary>
    public MeetingController(MeetingServices services)
    {
        ArgumentNullException.ThrowIfNull(services);
        _s = services;
    }

    /// <summary>Raised after any visible change, on whatever thread made it.</summary>
    public event EventHandler? Changed;

    /// <summary>Raised when a meeting has been finalised and saved.</summary>
    public event EventHandler<Guid>? Finalized;

    /// <summary>The state.</summary>
    public MeetingState State { get; private set; }

    /// <summary>The call on the card.</summary>
    public DetectedMeeting? Detected { get; private set; }

    /// <summary>Seconds left on the card; null waits for a click.</summary>
    public int? Countdown { get; private set; }

    /// <summary>The meeting being recorded.</summary>
    public MeetingRecord? Current { get; private set; }

    /// <summary>The live transcript, mic echoes hidden.</summary>
    public IReadOnlyList<TranscriptSegment> LiveSegments => _session?.VisibleSegments ?? [];

    /// <summary>Seconds recorded.</summary>
    public double Elapsed { get; private set; }

    /// <summary>A problem worth telling the user while recording.</summary>
    public string? Notice { get; private set; }

    /// <summary>What went wrong, in <see cref="MeetingState.Failed"/>.</summary>
    public string? Problem { get; private set; }

    /// <summary>Why the last recording ended.</summary>
    public StopReason? LastStopReason { get; private set; }

    /// <summary>The per-meeting "keep audio" checkbox (decision FLU-9 #2).</summary>
    public bool KeepAudio { get; set; }

    /// <summary>Whether recording.</summary>
    public bool IsRecording => State == MeetingState.Recording;

    /// <summary>The final pass in flight, for tests and shutdown.</summary>
    public Task Processing => _processing;

    private double Now => _s.HostClock.Now / 10_000_000.0;

    /// <summary>Once a second: detection, the card's countdown, stop rules, heartbeat, autosave.</summary>
    public async Task TickAsync()
    {
        var options = _s.Options();
        switch (State)
        {
            case MeetingState.Idle or MeetingState.Failed:
                if (options.DetectMeetings && _s.Detector?.Poll(Now) is [var first, ..]) Offer(first, options);
                break;

            case MeetingState.Detected when Detected is { } detected:
                _s.Detector?.Poll(Now);
                if (_s.Detector is { } detector && !detector.IsOnMicrophone(detected.Key, Now))
                {
                    // The call ended before anyone answered the card.
                    Dismiss();
                    break;
                }

                if (Countdown is { } remaining)
                {
                    if (remaining <= 1)
                    {
                        Countdown = 0;
                        await RecordAsync(detected, MeetingTrigger.Detected).ConfigureAwait(false);
                    }
                    else
                    {
                        Countdown = remaining - 1;
                        Raise();
                    }
                }

                break;

            case MeetingState.Recording when _session is { } session:
                await TickRecordingAsync(session, options).ConfigureAwait(false);
                break;
        }
    }

    /// <summary>"Record" on the card.</summary>
    public Task AcceptAsync() =>
        State == MeetingState.Detected && Detected is { } detected
            ? RecordAsync(detected, MeetingTrigger.Detected)
            : Task.CompletedTask;

    /// <summary>"Not now" on the card. The app is not offered again until it releases the microphone.</summary>
    public void Dismiss()
    {
        if (State != MeetingState.Detected) return;
        Detected = null;
        Countdown = null;
        State = MeetingState.Idle;
        Raise();
    }

    /// <summary>Clears a failure.</summary>
    public void DismissProblem()
    {
        if (State != MeetingState.Failed) return;
        Problem = null;
        State = MeetingState.Idle;
        Raise();
    }

    /// <summary>"Take meeting notes": the call on the card, or the first call on the microphone, or everything the computer plays.</summary>
    public Task TakeNotesAsync()
    {
        switch (State)
        {
            case MeetingState.Detected when Detected is { } detected:
                return RecordAsync(detected, MeetingTrigger.Detected);
            case MeetingState.Idle or MeetingState.Failed:
                // Poll marks what it finds as offered, so the card does not pop up over the recording.
                var onMic = _s.Detector?.Poll(Now) is [var found, ..] ? found : null;
                return RecordAsync(onMic, MeetingTrigger.Manual);
            default:
                return Task.CompletedTask;
        }
    }

    /// <summary>Stops recording and starts the final pass. Safe to call more than once.</summary>
    public async Task StopAsync(StopReason reason)
    {
        MeetingSession session;
        MeetingRecord meeting;
        lock (_sync)
        {
            if (State != MeetingState.Recording || _session is null || Current is null) return;
            State = MeetingState.Processing;
            session = _session;
            meeting = Current;
            LastStopReason = reason;
        }

        _s.Log.Info("meeting.stopped", new Dictionary<string, object?> { ["reason"] = reason.ToString() });
        Raise();

        var segments = await session.FinishAsync(CancellationToken.None).ConfigureAwait(false);
        meeting = meeting with
        {
            Segments = segments,
            EndedAt = _s.Clock.Now,
            KeepAudio = KeepAudio,
        };
        _s.Store.Save(meeting);
        await session.DisposeAsync().ConfigureAwait(false);

        _processing = Task.Run(() => FinishAsync(meeting, CancellationToken.None));
        await _processing.ConfigureAwait(false);

        lock (_sync)
        {
            _session = null;
            _recordingApp = null;
            Current = null;
            Notice = null;
            if (State == MeetingState.Processing) State = MeetingState.Idle;
        }

        Raise();
    }

    /// <summary>Finishes meetings a crash left marked as recording. Run once at launch.</summary>
    public async Task RecoverInterruptedAsync(CancellationToken cancellationToken)
    {
        foreach (var id in _s.Store.Interrupted())
        {
            if (_session?.MeetingId == id) continue;
            if (_s.Store.Load(id) is not { } meeting)
            {
                // Nothing readable to finish: leave the folder for "delete all" or retention.
                continue;
            }

            meeting = meeting with
            {
                EndedAt = meeting.EndedAt ?? meeting.StartedAt.AddSeconds(meeting.Segments.Select(s => s.End).DefaultIfEmpty(0).Max()),
            };
            await FinishAsync(meeting, cancellationToken).ConfigureAwait(false);
            _s.Log.Info("meeting.recovered");
        }
    }

    /// <summary>Turning voice prints off deletes every print (decision FLU-9 #3).</summary>
    public void VoicePrintSettingChanged(bool enabled)
    {
        if (!enabled) _s.VoicePrints?.DeleteAll();
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        await StopAsync(StopReason.User).ConfigureAwait(false);
        await _processing.ConfigureAwait(false);
    }

    private void Offer(DetectedMeeting detected, MeetingOptions options)
    {
        Detected = detected;
        Countdown = options.CountdownSeconds > 0 ? options.CountdownSeconds : null;
        Problem = null;
        State = MeetingState.Detected;
        Raise();
    }

    private async Task RecordAsync(DetectedMeeting? detected, MeetingTrigger trigger)
    {
        lock (_sync)
        {
            if (State is MeetingState.Recording or MeetingState.Processing) return;
            State = MeetingState.Recording;
        }

        Detected = null;
        Countdown = null;
        Notice = null;
        Problem = null;
        LastStopReason = null;
        var options = _s.Options();

        if (!_s.Transcriber.IsReady)
        {
            Fail("The speech model is not loaded, so meetings cannot be transcribed. See Settings, or docs/PARAKEET-WINDOWS.md.");
            return;
        }

        if (_s.CreateMicrophone() is not { } microphone)
        {
            Fail("No microphone is available, so the meeting cannot be recorded.");
            return;
        }

        var meeting = new MeetingRecord
        {
            Title = detected is null ? "Meeting" : $"{detected.Service} call",
            AppId = detected?.ProcessName,
            Trigger = trigger,
            StartedAt = _s.Clock.Now,
            KeepAudio = options.KeepAudioByDefault,
            Speakers = [Speaker.Me(), Speaker.Others],
        };
        KeepAudio = meeting.KeepAudio;

        var key = _s.Store.OpenKey(meeting.Id, create: true);
        if (key is null)
        {
            await microphone.DisposeAsync().ConfigureAwait(false);
            Fail("The meeting's encryption key could not be created, so nothing was recorded.");
            return;
        }

        var session = new MeetingSession(meeting.Id, _s.Store, key, detected?.LoopbackProcessId, new MeetingSessionDependencies
        {
            Microphone = microphone,
            Loopback = _s.Loopback,
            WindowsBuild = _s.WindowsBuild,
            Transcriber = _s.Transcriber,
            CreateVoiceActivity = _s.CreateVoiceActivity,
            Correct = _s.Correct,
            Clock = _s.HostClock,
            Log = _s.Log,
        });
        session.SegmentsChanged += (_, _) => Raise();

        try
        {
            await session.StartAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _s.Log.Error("meeting.start_failed", e);
            await session.DisposeAsync().ConfigureAwait(false);
            _s.Store.Delete(meeting.Id);
            Fail("Could not start recording: the meeting folder could not be written.");
            return;
        }

        _s.Store.Save(meeting);
        lock (_sync)
        {
            _session = session;
            _recordingApp = detected;
            Current = meeting;
            Elapsed = 0;
            _ticks = 0;
            if (!session.HasSystemAudio)
            {
                Notice = "Only your microphone is being recorded: Fluence could not capture the call's audio.";
            }
            else if (detected is not null && session.SystemScope == LoopbackScope.WholeSystem)
            {
                Notice = "Recording everything this computer plays, not only the call (this Windows version cannot isolate one app).";
            }
        }

        _s.Log.Info("meeting.recording", new Dictionary<string, object?>
        {
            ["trigger"] = trigger.ToString(),
            ["app"] = detected?.App.Name,
        });
        Raise();
    }

    private async Task TickRecordingAsync(MeetingSession session, MeetingOptions options)
    {
        _ticks++;
        Elapsed = session.Elapsed;
        session.Heartbeat();

        if (session.CaptureFailed)
        {
            await StopAsync(StopReason.CaptureFailed).ConfigureAwait(false);
            return;
        }

        double? appLastOnMic = null;
        if (_recordingApp is { } app && _s.Detector is { } detector)
        {
            detector.Poll(Now);
            var start = Now - session.Elapsed;
            appLastOnMic = detector.LastSeenOnMicrophone(app.Key) is { } seen ? Math.Max(0, seen - start) : 0;
        }

        var policy = new StopPolicy(options.MaxDurationMinutes * 60.0);
        if (policy.Reason(session.Elapsed, session.LastSpeech, appLastOnMic) is { } reason)
        {
            await StopAsync(reason).ConfigureAwait(false);
            return;
        }

        if (_ticks % 30 == 0 && Current is { } meeting)
        {
            Current = meeting with { Segments = session.AllSegments, KeepAudio = KeepAudio };
            _s.Store.Save(Current);
        }

        Raise();
    }

    /// <summary>Diarize, name, write notes, save, drop the spool unless kept, clear the marker.</summary>
    private async Task FinishAsync(MeetingRecord meeting, CancellationToken cancellationToken)
    {
        var directory = _s.Store.DirectoryFor(meeting.Id);
        var voicePrintsOn = _s.Options().VoicePrints && _s.VoicePrints is { IsEnabled: true };
        try
        {
            using var key = _s.Store.OpenKey(meeting.Id, create: false);
            using var system = key is null
                ? null
                : MeetingAudioSpoolReader.Open(MeetingAudioSpool.PathFor(directory, AudioSource.System), key, meeting.Id, AudioSource.System);
            using var diarizer = system is null ? null : _s.CreateDiarizer();
            using var embedder = diarizer is null || !voicePrintsOn ? null : _s.CreateEmbedder();

            var pass = MeetingFinalizer.Attribute(meeting, system, diarizer, embedder, _s.Correct, _s.Log, cancellationToken);
            var named = MeetingFinalizer.Name(pass, voicePrintsOn ? _s.VoicePrints : null, []);
            if (voicePrintsOn) _s.VoicePrints!.SaveCandidates(meeting.Id, pass.Voices);
            meeting = await MeetingNotesWriter.WriteAsync(named, _s.Notes, _s.Clock, _s.Log, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            // The live transcript is still worth keeping.
            _s.Log.Error("meeting.final_pass_failed", e);
            meeting = meeting with { Segments = [.. meeting.Segments.Select(s => s with { IsFinal = true })] };
        }

        _s.Store.Save(meeting);
        if (!meeting.KeepAudio)
        {
            foreach (var source in new[] { AudioSource.Microphone, AudioSource.System })
            {
                TryDelete(MeetingAudioSpool.PathFor(directory, source));
            }
        }

        TryDelete(_s.Store.MarkerPath(meeting.Id));
        _s.Log.Info("meeting.finalized", new Dictionary<string, object?>
        {
            ["segments"] = meeting.Segments.Count,
            ["speakers"] = meeting.Speakers.Count,
            ["notes"] = meeting.Notes is not null,
            ["keptAudio"] = meeting.KeepAudio,
        });
        Finalized?.Invoke(this, meeting.Id);
    }

    private void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _s.Log.Error("meeting.cleanup_failed", e);
        }
    }

    private void Fail(string message)
    {
        lock (_sync)
        {
            State = MeetingState.Failed;
            Problem = message;
        }

        _s.Log.Warning("meeting.failed");
        Raise();
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);
}
