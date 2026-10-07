using Murmur.Abstractions;

namespace Murmur.Core;

/// <summary>One piece of a long recording, ready for the encoder.</summary>
/// <param name="Samples">16 kHz mono float.</param>
/// <param name="OverlapsPrevious">
/// True when this piece starts before the previous one ended — the cut could not find a pause,
/// so the seam is transcribed twice and <see cref="TranscriptJoiner"/> removes the repeat.
/// </param>
public readonly record struct AudioSegment(ReadOnlyMemory<float> Samples, bool OverlapsPrevious);

/// <summary>
/// Splits a long recording into pieces the encoder can actually process.
/// </summary>
/// <remarks>
/// <para>
/// Parakeet's exported encoder carries a fixed relative-position table sized for 5000
/// frames. At 80 ms per frame that is <b>400 seconds</b>, and past it inference does not
/// degrade — it throws:
/// </para>
/// <code>
/// Attempting to broadcast an axis by a dimension other than 1. 126 by 5126
/// </code>
/// <para>
/// Memory is the tighter constraint in practice: a 7-second clip already has a ~2 GB working
/// set, and 300 seconds takes it past 4 GB. So the ceiling here is well below the hard limit.
/// </para>
/// <para>
/// <b>Where to cut.</b> In the last <see cref="SilenceSearchSeconds"/> before the limit, the
/// quietest <see cref="EnergyWindowMilliseconds"/> stretch wins, and the cut goes through its
/// middle. The window is deliberately long: a 20 ms window finds the gap <i>inside</i> a word
/// (every plosive has one), while 200 ms only fits between words.
/// </para>
/// <para>
/// <b>When there is no pause</b> — the quietest stretch is still loud compared with its
/// surroundings — the next piece starts <see cref="OverlapMilliseconds"/> early, so a word the
/// cut went through is heard whole by one side or the other, and the duplicate is removed when
/// the texts are joined. Where the cut is in a real pause there is no overlap: a fragment of
/// the previous word at the start of a piece is how recognisers invent words.
/// </para>
/// <para>
/// Silero VAD would place cuts better still, but needs a separate model download; this is the
/// dependency-free baseline.
/// </para>
/// </remarks>
public static class AudioSegmenter
{
    /// <summary>The hard limit imposed by the encoder's position table, in seconds.</summary>
    public const int EncoderCeilingSeconds = 400;

    /// <summary>
    /// Longest segment we will actually produce. Far below the ceiling, because memory grows
    /// with length and a 60-second segment already costs ~2.5 GB.
    /// </summary>
    public const int MaxSegmentSeconds = 60;

    /// <summary>
    /// How far back from the limit to look for a quiet moment. Segments are therefore between
    /// <c>MaxSegmentSeconds - SilenceSearchSeconds</c> and <c>MaxSegmentSeconds</c> long.
    /// </summary>
    public const int SilenceSearchSeconds = 8;

    /// <summary>Length of the window scored for quietness. At least 200 ms — see the remarks.</summary>
    public const int EnergyWindowMilliseconds = 200;

    /// <summary>How far a piece reaches back into the previous one when the cut is not in a pause.</summary>
    public const int OverlapMilliseconds = 750;

    /// <summary>
    /// A window counts as a pause when its RMS is at most this fraction of the search region's
    /// RMS. Relative, so it works at any microphone gain.
    /// </summary>
    public const double PauseRatio = 0.3;

    private const int MaxSegmentSamples = MaxSegmentSeconds * AudioChunk.SampleRate;
    private const int SearchSamples = SilenceSearchSeconds * AudioChunk.SampleRate;
    private const int EnergyWindow = EnergyWindowMilliseconds * AudioChunk.SampleRate / 1000;
    private const int OverlapSamples = OverlapMilliseconds * AudioChunk.SampleRate / 1000;

    /// <summary>Step between scored windows, ~10 ms.</summary>
    private const int Hop = AudioChunk.SampleRate / 100;

    /// <summary>
    /// Splits <paramref name="samples"/> into segments no longer than
    /// <see cref="MaxSegmentSeconds"/>.
    /// </summary>
    /// <returns>
    /// One segment when the input is already short enough — the common case for dictation,
    /// and it allocates nothing.
    /// </returns>
    public static IReadOnlyList<ReadOnlyMemory<float>> Split(ReadOnlyMemory<float> samples) =>
        SplitWithSeams(samples).Select(s => s.Samples).ToList();

    /// <summary>
    /// Like <see cref="Split"/>, but says which seams overlap so the texts can be joined
    /// without repeating words.
    /// </summary>
    public static IReadOnlyList<AudioSegment> SplitWithSeams(ReadOnlyMemory<float> samples)
    {
        if (samples.Length <= MaxSegmentSamples) return [new AudioSegment(samples, false)];

        var segments = new List<AudioSegment>();
        var start = 0;
        var overlapsPrevious = false;

        while (start < samples.Length)
        {
            var remaining = samples.Length - start;
            if (remaining <= MaxSegmentSamples)
            {
                segments.Add(new AudioSegment(samples[start..], overlapsPrevious));
                break;
            }

            var idealEnd = start + MaxSegmentSamples;
            var (cut, isPause) = FindQuietestPoint(samples.Span, idealEnd - SearchSamples, idealEnd);

            // Never let a degenerate search produce a tiny segment and loop (near) forever.
            if (cut <= start + OverlapSamples) (cut, isPause) = (idealEnd, false);

            segments.Add(new AudioSegment(samples[start..cut], overlapsPrevious));

            // No pause to cut in: the next piece re-hears the end of this one.
            overlapsPrevious = !isPause;
            start = isPause ? cut : cut - OverlapSamples;
        }

        return segments;
    }

    /// <summary>
    /// Finds the lowest-energy <see cref="EnergyWindowMilliseconds"/> window in
    /// <c>[from, to)</c> and returns its midpoint, and whether it is quiet enough to be a pause.
    /// </summary>
    private static (int Cut, bool IsPause) FindQuietestPoint(ReadOnlySpan<float> samples, int from, int to)
    {
        from = Math.Max(from, 0);
        to = Math.Min(to, samples.Length);
        if (to - from < EnergyWindow) return (to, false);

        // Prefix sums of squares: every window's energy in O(1).
        var length = to - from;
        var prefix = new double[length + 1];
        for (var i = 0; i < length; i++)
        {
            var s = (double)samples[from + i];
            prefix[i + 1] = prefix[i] + (s * s);
        }

        var quietestAt = 0;
        var quietest = double.MaxValue;

        for (var offset = 0; offset + EnergyWindow <= length; offset += Hop)
        {
            var energy = prefix[offset + EnergyWindow] - prefix[offset];

            // <=, so among equally quiet windows the latest wins: the longest segment.
            if (energy <= quietest)
            {
                quietest = energy;
                quietestAt = offset;
            }
        }

        var windowRms = Math.Sqrt(quietest / EnergyWindow);
        var regionRms = Math.Sqrt(prefix[length] / length);
        var isPause = windowRms <= PauseRatio * regionRms;

        return (from + quietestAt + (EnergyWindow / 2), isPause);
    }
}
