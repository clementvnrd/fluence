namespace Murmur.Meeting;

/// <summary>
/// Merges the microphone and system transcripts into one time-ordered list, dropping mic
/// segments that are only the loudspeaker's echo of the remote side. Port of
/// <c>TranscriptMerger.swift</c>; contract: <c>shared/meeting-test-vectors.json</c>, <c>merge</c>.
/// </summary>
/// <remarks>
/// <para>
/// <b>Echo backstop.</b> A mic segment is dropped when its normalised tokens
/// (<see cref="TextTokens"/>) match the system tokens spoken at the same time:
/// </para>
/// <list type="bullet">
/// <item>A = the mic segment's token set. Empty A is always kept.</item>
/// <item>Every system token carries a time: the midpoint of its word, or — for a segment with
/// no word timings — the midpoint of an even split of the segment span across its tokens.</item>
/// <item>For each shift d = −1.5 s … +1.5 s in 0.1 s steps (<c>k = 0…30</c>,
/// <c>d = (k − 15) / 10</c>), B(d) = the system tokens whose time t satisfies
/// <c>mic.start + d − 0.25 ≤ t ≤ mic.end + d + 0.25</c>.</item>
/// <item>The mic segment is dropped when <c>max over d of Jaccard(A, B(d)) &gt; 0.6</c>.</item>
/// </list>
/// <para>
/// <b>Order.</b> Kept segments are sorted by start; on a tie the microphone comes first, then
/// the earlier end, then the original order.
/// </para>
/// </remarks>
public static class TranscriptMerger
{
    /// <summary>Strictly above this, a mic segment is an echo.</summary>
    public const double JaccardThreshold = 0.6;

    /// <summary>Largest shift tried, seconds.</summary>
    public const double MaxShift = 1.5;

    /// <summary>Shift step, seconds.</summary>
    public const double ShiftStep = 0.1;

    /// <summary>Slack on both edges of the shifted window, seconds.</summary>
    public const double EdgeTolerance = 0.25;

    /// <summary>Both channels in time order, mic echoes removed.</summary>
    public static IReadOnlyList<TranscriptSegment> Merge(
        IReadOnlyList<TranscriptSegment> microphone, IReadOnlyList<TranscriptSegment> system)
    {
        ArgumentNullException.ThrowIfNull(microphone);
        ArgumentNullException.ThrowIfNull(system);

        var systemTokens = TimedTokens(system);
        var kept = microphone.Where(m => !IsEcho(m, systemTokens));
        return Sorted([.. kept, .. system]);
    }

    /// <summary>Whether <paramref name="mic"/> duplicates what the system stream said around the same time.</summary>
    public static bool IsEcho(TranscriptSegment mic, IReadOnlyList<TranscriptSegment> system) =>
        IsEcho(mic, TimedTokens(system));

    /// <summary>Start order; on a tie mic first, then the earlier end, then the original order.</summary>
    public static IReadOnlyList<TranscriptSegment> Sorted(IReadOnlyList<TranscriptSegment> segments)
    {
        ArgumentNullException.ThrowIfNull(segments);

        var indexed = segments.Select((segment, index) => (segment, index)).ToList();
        indexed.Sort((lhs, rhs) =>
        {
            var (a, b) = (lhs.segment, rhs.segment);
            if (a.Start != b.Start) return a.Start.CompareTo(b.Start);
            if (a.Source != b.Source) return a.Source == AudioSource.Microphone ? -1 : 1;
            if (a.End != b.End) return a.End.CompareTo(b.End);
            return lhs.index.CompareTo(rhs.index);
        });
        return [.. indexed.Select(x => x.segment)];
    }

    private readonly record struct TimedToken(string Token, double Time);

    private static List<TimedToken> TimedTokens(IReadOnlyList<TranscriptSegment> segments)
    {
        var result = new List<TimedToken>();
        foreach (var segment in segments)
        {
            if (segment.Words.Count == 0)
            {
                var tokens = TextTokens.Normalize(segment.Text);
                if (tokens.Count == 0) continue;
                var step = (segment.End - segment.Start) / tokens.Count;
                for (var index = 0; index < tokens.Count; index++)
                {
                    result.Add(new TimedToken(tokens[index], segment.Start + ((index + 0.5) * step)));
                }
            }
            else
            {
                foreach (var word in segment.Words)
                {
                    var time = (word.Start + word.End) / 2;
                    foreach (var token in TextTokens.Normalize(word.Text)) result.Add(new TimedToken(token, time));
                }
            }
        }

        // Only the time matters below, so the order among equal times is irrelevant.
        return [.. result.OrderBy(t => t.Time)];
    }

    private static bool IsEcho(TranscriptSegment mic, List<TimedToken> systemTokens)
    {
        var a = new HashSet<string>(TextTokens.Normalize(mic.Text), StringComparer.Ordinal);
        if (a.Count == 0) return false;

        // Only tokens that any shift could reach; binary-search the sorted tokens.
        var low = mic.Start - MaxShift - EdgeTolerance;
        var high = mic.End + MaxShift + EdgeTolerance;
        int first = 0, last = systemTokens.Count;
        while (first < last)
        {
            var middle = (first + last) / 2;
            if (systemTokens[middle].Time < low) first = middle + 1;
            else last = middle;
        }

        var nearby = new List<TimedToken>();
        for (var index = first; index < systemTokens.Count && systemTokens[index].Time <= high; index++)
        {
            nearby.Add(systemTokens[index]);
        }

        if (nearby.Count == 0) return false;

        var steps = (int)Math.Round(2 * MaxShift / ShiftStep, MidpointRounding.AwayFromZero);
        for (var k = 0; k <= steps; k++)
        {
            var shift = (double)(k - (steps / 2)) / 10;
            var lower = mic.Start + shift - EdgeTolerance;
            var upper = mic.End + shift + EdgeTolerance;
            var b = new HashSet<string>(
                nearby.Where(t => t.Time >= lower && t.Time <= upper).Select(t => t.Token), StringComparer.Ordinal);
            if (TextTokens.Jaccard(a, b) > JaccardThreshold) return true;
        }

        return false;
    }
}
