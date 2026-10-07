using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Meeting;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>The encrypted meeting store and audio spool.</summary>
public sealed class MeetingStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fluence-meetings-{Guid.NewGuid():N}");
    private readonly MeetingVault _vault;
    private bool _prints;

    public MeetingStoreTests()
    {
        _vault = MeetingVault.Open(_dir, new FakeSecretProtector(), new FakeClock(), NullDiagnosticLog.Instance, out _)!;
    }

    public void Dispose()
    {
        _vault.Dispose();
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private VoicePrintStore Prints() => new(_dir, _vault, () => _prints);

    private MeetingStore Store(VoicePrintStore? prints = null) => new(_dir, _vault, prints);

    private static MeetingRecord Meeting(string title, DateTimeOffset at, string text = "On parle du café crème.") => new()
    {
        Title = title,
        StartedAt = at,
        EndedAt = at.AddMinutes(30),
        Speakers = [Speaker.Me(), new Speaker("S1")],
        Segments = [new TranscriptSegment { Source = AudioSource.System, SpeakerId = "S1", Start = 1, End = 2, Text = text }],
    };

    [Fact]
    public void A_meeting_round_trips_sealed_and_survives_a_restart()
    {
        var store = Store();
        var meeting = Meeting("Weekly sync", DateTimeOffset.UnixEpoch.AddDays(20_000));
        store.Save(meeting).ShouldBeTrue();

        var folder = store.DirectoryFor(meeting.Id);
        File.ReadAllText(Path.Combine(folder, "meeting.sealed")).ShouldNotContain("café");
        File.ReadAllText(Path.Combine(_dir, "index.sealed")).ShouldNotContain("Weekly");

        var reopened = Store();
        reopened.Summaries.ShouldHaveSingleItem().Title.ShouldBe("Weekly sync");
        reopened.Load(meeting.Id).ShouldNotBeNull().Segments.Single().Text.ShouldBe("On parle du café crème.");
    }

    [Fact]
    public void A_lost_index_is_rebuilt_from_the_meetings()
    {
        var store = Store();
        store.Save(Meeting("A", DateTimeOffset.UnixEpoch.AddDays(1)));
        store.Save(Meeting("B", DateTimeOffset.UnixEpoch.AddDays(2)));
        File.Delete(Path.Combine(_dir, "index.sealed"));
        Store().Summaries.Select(s => s.Title).ShouldBe(["B", "A"]);
    }

    [Fact]
    public void Search_ignores_case_and_accents_and_reads_transcripts()
    {
        var store = Store();
        store.Save(Meeting("Point client", DateTimeOffset.UnixEpoch.AddDays(1)));
        store.Save(Meeting("Other", DateTimeOffset.UnixEpoch.AddDays(2), "Nothing here."));

        store.Search("CAFE").Select(s => s.Title).ShouldBe(["Point client"]);
        store.Search("point").Select(s => s.Title).ShouldBe(["Point client"]);
        store.Search("speaker 1").Count.ShouldBe(2);
        store.Search("  ").Count.ShouldBe(2);
        store.Search("absent").ShouldBeEmpty();
    }

    [Fact]
    public void Delete_removes_the_key_with_the_meeting()
    {
        var store = Store();
        var meeting = Meeting("A", DateTimeOffset.UnixEpoch);
        store.Save(meeting);
        store.Delete(meeting.Id);
        Directory.Exists(store.DirectoryFor(meeting.Id)).ShouldBeFalse();
        store.Summaries.ShouldBeEmpty();
        store.Load(meeting.Id).ShouldBeNull();
    }

    [Fact]
    public void Retention_purges_old_meetings_only()
    {
        var store = Store();
        var now = DateTimeOffset.UnixEpoch.AddDays(1000);
        store.Save(Meeting("old", now.AddDays(-40)));
        store.Save(Meeting("recent", now.AddDays(-3)));
        store.Purge(null, now).ShouldBe(0);
        store.Purge(30, now).ShouldBe(1);
        store.Summaries.Select(s => s.Title).ShouldBe(["recent"]);
    }

    [Fact]
    public void Delete_all_also_deletes_voice_prints()
    {
        _prints = true;
        var prints = Prints();
        var store = Store(prints);
        var meeting = Meeting("A", DateTimeOffset.UnixEpoch);
        store.Save(meeting);
        prints.SaveCandidates(meeting.Id, new Dictionary<string, float[]> { ["S1"] = [1, 0] });
        store.RenameSpeaker(meeting.Id, "S1", "Marie").ShouldNotBeNull();
        prints.Prints.ShouldHaveSingleItem().Name.ShouldBe("Marie");

        store.DeleteAll();
        store.Summaries.ShouldBeEmpty();
        prints.Prints.ShouldBeEmpty();
        File.Exists(MeetingVault.KeyPath(_dir)).ShouldBeTrue();
    }

    [Fact]
    public void Renaming_saves_everywhere_but_enrols_nothing_while_voice_prints_are_off()
    {
        var prints = Prints();
        var store = Store(prints);
        var meeting = Meeting("A", DateTimeOffset.UnixEpoch);
        store.Save(meeting);
        prints.SaveCandidates(meeting.Id, new Dictionary<string, float[]> { ["S1"] = [1, 0] });

        store.RenameSpeaker(meeting.Id, "S1", "Marie");
        store.Load(meeting.Id)!.SpeakerById("S1")!.Name.ShouldBe("Marie");
        store.Summaries.Single().SpeakerNames.ShouldContain("Marie");
        File.Exists(Path.Combine(_dir, "voiceprints.sealed")).ShouldBeFalse();
    }

    [Fact]
    public void Interrupted_recordings_are_found_by_their_marker()
    {
        var store = Store();
        var meeting = Meeting("A", DateTimeOffset.UnixEpoch);
        store.Save(meeting);
        store.Interrupted().ShouldBeEmpty();
        File.WriteAllBytes(store.MarkerPath(meeting.Id), []);
        store.Interrupted().ShouldBe([meeting.Id]);
    }

    [Fact]
    public void The_spool_round_trips_across_records_and_a_partial_tail()
    {
        var store = Store();
        var id = Guid.NewGuid();
        using var key = store.OpenKey(id, create: true)!;
        var path = MeetingAudioSpool.PathFor(store.DirectoryFor(id), AudioSource.System);
        var samples = Enumerable.Range(0, 40_000).Select(i => MathF.Sin(i / 10f) * 0.5f).ToArray();
        using (var spool = new MeetingAudioSpool(path, key, id, AudioSource.System))
        {
            spool.Append(samples.AsSpan(0, 12_345));
            spool.Append(samples.AsSpan(12_345));
        }

        File.ReadAllBytes(path).Length.ShouldBeLessThan(40_000 * 2 + 200);
        using var reader = MeetingAudioSpoolReader.Open(path, key, id, AudioSource.System)!;
        reader.SampleCount.ShouldBe(40_000);
        var back = new float[40_010];
        reader.Read(0, back).ShouldBe(40_000);
        for (var i = 0; i < 40_000; i += 997) back[i].ShouldBe(samples[i], 1e-4f);

        var middle = new float[100];
        reader.Read(15_950, middle).ShouldBe(100);
        middle[60].ShouldBe(samples[16_010], 1e-4f);
    }

    [Fact]
    public void A_spool_is_bound_to_its_meeting_and_channel()
    {
        var store = Store();
        var id = Guid.NewGuid();
        using var key = store.OpenKey(id, create: true)!;
        var path = MeetingAudioSpool.PathFor(store.DirectoryFor(id), AudioSource.Microphone);
        using (var spool = new MeetingAudioSpool(path, key, id, AudioSource.Microphone)) spool.Append([0.5f, 0.5f]);

        using var wrongChannel = MeetingAudioSpoolReader.Open(path, key, id, AudioSource.System)!;
        var back = new float[2];
        wrongChannel.Read(0, back);
        back.ShouldBe([0f, 0f]);

        using var right = MeetingAudioSpoolReader.Open(path, key, id, AudioSource.Microphone)!;
        right.Read(0, back);
        back[0].ShouldBe(0.5f, 1e-4f);
    }
}
