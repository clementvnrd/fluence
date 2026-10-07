using Murmur.Abstractions;
using Murmur.Meeting;

namespace Murmur.Core.Meetings;

/// <summary>A call the detector noticed.</summary>
/// <param name="App">The meeting app or browser.</param>
/// <param name="Service">The service the window shows ("Google Meet"), for a browser; the app's own name otherwise.</param>
/// <param name="SessionProcessId">The process using the microphone.</param>
/// <param name="LoopbackProcessId">The root of the process tree to capture.</param>
/// <param name="ProcessName">The image name that matched.</param>
public sealed record DetectedMeeting(
    MeetingApp App,
    string Service,
    int SessionProcessId,
    int LoopbackProcessId,
    string ProcessName)
{
    /// <summary>The key detection episodes are tracked by.</summary>
    public string Key => App.Name;
}

/// <summary>
/// Notices calls: polled about once a second, it looks for known meeting apps holding an
/// active microphone session, and for browsers whose window title shows a call.
/// </summary>
/// <remarks>
/// <para>
/// <b>One offer per episode.</b> An app is offered once when it starts using the microphone,
/// and not again until it has released it for <see cref="ReleaseGrace"/> — which is also what
/// makes "Not now" stick for the rest of that call.
/// </para>
/// <para>
/// <b>Browsers need a title.</b> A browser on the microphone is a dictation site as often as a
/// call; it only counts when one of its visible windows shows a meeting
/// (<see cref="MeetingTitles.MeetingService"/>). Window titles carry the active tab's title, so
/// a call in a background tab is missed: reading the tab strip would need UI Automation, whose
/// managed wrapper drags the WindowsDesktop framework into the publish (see windows/README.md).
/// </para>
/// <para>Fluence's own capture sessions are ignored. Titles are never logged.</para>
/// </remarks>
public sealed class MeetingDetector
{
    /// <summary>How long an app must be off the microphone before the episode ends, seconds.</summary>
    public const double ReleaseGrace = 5;

    private readonly IMeetingSignals _signals;
    private readonly int _ownProcessId;
    private readonly IDiagnosticLog _log;
    private readonly Lock _sync = new();
    private readonly Dictionary<string, double> _lastSeen = new(StringComparer.Ordinal);
    private readonly HashSet<string> _episodes = new(StringComparer.Ordinal);

    /// <summary>Creates a detector.</summary>
    /// <param name="signals">The platform enumeration.</param>
    /// <param name="ownProcessId">Fluence's own process, whose sessions never count.</param>
    /// <param name="log">Where failures go. Never receives titles or names.</param>
    public MeetingDetector(IMeetingSignals signals, int ownProcessId, IDiagnosticLog? log = null)
    {
        _signals = signals;
        _ownProcessId = ownProcessId;
        _log = log ?? NullDiagnosticLog.Instance;
    }

    /// <summary>
    /// Looks once. Returns the calls that started since the last look (normally none).
    /// </summary>
    /// <param name="now">Seconds on any monotonic clock; only differences matter.</param>
    public IReadOnlyList<DetectedMeeting> Poll(double now)
    {
        List<DetectedMeeting> current;
        try
        {
            current = Current();
        }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException
                                      or UnauthorizedAccessException)
        {
            _log.Warning("meeting.detect_poll_failed", e);
            current = [];
        }

        var started = new List<DetectedMeeting>();
        lock (_sync)
        {
            foreach (var meeting in current)
            {
                _lastSeen[meeting.Key] = now;
                if (_episodes.Add(meeting.Key)) started.Add(meeting);
            }

            foreach (var key in _episodes.ToList())
            {
                if (now - _lastSeen.GetValueOrDefault(key, double.NegativeInfinity) > ReleaseGrace) _episodes.Remove(key);
            }
        }

        foreach (var meeting in started)
        {
            _log.Info("meeting.detected", new Dictionary<string, object?>
            {
                ["app"] = meeting.App.Name,
                ["browser"] = meeting.App.IsBrowser,
            });
        }

        return started;
    }

    /// <summary>Whether <paramref name="key"/>'s app was on the microphone within <see cref="ReleaseGrace"/> of <paramref name="now"/>.</summary>
    public bool IsOnMicrophone(string key, double now)
    {
        lock (_sync) return _lastSeen.TryGetValue(key, out var seen) && now - seen <= ReleaseGrace;
    }

    /// <summary>When <paramref name="key"/>'s app was last seen on the microphone, if ever.</summary>
    public double? LastSeenOnMicrophone(string key)
    {
        lock (_sync) return _lastSeen.TryGetValue(key, out var seen) ? seen : null;
    }

    private List<DetectedMeeting> Current()
    {
        var found = new List<DetectedMeeting>();
        IReadOnlyList<WindowInfo>? windows = null;

        foreach (var session in _signals.CaptureSessions())
        {
            if (!session.IsActive || session.ProcessId == _ownProcessId || session.ProcessId <= 0) continue;
            if (MeetingAppCatalog.Identify(session.ProcessName) is not { } app) continue;
            if (found.Any(f => f.Key == app.Name)) continue;

            var service = app.Name;
            if (app.IsBrowser)
            {
                windows ??= _signals.VisibleWindows();
                var call = windows
                    .Where(w => app.Matches(w.ProcessName))
                    .Select(w => MeetingTitles.MeetingService(w.Title))
                    .FirstOrDefault(s => s is not null);
                if (call is null) continue;
                service = call;
            }

            var processName = MeetingAppCatalog.Normalize(session.ProcessName);
            var root = MeetingAppCatalog.LoopbackRoot(
                session.ProcessId,
                [.. _signals.ProcessesNamed(processName).Select(p => (p.ProcessId, p.StartedAt))]);
            found.Add(new DetectedMeeting(app, service, session.ProcessId, root, processName));
        }

        return found;
    }
}
