using Murmur.Abstractions;
using SherpaOnnx;

namespace Murmur.Speech;

/// <summary>
/// Silero VAD through sherpa-onnx, one decision per 512-sample (32 ms) window.
/// </summary>
/// <remarks>
/// sherpa-onnx's detector reports segments and an "in speech" flag rather than raw
/// per-window probabilities, so each hop is reported as 1 or 0 from
/// <c>IsSpeechDetected()</c>, with sherpa's own silence and speech minimums set short (0.1 s)
/// and its maximum long, so that the cutting rules that matter — 0.5 s pauses, the 14.5 s
/// cap — are the shared <c>UtteranceSegmenter</c>'s, identical to macOS. Segments sherpa
/// queues are discarded as they arrive: the samples are kept by the pipeline.
/// </remarks>
public sealed class SileroVoiceActivity : IVoiceActivityDetector
{
    /// <summary>Silero's window at 16 kHz.</summary>
    public const int Window = 512;

    private readonly VoiceActivityDetector _detector;
    private readonly float[] _buffer = new float[Window];

    /// <summary>Loads the model at <paramref name="modelPath"/>. Verify it first (<see cref="MeetingModels.Verify"/>).</summary>
    public SileroVoiceActivity(string modelPath)
    {
        var config = new VadModelConfig();
        config.SileroVad.Model = modelPath;
        config.SileroVad.Threshold = 0.5f;
        config.SileroVad.MinSilenceDuration = 0.1f;
        config.SileroVad.MinSpeechDuration = 0.1f;
        config.SileroVad.MaxSpeechDuration = 60f;
        config.SileroVad.WindowSize = Window;
        config.SampleRate = AudioChunk.SampleRate;
        config.NumThreads = 1;
        config.Provider = "cpu";
        _detector = new VoiceActivityDetector(config, 30);
    }

    /// <inheritdoc />
    public int HopSamples => Window;

    /// <inheritdoc />
    public string Kind => "silero";

    /// <inheritdoc />
    public float Push(ReadOnlySpan<float> hop)
    {
        if (hop.Length != Window) throw new ArgumentException($"Push exactly {Window} samples.", nameof(hop));
        hop.CopyTo(_buffer);
        _detector.AcceptWaveform(_buffer);
        while (!_detector.IsEmpty()) _detector.Pop();
        return _detector.IsSpeechDetected() ? 1f : 0f;
    }

    /// <inheritdoc />
    public void Dispose() => _detector.Dispose();
}
