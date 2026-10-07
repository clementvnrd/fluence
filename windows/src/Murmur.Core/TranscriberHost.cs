using Murmur.Abstractions;

namespace Murmur.Core;

/// <summary>Where the speech model is in its life cycle.</summary>
public enum ModelState
{
    /// <summary>No model files were found.</summary>
    NotInstalled,

    /// <summary>Files found; loading has not started.</summary>
    NotLoaded,

    /// <summary>Verifying and loading. Takes a few seconds.</summary>
    Loading,

    /// <summary>Loaded and able to transcribe.</summary>
    Ready,

    /// <summary>Loading failed. <see cref="TranscriberHost.Detail"/> says why.</summary>
    Failed,
}

/// <summary>
/// Owns the speech engine: loads it once, reports honestly whether it is ready, and makes
/// sure it is never freed while it is working.
/// </summary>
/// <remarks>
/// <para>
/// <b>Honest state.</b> "Parakeet ready" used to mean "the files exist" — the model was never
/// even loaded. The state here moves only on what actually happened: a load that threw shows
/// <see cref="ModelState.Failed"/> with the reason, which Settings and the main window display.
/// </para>
/// <para>
/// <b>One load at a time, off the caller's thread.</b> Loading verifies hashes and builds a
/// ~2 GB native graph; it runs on the thread pool, concurrent callers share the one attempt,
/// and a failed attempt can be retried.
/// </para>
/// <para>
/// <b>Safe disposal.</b> Transcription and disposal take the same gate, so quitting while a
/// decode is running waits for it instead of freeing native memory underneath it. If the
/// decode does not finish in <see cref="DisposeTimeout"/>, the engine is deliberately leaked —
/// the process is exiting anyway, and a leak is harmless where a use-after-free is a crash.
/// </para>
/// </remarks>
public sealed class TranscriberHost : ITranscriber
{
    /// <summary>How long disposal waits for a decode in progress.</summary>
    public static readonly TimeSpan DisposeTimeout = TimeSpan.FromSeconds(10);

    private readonly ITranscriber? _inner;
    private readonly IDiagnosticLog _log;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Lock _sync = new();
    private Task<bool>? _load;
    private volatile bool _disposed;

    /// <summary>Wraps <paramref name="inner"/>, which lives at <paramref name="location"/>.</summary>
    /// <param name="inner">The engine, or null when no model was found.</param>
    /// <param name="location">Where the model was found, for display.</param>
    /// <param name="log">Where failures are recorded.</param>
    public TranscriberHost(ITranscriber? inner, string? location, IDiagnosticLog? log = null)
    {
        _inner = inner;
        _log = log ?? NullDiagnosticLog.Instance;
        Location = location;
        State = inner is null ? ModelState.NotInstalled : ModelState.NotLoaded;
    }

    /// <summary>The current state. Changes are announced by <see cref="StateChanged"/>.</summary>
    public ModelState State { get; private set; }

    /// <summary>Why loading failed, in words a user can act on; otherwise null.</summary>
    public string? Detail { get; private set; }

    /// <summary>Where the model files are, or null when none were found.</summary>
    public string? Location { get; }

    /// <summary>Raised when <see cref="State"/> changes. May be raised on any thread.</summary>
    public event EventHandler? StateChanged;

    /// <inheritdoc />
    public bool IsReady => State == ModelState.Ready;

    /// <inheritdoc />
    /// <remarks>Shares an attempt already in flight; retries one that failed.</remarks>
    public async ValueTask<bool> LoadAsync(CancellationToken cancellationToken)
    {
        if (_inner is null || _disposed) return false;

        Task<bool> load;
        lock (_sync)
        {
            if (_load is null || (_load.IsCompleted && !_load.Result)) _load = Task.Run(LoadCoreAsync, CancellationToken.None);
            load = _load;
        }

        return await load.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<bool> LoadCoreAsync()
    {
        SetState(ModelState.Loading, null);

        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed) return false;

            var loaded = await _inner!.LoadAsync(CancellationToken.None).ConfigureAwait(false);
            SetState(loaded ? ModelState.Ready : ModelState.Failed,
                loaded ? null : "The speech model did not load.");
            return loaded;
        }
        catch (Exception e)
        {
            _log.Error("model.load_failed", e);
            SetState(ModelState.Failed, e.Message);
            return false;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <inheritdoc />
    public async ValueTask<string> TranscribeAsync(
        ReadOnlyMemory<float> samples,
        IReadOnlyList<string> biasPhrases,
        CancellationToken cancellationToken)
    {
        if (_inner is null) throw new InvalidOperationException("No speech model is installed.");

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return await _inner.TranscribeAsync(samples, biasPhrases, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private void SetState(ModelState state, string? detail)
    {
        lock (_sync)
        {
            State = state;
            Detail = detail;
        }

        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;

        if (_inner is null) return;

        if (!await _gate.WaitAsync(DisposeTimeout).ConfigureAwait(false))
        {
            _log.Warning("model.dispose_timed_out");
            return;
        }

        try
        {
            await _inner.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }
}
