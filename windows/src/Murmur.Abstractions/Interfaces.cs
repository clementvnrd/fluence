namespace Murmur.Abstractions;

/// <summary>
/// A block of captured audio: mono, 32-bit float, 16 kHz, samples in [-1, 1].
/// </summary>
/// <remarks>
/// The format is fixed at this boundary on purpose. Every speech model this app will use
/// wants 16 kHz mono float, and resampling is a device concern — so the platform layer deals
/// with whatever the hardware offers and nothing above it ever has to ask.
/// </remarks>
/// <param name="Samples">Owned by the receiver. The producer must not reuse the buffer.</param>
public readonly record struct AudioChunk(ReadOnlyMemory<float> Samples)
{
    /// <summary>The sample rate every implementation must deliver.</summary>
    public const int SampleRate = 16000;

    /// <summary>Duration of this chunk.</summary>
    public TimeSpan Duration => TimeSpan.FromSeconds((double)Samples.Length / SampleRate);

    /// <summary>
    /// Root-mean-square amplitude, 0…1. Drives the level meter.
    /// </summary>
    public float Rms()
    {
        var span = Samples.Span;
        if (span.Length == 0) return 0;

        double sum = 0;
        foreach (var sample in span) sum += (double)sample * sample;
        return (float)Math.Sqrt(sum / span.Length);
    }
}

/// <summary>Captures microphone audio.</summary>
/// <remarks>
/// Implementations must deliver <see cref="AudioChunk"/>s already converted to 16 kHz mono
/// float, and must hand over buffers they will not touch again — the single most common
/// audio bug on every platform is a capture callback reusing one array.
/// </remarks>
public interface IAudioCapture : IAsyncDisposable
{
    /// <summary>Whether capture is currently running.</summary>
    bool IsCapturing { get; }

    /// <summary>Opens the device and yields chunks until <paramref name="stopRequested"/> is cancelled.</summary>
    /// <param name="stopRequested">
    /// <b>A request to stop, not an abort.</b> When it is cancelled the implementation stops
    /// the device, then still yields every chunk it has already captured — including what is
    /// buffered in the driver and any resampler — and only then ends the sequence, normally,
    /// without throwing. Cancelling reads instead throws away the last word.
    /// </param>
    /// <remarks>
    /// Opening the device (COM activation, <c>IAudioClient.Initialize</c>) happens on the first
    /// <c>MoveNextAsync</c>, on the caller's thread. Never call this from a keyboard hook.
    /// </remarks>
    IAsyncEnumerable<AudioChunk> CaptureAsync(CancellationToken stopRequested);
}

/// <summary>Raised when the push-to-talk key goes down or comes up.</summary>
/// <remarks>
/// <b>Handlers run on the hook thread and must return immediately</b> — enqueue and leave.
/// Windows silently removes a low-level hook whose callback exceeds <c>LowLevelHooksTimeout</c>
/// (at most 1 s), and the app never finds out.
/// </remarks>
public interface IHotkeySource : IDisposable
{
    /// <summary>The key is held.</summary>
    event EventHandler? Pressed;

    /// <summary>The key was released.</summary>
    event EventHandler? Released;

    /// <summary>
    /// Another key went down while the push-to-talk key was held — a shortcut such as
    /// Right Ctrl+C, not a dictation.
    /// </summary>
    event EventHandler? ChordPressed;

    /// <summary>Begins listening.</summary>
    /// <returns>False if the hook could not be installed.</returns>
    bool Start();

    /// <summary>Stops listening.</summary>
    /// <remarks>Not named <c>Stop</c>: that is a reserved word in VB, which CA1716 flags
    /// on any interface member.</remarks>
    void StopListening();

    /// <summary>
    /// Whether the push-to-talk key is physically down right now, asked of the OS directly
    /// rather than inferred from hook events — so a key-up the hook never saw can be noticed.
    /// </summary>
    /// <returns>Null when the state cannot be known (for example, a key the hook swallows).</returns>
    bool? IsKeyDown();
}

/// <summary>The window text would be typed into, captured at a moment in time.</summary>
/// <param name="Window">An opaque window identity (an <c>HWND</c> on Windows); 0 when unknown.</param>
/// <param name="IsBlocked">
/// True when the OS will silently drop synthetic input to it — on Windows, a window running
/// at a higher integrity level (as administrator) than this app.
/// </param>
public readonly record struct FocusTarget(nint Window, bool IsBlocked)
{
    /// <summary>Nothing is known about the focused window.</summary>
    public static FocusTarget Unknown => default;
}

/// <summary>Types text into whatever application currently has focus.</summary>
public interface ITextInjector
{
    /// <summary>Which window currently has focus, and whether typing into it can work.</summary>
    /// <remarks>Cheap; called at key release and again just before typing.</remarks>
    FocusTarget GetFocusTarget();

    /// <summary>Inserts <paramref name="text"/> at the caret of the focused control.</summary>
    /// <returns>False if the text could not be delivered.</returns>
    ValueTask<bool> InjectAsync(string text, CancellationToken cancellationToken);
}

/// <summary>
/// Notices when the interactive session goes away: the workstation locks, the user switches,
/// or a secure desktop (UAC prompt, Ctrl+Alt+Del) takes over input.
/// </summary>
/// <remarks>
/// Each of those swallows the push-to-talk key-up. Without this, the microphone stays open
/// behind the lock screen and the text is typed into whatever has focus afterwards.
/// </remarks>
public interface ISessionMonitor : IDisposable
{
    /// <summary>The session was locked, disconnected or logged off. May be raised on any thread.</summary>
    event EventHandler? Interrupted;

    /// <summary>
    /// Whether the user's normal desktop is receiving input right now. False on the lock
    /// screen and on a secure desktop. Polled while recording.
    /// </summary>
    bool IsInputDesktopActive { get; }

    /// <summary>Begins listening for session changes.</summary>
    void Start();
}

/// <summary>
/// Policy for the push-to-talk keys, kept out of the platform layer so it can be tested.
/// </summary>
public static class PushToTalkKeys
{
    /// <summary>Right Ctrl, the default.</summary>
    public const int RightControl = 0xA3;

    /// <summary>Right Alt — AltGr on many layouts.</summary>
    public const int RightAlt = 0xA5;

    /// <summary>Left Ctrl.</summary>
    public const int LeftControl = 0xA2;

    /// <summary>Caps Lock.</summary>
    public const int CapsLock = 0x14;

    /// <summary>
    /// The scan code Windows gives the phantom Left Ctrl it synthesises around AltGr.
    /// </summary>
    public const int AltGrPhantomControlScanCode = 0x21D;

    /// <summary>
    /// Whether the hook should swallow this key rather than pass it on.
    /// </summary>
    /// <remarks>
    /// Only Caps Lock. Every other key is observed, never swallowed: if a modifier's key-down
    /// were swallowed and its key-up escaped, the target app would believe it was held down
    /// forever. Caps Lock is different — it is a toggle that acts on key-down, so passing it
    /// through flips the user's Caps Lock state every time they dictate, and swallowing it
    /// cannot leave anything stuck.
    /// </remarks>
    public static bool ShouldSwallow(int virtualKey) => virtualKey == CapsLock;

    /// <summary>
    /// Whether the OS can report this key's physical state. A key the hook swallows never
    /// reaches the system's key-state table, so asking about it would always say "up".
    /// </summary>
    public static bool CanPollPhysicalState(int virtualKey) => !ShouldSwallow(virtualKey);

    /// <summary>
    /// Whether a key-down of <paramref name="virtualKey"/> while <paramref name="pushToTalkKey"/>
    /// is held makes the gesture a shortcut rather than a dictation.
    /// </summary>
    public static bool IsChord(int pushToTalkKey, int virtualKey, int scanCode)
    {
        if (virtualKey == pushToTalkKey) return false;   // auto-repeat of the key itself

        // AltGr arrives as a synthetic Left Ctrl plus Right Alt, and auto-repeat resends both.
        if (pushToTalkKey == RightAlt && virtualKey == LeftControl && scanCode == AltGrPhantomControlScanCode)
        {
            return false;
        }

        return true;
    }
}

/// <summary>Turns audio into text.</summary>
public interface ITranscriber : IAsyncDisposable
{
    /// <summary>Whether the model is loaded and ready.</summary>
    bool IsReady { get; }

    /// <summary>Loads the model. Slow — call once, at startup or first use.</summary>
    ValueTask<bool> LoadAsync(CancellationToken cancellationToken);

    /// <summary>Transcribes one utterance.</summary>
    /// <param name="samples">16 kHz mono float, in [-1, 1].</param>
    /// <param name="biasPhrases">
    /// Dictionary terms to bias the recogniser toward. May be ignored by engines that don't
    /// support it — the correction pass is what actually guarantees spelling.
    /// </param>
    /// <param name="cancellationToken">Cancels a transcription in flight.</param>
    ValueTask<string> TranscribeAsync(
        ReadOnlyMemory<float> samples,
        IReadOnlyList<string> biasPhrases,
        CancellationToken cancellationToken);
}

/// <summary>
/// Wall-clock time, behind an interface so timing logic is testable.
/// </summary>
/// <remarks>
/// Anything that measures a duration takes one of these. A test that depends on the real
/// clock is a test that fails on a slow CI runner.
/// </remarks>
public interface IClock
{
    /// <summary>The current instant.</summary>
    DateTimeOffset Now { get; }
}

/// <inheritdoc cref="IClock"/>
public sealed class SystemClock : IClock
{
    /// <summary>The shared instance.</summary>
    public static SystemClock Instance { get; } = new();

    /// <inheritdoc />
    public DateTimeOffset Now => DateTimeOffset.Now;
}

/// <summary>
/// Protects a small secret so only the current user on this machine can read it back.
/// </summary>
/// <remarks>
/// <para>
/// On Windows this is DPAPI (<c>ProtectedData</c>, <c>CurrentUser</c> scope): the secret is
/// bound to the user's logon credentials, so the file it is written to is useless when copied
/// to another account or machine, or read from a backup by someone else.
/// </para>
/// <para>
/// Used to wrap the key that seals the transcript history — never the history itself. The
/// bulk encryption (AES-GCM) is platform-neutral and lives in <c>Murmur.Core</c>, where CI can
/// test it; only this wrapping step needs Windows.
/// </para>
/// </remarks>
public interface ISecretProtector
{
    /// <summary>Wraps <paramref name="secret"/> for the current user.</summary>
    byte[] Protect(byte[] secret);

    /// <summary>Unwraps what <see cref="Protect"/> produced.</summary>
    /// <exception cref="System.Security.Cryptography.CryptographicException">
    /// The blob was protected by another user or machine, or is corrupt.
    /// </exception>
    byte[] Unprotect(byte[] protectedSecret);
}
