using Avalonia.Headless.XUnit;
using Murmur.Abstractions;
using Murmur.App.Design;
using Murmur.App.Views;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Meeting;
using Murmur.Testing;
using Shouldly;

namespace Murmur.AppTests;

/// <summary>The Notetaker's panel, Meetings view and settings, headless.</summary>
public sealed class MeetingUiTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fluence-ui-meetings-{Guid.NewGuid():N}");
    private readonly MeetingVault _vault;
    private readonly MeetingStore _store;
    private readonly FakeMeetingSignals _signals = new();
    private readonly FakeHostClock _host = new() { Now = 500 * 10_000_000L };

    public MeetingUiTests()
    {
        _vault = MeetingVault.Open(_dir, new FakeSecretProtector(), new FakeClock(), NullDiagnosticLog.Instance, out _)!;
        _store = new MeetingStore(_dir, _vault, null);
    }

    public void Dispose()
    {
        _vault.Dispose();
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private MeetingController Controller() => new(new MeetingServices
    {
        Store = _store,
        Detector = new MeetingDetector(_signals, 1),
        CreateMicrophone = () => FakeAudioCapture.Silence(1),
        Transcriber = new FakeTimedTranscriber(_ => "hi"),
        CreateVoiceActivity = () => new EnergyVoiceActivity(),
        Correct = t => t,
        Options = () => new MeetingOptions { CountdownSeconds = 10 },
        HostClock = _host,
        Clock = new FakeClock(),
        Log = NullDiagnosticLog.Instance,
    });

    private MeetingRecord Saved(string title, int day, params (string Speaker, double Start, string Text)[] lines)
    {
        var meeting = new MeetingRecord
        {
            Title = title,
            StartedAt = DateTimeOffset.UnixEpoch.AddDays(20_000 + day),
            EndedAt = DateTimeOffset.UnixEpoch.AddDays(20_000 + day).AddMinutes(30),
            Speakers = [Speaker.Me(), new Speaker("S1")],
            Segments = [.. lines.Select(l => new TranscriptSegment
            {
                Source = l.Speaker == "me" ? AudioSource.Microphone : AudioSource.System,
                SpeakerId = l.Speaker,
                Start = l.Start,
                End = l.Start + 1,
                Text = l.Text,
            })],
        };
        _store.Save(meeting);
        return meeting;
    }

    [AvaloniaFact]
    public async Task The_card_counts_down_with_the_lamp_dark_and_recording_lights_it()
    {
        _signals.Sessions.Add(new AudioSessionInfo(77, "ms-teams.exe", true));
        await using var controller = Controller();
        var window = new MeetingPanelWindow(controller);
        var panel = window.Panel;

        _host.Advance(1);
        await controller.TickAsync();
        window.Sync();
        window.IsVisible.ShouldBeTrue();
        panel.Headline.ShouldBe("MICROSOFT TEAMS CALL DETECTED");
        panel.Detail.ShouldNotBeNull().ShouldContain("10 s");
        panel.VisibleKeys.ShouldBe(["RECORD", "NOT NOW", "CONSENT FR", "CONSENT EN"]);
        panel.RecordLamp.IsLit.ShouldBeFalse("red means recording, and the card is not recording yet");

        await controller.AcceptAsync();
        panel.Refresh();
        panel.Headline.ShouldBe("TAKING NOTES");
        panel.RecordLamp.IsLit.ShouldBeTrue();
        panel.RecordLamp.LampColor.ShouldBe(Tokens.Colors.Record);
        panel.VisibleKeys.ShouldBe(["STOP", "CONSENT FR", "CONSENT EN"]);
        panel.ShowsKeepAudio.ShouldBeTrue();

        // Closing the window while recording leaves it on screen.
        window.Close();
        window.IsVisible.ShouldBeTrue();

        await controller.StopAsync(StopReason.User);
        window.Sync();
        panel.HasContent.ShouldBeFalse();
        window.IsVisible.ShouldBeFalse();
    }

    [AvaloniaFact]
    public async Task Meetings_list_newest_first_and_rename_updates_every_line()
    {
        Saved("Older", 1, ("me", 0, "Bonjour."));
        var newest = Saved("Weekly sync", 2, ("me", 1, "Hi."), ("S1", 3, "Hello from the call."), ("S1", 9, "Bye."));

        var view = new MeetingsView(_store);
        view.ListedTitles.ShouldBe(["Weekly sync", "Older"]);
        view.Selected!.Id.ShouldBe(newest.Id);
        view.ShownTranscript.ShouldBe(["[00:01] You: Hi.", "[00:03] Speaker 1: Hello from the call.", "[00:09] Speaker 1: Bye."]);

        view.Rename("S1", "Marie");
        view.ShownTranscript.ShouldBe(["[00:01] You: Hi.", "[00:03] Marie: Hello from the call.", "[00:09] Marie: Bye."]);
        _store.Load(newest.Id)!.SpeakerById("S1")!.NameSource.ShouldBe(NameSource.User);
        view.SelectedMarkdown.ShouldNotBeNull().ShouldContain("**[00:03] Marie:** Hello from the call.");
        view.SelectedMarkdown.ShouldContain("_No notes were generated for this meeting._");

        await view.SearchAsync();
        view.ListedTitles.Count.ShouldBe(2);
    }

    [AvaloniaFact]
    public void Without_a_store_the_view_says_why()
    {
        var view = new MeetingsView(null, "Meetings cannot be recorded: no secure key storage is available on this system.");
        view.Problem.ShouldNotBeNull().ShouldContain("secure key storage");
        view.ListedTitles.ShouldBeEmpty();
    }

    [AvaloniaFact]
    public void Notetaker_settings_save_and_voice_prints_start_off()
    {
        var path = Path.Combine(_dir, "settings.json");
        var settings = new AppSettings(path);
        settings.Data.NotetakerVoicePrints.ShouldBeFalse();
        settings.Data.NotetakerDetectMeetings.ShouldBeTrue();

        var window = new SettingsWindow(settings, meetings: _store);
        window.Show();
        window.SelectCountdown(30);
        window.SelectMeetingRetention(RetentionChoice.Quarter);

        var reloaded = new AppSettings(path).Data;
        reloaded.NotetakerCountdownSeconds.ShouldBe(30);
        reloaded.NotetakerRetentionDays.ShouldBe(90);
    }
}
