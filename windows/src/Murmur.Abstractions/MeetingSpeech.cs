namespace Murmur.Abstractions;

/// <summary>One sub-word token from the recogniser.</summary>
/// <param name="Text">The SentencePiece piece, e.g. <c>▁Bon</c>.</param>
/// <param name="Start">Seconds from the start of the audio passed in.</param>
/// <param name="End">Seconds from the start of the audio passed in.</param>
public readonly record struct RecognizedToken(string Text, double Start, double End);

/// <summary>A transcription with token timings.</summary>
/// <param name="Text">The whole text.</param>
/// <param name="Tokens">The tokens, in order; empty when the engine gives no timings.</param>
public sealed record TimedTranscript(string Text, IReadOnlyList<RecognizedToken> Tokens);

/// <summary>An engine that can say when each token was spoken. Meetings need it for word → speaker.</summary>
public interface ITimedTranscriber
{
    /// <summary>Whether the model is loaded and ready.</summary>
    bool IsReady { get; }

    /// <summary>Transcribes one utterance with token timings.</summary>
    /// <param name="samples">16 kHz mono float, in [-1, 1].</param>
    /// <param name="cancellationToken">Cancels a transcription in flight.</param>
    ValueTask<TimedTranscript> TranscribeTimedAsync(ReadOnlyMemory<float> samples, CancellationToken cancellationToken);
}

/// <summary>Says, hop by hop, whether a channel has speech in it.</summary>
public interface IVoiceActivityDetector : IDisposable
{
    /// <summary>Samples per decision. <see cref="Push"/> takes exactly this many.</summary>
    int HopSamples { get; }

    /// <summary>A short name for the diagnostic log ("silero", "energy").</summary>
    string Kind { get; }

    /// <summary>Feeds the next hop of 16 kHz mono audio; returns a speech probability in [0, 1].</summary>
    float Push(ReadOnlySpan<float> hop);
}

/// <summary>One stretch of one voice, from the diarizer.</summary>
/// <param name="Speaker">The diarizer's cluster index.</param>
/// <param name="Start">Seconds from the start of the audio passed in.</param>
/// <param name="End">Seconds from the start of the audio passed in.</param>
public readonly record struct DiarizedTurn(int Speaker, double Start, double End);

/// <summary>Separates the voices in one channel of audio, after the meeting.</summary>
public interface ISpeakerDiarizer : IDisposable
{
    /// <summary>Who spoke when, in <paramref name="samples"/> (16 kHz mono).</summary>
    IReadOnlyList<DiarizedTurn> Diarize(float[] samples, CancellationToken cancellationToken);
}

/// <summary>Turns a stretch of one voice into a fixed-length embedding (a "voice print").</summary>
/// <remarks>Biometric data (GDPR art. 9): only computed when the user has opted in to voice prints.</remarks>
public interface ISpeakerEmbedder : IDisposable
{
    /// <summary>The embedding's length.</summary>
    int Dimension { get; }

    /// <summary>The embedding of <paramref name="samples"/> (16 kHz mono), or null when too short to say.</summary>
    float[]? Embed(float[] samples);
}
