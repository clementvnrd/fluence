using Murmur.Abstractions;
using SherpaOnnx;

namespace Murmur.Speech;

/// <summary>
/// NVIDIA Parakeet TDT, running locally through sherpa-onnx.
/// </summary>
/// <remarks>
/// <para>
/// Windows has no counterpart to Apple's <c>SpeechAnalyzer</c>, so unlike the macOS build —
/// where Parakeet is an optional upgrade — this is the only engine, and the app cannot
/// transcribe until the model files are downloaded. See <c>docs/PARAKEET-WINDOWS.md</c>.
/// </para>
/// <para>
/// <b>CPU only, deliberately.</b> sherpa-onnx ships no GPU package at all — setting a CUDA
/// provider silently falls back to CPU. DirectML is several releases behind, forbids parallel
/// inference, and wants fixed tensor shapes, which a variable-length audio model cannot
/// provide. With int8 weights on four threads this runs roughly 40× faster than real time,
/// so none of that is worth the dependency.
/// </para>
/// <para>
/// <b>Biasing is not wired up yet.</b> sherpa-onnx has a hotwords feature, but it needs
/// <c>modified_beam_search</c> (this engine uses the faster <c>greedy_search</c>) and has not
/// been tried with this model, so the dictionary's correction pass carries the whole job on
/// Windows. That pass was always the guarantee and biasing only ever the nudge.
/// </para>
/// </remarks>
public sealed class ParakeetTranscriber : ITranscriber
{
    /// <summary>Threads for inference. Four measured fastest; eight measured slower.</summary>
    private const int Threads = 4;

    /// <summary>
    /// Feature dimension. <b>Must be 128</b> — the library defaults to 80, which is wrong for
    /// this model.
    /// </summary>
    private const int FeatureDim = 128;

    /// <summary>
    /// Model family. <b>Required.</b> Without it the model fails to load.
    /// </summary>
    private const string ModelType = "nemo_transducer";

    /// <summary>Folder names searched under each models root, preferred first.</summary>
    /// <remarks>
    /// v3 first: its folder only exists if someone deliberately chose the multilingual model,
    /// which is a superset of v2's English. To force one when both are installed, set
    /// <c>ModelDirectory</c> in settings.json.
    /// </remarks>
    public static IReadOnlyList<string> VariantFolders { get; } = ["parakeet-v3", "parakeet-v2"];

    private readonly string _modelDirectory;
    private readonly Lock _sync = new();
    private OfflineRecognizer? _recognizer;
    private bool _disposed;

    /// <summary>Points the engine at a folder of model files.</summary>
    /// <param name="modelDirectory">
    /// Must contain <c>encoder.int8.onnx</c>, <c>decoder.int8.onnx</c>,
    /// <c>joiner.int8.onnx</c> and <c>tokens.txt</c>.
    /// </param>
    public ParakeetTranscriber(string modelDirectory) => _modelDirectory = modelDirectory;

    /// <summary>The folder this engine loads from.</summary>
    public string ModelDirectory => _modelDirectory;

    /// <summary>The outcome of the last verification, once <see cref="LoadAsync"/> has run.</summary>
    public ModelCheck? LastCheck { get; private set; }

    /// <summary>Where the model is looked for, in order.</summary>
    /// <param name="configured">
    /// <c>ModelDirectory</c> from settings. When set it is the <i>only</i> candidate — a user
    /// who pointed the app somewhere must not silently get a different model.
    /// </param>
    /// <param name="modelsRoot"><c>%LOCALAPPDATA%\Fluence\models</c>.</param>
    /// <remarks>
    /// <c>%LOCALAPPDATA%</c> first: it needs no administrator rights, so the app can download
    /// and update the model itself even when installed under Program Files.
    /// </remarks>
    public static IEnumerable<string> SearchPaths(string? configured, string modelsRoot)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            yield return configured;
            yield break;
        }

        foreach (var variant in VariantFolders) yield return Path.Combine(modelsRoot, variant);

        // AppContext.BaseDirectory, not Assembly.Location — the latter returns an empty
        // string in a single-file app, which silently resolves paths against the current
        // directory instead.
        foreach (var variant in VariantFolders)
        {
            yield return Path.Combine(AppContext.BaseDirectory, "models", variant);
        }
    }

    /// <summary>Finds a directory containing a complete model, or null.</summary>
    public static string? Locate(string? configured, string modelsRoot) =>
        SearchPaths(configured, modelsRoot).FirstOrDefault(IsComplete);

    /// <summary>Whether <paramref name="directory"/> holds every required file.</summary>
    /// <remarks>
    /// Presence only — cheap enough for the UI. <see cref="LoadAsync"/> verifies sizes and
    /// hashes before anything reaches native code.
    /// </remarks>
    public static bool IsComplete(string directory) =>
        RequiredFiles.All(f => File.Exists(Path.Combine(directory, f)));

    /// <summary>The files the engine needs.</summary>
    public static IReadOnlyList<string> RequiredFiles { get; } =
    [
        "encoder.int8.onnx",
        "decoder.int8.onnx",
        "joiner.int8.onnx",
        "tokens.txt",
    ];

    /// <inheritdoc />
    public bool IsReady => Volatile.Read(ref _recognizer) is not null;

    /// <inheritdoc />
    /// <remarks>
    /// Synchronous and slow (hashing on first run, then ~2 s of model load): call it from a
    /// background thread. Throws <see cref="InvalidDataException"/> with a user-readable
    /// message when the files are missing or do not match their manifest — <i>before</i>
    /// anything reaches native code, where a corrupt file can abort the process.
    /// </remarks>
    public ValueTask<bool> LoadAsync(CancellationToken cancellationToken)
    {
        if (IsReady) return ValueTask.FromResult(true);

        var check = ModelVerifier.Verify(_modelDirectory, RequiredFiles, cancellationToken);
        LastCheck = check;
        if (!check.IsUsable) throw new InvalidDataException(check.Problem);

        var config = new OfflineRecognizerConfig();
        config.FeatConfig.SampleRate = AudioChunk.SampleRate;
        config.FeatConfig.FeatureDim = FeatureDim;

        config.ModelConfig.Transducer.Encoder = Path.Combine(_modelDirectory, "encoder.int8.onnx");
        config.ModelConfig.Transducer.Decoder = Path.Combine(_modelDirectory, "decoder.int8.onnx");
        config.ModelConfig.Transducer.Joiner = Path.Combine(_modelDirectory, "joiner.int8.onnx");
        config.ModelConfig.Tokens = Path.Combine(_modelDirectory, "tokens.txt");
        config.ModelConfig.ModelType = ModelType;
        config.ModelConfig.NumThreads = Threads;
        config.ModelConfig.Provider = "cpu";
        config.DecodingMethod = "greedy_search";

        var recognizer = new OfflineRecognizer(config);

        lock (_sync)
        {
            if (_disposed || _recognizer is not null)
            {
                recognizer.Dispose();
                return ValueTask.FromResult(!_disposed);
            }

            _recognizer = recognizer;
        }

        return ValueTask.FromResult(true);
    }

    /// <inheritdoc />
    /// <remarks>
    /// <paramref name="biasPhrases"/> is accepted and ignored — see the class remarks. Audio
    /// longer than the encoder can handle is the caller's problem; <c>AudioSegmenter</c>
    /// splits it before this is reached.
    /// </remarks>
    public ValueTask<string> TranscribeAsync(
        ReadOnlyMemory<float> samples,
        IReadOnlyList<string> biasPhrases,
        CancellationToken cancellationToken)
    {
        if (samples.Length == 0) return ValueTask.FromResult(string.Empty);
        cancellationToken.ThrowIfCancellationRequested();

        // Held across Decode, and taken by DisposeAsync: the native recognizer must never be
        // freed while a decode is running inside it.
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_recognizer is null)
            {
                throw new InvalidOperationException("The speech model is not loaded.");
            }

            using var stream = _recognizer.CreateStream();
            stream.AcceptWaveform(AudioChunk.SampleRate, samples.ToArray());
            _recognizer.Decode(stream);

            return ValueTask.FromResult(stream.Result.Text?.Trim() ?? string.Empty);
        }
    }

    /// <inheritdoc />
    /// <remarks>Waits for a decode in progress to finish before freeing native memory.</remarks>
    public ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            _disposed = true;
            _recognizer?.Dispose();
            _recognizer = null;
        }

        return ValueTask.CompletedTask;
    }

    /// <summary>
    /// The sherpa-onnx native library's version — a real P/Invoke, so calling this proves the
    /// native DLL was found, extracted and loaded.
    /// </summary>
    public static string NativeVersion() => VersionInfo.Version;
}
