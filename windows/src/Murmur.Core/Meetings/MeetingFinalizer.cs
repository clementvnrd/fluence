using System.Globalization;
using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>Reads a channel's timeline back from the encrypted spool.</summary>
public interface IAudioSpoolReader
{
    /// <summary>Samples in the timeline.</summary>
    long SampleCount { get; }

    /// <summary>Reads up to <paramref name="destination"/>'s length from <paramref name="start"/>; returns how many.</summary>
    int Read(long start, Span<float> destination);
}

/// <summary>
/// The system channel's speech, cut out of the timeline and laid end to end for the diarizer,
/// with the way back to meeting time.
/// </summary>
/// <remarks>
/// A meeting is mostly silence on the system channel. Diarizing only the speech (the live
/// segments, padded) keeps the buffer — and the time — proportional to what was said rather
/// than to how long the call lasted; a turn that straddles a seam is split at it.
/// </remarks>
public sealed class SpeechConcatenation
{
    private readonly List<(long Start, long Length, long Offset)> _pieces = [];

    private SpeechConcatenation()
    {
    }

    /// <summary>The pieces, as (timeline start, length) in samples.</summary>
    public IReadOnlyList<(long Start, long Length)> Pieces => [.. _pieces.Select(p => (p.Start, p.Length))];

    /// <summary>Samples once concatenated.</summary>
    public long TotalSamples => _pieces.Count == 0 ? 0 : _pieces[^1].Offset + _pieces[^1].Length;

    /// <summary>Merges padded spans (seconds) into pieces inside a timeline of <paramref name="timelineSamples"/>.</summary>
    public static SpeechConcatenation FromSpans(
        IEnumerable<(double Start, double End)> spans, double padding, long timelineSamples)
    {
        ArgumentNullException.ThrowIfNull(spans);
        var result = new SpeechConcatenation();
        var rate = AudioChunk.SampleRate;
        long offset = 0;
        (long Start, long End)? current = null;

        foreach (var (start, end) in spans.OrderBy(s => s.Start))
        {
            var a = Math.Clamp((long)Math.Floor((start - padding) * rate), 0, timelineSamples);
            var b = Math.Clamp((long)Math.Ceiling((end + padding) * rate), 0, timelineSamples);
            if (b <= a) continue;
            if (current is { } c && a <= c.End)
            {
                current = (c.Start, Math.Max(c.End, b));
                continue;
            }

            if (current is { } done)
            {
                result._pieces.Add((done.Start, done.End - done.Start, offset));
                offset += done.End - done.Start;
            }

            current = (a, b);
        }

        if (current is { } last) result._pieces.Add((last.Start, last.End - last.Start, offset));
        return result;
    }

    /// <summary>The concatenated samples.</summary>
    public float[] Gather(IAudioSpoolReader reader)
    {
        ArgumentNullException.ThrowIfNull(reader);
        var buffer = new float[TotalSamples];
        foreach (var piece in _pieces)
        {
            reader.Read(piece.Start, buffer.AsSpan((int)piece.Offset, (int)piece.Length));
        }

        return buffer;
    }

    /// <summary>Diarizer turns (concatenated time) back on the meeting clock, split at seams.</summary>
    public IReadOnlyList<SpeakerTurn> MapBack(IReadOnlyList<DiarizedTurn> turns)
    {
        ArgumentNullException.ThrowIfNull(turns);
        var rate = (double)AudioChunk.SampleRate;
        var result = new List<SpeakerTurn>();
        foreach (var turn in turns)
        {
            var label = "spk_" + turn.Speaker.ToString(CultureInfo.InvariantCulture);
            var from = (long)(turn.Start * rate);
            var to = (long)(turn.End * rate);
            foreach (var piece in _pieces)
            {
                var a = Math.Max(from, piece.Offset);
                var b = Math.Min(to, piece.Offset + piece.Length);
                if (b <= a) continue;
                result.Add(new SpeakerTurn(label, (piece.Start + (a - piece.Offset)) / rate, (piece.Start + (b - piece.Offset)) / rate));
            }
        }

        return [.. result.OrderBy(t => t.Start)];
    }
}

/// <summary>What the final pass produced.</summary>
/// <param name="Meeting">The meeting, segments merged and attributed, speakers listed.</param>
/// <param name="Voices"><c>S1…Sn</c> → embedding, only when voice prints are on.</param>
/// <param name="Diarized">Whether remote speech was separated into voices.</param>
public sealed record FinalPass(MeetingRecord Meeting, IReadOnlyDictionary<string, float[]> Voices, bool Diarized);

/// <summary>
/// The pass after a meeting ends: who said what. Port of <c>MeetingFinalizer.swift</c>.
/// </summary>
/// <remarks>
/// <list type="number">
/// <item>Diarize the <b>system channel only</b>, from the spool. The microphone is the user by
/// construction, so their voice can never be split into clusters.</item>
/// <item>Attribute each system word to the voice most active over it, split where the voice
/// changes, relabel <c>S1…Sn</c> (<see cref="SpeakerAssignment"/>).</item>
/// <item>Merge with the microphone, dropping its echoes (<see cref="TranscriptMerger"/>).</item>
/// <item>Name the voices (<see cref="Name"/>).</item>
/// </list>
/// Without the diarization models, system audio, or two seconds of remote speech, step 1 is
/// skipped and remote speech stays "Others".
/// </remarks>
public static class MeetingFinalizer
{
    /// <summary>Padding around each live segment when cutting speech for the diarizer, seconds.</summary>
    public const double SpanPadding = 0.3;

    /// <summary>At most this much of one voice goes into its embedding, seconds.</summary>
    public const double EmbeddingSeconds = 30;

    /// <summary>Steps 1–3.</summary>
    /// <param name="meeting">The meeting with its live segments.</param>
    /// <param name="system">The system channel's spool, if any.</param>
    /// <param name="diarizer">Null when the models are not installed.</param>
    /// <param name="embedder">Null unless voice prints are on and the model is installed.</param>
    /// <param name="correct">The dictionary, applied to text re-joined after a split.</param>
    /// <param name="log">Counts and timings only.</param>
    /// <param name="cancellationToken">Cancels the pass.</param>
    public static FinalPass Attribute(
        MeetingRecord meeting,
        IAudioSpoolReader? system,
        ISpeakerDiarizer? diarizer,
        ISpeakerEmbedder? embedder,
        Func<string, string> correct,
        IDiagnosticLog log,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        ArgumentNullException.ThrowIfNull(log);

        var mic = meeting.Segments.Where(s => s.Source == AudioSource.Microphone).ToList();
        var remote = meeting.Segments.Where(s => s.Source == AudioSource.System).ToList();

        IReadOnlyList<SpeakerTurn> turns = [];
        var rawVoices = new Dictionary<string, float[]>(StringComparer.Ordinal);
        if (remote.Count > 0 && system is not null && diarizer is not null)
        {
            try
            {
                var speech = SpeechConcatenation.FromSpans(remote.Select(s => (s.Start, s.End)), SpanPadding, system.SampleCount);
                if (speech.TotalSamples >= 2 * AudioChunk.SampleRate)
                {
                    var started = DateTimeOffset.UtcNow;
                    turns = speech.MapBack(diarizer.Diarize(speech.Gather(system), cancellationToken));
                    log.Info("meeting.diarized", new Dictionary<string, object?>
                    {
                        ["speechSeconds"] = Math.Round((double)speech.TotalSamples / AudioChunk.SampleRate),
                        ["elapsedSeconds"] = Math.Round((DateTimeOffset.UtcNow - started).TotalSeconds, 1),
                        ["voices"] = turns.Select(t => t.Speaker).Distinct().Count(),
                    });

                    if (embedder is not null) rawVoices = Embed(turns, system, embedder);
                }
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                log.Error("meeting.diarization_failed", e);
                turns = [];
            }
        }

        var attribution = SpeakerAssignment.Attribute(remote, turns, Speaker.OthersId, correct);
        var segments = TranscriptMerger.Merge(mic, attribution.Segments).Select(s => s with { IsFinal = true }).ToList();

        // Speakers: me (as it was), then S1…Sn, then "Others" if anything stayed unattributed.
        var me = meeting.Speakers.FirstOrDefault(s => s.IsMe) ?? Speaker.Me();
        var labels = attribution.Labels.Values.OrderBy(l => int.Parse(l[1..], CultureInfo.InvariantCulture));
        var speakers = new List<Speaker> { me };
        speakers.AddRange(labels.Select(l => meeting.SpeakerById(l) ?? new Speaker(l)));
        if (segments.Any(s => s.SpeakerId == Speaker.OthersId)) speakers.Add(Speaker.Others);

        var voices = new Dictionary<string, float[]>(StringComparer.Ordinal);
        foreach (var (raw, label) in attribution.Labels)
        {
            if (rawVoices.TryGetValue(raw, out var embedding)) voices[label] = embedding;
        }

        return new FinalPass(meeting with { Segments = segments, Speakers = speakers }, voices, turns.Count > 0);
    }

    /// <summary>
    /// Step 4. On Windows there is no calendar and no meeting-window reading yet, so the
    /// candidates are empty: voice prints only ever match calendar attendees (decision FLU-9 #3),
    /// and names come from the user's renames. The rules still run, so the day a calendar
    /// source exists, naming works as on macOS.
    /// </summary>
    public static MeetingRecord Name(FinalPass pass, VoicePrintStore? prints, IReadOnlyList<string> windowParticipants)
    {
        ArgumentNullException.ThrowIfNull(pass);
        var meeting = pass.Meeting;
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, double>> similarity =
            prints is not null && meeting.Attendees.Count > 0
                ? prints.Similarities(pass.Voices, meeting.Attendees)
                : new Dictionary<string, IReadOnlyDictionary<string, double>>();

        return meeting with
        {
            Speakers = SpeakerNaming.Name(meeting.Speakers, new NamingCandidates
            {
                WindowParticipants = windowParticipants,
                Attendees = meeting.Attendees,
                VoicePrintSimilarity = similarity,
            }),
        };
    }

    private static Dictionary<string, float[]> Embed(
        IReadOnlyList<SpeakerTurn> turns, IAudioSpoolReader system, ISpeakerEmbedder embedder)
    {
        var result = new Dictionary<string, float[]>(StringComparer.Ordinal);
        foreach (var voice in turns.GroupBy(t => t.Speaker))
        {
            var budget = (int)(EmbeddingSeconds * AudioChunk.SampleRate);
            var samples = new List<float>();
            foreach (var turn in voice.OrderByDescending(t => t.End - t.Start))
            {
                var start = (long)(turn.Start * AudioChunk.SampleRate);
                var length = (int)Math.Min(budget - samples.Count, (turn.End - turn.Start) * AudioChunk.SampleRate);
                if (length <= 0) break;
                var piece = new float[length];
                var read = system.Read(start, piece);
                samples.AddRange(piece.AsSpan(0, read).ToArray());
            }

            if (embedder.Embed([.. samples]) is { } embedding) result[voice.Key] = embedding;
        }

        return result;
    }
}
