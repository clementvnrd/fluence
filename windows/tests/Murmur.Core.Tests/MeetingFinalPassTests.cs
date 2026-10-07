using System.Security.Cryptography;
using System.Text;
using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Meeting;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

internal sealed class ArraySpool(float[] samples) : IAudioSpoolReader
{
    public long SampleCount => samples.Length;

    public int Read(long start, Span<float> destination)
    {
        if (start >= samples.Length) return 0;
        var count = (int)Math.Min(destination.Length, samples.Length - start);
        samples.AsSpan((int)start, count).CopyTo(destination);
        return count;
    }
}

/// <summary>The vault: a DPAPI-wrapped master key and per-item keys bound to what they protect.</summary>
public sealed class MeetingVaultTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fluence-vault-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private MeetingVault Open(ISecretProtector? protector, out string? problem) =>
        MeetingVault.Open(_dir, protector, new FakeClock(), NullDiagnosticLog.Instance, out problem)!;

    [Fact]
    public void Item_keys_round_trip_only_under_their_own_label()
    {
        using var vault = Open(new FakeSecretProtector(), out _);
        var (key, wrapped) = vault.CreateItemKey("meeting-a");
        using (key)
        {
            var sealedBytes = AeadBox.Seal(key, "hello"u8, "ad"u8);

            vault.TryOpenItemKey(wrapped, "meeting-a", out var reopened).ShouldBeTrue();
            using (reopened)
            {
                AeadBox.TryOpen(reopened!, sealedBytes, "ad"u8, out var plain).ShouldBeTrue();
                Encoding.UTF8.GetString(plain!).ShouldBe("hello");
                AeadBox.TryOpen(reopened!, sealedBytes, "other"u8, out _).ShouldBeFalse();
            }

            vault.TryOpenItemKey(wrapped, "meeting-b", out _).ShouldBeFalse();
        }
    }

    [Fact]
    public void Without_a_protector_there_is_no_vault_and_no_plaintext_fallback()
    {
        MeetingVault.Open(_dir, null, new FakeClock(), NullDiagnosticLog.Instance, out var problem).ShouldBeNull();
        problem.ShouldNotBeNull().ShouldContain("cannot be recorded");
        Directory.Exists(_dir).ShouldBeFalse();
    }

    [Fact]
    public void A_master_key_from_another_account_is_set_aside_not_deleted()
    {
        using (Open(new FakeSecretProtector(0x11), out _)) { }

        using var second = Open(new FakeSecretProtector(0x22), out var problem);
        second.ShouldNotBeNull();
        problem.ShouldNotBeNull().ShouldContain("kept");
        Directory.GetFiles(_dir, "meetings.unreadable-*.key").ShouldHaveSingleItem();
        File.Exists(MeetingVault.KeyPath(_dir)).ShouldBeTrue();
    }

    [Fact]
    public void History_lines_and_byte_seals_cannot_be_swapped()
    {
        var keyPath = Path.Combine(_dir, "k.key");
        Directory.CreateDirectory(_dir);
        using var cipher = HistoryCipher.OpenOrCreate(keyPath, new FakeSecretProtector());
        var blob = cipher.SealBytes("x"u8, "label-1"u8);
        cipher.TryOpenBytes(blob, "label-1"u8, out _).ShouldBeTrue();
        cipher.TryOpenBytes(blob, "label-2"u8, out _).ShouldBeFalse();
        cipher.TryOpen("f1:" + Convert.ToBase64String(blob), out _).ShouldBeFalse();
    }
}

/// <summary>Cutting the system channel's speech out for the diarizer, and back to meeting time.</summary>
public sealed class SpeechConcatenationTests
{
    [Fact]
    public void Padded_spans_merge_and_turns_map_back_split_at_seams()
    {
        // Speech at 1–2 s and 1.5–3 s (overlapping) and 10–11 s, padding 0.5 s, 20 s timeline.
        var speech = SpeechConcatenation.FromSpans([(10, 11), (1, 2), (1.5, 3)], 0.5, 20 * 16_000);
        speech.Pieces.ShouldBe([(8_000L, 48_000L), (152_000L, 32_000L)]);
        speech.TotalSamples.ShouldBe(80_000);

        // One turn covering the end of the first piece and the start of the second.
        var turns = speech.MapBack([new DiarizedTurn(3, 2.5, 3.5)]);
        turns.Select(t => (t.Speaker, Math.Round(t.Start, 3), Math.Round(t.End, 3)))
            .ShouldBe([("spk_3", 3.0, 3.5), ("spk_3", 9.5, 10.0)]);
    }

    [Fact]
    public void Gathering_reads_each_piece_from_the_spool()
    {
        var timeline = Enumerable.Range(0, 32_000).Select(i => (float)i).ToArray();
        var speech = SpeechConcatenation.FromSpans([(0.5, 0.6), (1.5, 1.6)], 0, timeline.Length);
        var gathered = speech.Gather(new ArraySpool(timeline));
        gathered.Length.ShouldBe(3_200);
        gathered[0].ShouldBe(8_000f);
        gathered[1_600].ShouldBe(24_000f);
    }
}

/// <summary>The final pass: who said what.</summary>
public sealed class MeetingFinalizerTests
{
    private static TranscriptSegment System(double start, double end, string text, params (string W, double S, double E)[] words) => new()
    {
        Source = AudioSource.System,
        SpeakerId = Speaker.OthersId,
        Start = start,
        End = end,
        Text = text,
        Words = [.. words.Select(w => new Word(w.W, w.S, w.E))],
    };

    private static MeetingRecord Meeting() => new()
    {
        Title = "Weekly",
        StartedAt = DateTimeOffset.UnixEpoch,
        EndedAt = DateTimeOffset.UnixEpoch.AddSeconds(20),
        Speakers = [Speaker.Me(), Speaker.Others],
        Segments =
        [
            new TranscriptSegment { Source = AudioSource.Microphone, SpeakerId = Speaker.MeId, Start = 0.5, End = 1.5, Text = "Hi all" },
            System(2, 6, "Hello there. How are you?",
                ("Hello", 2.0, 2.5), ("there.", 2.5, 3.0), ("How", 4.2, 4.5), ("are", 4.5, 4.8), ("you?", 4.8, 5.2)),
            new TranscriptSegment { Source = AudioSource.Microphone, SpeakerId = Speaker.MeId, Start = 4.4, End = 5.4, Text = "how are you" },
        ],
    };

    private static readonly float[] Timeline = [.. Enumerable.Range(0, 20 * 16_000).Select(i => i < 64_000 ? 0.1f : 0.6f)];

    [Fact]
    public void Remote_speech_is_split_by_voice_and_mic_echoes_are_dropped()
    {
        var diarizer = new FakeDiarizer([new DiarizedTurn(7, 0.0, 1.6), new DiarizedTurn(2, 1.8, 3.5)]);
        var pass = MeetingFinalizer.Attribute(Meeting(), new ArraySpool(Timeline), diarizer, null, t => t,
            NullDiagnosticLog.Instance, CancellationToken.None);

        pass.Diarized.ShouldBeTrue();
        diarizer.Calls.ShouldHaveSingleItem().ShouldBeLessThan(Timeline.Length);   // speech only, not the whole call
        pass.Meeting.Segments.Select(s => (s.SpeakerId, s.Text)).ShouldBe(
        [
            ("me", "Hi all"),
            ("S1", "Hello there."),
            ("S2", "How are you?"),
        ]);
        pass.Meeting.Segments.ShouldAllBe(s => s.IsFinal);
        pass.Meeting.Speakers.Select(s => s.Id).ShouldBe(["me", "S1", "S2"]);
        pass.Voices.ShouldBeEmpty();   // no embedder: voice prints are off
    }

    [Fact]
    public void Without_diarization_models_remote_speech_stays_others()
    {
        var pass = MeetingFinalizer.Attribute(Meeting(), new ArraySpool(Timeline), null, null, t => t,
            NullDiagnosticLog.Instance, CancellationToken.None);

        pass.Diarized.ShouldBeFalse();
        pass.Meeting.Segments.Where(s => s.Source == AudioSource.System).ShouldAllBe(s => s.SpeakerId == Speaker.OthersId);
        pass.Meeting.Speakers.Select(s => s.DisplayName).ShouldBe(["You", "Others"]);
    }

    [Fact]
    public void A_failing_diarizer_is_logged_and_the_transcript_survives()
    {
        var log = new RecordingDiagnosticLog();
        var diarizer = new FakeDiarizer([]) { Failure = new InvalidOperationException("native failure") };
        var pass = MeetingFinalizer.Attribute(Meeting(), new ArraySpool(Timeline), diarizer, null, t => t, log, CancellationToken.None);

        log.Events.ShouldContain(e => e.Name == "meeting.diarization_failed");
        pass.Meeting.Segments.Count.ShouldBe(2);
    }

    [Fact]
    public void With_voice_prints_on_each_voice_gets_an_embedding_under_its_final_label()
    {
        var diarizer = new FakeDiarizer([new DiarizedTurn(7, 0.0, 1.6), new DiarizedTurn(2, 1.8, 3.5)]);
        var pass = MeetingFinalizer.Attribute(Meeting(), new ArraySpool(Timeline), diarizer, new FakeEmbedder(), t => t,
            NullDiagnosticLog.Instance, CancellationToken.None);

        pass.Voices.Keys.Order(StringComparer.Ordinal).ShouldBe(["S1", "S2"]);
        pass.Voices["S1"][0].ShouldBeLessThan(pass.Voices["S2"][0]);   // read from the right stretch of the spool
    }

    [Fact]
    public void Without_calendar_attendees_voice_prints_never_name_anyone()
    {
        var pass = new FinalPass(Meeting() with { Speakers = [Speaker.Me(), new Speaker("S1")] },
            new Dictionary<string, float[]> { ["S1"] = [1, 0, 0, 0] }, true);
        var named = MeetingFinalizer.Name(pass, null, []);
        named.Speakers.Single(s => s.Id == "S1").Name.ShouldBeNull();
    }
}

/// <summary>Opt-in voice prints: nothing without consent, sealed on disk, deletable.</summary>
public sealed class VoicePrintStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fluence-prints-{Guid.NewGuid():N}");
    private readonly MeetingVault _vault;
    private bool _enabled;

    public VoicePrintStoreTests()
    {
        _vault = MeetingVault.Open(_dir, new FakeSecretProtector(), new FakeClock(), NullDiagnosticLog.Instance, out _)!;
    }

    public void Dispose()
    {
        _vault.Dispose();
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private VoicePrintStore Store() => new(_dir, _vault, () => _enabled);

    [Fact]
    public void Off_by_default_nothing_is_stored_or_matched()
    {
        var store = Store();
        var meeting = Guid.NewGuid();
        store.SaveCandidates(meeting, new Dictionary<string, float[]> { ["S1"] = [1, 0] });
        store.Enroll(meeting, "S1", "Ada").ShouldBeFalse();
        File.Exists(Path.Combine(_dir, "voiceprints.sealed")).ShouldBeFalse();
        store.Prints.ShouldBeEmpty();
    }

    [Fact]
    public void A_rename_enrols_the_voice_sealed_and_a_second_meeting_refines_it()
    {
        _enabled = true;
        var store = Store();
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        store.SaveCandidates(first, new Dictionary<string, float[]> { ["S1"] = [1, 0] });
        store.SaveCandidates(second, new Dictionary<string, float[]> { ["S2"] = [0, 1] });

        store.Enroll(first, "S1", "Ada Lovelace").ShouldBeTrue();
        store.Enroll(second, "S2", "ada lovelace").ShouldBeTrue();

        var print = store.Prints.ShouldHaveSingleItem();
        print.Name.ShouldBe("Ada Lovelace");
        print.Samples.ShouldBe(2);
        print.Embedding.ShouldBe([0.5f, 0.5f]);
        File.ReadAllText(Path.Combine(_dir, "voiceprints.sealed")).ShouldNotContain("Ada");
    }

    [Fact]
    public void Matching_is_restricted_to_allowed_names()
    {
        _enabled = true;
        var store = Store();
        var meeting = Guid.NewGuid();
        store.SaveCandidates(meeting, new Dictionary<string, float[]> { ["S1"] = [1, 0] });
        store.Enroll(meeting, "S1", "Ada");

        var voices = new Dictionary<string, float[]> { ["S1"] = [1, 0] };
        store.Similarities(voices, []).ShouldBeEmpty();
        store.Similarities(voices, ["Ada"])["S1"]["Ada"].ShouldBe(1.0, 1e-9);
    }

    [Fact]
    public void One_person_or_everything_can_be_deleted()
    {
        _enabled = true;
        var store = Store();
        var meeting = Guid.NewGuid();
        store.SaveCandidates(meeting, new Dictionary<string, float[]> { ["S1"] = [1, 0], ["S2"] = [0, 1] });
        store.Enroll(meeting, "S1", "Ada");
        store.Enroll(meeting, "S2", "Bob");

        store.Delete(store.Prints.Single(p => p.Name == "Ada").Id);
        store.Prints.Select(p => p.Name).ShouldBe(["Bob"]);

        store.DeleteAll();
        store.Prints.ShouldBeEmpty();
        File.Exists(Path.Combine(_dir, "voiceprints.sealed")).ShouldBeFalse();
    }
}
