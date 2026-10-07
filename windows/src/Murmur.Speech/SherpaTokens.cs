using Murmur.Abstractions;

namespace Murmur.Speech;

/// <summary>Turns sherpa-onnx's parallel token arrays into timed tokens.</summary>
public static class SherpaTokens
{
    /// <summary>The last token's assumed length: two 80 ms encoder frames.</summary>
    public const double FallbackTokenSeconds = 0.16;

    /// <summary>
    /// The longest a token is allowed to last: six encoder frames. Without a cap, the word
    /// before a pause would stretch across it and could be attributed to whoever speaks next.
    /// </summary>
    public const double MaxTokenSeconds = 0.48;

    /// <summary>
    /// Pairs each token with its start; it ends at the next token's start (at most
    /// <see cref="MaxTokenSeconds"/> later), the last one <see cref="FallbackTokenSeconds"/> after
    /// its start, capped at the end of the audio. An end never precedes its start. Arrays of
    /// different lengths are paired up to the shorter; a null array means no timings.
    /// </summary>
    /// <remarks>
    /// sherpa-onnx also reports per-token <c>Durations</c> for TDT models, but on real speech
    /// with Parakeet TDT 0.6B v2 and 1.13.8 they alternate between 0 and ~0.11 s whatever the
    /// word (measured 2026-10-07), so they are not used.
    /// </remarks>
    public static IReadOnlyList<RecognizedToken> Timed(
        IReadOnlyList<string>? tokens, IReadOnlyList<float>? starts, double audioSeconds)
    {
        if (tokens is null || starts is null) return [];
        var count = Math.Min(tokens.Count, starts.Count);
        var result = new List<RecognizedToken>(count);

        for (var i = 0; i < count; i++)
        {
            double start = starts[i];
            var end = i + 1 < count
                ? Math.Min(starts[i + 1], start + MaxTokenSeconds)
                : Math.Min(audioSeconds, start + FallbackTokenSeconds);
            result.Add(new RecognizedToken(tokens[i], start, Math.Max(start, end)));
        }

        return result;
    }
}
