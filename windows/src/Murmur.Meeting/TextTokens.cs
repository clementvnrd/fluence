using System.Globalization;
using System.Text;

namespace Murmur.Meeting;

/// <summary>
/// Word-level text comparison for the echo backstop. Port of <c>TextTokens.swift</c>.
/// </summary>
/// <remarks>
/// Cross-platform contract (<c>shared/meeting-test-vectors.json</c>, <c>normalization</c>). The
/// rules, in order:
/// <list type="number">
/// <item>Unicode NFKD (compatibility decomposition).</item>
/// <item>Drop every non-spacing combining mark (general category Mn) — <c>é</c> → <c>e</c>.</item>
/// <item>Lowercase.</item>
/// <item>Every character that is not a letter or a number becomes a space.</item>
/// <item>Split on whitespace; drop empty pieces.</item>
/// </list>
/// Works on <see cref="Rune"/>s, not <see cref="char"/>s, so a letter outside the Basic
/// Multilingual Plane is one letter, as it is to Swift.
/// </remarks>
public static class TextTokens
{
    /// <summary>The normalised tokens of <paramref name="text"/>.</summary>
    public static IReadOnlyList<string> Normalize(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var decomposed = text.Normalize(NormalizationForm.FormKD);
        var folded = new StringBuilder(decomposed.Length);
        foreach (var rune in decomposed.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.NonSpacingMark) folded.Append(rune.ToString());
        }

        var lowered = folded.ToString().ToLowerInvariant();

        var tokens = new List<string>();
        var current = new StringBuilder();
        foreach (var rune in lowered.EnumerateRunes())
        {
            if (Rune.IsLetter(rune) || Rune.IsNumber(rune))
            {
                current.Append(rune.ToString());
            }
            else if (current.Length > 0)
            {
                tokens.Add(current.ToString());
                current.Clear();
            }
        }

        if (current.Length > 0) tokens.Add(current.ToString());
        return tokens;
    }

    /// <summary>
    /// |A ∩ B| / |A ∪ B| over token sets. Two empty sets score 0: nothing to match is never a
    /// duplicate.
    /// </summary>
    public static double Jaccard(IReadOnlySet<string> a, IReadOnlySet<string> b)
    {
        ArgumentNullException.ThrowIfNull(a);
        ArgumentNullException.ThrowIfNull(b);

        var union = new HashSet<string>(a, StringComparer.Ordinal);
        union.UnionWith(b);
        if (union.Count == 0) return 0;

        var intersection = a.Count(b.Contains);
        return (double)intersection / union.Count;
    }
}
