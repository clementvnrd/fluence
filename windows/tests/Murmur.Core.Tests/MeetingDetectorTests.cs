using Murmur.Abstractions;
using Murmur.Core.Meetings;
using Murmur.Meeting;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>Which processes on the microphone mean a call, and when to offer the card.</summary>
public sealed class MeetingDetectorTests
{
    private const int Own = 999;

    [Fact]
    public void Native_meeting_apps_are_recognised_by_image_name()
    {
        MeetingAppCatalog.Identify("ms-teams.exe")!.Name.ShouldBe("Microsoft Teams");
        MeetingAppCatalog.Identify("Teams")!.Name.ShouldBe("Microsoft Teams");
        MeetingAppCatalog.Identify("ZOOM.EXE")!.Name.ShouldBe("Zoom");
        MeetingAppCatalog.Identify(@"C:\Users\a\AppData\Local\Discord\app-1\Discord.exe")!.Name.ShouldBe("Discord");
        MeetingAppCatalog.Identify("chrome")!.IsBrowser.ShouldBeTrue();
        MeetingAppCatalog.Identify("msedge.exe")!.Name.ShouldBe("Microsoft Edge");
        MeetingAppCatalog.Identify("Spotify").ShouldBeNull();
        MeetingAppCatalog.Identify("chromedriver").ShouldBeNull();
    }

    [Fact]
    public void The_loopback_target_is_the_earliest_started_process_of_the_family()
    {
        var t0 = new DateTimeOffset(2026, 10, 7, 9, 0, 0, TimeSpan.Zero);
        MeetingAppCatalog.LoopbackRoot(30, [(30, t0.AddMinutes(5)), (10, t0), (20, t0.AddMinutes(1))]).ShouldBe(10);
        MeetingAppCatalog.LoopbackRoot(30, [(30, null)]).ShouldBe(30);
        MeetingAppCatalog.LoopbackRoot(30, []).ShouldBe(30);
    }

    [Fact]
    public void A_meeting_app_on_the_microphone_is_offered_once_per_call()
    {
        var signals = new FakeMeetingSignals();
        signals.Sessions.Add(new AudioSessionInfo(4242, "Zoom", true));
        var detector = new MeetingDetector(signals, Own);

        var first = detector.Poll(0).ShouldHaveSingleItem();
        first.App.Name.ShouldBe("Zoom");
        first.LoopbackProcessId.ShouldBe(4242);
        detector.Poll(1).ShouldBeEmpty();
        detector.IsOnMicrophone("Zoom", 1).ShouldBeTrue();

        // A short blip off the microphone is the same call…
        signals.Sessions.Clear();
        detector.Poll(3).ShouldBeEmpty();
        signals.Sessions.Add(new AudioSessionInfo(4242, "Zoom", true));
        detector.Poll(4).ShouldBeEmpty();

        // …but after the grace period the next use is a new call.
        signals.Sessions.Clear();
        detector.Poll(10).ShouldBeEmpty();
        detector.IsOnMicrophone("Zoom", 10).ShouldBeFalse();
        detector.LastSeenOnMicrophone("Zoom").ShouldBe(4);
        signals.Sessions.Add(new AudioSessionInfo(4242, "Zoom", true));
        detector.Poll(11).ShouldHaveSingleItem();
    }

    [Fact]
    public void Inactive_sessions_unknown_apps_and_Fluence_itself_are_ignored()
    {
        var signals = new FakeMeetingSignals();
        signals.Sessions.Add(new AudioSessionInfo(1, "Zoom", false));
        signals.Sessions.Add(new AudioSessionInfo(2, "obs64", true));
        signals.Sessions.Add(new AudioSessionInfo(Own, "Fluence", true));
        new MeetingDetector(signals, Own).Poll(0).ShouldBeEmpty();
    }

    [Fact]
    public void A_browser_counts_only_when_one_of_its_windows_shows_a_call()
    {
        var signals = new FakeMeetingSignals();
        signals.Sessions.Add(new AudioSessionInfo(5150, "chrome", true));
        signals.Windows.Add(new WindowInfo(5000, "chrome", "Inbox (3) - Gmail - Google Chrome"));
        signals.Windows.Add(new WindowInfo(6000, "msedge", "Meet – abc-defg-hij - Microsoft Edge"));
        var detector = new MeetingDetector(signals, Own);

        detector.Poll(0).ShouldBeEmpty();   // the Meet window belongs to another browser

        var t0 = new DateTimeOffset(2026, 10, 7, 9, 0, 0, TimeSpan.Zero);
        signals.Processes["chrome"] = [new(5150, t0.AddSeconds(30)), new(5000, t0)];
        signals.Windows.Add(new WindowInfo(5000, "chrome", "Meet – abc-defg-hij - Google Chrome"));
        var detected = detector.Poll(1).ShouldHaveSingleItem();
        detected.Service.ShouldBe("Google Meet");
        detected.SessionProcessId.ShouldBe(5150);
        detected.LoopbackProcessId.ShouldBe(5000);   // the browser's main process: its tree holds the audio
    }

    [Fact]
    public void A_failing_enumeration_is_logged_and_detects_nothing()
    {
        var signals = new FakeMeetingSignals { Failure = new InvalidOperationException("no audio service") };
        var log = new RecordingDiagnosticLog();
        new MeetingDetector(signals, Own, log).Poll(0).ShouldBeEmpty();
        log.Events.ShouldContain(e => e.Name == "meeting.detect_poll_failed");
    }

    [Fact]
    public void Window_titles_never_reach_the_log()
    {
        var signals = new FakeMeetingSignals();
        signals.Sessions.Add(new AudioSessionInfo(1, "msedge", true));
        signals.Windows.Add(new WindowInfo(1, "msedge", "Salary review with Ada | Microsoft Teams - Microsoft Edge"));
        var log = new RecordingDiagnosticLog();
        new MeetingDetector(signals, Own, log).Poll(0).ShouldHaveSingleItem();

        var logged = log.Events.SelectMany(e => e.Fields?.Values ?? []).OfType<string>().ToList();
        logged.ShouldNotBeEmpty();
        logged.ShouldAllBe(v => !v.Contains("Ada", StringComparison.Ordinal) && !v.Contains("Salary", StringComparison.Ordinal));
    }
}
