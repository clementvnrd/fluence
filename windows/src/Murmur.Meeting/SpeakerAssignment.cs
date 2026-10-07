namespace Murmur.Meeting;

/// <summary>One diarizer turn: "this voice was active over this span" (meeting time, seconds).</summary>
/// <param name="Speaker">The diarizer's label for the voice.</param>
/// <param name="Start">Start, seconds.</param>
/// <param name="End">End, seconds.</param>
public sealed record SpeakerTurn(string Speaker, double Start, double End);

/// <summary>What <see cref="SpeakerAssignment.Attribute"/> produced.</summary>
/// <param name="Segments">The system segments, split at voice changes, labelled <c>S1…Sn</c> (or the fallback).</param>
/// <param name="Labels">Diarizer label → <c>S1…Sn</c>, for the voices that ended up with at least one segment.</param>
public sealed record AttributionResult(
    IReadOnlyList<TranscriptSegment> Segments,
    IReadOnlyDictionary<string, string> Labels);

/// <summary>
/// Attributes the system channel's words to diarized voices, splits segments where the voice
/// changes, and relabels the voices <c>S1…Sn</c> in order of first appearance. Port of
/// <c>SpeakerAssignment.swift</c>; contract: <c>shared/meeting-test-vectors.json</c>,
/// <c>wordSpeaker</c> and <c>attribution</c>.
/// </summary>
/// <remarks>
/// <b>Word → speaker.</b> For a span [s, e], each turn's overlap is
/// <c>max(0, min(e, turn.end) − max(s, turn.start))</c>. The turn with the largest positive
/// overlap wins; ties go to the earlier turn start, then to the smaller label (ordinal). With no
/// positive overlap, the nearest turn wins when its gap <c>max(turn.start − e, s − turn.end, 0)</c>
/// is at most 1.0 s (ties as above). Otherwise the word is unattributed (null).
/// </remarks>
public static class SpeakerAssignment
{
    /// <summary>Largest gap to a turn that still attributes a word, seconds.</summary>
    public const double MaxGap = 1.0;

    /// <summary>The voice for the span [<paramref name="start"/>, <paramref name="end"/>], or null.</summary>
    public static string? SpeakerFor(double start, double end, IReadOnlyList<SpeakerTurn> turns)
    {
        ArgumentNullException.ThrowIfNull(turns);

        SpeakerTurn? best = null;
        var bestOverlap = 0.0;
        foreach (var turn in turns)
        {
            var overlap = Math.Max(0, Math.Min(end, turn.End) - Math.Max(start, turn.Start));
            if (overlap <= 0) continue;
            if (best is null || overlap > bestOverlap || (overlap == bestOverlap && Precedes(turn, best)))
            {
                best = turn;
                bestOverlap = overlap;
            }
        }

        if (best is not null) return best.Speaker;

        SpeakerTurn? nearest = null;
        var nearestGap = 0.0;
        foreach (var turn in turns)
        {
            var gap = Math.Max(Math.Max(turn.Start - end, start - turn.End), 0);
            if (gap > MaxGap) continue;
            if (nearest is null || gap < nearestGap || (gap == nearestGap && Precedes(turn, nearest)))
            {
                nearest = turn;
                nearestGap = gap;
            }
        }

        return nearest?.Speaker;
    }

    /// <summary>One label per word, in order.</summary>
    public static IReadOnlyList<string?> SpeakersFor(IReadOnlyList<Word> words, IReadOnlyList<SpeakerTurn> turns)
    {
        ArgumentNullException.ThrowIfNull(words);
        return [.. words.Select(w => SpeakerFor(w.Start, w.End, turns))];
    }

    private static bool Precedes(SpeakerTurn a, SpeakerTurn b)
    {
        if (a.Start != b.Start) return a.Start < b.Start;
        return string.CompareOrdinal(a.Speaker, b.Speaker) < 0;
    }

    /// <summary>Attributes every system segment.</summary>
    /// <remarks>
    /// <list type="bullet">
    /// <item>Within a segment, an unattributed word takes the speaker of the closest preceding
    /// attributed word, or — at the start — of the first following one.</item>
    /// <item>A segment with no attributed word at all (or no words) is attributed as one span with
    /// the same rule; failing that it gets <paramref name="fallbackId"/>.</item>
    /// <item>Consecutive words with the same speaker form one output segment. A segment that stays
    /// whole keeps its text, span and id; a split piece gets the words' span and
    /// <c>transform(words joined by single spaces)</c> as its text.</item>
    /// <item>Output is time-ordered (<see cref="TranscriptMerger.Sorted"/>), then labels are renamed
    /// <c>S1, S2…</c> in order of first appearance. <paramref name="fallbackId"/> is never renamed.</item>
    /// </list>
    /// </remarks>
    public static AttributionResult Attribute(
        IReadOnlyList<TranscriptSegment> segments,
        IReadOnlyList<SpeakerTurn> turns,
        string fallbackId,
        Func<string, string>? transform = null)
    {
        ArgumentNullException.ThrowIfNull(segments);
        transform ??= static text => text;

        var pieces = new List<TranscriptSegment>();
        foreach (var segment in segments)
        {
            var filled = FillGaps(SpeakersFor(segment.Words, turns));

            if (segment.Words.Count == 0 || filled.Count == 0 || filled[0] is not { } firstLabel)
            {
                pieces.Add(segment with { SpeakerId = SpeakerFor(segment.Start, segment.End, turns) ?? fallbackId });
                continue;
            }

            // Runs of identical labels.
            var runs = new List<(string Label, int Start, int End)>();
            var runStart = 0;
            var runLabel = firstLabel;
            for (var index = 1; index < filled.Count; index++)
            {
                var label = filled[index] ?? runLabel;
                if (label != runLabel)
                {
                    runs.Add((runLabel, runStart, index));
                    runStart = index;
                    runLabel = label;
                }
            }

            runs.Add((runLabel, runStart, filled.Count));

            if (runs.Count == 1)
            {
                pieces.Add(segment with { SpeakerId = runLabel });
                continue;
            }

            foreach (var run in runs)
            {
                var words = segment.Words.Skip(run.Start).Take(run.End - run.Start).ToList();
                pieces.Add(new TranscriptSegment
                {
                    Source = segment.Source,
                    SpeakerId = run.Label,
                    Start = words[0].Start,
                    End = words[^1].End,
                    Text = transform(string.Join(" ", words.Select(w => w.Text))),
                    Words = words,
                    IsFinal = segment.IsFinal,
                });
            }
        }

        var ordered = TranscriptMerger.Sorted(pieces);
        var mapping = new Dictionary<string, string>(StringComparer.Ordinal);
        var next = 1;
        foreach (var segment in ordered)
        {
            if (segment.SpeakerId == fallbackId || mapping.ContainsKey(segment.SpeakerId)) continue;
            mapping[segment.SpeakerId] = "S" + next.ToString(System.Globalization.CultureInfo.InvariantCulture);
            next++;
        }

        var relabelled = ordered
            .Select(s => s with { SpeakerId = mapping.TryGetValue(s.SpeakerId, out var to) ? to : s.SpeakerId })
            .ToList();
        return new AttributionResult(relabelled, mapping);
    }

    /// <summary>Unattributed entries take the previous label, or the next one at the start.</summary>
    internal static IReadOnlyList<string?> FillGaps(IReadOnlyList<string?> labels)
    {
        var firstKnown = labels.FirstOrDefault(l => l is not null);
        if (firstKnown is null) return labels;

        var result = new List<string?>(labels.Count);
        var last = firstKnown;
        foreach (var label in labels)
        {
            if (label is not null) last = label;
            result.Add(last);
        }

        return result;
    }
}
