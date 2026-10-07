using System.Runtime.CompilerServices;
using Murmur.Abstractions;

namespace Murmur.Testing;

/// <summary>
/// Test doubles for the four platform interfaces.
/// </summary>
/// <remarks>
/// These are what make the Windows app's behaviour verifiable from a machine that is not
/// Windows. Everything interesting — the state machine, chunking, the correction pass, the
/// silence case — runs against these in milliseconds, on any platform, in CI.
/// </remarks>
public sealed class FakeAudioCapture : IAudioCapture
{
    private readonly float[] _samples;
    private readonly int _chunkSize;
    private readonly bool _loop;

    /// <summary>Replays a fixed buffer as a series of chunks.</summary>
    /// <param name="samples">16 kHz mono float.</param>
    /// <param name="chunkSize">Samples per chunk; defaults to 20 ms.</param>
    /// <param name="loop">
    /// Keep replaying until stopped, like a real microphone, rather than ending when the
    /// buffer runs out.
    /// </param>
    public FakeAudioCapture(float[] samples, int chunkSize = AudioChunk.SampleRate / 50, bool loop = false)
    {
        _samples = samples;
        _chunkSize = Math.Max(1, chunkSize);
        _loop = loop;
    }

    /// <summary>A microphone that hears a steady tone until stopped.</summary>
    public static FakeAudioCapture Live(float amplitude = 0.5f)
    {
        var tone = Tone(0.2, amplitude);
        return new FakeAudioCapture(tone._samples, loop: true);
    }

    /// <summary>When set, opening the device throws this.</summary>
    public Exception? OpenError { get; set; }

    /// <summary>How many times the device was opened.</summary>
    public int Opens { get; private set; }

    /// <summary>Chunks delivered after stop was requested — the drained tail.</summary>
    public int ChunksAfterStop { get; private set; }

    /// <summary>Chunks still "in the driver" when stop is requested, delivered before the sequence ends.</summary>
    public int TailChunks { get; set; } = 2;

    /// <summary>Blocks the opening thread this long, like COM activation and IAudioClient.Initialize.</summary>
    public TimeSpan OpenDelay { get; set; }

    /// <summary>Every chunk handed out, in samples.</summary>
    public int SamplesDelivered => Volatile.Read(ref _samplesDelivered);

    private int _samplesDelivered;

    /// <summary>Generates <paramref name="seconds"/> of a steady tone at <paramref name="amplitude"/>.</summary>
    public static FakeAudioCapture Tone(double seconds, float amplitude = 0.5f)
    {
        var count = (int)(seconds * AudioChunk.SampleRate);
        var samples = new float[count];
        for (var i = 0; i < count; i++)
        {
            samples[i] = amplitude * MathF.Sin(2 * MathF.PI * 440 * i / AudioChunk.SampleRate);
        }
        return new FakeAudioCapture(samples);
    }

    /// <summary>Generates <paramref name="seconds"/> of digital silence.</summary>
    public static FakeAudioCapture Silence(double seconds) =>
        new(new float[(int)(seconds * AudioChunk.SampleRate)]);

    /// <inheritdoc />
    public bool IsCapturing { get; private set; }

    /// <inheritdoc />
    /// <remarks>
    /// Honours the drain contract: once <paramref name="stopRequested"/> is cancelled it delivers
    /// <see cref="TailChunks"/> more chunks, then ends normally.
    /// </remarks>
    public async IAsyncEnumerable<AudioChunk> CaptureAsync(
        [EnumeratorCancellation] CancellationToken stopRequested)
    {
        Opens++;
        if (OpenDelay > TimeSpan.Zero) Thread.Sleep(OpenDelay);
        if (OpenError is not null) throw OpenError;

        IsCapturing = true;
        try
        {
            var tail = -1;
            var offset = 0;
            while (true)
            {
                if (offset >= _samples.Length)
                {
                    if (!_loop)
                    {
                        // Like a real microphone, the stream does not end by itself: it ends
                        // when stop is requested.
                        try { await Task.Delay(Timeout.Infinite, stopRequested); }
                        catch (OperationCanceledException) { /* stop requested */ }
                        yield break;
                    }

                    offset = 0;
                }

                if (stopRequested.IsCancellationRequested)
                {
                    if (tail < 0) tail = TailChunks;
                    if (tail-- == 0) yield break;
                    ChunksAfterStop++;
                }

                var length = Math.Min(_chunkSize, _samples.Length - offset);

                // A fresh array per chunk, deliberately: a fake that reuses one buffer would
                // hide the very aliasing bug real capture implementations are prone to.
                var chunk = new float[length];
                Array.Copy(_samples, offset, chunk, 0, length);
                offset += length;
                Interlocked.Add(ref _samplesDelivered, length);
                yield return new AudioChunk(chunk);

                if (_loop) await Task.Delay(1, CancellationToken.None);
                else await Task.Yield();
            }
        }
        finally
        {
            IsCapturing = false;
        }
    }

    /// <inheritdoc />
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

/// <summary>A hotkey you press from a test.</summary>
public sealed class FakeHotkeySource : IHotkeySource
{
    /// <inheritdoc />
    public event EventHandler? Pressed;

    /// <inheritdoc />
    public event EventHandler? Released;

    /// <inheritdoc />
    public event EventHandler? ChordPressed;

    /// <summary>What <see cref="IsKeyDown"/> reports. Null (unknown) by default.</summary>
    public bool? PhysicallyDown { get; set; }

    /// <inheritdoc />
    public bool? IsKeyDown() => PhysicallyDown;

    /// <summary>Raises <see cref="ChordPressed"/>.</summary>
    public void PressOtherKey() => ChordPressed?.Invoke(this, EventArgs.Empty);

    /// <summary>Whether <see cref="Start"/> has been called.</summary>
    public bool IsRunning { get; private set; }

    /// <inheritdoc />
    public bool Start() { IsRunning = true; return true; }

    /// <inheritdoc />
    public void StopListening() => IsRunning = false;

    /// <summary>Raises <see cref="Pressed"/>.</summary>
    public void Press() => Pressed?.Invoke(this, EventArgs.Empty);

    /// <summary>Raises <see cref="Released"/>.</summary>
    public void Release() => Released?.Invoke(this, EventArgs.Empty);

    /// <inheritdoc />
    public void Dispose() => StopListening();
}

/// <summary>Returns canned transcripts and records what it was asked to transcribe.</summary>
public sealed class FakeTranscriber : ITranscriber
{
    private readonly Queue<string> _responses;

    /// <summary>Each call returns the next response; the last repeats once exhausted.</summary>
    public FakeTranscriber(params string[] responses) => _responses = new Queue<string>(responses);

    /// <summary>How many segments were submitted. Reveals chunking behaviour.</summary>
    public List<int> SegmentLengths { get; } = [];

    /// <summary>The bias list handed over on the most recent call.</summary>
    public IReadOnlyList<string> LastBias { get; private set; } = [];

    /// <inheritdoc />
    public bool IsReady { get; private set; }

    /// <summary>When set, <see cref="LoadAsync"/> throws this instead of loading.</summary>
    public Exception? LoadError { get; set; }

    /// <summary>When set, <see cref="TranscribeAsync"/> throws this.</summary>
    public Exception? TranscribeError { get; set; }

    /// <summary>When set, every transcription waits for this task first — a "slow decode".</summary>
    public Task? TranscribeGate { get; set; }

    /// <summary>How many times <see cref="LoadAsync"/> ran.</summary>
    public int LoadCalls { get; private set; }

    /// <summary>Whether a transcription is running right now.</summary>
    public bool IsTranscribing { get; private set; }

    /// <summary>Whether <see cref="DisposeAsync"/> ran, and whether a transcription was running at the time.</summary>
    public (bool Disposed, bool WhileTranscribing) Disposal { get; private set; }

    /// <inheritdoc />
    public ValueTask<bool> LoadAsync(CancellationToken cancellationToken)
    {
        LoadCalls++;
        if (LoadError is not null) throw LoadError;

        IsReady = true;
        return ValueTask.FromResult(true);
    }

    /// <inheritdoc />
    public async ValueTask<string> TranscribeAsync(
        ReadOnlyMemory<float> samples,
        IReadOnlyList<string> biasPhrases,
        CancellationToken cancellationToken)
    {
        IsTranscribing = true;
        try
        {
            if (TranscribeGate is not null) await TranscribeGate.ConfigureAwait(false);
            if (TranscribeError is not null) throw TranscribeError;

            lock (SegmentLengths)
            {
                SegmentLengths.Add(samples.Length);
                LastBias = biasPhrases;
                return _responses.Count > 1 ? _responses.Dequeue() : _responses.Peek();
            }
        }
        finally
        {
            IsTranscribing = false;
        }
    }

    /// <inheritdoc />
    public ValueTask DisposeAsync()
    {
        Disposal = (true, IsTranscribing);
        return ValueTask.CompletedTask;
    }
}

/// <summary>
/// Records what would have been typed.
/// </summary>
/// <remarks>
/// Asserting on intent rather than on an OS effect is deliberate: whether a keystroke really
/// lands in another application's text field is the one thing CI cannot observe, because
/// runners cannot take the foreground.
/// </remarks>
public sealed class RecordingTextInjector : ITextInjector
{
    /// <summary>Everything injected, in order.</summary>
    public List<string> Injected { get; } = [];

    /// <summary>What <see cref="GetFocusTarget"/> returns. Change it to simulate a focus switch.</summary>
    public FocusTarget Focus { get; set; } = FocusTarget.Unknown;

    /// <summary>What <see cref="InjectAsync"/> returns.</summary>
    public bool Succeeds { get; set; } = true;

    /// <summary>Called on every focus query, before it answers — lets a test move focus "during" a dictation.</summary>
    public Action<RecordingTextInjector>? OnFocusQuery { get; set; }

    /// <inheritdoc />
    public FocusTarget GetFocusTarget()
    {
        OnFocusQuery?.Invoke(this);
        return Focus;
    }

    /// <inheritdoc />
    public ValueTask<bool> InjectAsync(string text, CancellationToken cancellationToken)
    {
        lock (Injected) Injected.Add(text);
        return ValueTask.FromResult(Succeeds);
    }
}

/// <summary>A clock you advance by hand. Thread-safe: the engine reads it from several tasks.</summary>
public sealed class FakeClock : IClock
{
    private readonly Lock _sync = new();
    private DateTimeOffset _now = new(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);

    /// <inheritdoc />
    public DateTimeOffset Now
    {
        get { lock (_sync) return _now; }
    }

    /// <summary>Moves time forward.</summary>
    public void Advance(TimeSpan by)
    {
        lock (_sync) _now += by;
    }
}

/// <summary>A session you lock from a test.</summary>
public sealed class FakeSessionMonitor : ISessionMonitor
{
    /// <inheritdoc />
    public event EventHandler? Interrupted;

    /// <inheritdoc />
    public bool IsInputDesktopActive { get; set; } = true;

    /// <summary>Whether <see cref="Start"/> was called.</summary>
    public bool Started { get; private set; }

    /// <inheritdoc />
    public void Start() => Started = true;

    /// <summary>Raises <see cref="Interrupted"/>, as a Win+L would.</summary>
    public void Lock() => Interrupted?.Invoke(this, EventArgs.Empty);

    /// <inheritdoc />
    public void Dispose()
    {
    }
}

/// <summary>
/// A reversible stand-in for DPAPI: XORs with a per-instance byte and adds a marker, so a test
/// can tell a protected blob from a raw one and simulate "another user's key".
/// </summary>
public sealed class FakeSecretProtector : ISecretProtector
{
    private const byte Marker = 0xD7;
    private readonly byte _mask;

    /// <summary>Creates a protector; two with different <paramref name="identity"/> cannot read each other's blobs.</summary>
    public FakeSecretProtector(byte identity = 0x5A) => _mask = identity;

    /// <summary>How many times <see cref="Unprotect"/> was called.</summary>
    public int UnprotectCalls { get; private set; }

    /// <inheritdoc />
    public byte[] Protect(byte[] secret)
    {
        var blob = new byte[secret.Length + 2];
        blob[0] = Marker;
        blob[1] = _mask;
        for (var i = 0; i < secret.Length; i++) blob[i + 2] = (byte)(secret[i] ^ _mask);
        return blob;
    }

    /// <inheritdoc />
    public byte[] Unprotect(byte[] protectedSecret)
    {
        UnprotectCalls++;
        if (protectedSecret.Length < 2 || protectedSecret[0] != Marker || protectedSecret[1] != _mask)
        {
            throw new System.Security.Cryptography.CryptographicException("Key not valid for use in specified state.");
        }

        var secret = new byte[protectedSecret.Length - 2];
        for (var i = 0; i < secret.Length; i++) secret[i] = (byte)(protectedSecret[i + 2] ^ _mask);
        return secret;
    }
}

/// <summary>Captures diagnostic events so a test can assert on them.</summary>
public sealed class RecordingDiagnosticLog : IDiagnosticLog
{
    private readonly List<(LogLevel Level, string Name, Exception? Exception, IReadOnlyDictionary<string, object?>? Fields)> _events = [];

    /// <summary>Everything logged so far, in order.</summary>
    public IReadOnlyList<(LogLevel Level, string Name, Exception? Exception, IReadOnlyDictionary<string, object?>? Fields)> Events
    {
        get { lock (_events) return [.. _events]; }
    }

    /// <inheritdoc />
    public void Write(LogLevel level, string eventName, Exception? exception = null,
        IReadOnlyDictionary<string, object?>? fields = null)
    {
        lock (_events) _events.Add((level, eventName, exception, fields));
    }
}
