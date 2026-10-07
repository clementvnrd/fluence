using Murmur.Abstractions;
using SherpaOnnx;

namespace Murmur.Speech;

/// <summary>
/// sherpa-onnx's offline speaker diarization: pyannote segmentation 3.0 + a speaker-embedding
/// model + clustering. Run once, after the meeting, on the system channel only.
/// </summary>
/// <remarks>
/// The number of voices is not known on Windows (no calendar yet), so clustering runs on a
/// distance threshold rather than a fixed count. Verify the files first
/// (<see cref="MeetingModels.Verify"/>): a truncated model can abort the process in native code.
/// </remarks>
public sealed class SherpaDiarizer : ISpeakerDiarizer
{
    /// <summary>
    /// Clustering threshold: lower splits voices more readily. Measured on one two-speaker
    /// English clip (sherpa-onnx's <c>2-two-speakers-en.wav</c>) with this embedding model: 0.5
    /// merged both voices into one, 0.4 split one voice in two, 0.45 got both right. One clip is
    /// not a benchmark — retune against the meeting benchmark (docs/NOTETAKER.md §5).
    /// </summary>
    public const float ClusterThreshold = 0.45f;

    /// <summary>Threads per model. 4 ran ~2.5× faster than 2 (34 s of audio in ~6 s on an Apple-silicon Mac).</summary>
    public const int Threads = 4;

    private readonly OfflineSpeakerDiarization _diarization;

    /// <summary>Loads the models in <paramref name="folder"/> (<c>segmentation.onnx</c>, <c>embedding.onnx</c>).</summary>
    public SherpaDiarizer(string folder)
    {
        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = Path.Combine(folder, "segmentation.onnx");
        config.Segmentation.NumThreads = Threads;
        config.Segmentation.Provider = "cpu";
        config.Embedding.Model = Path.Combine(folder, "embedding.onnx");
        config.Embedding.NumThreads = Threads;
        config.Embedding.Provider = "cpu";
        config.Clustering.NumClusters = -1;
        config.Clustering.Threshold = ClusterThreshold;
        config.MinDurationOn = 0.3f;
        config.MinDurationOff = 0.5f;
        _diarization = new OfflineSpeakerDiarization(config);
    }

    /// <inheritdoc />
    public IReadOnlyList<DiarizedTurn> Diarize(float[] samples, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(samples);
        cancellationToken.ThrowIfCancellationRequested();
        return [.. _diarization.Process(samples).Select(s => new DiarizedTurn(s.Speaker, s.Start, s.End))];
    }

    /// <inheritdoc />
    public void Dispose() => _diarization.Dispose();
}

/// <summary>sherpa-onnx's speaker-embedding extractor, for opt-in voice prints.</summary>
public sealed class SherpaSpeakerEmbedder : ISpeakerEmbedder
{
    private readonly SpeakerEmbeddingExtractor _extractor;

    /// <summary>Loads <paramref name="modelPath"/> (the diarization folder's <c>embedding.onnx</c>).</summary>
    public SherpaSpeakerEmbedder(string modelPath)
    {
        var config = new SpeakerEmbeddingExtractorConfig();
        config.Model = modelPath;
        config.NumThreads = 2;
        config.Provider = "cpu";
        _extractor = new SpeakerEmbeddingExtractor(config);
    }

    /// <inheritdoc />
    public int Dimension => _extractor.Dim;

    /// <inheritdoc />
    public float[]? Embed(float[] samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        using var stream = _extractor.CreateStream();
        stream.AcceptWaveform(AudioChunk.SampleRate, samples);
        stream.InputFinished();
        return _extractor.IsReady(stream) ? _extractor.Compute(stream) : null;
    }

    /// <inheritdoc />
    public void Dispose() => _extractor.Dispose();
}

/// <summary>Real calls into the native speaker-ID and VAD code that need no model file. Used by <c>--selftest</c>.</summary>
public static class SherpaMeetingProbe
{
    /// <summary>Creates and frees native objects from the VAD and speaker-ID halves of the library.</summary>
    /// <returns>A short description.</returns>
    public static string Run()
    {
        using (var buffer = new CircularBuffer(1024))
        {
            buffer.Push(new float[256]);
            if (buffer.Size != 256) throw new InvalidOperationException("sherpa-onnx circular buffer misbehaved.");
        }

        using var manager = new SpeakerEmbeddingManager(4);
        if (!manager.Add("probe", [1f, 0f, 0f, 0f]) || manager.NumSpeakers != 1)
        {
            throw new InvalidOperationException("sherpa-onnx speaker manager misbehaved.");
        }

        var config = new OfflineSpeakerDiarizationConfig();
        return $"VAD buffer and speaker manager load (clustering default {config.Clustering.Threshold})";
    }
}
