namespace Murmur.Meeting;

/// <summary>Why a recording ended.</summary>
public enum StopReason
{
    /// <summary>The Stop button.</summary>
    User,

    /// <summary>The meeting app stopped using the microphone.</summary>
    CallEnded,

    /// <summary>Ten minutes without speech on either channel.</summary>
    Silence,

    /// <summary>The configured maximum meeting length.</summary>
    MaxDuration,

    /// <summary>The workstation locked.</summary>
    ScreenLocked,

    /// <summary>The computer went to sleep.</summary>
    SystemSleep,

    /// <summary>Audio capture failed.</summary>
    CaptureFailed,
}

/// <summary>Words for <see cref="StopReason"/>.</summary>
public static class StopReasonText
{
    /// <summary>What the UI says. Port of <c>StopReason.explanation</c>, with Windows wording.</summary>
    public static string Explanation(this StopReason reason) => reason switch
    {
        StopReason.User => "Stopped",
        StopReason.CallEnded => "Call ended",
        StopReason.Silence => "Stopped after 10 minutes of silence",
        StopReason.MaxDuration => "Reached the maximum meeting length",
        StopReason.ScreenLocked => "Stopped: screen locked",
        StopReason.SystemSleep => "Stopped: the computer is going to sleep",
        StopReason.CaptureFailed => "Stopped: audio capture failed",
        _ => "Stopped",
    };
}

/// <summary>
/// The automatic stop conditions that depend only on elapsed times. Port of
/// <c>StopPolicy.swift</c>. Event-driven ones (Stop, lock, sleep) are handled by the controller.
/// </summary>
/// <param name="MaxDuration">Hard cap, seconds.</param>
/// <param name="CallEndedAfter">The meeting app has not used the mic for this long: the call ended.</param>
/// <param name="SilenceLimit">No speech on either channel for this long.</param>
public sealed record StopPolicy(double MaxDuration, double CallEndedAfter = 30, double SilenceLimit = 600)
{
    /// <summary>Why to stop now, or null. All times are seconds since the meeting started.</summary>
    /// <param name="elapsed">Now.</param>
    /// <param name="lastSpeech">The last time either channel had speech; null = never.</param>
    /// <param name="appLastUsingMic">
    /// The last time the meeting app was seen using the microphone; null when there is no app
    /// to watch (manual recording), which disables the call-ended rule.
    /// </param>
    public StopReason? Reason(double elapsed, double? lastSpeech, double? appLastUsingMic)
    {
        if (elapsed >= MaxDuration) return StopReason.MaxDuration;
        if (appLastUsingMic is { } lastUse && elapsed - lastUse >= CallEndedAfter) return StopReason.CallEnded;
        if (elapsed - (lastSpeech ?? 0) >= SilenceLimit) return StopReason.Silence;
        return null;
    }
}

/// <summary>Where to put one chunk on a channel's timeline.</summary>
/// <param name="Padding">Zeros to write before the chunk.</param>
/// <param name="DropLeading">Samples to drop from the front of the chunk.</param>
public readonly record struct Placement(int Padding, int DropLeading);

/// <summary>
/// Keeps one channel's samples on the meeting clock. Port of <c>TimelineAligner.swift</c>.
/// </summary>
/// <remarks>
/// Each channel is written as one continuous timeline where sample <i>i</i> is meeting time
/// <i>i / sampleRate</i>: gaps become silence, overlaps are trimmed. That invariant is what lets
/// the diarizer's times line up with the transcript and the spool be indexed by time. On
/// Windows it is also what fills the silences WASAPI loopback leaves: loopback delivers no
/// packets at all while nothing plays. Jitter under <see cref="Tolerance"/> is absorbed, so a
/// healthy stream is written untouched.
/// </remarks>
public sealed class TimelineAligner
{
    /// <summary>Creates an aligner.</summary>
    /// <param name="sampleRate">Samples per second.</param>
    /// <param name="tolerance">Jitter absorbed without correction, seconds.</param>
    public TimelineAligner(double sampleRate = 16_000, double tolerance = 0.12)
    {
        SampleRate = sampleRate;
        Tolerance = (int)(tolerance * sampleRate);
    }

    /// <summary>Samples per second.</summary>
    public double SampleRate { get; }

    /// <summary>Jitter absorbed, samples.</summary>
    public int Tolerance { get; }

    /// <summary>Samples written so far: the timeline's current length.</summary>
    public long Written { get; private set; }

    /// <summary>
    /// Where to put <paramref name="count"/> samples whose first sample was captured
    /// <paramref name="time"/> seconds after the meeting start. Advances the timeline.
    /// </summary>
    public Placement Place(double time, int count)
    {
        var expected = (long)Math.Round(Math.Max(0, time) * SampleRate, MidpointRounding.AwayFromZero);
        var gap = expected - Written;
        var placement = new Placement(0, 0);
        if (gap > Tolerance) placement = placement with { Padding = (int)gap };
        else if (gap < -Tolerance) placement = placement with { DropLeading = (int)Math.Min(-gap, count) };
        Written += placement.Padding + count - placement.DropLeading;
        return placement;
    }

    /// <summary>
    /// Extends the timeline with silence up to <paramref name="time"/> (a channel that delivered
    /// nothing). Returns the zeros to write.
    /// </summary>
    public int PadUntil(double time)
    {
        var expected = (long)Math.Round(Math.Max(0, time) * SampleRate, MidpointRounding.AwayFromZero);
        var gap = expected - Written;
        if (gap <= Tolerance) return 0;
        Written += gap;
        return (int)gap;
    }
}

/// <summary>One sub-word token from the recogniser, timed relative to the utterance.</summary>
/// <param name="Text">The SentencePiece piece, e.g. <c>▁Bon</c>.</param>
/// <param name="Start">Seconds from the utterance start.</param>
/// <param name="End">Seconds from the utterance start.</param>
/// <param name="Confidence">0…1.</param>
public sealed record TimedToken(string Text, double Start, double End, float Confidence);

/// <summary>
/// Groups SentencePiece tokens into words on the meeting clock. Port of <c>WordBuilder.swift</c>.
/// </summary>
/// <remarks>
/// A token starting with the word-boundary marker <c>▁</c> (U+2581) or a space begins a new
/// word; any other token continues the current one. A word spans its first token's start to
/// its last token's end, plus the offset; its confidence is the lowest of its tokens'.
/// <c>&lt;blank&gt;</c>, <c>&lt;pad&gt;</c> and empty tokens are skipped.
/// </remarks>
public static class WordBuilder
{
    /// <summary>SentencePiece's word-boundary marker.</summary>
    public const char Boundary = '▁';

    /// <summary>Words from <paramref name="tokens"/>, shifted by <paramref name="offset"/> seconds.</summary>
    public static IReadOnlyList<Word> Words(IReadOnlyList<TimedToken> tokens, double offset)
    {
        ArgumentNullException.ThrowIfNull(tokens);

        var words = new List<Word>();
        Word? current = null;

        void Flush()
        {
            if (current is null) return;
            var text = current.Text.Trim(' ', '\t');
            if (text.Length > 0) words.Add(current with { Text = text });
            current = null;
        }

        foreach (var token in tokens)
        {
            var raw = token.Text;
            if (raw.Length == 0 || raw == "<blank>" || raw == "<pad>") continue;
            var startsWord = raw[0] == Boundary || raw[0] == ' ';
            var piece = startsWord ? raw.TrimStart(Boundary, ' ') : raw;

            if (startsWord || current is null)
            {
                Flush();
                current = new Word(piece, token.Start + offset, token.End + offset, token.Confidence);
            }
            else
            {
                current = current with
                {
                    Text = current.Text + piece,
                    End = token.End + offset,
                    Confidence = Math.Min(current.Confidence ?? token.Confidence, token.Confidence),
                };
            }
        }

        Flush();
        return words;
    }
}
