using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Dictionary;
using Murmur.Speech;

namespace Murmur.App;

/// <summary>
/// Wires the app together: settings, storage, the platform layer, and the engine.
/// </summary>
/// <remarks>
/// <para>
/// The only place that knows about every layer at once. Views take what they need; nothing
/// else reaches across.
/// </para>
/// <para>
/// The platform implementations are resolved by reflection rather than referenced directly,
/// so <c>Murmur.App</c> can target plain <c>net10.0</c> and therefore be built, run and
/// headless-tested on macOS — which is the entire reason Avalonia was chosen over WPF. On any
/// non-Windows machine the lookup simply finds nothing and the app runs with inert stand-ins,
/// which is exactly what a UI test wants.
/// </para>
/// </remarks>
public sealed class Composition : IAsyncDisposable
{
    private Composition(
        AppSettings settings,
        DictionaryFile dictionary,
        TranscriptStore transcripts,
        DictationEngine? engine,
        ITextInjector? injector,
        TranscriberHost model,
        bool platformAvailable)
    {
        Model = model;
        Settings = settings;
        Dictionary = dictionary;
        Transcripts = transcripts;
        Engine = engine;
        Injector = injector;
        IsPlatformAvailable = platformAvailable;
    }

    /// <summary>
    /// The text injector, exposed so the app can wire the clipboard-paste path into it
    /// once a window (and therefore a clipboard) exists.
    /// </summary>
    public ITextInjector? Injector { get; }

    /// <summary>User preferences.</summary>
    public AppSettings Settings { get; }

    /// <summary>The correction dictionary.</summary>
    public DictionaryFile Dictionary { get; }

    /// <summary>Transcript history.</summary>
    public TranscriptStore Transcripts { get; }

    /// <summary>The dictation engine, or null when no platform layer is available.</summary>
    public DictationEngine? Engine { get; }

    /// <summary>Whether real audio and hotkey support were found.</summary>
    public bool IsPlatformAvailable { get; }

    /// <summary>The speech model: where it is, and whether it actually loaded.</summary>
    public TranscriberHost Model { get; }

    /// <summary>Builds the object graph.</summary>
    /// <param name="log">Where failures are recorded. Never receives transcript text.</param>
    public static Composition Create(IDiagnosticLog log)
    {
        var settings = new AppSettings(AppSettings.DefaultPath);
        var dictionary = new DictionaryFile(DictionaryFile.DefaultPath, log);
        dictionary.StartWatching();

        // Sealed under a DPAPI-wrapped key. With no platform layer there is no protector and
        // the history stays in memory — never a plaintext fallback.
        var transcripts = new TranscriptStore(
            TranscriptStore.DefaultPath, PlatformFactory.CreateSecretProtector(), log);

        // Purge on start, whenever the setting changes, and after every dictation (below).
        transcripts.ApplyRetention(settings.Data.HistoryRetention, DateTimeOffset.Now);
        settings.Changed += (_, _) =>
            transcripts.ApplyRetention(settings.Data.HistoryRetention, DateTimeOffset.Now);

        var capture = PlatformFactory.CreateAudioCapture();
        var hotkey = PlatformFactory.CreateHotkeySource(settings.Data.PushToTalkKey);
        var injector = PlatformFactory.CreateTextInjector();

        DictationEngine? engine = null;
        var available = capture is not null && hotkey is not null && injector is not null;

        // ModelDirectory from settings.json, when set, is the only place looked at.
        var modelDirectory = ParakeetTranscriber.Locate(settings.Data.ModelDirectory, AppPaths.ModelsDirectory);
        var model = new TranscriberHost(
            modelDirectory is null ? null : new ParakeetTranscriber(modelDirectory), modelDirectory, log);

        if (available)
        {
            // Load now, in the background, rather than on the first key press: the first
            // dictation is not delayed, and a corrupt or missing file is reported in the
            // window straight away instead of when the user first speaks.
            _ = model.LoadAsync(CancellationToken.None).AsTask();

            engine = new DictationEngine(
                capture!, hotkey!, model, injector!,
                () => dictionary.Entries);

            engine.Completed += (_, result) =>
            {
                var retention = settings.Data.HistoryRetention;

                if (retention != HistoryRetention.Never)
                {
                    transcripts.Add(new TranscriptRecord
                    {
                        At = result.At,
                        AudioSeconds = result.AudioDuration.TotalSeconds,
                        ProcessingSeconds = result.ProcessingTime.TotalSeconds,
                        Text = result.Text,
                        RawText = result.RawText == result.Text ? null : result.RawText,
                        Corrections = result.Corrections.Count > 0 ? result.Corrections : null,
                    });
                }

                transcripts.ApplyRetention(retention, DateTimeOffset.Now);
            };
        }

        return new Composition(settings, dictionary, transcripts, engine, injector, model, available);
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        // The engine disposes the model it was given; without one, dispose it here.
        if (Engine is not null) await Engine.DisposeAsync().ConfigureAwait(false);
        else await Model.DisposeAsync().ConfigureAwait(false);
        Transcripts.Dispose();
        Dictionary.Dispose();
    }
}
