using Murmur.Abstractions;

namespace Murmur.Speech;

/// <summary>Turns sherpa-onnx's parallel token arrays into timed tokens.</summary>
public static class SherpaTokens
{
    /// <summary>The longest a token is assumed to last when nothing else bounds it: two 80 ms encoder frames.</summary>
    public const double FallbackTokenSeconds = 0.16;

    /// <summary>
    /// Pairs each token with its start. Its end is, in order of preference: start + duration
    /// (TDT models report one), the next token's start, or start + <see cref="FallbackTokenSeconds"/>
    /// capped at the end of the audio. An end never precedes its start. Arrays of different
    /// lengths are paired up to the shorter; a null array means no timings.
    /// </summary>
    public static IReadOnlyList<RecognizedToken> Timed(
        IReadOnlyList<string>? tokens, IReadOnlyList<float>? starts, IReadOnlyList<float>? durations, double audioSeconds)
    {
        if (tokens is null || starts is null) return [];
        var count = Math.Min(tokens.Count, starts.Count);
        var result = new List<RecognizedToken>(count);

        for (var i = 0; i < count; i++)
        {
            double start = starts[i];
            double end;
            if (durations is not null && i < durations.Count && durations[i] > 0) end = start + durations[i];
            else if (i + 1 < count) end = starts[i + 1];
            else end = Math.Min(audioSeconds, start + FallbackTokenSeconds);

            result.Add(new RecognizedToken(tokens[i], start, Math.Max(start, end)));
        }

        return result;
    }
}
