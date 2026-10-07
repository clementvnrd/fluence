using System.Globalization;
using System.Text;

namespace Murmur.Core;

/// <summary>
/// Joins the texts of consecutive audio segments into one transcript.
/// </summary>
/// <remarks>
/// <para>
/// Two things go wrong at a seam. Where the segments overlap (see
/// <see cref="AudioSegmenter"/>), the overlapped words come back twice. And every segment is
/// transcribed as if it were a complete utterance, so punctuation lands on both sides of the
/// cut: <c>"…the report. . And then…"</c>.
/// </para>
/// <para>
/// Duplicates are removed only where the audio actually overlapped, and only as a run of
/// whole words matching the end of the previous text — a speaker who genuinely says "that
/// that" across a pause keeps both.
/// </para>
/// </remarks>
public static class TranscriptJoiner
{
    /// <summary>The longest repeated run considered. 750 ms of speech is two or three words.</summary>
    public const int MaxSeamWords = 6;

    private const string SeamPunctuation = ".,;:!?…";

    /// <summary>Joins segment texts.</summary>
    /// <param name="pieces">
    /// Each segment's text, and whether its audio overlapped the previous segment's.
    /// </param>
    public static string Join(IReadOnlyList<(string Text, bool OverlapsPrevious)> pieces)
    {
        var result = new StringBuilder();

        foreach (var (raw, overlaps) in pieces)
        {
            var text = raw.Trim();
            if (text.Length == 0) continue;

            if (result.Length == 0)
            {
                result.Append(text);
                continue;
            }

            if (overlaps) text = DropRepeatedPrefix(result.ToString(), text);

            // "end." + ". start" → "end. start": one side's punctuation is enough.
            if (EndsWithPunctuation(result)) text = text.TrimStart(SeamPunctuation.ToCharArray()).TrimStart();
            if (text.Length == 0) continue;

            result.Append(' ').Append(text);
        }

        return result.ToString();
    }

    /// <summary>
    /// Removes from the start of <paramref name="next"/> the longest run of words that the end
    /// of <paramref name="previous"/> already contains.
    /// </summary>
    private static string DropRepeatedPrefix(string previous, string next)
    {
        var before = previous.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var after = next.Split(' ', StringSplitOptions.RemoveEmptyEntries);

        for (var k = Math.Min(MaxSeamWords, Math.Min(before.Length, after.Length)); k >= 1; k--)
        {
            var matches = true;
            for (var i = 0; i < k && matches; i++)
            {
                matches = Normalize(before[before.Length - k + i]) == Normalize(after[i])
                          && Normalize(after[i]).Length > 0;
            }

            if (matches) return string.Join(' ', after.Skip(k));
        }

        return next;
    }

    /// <summary>Case- and punctuation-insensitive comparison key for one word.</summary>
    private static string Normalize(string word)
    {
        var builder = new StringBuilder(word.Length);
        foreach (var c in word)
        {
            if (char.IsLetterOrDigit(c)) builder.Append(char.ToLower(c, CultureInfo.InvariantCulture));
        }

        return builder.ToString();
    }

    private static bool EndsWithPunctuation(StringBuilder text) =>
        text.Length > 0 && SeamPunctuation.Contains(text[^1], StringComparison.Ordinal);
}
