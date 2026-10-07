using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>Where a channel's timeline samples are kept for the final pass (the encrypted spool).</summary>
public interface IAudioSpoolWriter
{
    /// <summary>Appends samples; the spool's sample <i>i</i> is meeting time <i>i</i> / 16 000.</summary>
    void Append(ReadOnlySpan<float> samples);
}

/// <summary>
/// The fallback when Silero is not installed: speech is a hop louder than −40 dBFS. Same rule
/// as the macOS fallback, on Silero's 512-sample hop.
/// </summary>
public sealed class EnergyVoiceActivity : IVoiceActivityDetector
{
    /// <inheritdoc />
    public int HopSamples => 512;

    /// <inheritdoc />
    public string Kind => "energy";

    /// <inheritdoc />
    public float Push(ReadOnlySpan<float> hop)
    {
        double energy = 0;
        foreach (var sample in hop) energy += sample * sample;
        return hop.Length > 0 && Math.Sqrt(energy / hop.Length) > 0.01 ? 0.9f : 0.1f;
    }

    /// <inheritdoc />
    public void Dispose()
    {
    }
}

/// <summary>
/// One channel of a meeting, from timed samples to transcript segments. The Windows
/// counterpart of <c>ChannelPipeline.swift</c>:
/// </summary>
/// <remarks>
/// <code>
/// timed samples ─► TimelineAligner ─► encrypted spool
///                        │
///             VAD, one decision per hop (Silero, else energy)
///                        │
///             UtteranceSegmenter (≤ 14.5 s, cut at pauses)
///                        │
///             Parakeet per utterance ─► words on the meeting clock
///                        │
///             dictionary ─► TranscriptSegment (mic = me, system = S?)
/// </code>
/// <para>
/// Sample <i>i</i> of every stage is meeting time <i>i</i> / 16 000: the aligner pads gaps
/// (loopback's silences) and trims overlaps, so utterance positions are meeting times without
/// bookkeeping. Not thread-safe: one caller feeds a channel, in order. Transcription is awaited
/// inline — Parakeet runs ~40× real time, and the model is shared with dictation behind one gate.
/// </para>
/// <para>No echo canceller on Windows yet: the text dedupe in <see cref="TranscriptMerger"/> is the backstop.</para>
/// </remarks>
public sealed class ChannelPipeline : IDisposable
{
    /// <summary>Utterances shorter than this are padded with silence before recognition (Parakeet refuses under ~0.3 s).</summary>
    public const int MinimumRecognitionSamples = AudioChunk.SampleRate / 2;

    private readonly ITimedTranscriber _transcriber;
    private readonly Func<string, string> _correct;
    private readonly IAudioSpoolWriter? _spool;
    private readonly IDiagnosticLog _log;
    private readonly TimelineAligner _aligner = new();
    private readonly SampleHistory _history = new(30 * AudioChunk.SampleRate);
    private readonly UtteranceSegmenter _segmenter;
    private readonly float[] _hop;
    private readonly List<TranscriptSegment> _produced = [];
    private IVoiceActivityDetector _vad;
    private int _hopFill;
    private bool _spoolFailed;

    /// <summary>Creates the pipeline for one channel.</summary>
    /// <param name="source">Which channel: the microphone is "me", the system is "others" until diarized.</param>
    /// <param name="transcriber">Parakeet with token timings.</param>
    /// <param name="vad">The voice detector; replaced by <see cref="EnergyVoiceActivity"/> if it fails.</param>
    /// <param name="correct">The dictionary's correction pass.</param>
    /// <param name="spool">Where the timeline is kept for the final pass, or null.</param>
    /// <param name="log">Counts and timings only — never text.</param>
    public ChannelPipeline(
        AudioSource source,
        ITimedTranscriber transcriber,
        IVoiceActivityDetector vad,
        Func<string, string> correct,
        IAudioSpoolWriter? spool,
        IDiagnosticLog? log = null)
    {
        ArgumentNullException.ThrowIfNull(vad);
        Source = source;
        _transcriber = transcriber;
        _vad = vad;
        _correct = correct;
        _spool = spool;
        _log = log ?? NullDiagnosticLog.Instance;
        _hop = new float[vad.HopSamples];
        _segmenter = new UtteranceSegmenter(new UtteranceSegmenterConfig { HopSamples = vad.HopSamples });
    }

    /// <summary>Which channel this is.</summary>
    public AudioSource Source { get; }

    /// <summary>A finished live segment. Raised on the feeding thread.</summary>
    public event EventHandler<TranscriptSegment>? SegmentProduced;

    /// <summary>Speech was heard at this meeting time (seconds). Raised on the feeding thread.</summary>
    public event EventHandler<double>? SpeechHeard;

    /// <summary>The timeline's length so far, in samples.</summary>
    public long TimelineSamples => _aligner.Written;

    /// <summary>Which detector is deciding ("silero", "energy").</summary>
    public string VadKind => _vad.Kind;

    /// <summary>Places a chunk on the timeline and runs it through.</summary>
    public async Task AcceptAsync(TimedSamples chunk, CancellationToken cancellationToken)
    {
        var placement = _aligner.Place(chunk.Time, chunk.Samples.Length);
        if (placement.Padding > 0) await AnalyseSilenceAsync(placement.Padding, cancellationToken).ConfigureAwait(false);
        if (placement.DropLeading < chunk.Samples.Length)
        {
            await AnalyseAsync(chunk.Samples.AsMemory(placement.DropLeading), cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Extends the timeline with silence up to <paramref name="time"/>: a channel that delivered
    /// nothing (loopback while nobody speaks) still advances, so the next packet lands in place.
    /// </summary>
    public Task PadUntilAsync(double time, CancellationToken cancellationToken)
    {
        var zeros = _aligner.PadUntil(time);
        return zeros > 0 ? AnalyseSilenceAsync(zeros, cancellationToken) : Task.CompletedTask;
    }

    /// <summary>
    /// Flushes the last partial hop, transcribes the last utterance, and returns every segment
    /// this channel produced, in production order.
    /// </summary>
    public async Task<IReadOnlyList<TranscriptSegment>> FinishAsync(CancellationToken cancellationToken)
    {
        if (_hopFill > 0)
        {
            Array.Clear(_hop, _hopFill, _hop.Length - _hopFill);
            _hopFill = _hop.Length;
            await DecideHopAsync(cancellationToken).ConfigureAwait(false);
        }

        foreach (var utterance in _segmenter.Finish())
        {
            await TranscribeAsync(utterance, cancellationToken).ConfigureAwait(false);
        }

        return [.. _produced];
    }

    private async Task AnalyseSilenceAsync(int count, CancellationToken cancellationToken)
    {
        var block = new float[Math.Min(count, AudioChunk.SampleRate)];
        while (count > 0)
        {
            var take = Math.Min(count, block.Length);
            await AnalyseAsync(block.AsMemory(0, take), cancellationToken).ConfigureAwait(false);
            count -= take;
        }
    }

    private async Task AnalyseAsync(ReadOnlyMemory<float> samples, CancellationToken cancellationToken)
    {
        WriteSpool(samples.Span);
        _history.Append(samples.Span);

        var offset = 0;
        while (offset < samples.Length)
        {
            var take = Math.Min(_hop.Length - _hopFill, samples.Length - offset);
            samples.Span.Slice(offset, take).CopyTo(_hop.AsSpan(_hopFill));
            _hopFill += take;
            offset += take;
            if (_hopFill == _hop.Length) await DecideHopAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task DecideHopAsync(CancellationToken cancellationToken)
    {
        _hopFill = 0;
        var probability = SpeechProbability();
        if (probability >= _segmenter.Config.Threshold)
        {
            SpeechHeard?.Invoke(this, (double)(_segmenter.ProcessedSamples + _hop.Length) / AudioChunk.SampleRate);
        }

        foreach (var utterance in _segmenter.Push(probability))
        {
            await TranscribeAsync(utterance, cancellationToken).ConfigureAwait(false);
        }
    }

    private float SpeechProbability()
    {
        try
        {
            return _vad.Push(_hop);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            // Same hop size by construction, so the segmenter's clock is unaffected.
            _log.Error("meeting.vad_failed", e, new Dictionary<string, object?> { ["source"] = Source.ToString() });
            _vad.Dispose();
            _vad = new EnergyVoiceActivity();
            return _vad.Push(_hop);
        }
    }

    private void WriteSpool(ReadOnlySpan<float> samples)
    {
        if (_spool is null || _spoolFailed) return;
        try
        {
            _spool.Append(samples);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
        {
            // The live transcript continues; only the final pass (diarization) loses its audio.
            _spoolFailed = true;
            _log.Error("meeting.spool_write_failed", e, new Dictionary<string, object?> { ["source"] = Source.ToString() });
        }
    }

    private async Task TranscribeAsync(Utterance utterance, CancellationToken cancellationToken)
    {
        var samples = _history.Read(utterance.StartSample, utterance.EndSample);
        if (samples.Length == 0) return;

        var start = (double)utterance.StartSample / AudioChunk.SampleRate;
        var end = start + ((double)samples.Length / AudioChunk.SampleRate);
        var audio = samples.Length >= MinimumRecognitionSamples ? samples : [.. samples, .. new float[MinimumRecognitionSamples - samples.Length]];

        TimedTranscript result;
        try
        {
            result = await _transcriber.TranscribeTimedAsync(audio, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception e) when (e is InvalidOperationException or InvalidDataException or ObjectDisposedException
                                      or System.Runtime.InteropServices.ExternalException)
        {
            _log.Error("meeting.utterance_not_transcribed", e, new Dictionary<string, object?>
            {
                ["source"] = Source.ToString(),
                ["seconds"] = Math.Round(end - start, 2),
            });
            return;
        }

        var text = result.Text.Trim();
        if (text.Length == 0) return;

        var tokens = result.Tokens.Select(t => new TimedToken(t.Text, t.Start, t.End, 1f)).ToList();
        // Parakeet through sherpa-onnx reports no per-token confidence: say so rather than store 1.0.
        var words = WordBuilder.Words(tokens, start).Select(w => w with { Confidence = null }).ToList();

        var segment = new TranscriptSegment
        {
            Source = Source,
            SpeakerId = Source == AudioSource.Microphone ? Speaker.MeId : Speaker.OthersId,
            Start = words.Count > 0 ? Math.Min(words[0].Start, end) : start,
            End = words.Count > 0 ? Math.Min(Math.Max(words[^1].End, start), end) : end,
            Text = _correct(text),
            Words = words,
        };

        _produced.Add(segment);
        SegmentProduced?.Invoke(this, segment);
    }

    /// <inheritdoc />
    public void Dispose() => _vad.Dispose();
}

/// <summary>The last few seconds of a channel's samples, addressed by timeline position.</summary>
internal sealed class SampleHistory
{
    private readonly float[] _ring;

    public SampleHistory(int capacity) => _ring = new float[capacity];

    /// <summary>Samples appended so far: the timeline position of the next one.</summary>
    public long Count { get; private set; }

    public void Append(ReadOnlySpan<float> samples)
    {
        foreach (var sample in samples)
        {
            _ring[Count % _ring.Length] = sample;
            Count++;
        }
    }

    /// <summary>[<paramref name="start"/>, <paramref name="end"/>), clamped to what is still held.</summary>
    public float[] Read(long start, long end)
    {
        var lower = Math.Max(Math.Max(start, Count - _ring.Length), 0);
        var upper = Math.Min(end, Count);
        if (upper <= lower) return [];
        var result = new float[upper - lower];
        for (var i = lower; i < upper; i++) result[i - lower] = _ring[i % _ring.Length];
        return result;
    }
}
