using System.Threading.Channels;
using Murmur.Abstractions;
using Murmur.Dictionary;

namespace Murmur.Core;

/// <summary>What the engine is doing right now.</summary>
public enum DictationState
{
    /// <summary>Waiting for the hotkey.</summary>
    Idle,

    /// <summary>The key is held; audio is being captured.</summary>
    Recording,

    /// <summary>The key is released; an utterance is being transcribed or typed.</summary>
    Transcribing,

    /// <summary>
    /// Idle, but the last dictation failed. <see cref="DictationEngine.LastError"/> says why.
    /// The next key press clears it.
    /// </summary>
    Error,
}

/// <summary>What happened to a transcript after it was produced.</summary>
public enum DeliveryOutcome
{
    /// <summary>Typed into the focused app.</summary>
    Typed,

    /// <summary>Typing is switched off in settings.</summary>
    TypingDisabled,

    /// <summary>Not typed: the focused window changed between key release and typing.</summary>
    FocusChanged,

    /// <summary>Not typed: the focused app runs as administrator and Windows blocks input to it.</summary>
    Blocked,

    /// <summary>Not typed: the injector reported failure or threw.</summary>
    Failed,

    /// <summary>Not typed: recording hit the length limit with the key still held.</summary>
    LimitReached,

    /// <summary>Not typed: the app was quitting.</summary>
    ShuttingDown,
}

/// <summary>One completed dictation.</summary>
public sealed record DictationResult(
    DateTimeOffset At,
    TimeSpan AudioDuration,
    TimeSpan ProcessingTime,
    string Text,
    IReadOnlyList<AppliedCorrection> Corrections)
{
    /// <summary>What the speech engine heard, before the dictionary ran.</summary>
    public string RawText { get; init; } = Text;

    /// <summary>Whether, and why not, the text reached the focused app.</summary>
    public DeliveryOutcome Delivery { get; init; } = DeliveryOutcome.Typed;
}

/// <summary>Timing and policy for <see cref="DictationEngine"/>.</summary>
public sealed record DictationOptions
{
    /// <summary>
    /// A press shorter than this is a tap, not a dictation, and is discarded. Stops every
    /// accidental brush of Right Ctrl from opening the microphone and typing room noise.
    /// </summary>
    public TimeSpan MinimumHold { get; init; } = TimeSpan.FromMilliseconds(250);

    /// <summary>
    /// How long capture continues after the key is released, so the last word is not cut —
    /// people release the key as they finish speaking, not after.
    /// </summary>
    public TimeSpan PostRoll { get; init; } = TimeSpan.FromMilliseconds(250);

    /// <summary>
    /// Recording stops on its own after this long. A key-up lost to a lock screen or a crashed
    /// hook would otherwise leave the microphone open indefinitely (~230 MB of audio an hour).
    /// </summary>
    public TimeSpan MaxRecording { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>How often a recording is checked for a lost key-up, a lock, or the length limit.</summary>
    public TimeSpan WatchdogInterval { get; init; } = TimeSpan.FromMilliseconds(250);

    /// <summary>How long the device gets to stop and drain before the audio is taken as is.</summary>
    public TimeSpan CaptureStopGrace { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>Read on every dictation: whether to type the result. False keeps it in the history only.</summary>
    public Func<bool> InjectText { get; init; } = static () => true;

    /// <summary>Lock and secure-desktop detection, if the platform provides it.</summary>
    public ISessionMonitor? Session { get; init; }

    /// <summary>Where failures are recorded. Never receives transcript text.</summary>
    public IDiagnosticLog Log { get; init; } = NullDiagnosticLog.Instance;
}

/// <summary>
/// The whole dictation flow: hotkey down, capture, hotkey up, transcribe, correct, inject.
/// </summary>
/// <remarks>
/// <para>
/// Deliberately platform-neutral. It targets plain <c>net10.0</c>, so <c>CA1416</c> turns any
/// accidental Windows API call in here into a build error. Everything platform-specific
/// arrives through interfaces, which is what lets the whole path — timing rules included —
/// run against fakes on any machine, in milliseconds.
/// </para>
/// <para>
/// <b>Three tasks, no shared mutable state between them without a lock:</b>
/// </para>
/// <list type="bullet">
/// <item>The <b>hotkey handlers</b> only timestamp the event and enqueue it. They run on the
/// keyboard hook's thread, where anything slow — opening the audio device was, before —
/// makes Windows silently remove the hook.</item>
/// <item>The <b>control loop</b> consumes those events one at a time and owns the recording
/// session: it applies the minimum hold, chord cancellation, the watchdog and the length
/// limit, and snapshots the focused window at release. Each recording's capture runs on its
/// own task and owns its buffer; nobody reads the buffer until that task has finished
/// draining (or a grace period has expired and the buffer is sealed under its lock).</item>
/// <item>The <b>processing loop</b> transcribes finished utterances strictly in order, one at
/// a time, so a quick second dictation is neither lost nor typed before the first.</item>
/// </list>
/// <para>
/// <b>Nothing fails silently.</b> Every exception on these paths is caught, logged (without
/// text) and turned into <see cref="DictationState.Error"/> with a message the window shows.
/// </para>
/// </remarks>
public sealed class DictationEngine : IAsyncDisposable
{
    private readonly IAudioCapture _capture;
    private readonly IHotkeySource _hotkey;
    private readonly ITranscriber _transcriber;
    private readonly ITextInjector _injector;
    private readonly IClock _clock;
    private readonly Func<IReadOnlyList<DictionaryEntry>> _dictionary;
    private readonly DictationOptions _options;
    private readonly IDiagnosticLog _log;

    private readonly Channel<Signal> _signals =
        Channel.CreateUnbounded<Signal>(new UnboundedChannelOptions { SingleReader = true });

    private readonly Channel<Utterance> _utterances =
        Channel.CreateUnbounded<Utterance>(new UnboundedChannelOptions { SingleReader = true });

    private readonly CancellationTokenSource _shutdown = new();
    private readonly Task _controlLoop;
    private readonly Task _processLoop;
    private readonly Task _watchdogLoop;
    private readonly Lock _finishing = new();
    private readonly HashSet<Task> _finishers = [];

    /// <summary>The recording in progress. Touched only by the control loop.</summary>
    private Session? _session;

    /// <summary>The previous recording's capture, which the next one waits for before opening the device.</summary>
    private Task _lastCapture = Task.CompletedTask;

    private volatile Session? _visibleSession;
    private int _pending;
    private volatile string? _error;
    private float _level;
    private int _disposed;

    private enum SignalKind { Press, Release, Chord, Toggle, Interrupted, Tick }

    private readonly record struct Signal(SignalKind Kind, DateTimeOffset At);

    private enum EndReason { Released, LimitReached }

    private sealed record Utterance(
        float[] Samples, DateTimeOffset ReleasedAt, FocusTarget Target, EndReason Reason);

    private sealed class Session(bool fromHotkey, DateTimeOffset pressedAt, DateTimeOffset startedAt)
    {
        public bool FromHotkey { get; } = fromHotkey;
        public DateTimeOffset PressedAt { get; } = pressedAt;
        public DateTimeOffset StartedAt { get; } = startedAt;
        public CancellationTokenSource Stop { get; } = new();
        public Lock Sync { get; } = new();
        public List<float> Buffer { get; } = [];
        public bool Sealed { get; set; }
        public Exception? CaptureError { get; set; }
        public Task Capture { get; set; } = Task.CompletedTask;
        public int MissedKeyDownReadings { get; set; }
    }

    /// <summary>Current state.</summary>
    public DictationState State =>
        _visibleSession is not null ? DictationState.Recording
        : Volatile.Read(ref _pending) > 0 ? DictationState.Transcribing
        : _error is not null ? DictationState.Error
        : DictationState.Idle;

    /// <summary>Why the last dictation failed, in words for the user; null when it did not.</summary>
    public string? LastError => _error;

    /// <summary>Most recent input level, 0…1. Drives the meter.</summary>
    public float Level => Volatile.Read(ref _level);

    /// <summary>Raised when a dictation completes and produced text, whether or not it was typed.</summary>
    /// <remarks>Raised after typing, on a background thread.</remarks>
    public event EventHandler<DictationResult>? Completed;

    /// <summary>Raised whenever <see cref="State"/>, <see cref="Level"/> or <see cref="LastError"/> changes.</summary>
    public event EventHandler? Changed;

    /// <summary>Wires the engine to its platform implementations.</summary>
    /// <param name="capture">Microphone source.</param>
    /// <param name="hotkey">Push-to-talk source.</param>
    /// <param name="transcriber">Speech engine. Disposed with the engine.</param>
    /// <param name="injector">Where finished text goes.</param>
    /// <param name="dictionary">
    /// Read fresh on every utterance rather than captured once, so edits take effect without
    /// a restart. Must return a snapshot that is safe to read on another thread.
    /// </param>
    /// <param name="clock">Time source; defaults to the system clock.</param>
    /// <param name="options">Timing and policy; defaults are the shipping values.</param>
    public DictationEngine(
        IAudioCapture capture,
        IHotkeySource hotkey,
        ITranscriber transcriber,
        ITextInjector injector,
        Func<IReadOnlyList<DictionaryEntry>> dictionary,
        IClock? clock = null,
        DictationOptions? options = null)
    {
        _capture = capture;
        _hotkey = hotkey;
        _transcriber = transcriber;
        _injector = injector;
        _dictionary = dictionary;
        _clock = clock ?? SystemClock.Instance;
        _options = options ?? new DictationOptions();
        _log = _options.Log;

        _hotkey.Pressed += OnPressed;
        _hotkey.Released += OnReleased;
        _hotkey.ChordPressed += OnChord;
        if (_options.Session is { } session) session.Interrupted += OnSessionInterrupted;

        _controlLoop = Task.Run(ControlLoopAsync);
        _processLoop = Task.Run(ProcessLoopAsync);
        _watchdogLoop = Task.Run(WatchdogLoopAsync);
    }

    /// <summary>Arms the hotkey and the session monitor.</summary>
    /// <returns>False if the hook could not be installed.</returns>
    public bool Start()
    {
        _options.Session?.Start();
        return _hotkey.Start();
    }

    /// <summary>
    /// Starts or stops recording from a button rather than the hotkey.
    /// </summary>
    /// <remarks>
    /// Routed through the same queue as the hotkey, deliberately. Two independent paths into
    /// recording would eventually disagree about whether it is running.
    /// </remarks>
    public void TogglePushToTalk() => Enqueue(SignalKind.Toggle);

    // The hook thread's entire involvement: a timestamp and a non-blocking write.
    private void OnPressed(object? sender, EventArgs e) => Enqueue(SignalKind.Press);

    private void OnReleased(object? sender, EventArgs e) => Enqueue(SignalKind.Release);

    private void OnChord(object? sender, EventArgs e) => Enqueue(SignalKind.Chord);

    private void OnSessionInterrupted(object? sender, EventArgs e) => Enqueue(SignalKind.Interrupted);

    private void Enqueue(SignalKind kind) => _signals.Writer.TryWrite(new Signal(kind, _clock.Now));

    private async Task ControlLoopAsync()
    {
        try
        {
            await foreach (var signal in _signals.Reader.ReadAllAsync(_shutdown.Token).ConfigureAwait(false))
            {
                try
                {
                    Handle(signal);
                }
                catch (Exception e)
                {
                    Fail("engine.signal_failed", e, "Dictation failed unexpectedly. Details are in the log.");
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Shutting down.
        }
    }

    private void Handle(Signal signal)
    {
        var session = _session;

        switch (signal.Kind)
        {
            case SignalKind.Press when session is null:
                Begin(fromHotkey: true, signal.At);
                break;

            case SignalKind.Toggle when session is null:
                Begin(fromHotkey: false, signal.At);
                break;

            case SignalKind.Toggle:
                End(session, EndReason.Released, signal.At);
                break;

            case SignalKind.Release when session is { FromHotkey: true }:
                if (signal.At - session.PressedAt < _options.MinimumHold) Cancel(session, null);
                else End(session, EndReason.Released, signal.At);
                break;

            case SignalKind.Chord when session is { FromHotkey: true }:
                // Right Ctrl+C and friends: a shortcut, not a dictation. Silently dropped.
                Cancel(session, null);
                break;

            case SignalKind.Interrupted when session is not null:
                Cancel(session, "Recording cancelled: the session was locked or switched.");
                break;

            case SignalKind.Tick when session is not null:
                CheckWatchdog(session);
                break;
        }
    }

    private void CheckWatchdog(Session session)
    {
        var now = _clock.Now;

        if (now - session.StartedAt >= _options.MaxRecording)
        {
            End(session, EndReason.LimitReached, now);
            return;
        }

        if (_options.Session is { IsInputDesktopActive: false })
        {
            Cancel(session, "Recording cancelled: the screen was locked or a secure desktop "
                          + "(UAC, Ctrl+Alt+Del) took over the keyboard.");
            return;
        }

        if (!session.FromHotkey || now - session.PressedAt < _options.MinimumHold) return;

        // The hook reports key-up before the OS updates its key-state table, so one "up"
        // reading can race a genuine release still in the queue. Two in a row, a watchdog
        // interval apart, cannot.
        if (_hotkey.IsKeyDown() == false)
        {
            if (++session.MissedKeyDownReadings >= 2)
            {
                Cancel(session, "Recording cancelled: the push-to-talk key is up but its release "
                              + "was never received (the keyboard hook may have been removed).");
            }
        }
        else
        {
            session.MissedKeyDownReadings = 0;
        }
    }

    private void Begin(bool fromHotkey, DateTimeOffset pressedAt)
    {
        _error = null;

        var session = new Session(fromHotkey, pressedAt, _clock.Now);
        var previous = _lastCapture;

        // Off this loop and off the hook thread: opening the device is COM activation plus
        // IAudioClient.Initialize, tens of milliseconds even when nothing goes wrong.
        session.Capture = Task.Run(() => CaptureAsync(session, previous));
        _lastCapture = session.Capture;

        _session = session;
        _visibleSession = session;
        RaiseChanged();
    }

    private async Task CaptureAsync(Session session, Task previous)
    {
        // One device, one session at a time: a fast re-press waits for the previous
        // recording to finish draining rather than opening the device twice.
        try { await previous.ConfigureAwait(false); }
        catch (Exception) { /* already reported by its own session */ }

        try
        {
            await foreach (var chunk in _capture.CaptureAsync(session.Stop.Token).ConfigureAwait(false))
            {
                lock (session.Sync)
                {
                    if (session.Sealed) break;
                    session.Buffer.AddRange(chunk.Samples.Span);
                }

                if (ReferenceEquals(_visibleSession, session))
                {
                    Volatile.Write(ref _level, chunk.Rms());
                    RaiseChanged();
                }
            }
        }
        catch (OperationCanceledException) when (session.Stop.IsCancellationRequested)
        {
            // An implementation that throws on stop rather than draining. Tolerated.
        }
        catch (Exception e)
        {
            session.CaptureError = e;
        }
        finally
        {
            Volatile.Write(ref _level, 0);
            RaiseChanged();
        }
    }

    private void End(Session session, EndReason reason, DateTimeOffset releasedAt)
    {
        // Counted before the session is cleared, so State goes Recording → Transcribing
        // without ever passing through Idle.
        Interlocked.Increment(ref _pending);
        _session = null;
        _visibleSession = null;

        // Snapshot the focused window now, at release: that is where the user meant the text
        // to go. If it is different by the time the text is ready, nothing is typed.
        var target = reason == EndReason.Released ? SafeFocusTarget() : FocusTarget.Unknown;

        Track(FinishAsync(session, reason, releasedAt, target));
        RaiseChanged();
    }

    private void Cancel(Session session, string? error)
    {
        _session = null;
        _visibleSession = null;
        session.Stop.Cancel();

        if (error is not null)
        {
            _error = error;
            _log.Warning("dictation.cancelled", fields: new Dictionary<string, object?> { ["reason"] = error });
        }

        RaiseChanged();
    }

    private async Task FinishAsync(Session session, EndReason reason, DateTimeOffset releasedAt, FocusTarget target)
    {
        var queued = false;
        try
        {
            if (reason == EndReason.Released && _options.PostRoll > TimeSpan.Zero)
            {
                await Task.Delay(_options.PostRoll, _shutdown.Token).ConfigureAwait(false);
            }

            await session.Stop.CancelAsync().ConfigureAwait(false);

            // B5: the buffer is read only once the capture loop has drained and finished — or,
            // if the device will not stop, after sealing it under its lock so no late chunk can
            // be appended while it is copied.
            var drained = await Task.WhenAny(session.Capture, Task.Delay(_options.CaptureStopGrace)).ConfigureAwait(false)
                          == session.Capture;

            float[] samples;
            lock (session.Sync)
            {
                session.Sealed = true;
                samples = [.. session.Buffer];
            }

            if (!drained) _log.Warning("capture.stop_timed_out");

            if (session.CaptureError is { } captureError)
            {
                if (samples.Length == 0)
                {
                    Fail("capture.failed", captureError,
                        "The microphone could not be opened. Check that one is connected and that "
                        + "Windows lets desktop apps use it (Settings → Privacy & security → Microphone).");
                    return;
                }

                // Unplugged mid-sentence: keep what was captured rather than losing it all.
                _log.Warning("capture.interrupted", captureError);
            }

            await _utterances.Writer.WriteAsync(new Utterance(samples, releasedAt, target, reason)).ConfigureAwait(false);
            queued = true;
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
        {
            // Quitting.
        }
        catch (ChannelClosedException)
        {
            // Quitting.
        }
        catch (Exception e)
        {
            Fail("dictation.finish_failed", e, "Dictation failed unexpectedly. Details are in the log.");
        }
        finally
        {
            // Whatever happened above — including quitting during the post-roll — the device
            // must be told to stop, or its capture task runs forever and shutdown waits on it.
            // session.Stop is deliberately not disposed: a capture that missed the grace
            // period may still be observing its token.
            session.Stop.Cancel();

            if (!queued)
            {
                Interlocked.Decrement(ref _pending);
                RaiseChanged();
            }
        }
    }

    private async Task ProcessLoopAsync()
    {
        await foreach (var utterance in _utterances.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                await ProcessAsync(utterance).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Fail("transcription.failed", e, "Transcription failed — the recording was not typed. "
                                                + "Details are in the log.");
            }
            finally
            {
                Interlocked.Decrement(ref _pending);
                RaiseChanged();
            }
        }
    }

    private async Task ProcessAsync(Utterance utterance)
    {
        if (utterance.Samples.Length == 0 || _shutdown.IsCancellationRequested) return;

        var audio = new ReadOnlyMemory<float>(utterance.Samples);

        if (!_transcriber.IsReady
            && !await _transcriber.LoadAsync(_shutdown.Token).ConfigureAwait(false))
        {
            _error = "The speech model is not loaded, so nothing was transcribed. See Settings → Model.";
            _log.Warning("transcription.model_not_ready");
            return;
        }

        var entries = _dictionary();
        var bias = DictionaryCorrector.BiasPhrases(entries);

        var pieces = AudioSegmenter.SplitWithSeams(audio);
        var transcripts = new List<(string, bool)>(pieces.Count);

        foreach (var piece in pieces)
        {
            var text = await _transcriber
                .TranscribeAsync(piece.Samples, bias, CancellationToken.None)
                .ConfigureAwait(false);

            transcripts.Add((text ?? string.Empty, piece.OverlapsPrevious));
        }

        var raw = TranscriptJoiner.Join(transcripts);
        if (string.IsNullOrWhiteSpace(raw)) return;

        // The dictionary runs last and unconditionally. Biasing only raises the odds of the
        // right word; this is the pass that guarantees it.
        var (corrected, applied) = new DictionaryCorrector(entries).Apply(raw);

        // Typed first, recorded second: the history write must never delay the text.
        var delivery = await DeliverAsync(corrected, utterance).ConfigureAwait(false);

        var result = new DictationResult(
            At: utterance.ReleasedAt,
            AudioDuration: TimeSpan.FromSeconds((double)audio.Length / AudioChunk.SampleRate),
            ProcessingTime: _clock.Now - utterance.ReleasedAt,
            Text: corrected,
            Corrections: applied)
        {
            RawText = raw,
            Delivery = delivery,
        };

        try
        {
            Completed?.Invoke(this, result);
        }
        catch (Exception e)
        {
            // A subscriber (the history write) failing costs the history entry, nothing more.
            _log.Error("dictation.completed_handler_failed", e);
        }

        var message = delivery switch
        {
            DeliveryOutcome.FocusChanged =>
                "Not typed: a different window was focused by the time the text was ready. It is in the history.",
            DeliveryOutcome.Blocked =>
                "Not typed: the focused app runs as administrator, and Windows blocks typing into it "
                + "from a normal app. The text is in the history.",
            DeliveryOutcome.Failed =>
                "Typing into the focused app failed. The text is in the history.",
            DeliveryOutcome.LimitReached => string.Create(System.Globalization.CultureInfo.InvariantCulture,
                $"Recording stopped at the {_options.MaxRecording.TotalMinutes:0}-minute limit with the key still held, so the text was not typed. It is in the history."),
            _ => null,
        };

        if (message is not null)
        {
            _error = message;
            _log.Warning("dictation.not_typed", fields: new Dictionary<string, object?> { ["outcome"] = delivery });
        }
    }

    private async Task<DeliveryOutcome> DeliverAsync(string text, Utterance utterance)
    {
        if (_shutdown.IsCancellationRequested) return DeliveryOutcome.ShuttingDown;
        if (utterance.Reason == EndReason.LimitReached) return DeliveryOutcome.LimitReached;
        if (!_options.InjectText()) return DeliveryOutcome.TypingDisabled;

        var now = SafeFocusTarget();
        if (utterance.Target.Window != 0 && now.Window != utterance.Target.Window) return DeliveryOutcome.FocusChanged;
        if (now.IsBlocked) return DeliveryOutcome.Blocked;

        try
        {
            return await _injector.InjectAsync(text, CancellationToken.None).ConfigureAwait(false)
                ? DeliveryOutcome.Typed
                : DeliveryOutcome.Failed;
        }
        catch (Exception e)
        {
            _log.Error("inject.failed", e);
            return DeliveryOutcome.Failed;
        }
    }

    private FocusTarget SafeFocusTarget()
    {
        try
        {
            return _injector.GetFocusTarget();
        }
        catch (Exception e)
        {
            _log.Warning("inject.focus_query_failed", e);
            return FocusTarget.Unknown;
        }
    }

    private async Task WatchdogLoopAsync()
    {
        using var timer = new PeriodicTimer(_options.WatchdogInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(_shutdown.Token).ConfigureAwait(false))
            {
                if (_visibleSession is not null) Enqueue(SignalKind.Tick);
            }
        }
        catch (OperationCanceledException)
        {
            // Shutting down.
        }
    }

    private void Fail(string eventName, Exception exception, string message)
    {
        _error = message;
        _log.Error(eventName, exception);
        RaiseChanged();
    }

    private void Track(Task task)
    {
        lock (_finishing) _finishers.Add(task);
        _ = task.ContinueWith(
            t => { lock (_finishing) _finishers.Remove(t); },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void RaiseChanged()
    {
        try
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception e)
        {
            _log.Error("engine.changed_handler_failed", e);
        }
    }

    /// <inheritdoc />
    /// <remarks>
    /// Order matters: stop new input, cancel the recording, let a decode already running
    /// finish (it cannot be interrupted in native code), and only then free the engine.
    /// Queued utterances are dropped, not typed — the user asked to quit.
    /// </remarks>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;

        _hotkey.Pressed -= OnPressed;
        _hotkey.Released -= OnReleased;
        _hotkey.ChordPressed -= OnChord;
        _hotkey.Dispose();

        if (_options.Session is { } session)
        {
            session.Interrupted -= OnSessionInterrupted;
            session.Dispose();
        }

        _signals.Writer.TryComplete();
        await _shutdown.CancelAsync().ConfigureAwait(false);
        await IgnoreFailures(_controlLoop).ConfigureAwait(false);
        await IgnoreFailures(_watchdogLoop).ConfigureAwait(false);

        _session?.Stop.Cancel();

        Task[] finishers;
        lock (_finishing) finishers = [.. _finishers];
        await IgnoreFailures(Task.WhenAll(finishers)).ConfigureAwait(false);

        _utterances.Writer.TryComplete();
        await IgnoreFailures(_processLoop).ConfigureAwait(false);
        await IgnoreFailures(_lastCapture).ConfigureAwait(false);

        await _capture.DisposeAsync().ConfigureAwait(false);
        await _transcriber.DisposeAsync().ConfigureAwait(false);
        _shutdown.Dispose();
    }

    private static async Task IgnoreFailures(Task task)
    {
        try { await task.ConfigureAwait(false); }
        catch (Exception) { /* already logged where it happened */ }
    }
}
