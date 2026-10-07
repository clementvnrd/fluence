namespace Murmur.Meeting;

/// <summary>
/// A stretch of one channel to transcribe as a unit, in samples of that channel's timeline
/// (meeting time × sample rate).
/// </summary>
/// <param name="StartSample">First sample.</param>
/// <param name="EndSample">One past the last sample.</param>
public readonly record struct Utterance(int StartSample, int EndSample)
{
    /// <summary>Length in samples.</summary>
    public int SampleCount => EndSample - StartSample;
}

/// <summary>Tuning for <see cref="UtteranceSegmenter"/>.</summary>
public sealed record UtteranceSegmenterConfig
{
    /// <summary>Samples per second of the channel.</summary>
    public int SampleRate { get; init; } = 16_000;

    /// <summary>
    /// Samples per probability. macOS (FluidAudio's Silero) uses 4096-sample hops; the Windows
    /// pipeline feeds sherpa-onnx's Silero in 512-sample windows and sets this to 512.
    /// </summary>
    public int HopSamples { get; init; } = 4_096;

    /// <summary>Speech starts at a hop at or above this.</summary>
    public float Threshold { get; init; } = 0.5f;

    /// <summary>While in speech, a hop below this is silence.</summary>
    public float NegativeThreshold { get; init; } = 0.35f;

    /// <summary>Consecutive silence that ends an utterance, seconds.</summary>
    public double MinSilence { get; init; } = 0.5;

    /// <summary>Shorter utterances are dropped, seconds.</summary>
    public double MinSpeech { get; init; } = 0.25;

    /// <summary>
    /// Cap, seconds. Parakeet transcribes up to 15 s in one encoder pass; 14.5 s plus the
    /// padding on both sides stays inside it.
    /// </summary>
    public double MaxDuration { get; init; } = 14.5;

    /// <summary>Added on both sides, seconds.</summary>
    public double Padding { get; init; } = 0.1;
}

/// <summary>
/// Turns a stream of per-hop voice probabilities into utterances for the recogniser. Port of
/// <c>UtteranceSegmenter.swift</c> — the same rules, so both platforms cut a meeting the same way.
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item>Speech starts at a hop whose probability is ≥ <c>Threshold</c>.</item>
/// <item>While in speech, a hop below <c>NegativeThreshold</c> is silence; anything at or above it
/// counts as speech (a dip between the two thresholds never ends an utterance).</item>
/// <item>Speech ends once <c>MinSilence</c> of consecutive silence has accumulated; the utterance
/// ends where that silence began.</item>
/// <item>An utterance reaching <c>MaxDuration</c> is cut at the start of its least probable hop in
/// the second half (ties: the latest), and speech continues from there as a new one.</item>
/// <item>Utterances with less than <c>MinSpeech</c> of speech are dropped.</item>
/// <item><c>Padding</c> is added on both sides, clamped to the samples seen so far and never
/// reaching back before the previous utterance's end.</item>
/// </list>
/// </remarks>
public sealed class UtteranceSegmenter
{
    private readonly List<float> _probabilities = [];
    private int _hop;
    private bool _inSpeech;
    private int _startHop;
    private int _silentHops;
    private int _lastEnd;

    /// <summary>Creates a segmenter.</summary>
    public UtteranceSegmenter(UtteranceSegmenterConfig? config = null) => Config = config ?? new UtteranceSegmenterConfig();

    /// <summary>The tuning in use.</summary>
    public UtteranceSegmenterConfig Config { get; }

    /// <summary>Samples covered so far.</summary>
    public int ProcessedSamples => _hop * Config.HopSamples;

    /// <summary>Whether the last hop left the segmenter inside speech.</summary>
    public bool IsInSpeech => _inSpeech;

    /// <summary>Feeds the probability for the next hop. Returns any utterance that closed.</summary>
    public IReadOnlyList<Utterance> Push(float probability)
    {
        try
        {
            var closed = new List<Utterance>();

            if (!_inSpeech)
            {
                if (probability >= Config.Threshold)
                {
                    _inSpeech = true;
                    _startHop = _hop;
                    _silentHops = 0;
                    _probabilities.Clear();
                    _probabilities.Add(probability);
                }

                return closed;
            }

            _probabilities.Add(probability);
            _silentHops = probability < Config.NegativeThreshold ? _silentHops + 1 : 0;

            var minSilenceHops = Math.Max(1, Hops(Config.MinSilence));
            if (_silentHops >= minSilenceHops)
            {
                var endHop = _hop + 1 - _silentHops;
                if (Finish(_startHop, endHop, _hop + 1) is { } utterance) closed.Add(utterance);
                _inSpeech = false;
                _probabilities.Clear();
                return closed;
            }

            var maxHops = Math.Max(2, Hops(Config.MaxDuration));
            if (_probabilities.Count >= maxHops)
            {
                // Cut at the least probable hop in the second half; latest on ties.
                var half = _probabilities.Count / 2;
                var cut = half;
                for (var index = half; index < _probabilities.Count; index++)
                {
                    if (_probabilities[index] <= _probabilities[cut]) cut = index;
                }

                cut = Math.Max(cut, 1);
                var cutHop = _startHop + cut;
                if (Finish(_startHop, cutHop, _hop + 1, padEnd: false) is { } utterance) closed.Add(utterance);
                _probabilities.RemoveRange(0, cut);
                _startHop = cutHop;
                _silentHops = 0;
            }

            return closed;
        }
        finally
        {
            _hop++;
        }
    }

    /// <summary>Closes any open utterance at the end of the stream.</summary>
    public IReadOnlyList<Utterance> Finish()
    {
        if (!_inSpeech) return [];
        _inSpeech = false;
        var endHop = _hop - _silentHops;
        _probabilities.Clear();
        return Finish(_startHop, endHop, _hop) is { } utterance ? [utterance] : [];
    }

    private int Hops(double seconds) =>
        (int)Math.Round(seconds * Config.SampleRate / Config.HopSamples, MidpointRounding.AwayFromZero);

    private Utterance? Finish(int fromHop, int toHop, int totalHops, bool padEnd = true)
    {
        var speechSamples = (toHop - fromHop) * Config.HopSamples;
        if (speechSamples < Config.MinSpeech * Config.SampleRate) return null;

        var pad = (int)(Config.Padding * Config.SampleRate);
        var start = Math.Max(Math.Max(_lastEnd, (fromHop * Config.HopSamples) - pad), 0);
        var end = Math.Min((toHop * Config.HopSamples) + (padEnd ? pad : 0), totalHops * Config.HopSamples);
        if (end <= start) return null;

        _lastEnd = end;
        return new Utterance(start, end);
    }
}
