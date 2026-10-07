namespace Murmur.Meeting;

/// <summary>An app that holds calls, identified on Windows by its process image name.</summary>
/// <param name="Name">What the UI says: "Zoom", "Google Chrome"…</param>
/// <param name="ProcessNames">Image names without <c>.exe</c>, compared case-insensitively.</param>
/// <param name="IsBrowser">A browser is only a meeting when one of its windows shows a call.</param>
public sealed record MeetingApp(string Name, IReadOnlyList<string> ProcessNames, bool IsBrowser)
{
    /// <summary>Whether <paramref name="processName"/> (with or without <c>.exe</c>) is one of this app's processes.</summary>
    public bool Matches(string processName)
    {
        var name = MeetingAppCatalog.Normalize(processName);
        return ProcessNames.Any(p => string.Equals(p, name, StringComparison.OrdinalIgnoreCase));
    }
}

/// <summary>
/// The Windows counterpart of the macOS bundle-ID catalogue (<c>MeetingApps.swift</c>): which
/// processes using the microphone mean a call.
/// </summary>
/// <remarks>
/// Process names are the documented or commonly observed image names; the ones marked below
/// have not been confirmed on a real machine (no Windows hardware yet). A miss only means no
/// "Meeting detected" card — recording by hand still works.
/// </remarks>
public static class MeetingAppCatalog
{
    /// <summary>Dedicated meeting apps.</summary>
    public static IReadOnlyList<MeetingApp> Native { get; } =
    [
        // New Teams (2023+) is ms-teams.exe; classic Teams was Teams.exe.
        new("Microsoft Teams", ["ms-teams", "Teams", "ms-teams_modulehost"], false),
        new("Zoom", ["Zoom"], false),
        // Webex App and the older Meetings client. Unconfirmed: which of these owns the audio session.
        new("Webex", ["CiscoCollabHost", "Webex", "webexmta", "atmgr"], false),
        new("Slack", ["slack"], false),
        new("Discord", ["Discord"], false),
        new("GoTo Meeting", ["GoTo", "g2mcomm"], false),
    ];

    /// <summary>Browsers, which only count when a window title shows a call.</summary>
    public static IReadOnlyList<MeetingApp> Browsers { get; } =
    [
        new("Google Chrome", ["chrome"], true),
        new("Microsoft Edge", ["msedge"], true),
        new("Firefox", ["firefox"], true),
        new("Brave", ["brave"], true),
        new("Arc", ["Arc"], true),
        new("Opera", ["opera"], true),
        new("Vivaldi", ["vivaldi"], true),
    ];

    /// <summary>The meeting app or browser <paramref name="processName"/> belongs to, if any.</summary>
    public static MeetingApp? Identify(string processName)
    {
        ArgumentNullException.ThrowIfNull(processName);
        return Native.FirstOrDefault(a => a.Matches(processName)) ?? Browsers.FirstOrDefault(a => a.Matches(processName));
    }

    /// <summary>An image name without directory or <c>.exe</c>.</summary>
    public static string Normalize(string processName)
    {
        ArgumentNullException.ThrowIfNull(processName);
        // Both separators, whatever the OS running this: the names are Windows paths.
        var trimmed = processName.Trim();
        var name = trimmed[(trimmed.LastIndexOfAny(['\\', '/']) + 1)..];
        return name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name;
    }

    /// <summary>
    /// The process to capture for a call heard in <paramref name="sessionProcessId"/>: the
    /// earliest-started process with the same image name. Browsers render audio in a child
    /// process of their main one, and process loopback captures the whole tree under the
    /// process it is given, so the root is the one to name.
    /// </summary>
    /// <param name="sessionProcessId">The process that owns the capture session.</param>
    /// <param name="sameName">Every running process with the same image name, with its start time when readable.</param>
    public static int LoopbackRoot(int sessionProcessId, IReadOnlyList<(int ProcessId, DateTimeOffset? StartedAt)> sameName)
    {
        ArgumentNullException.ThrowIfNull(sameName);
        var earliest = sameName
            .Where(p => p.StartedAt is not null)
            .OrderBy(p => p.StartedAt)
            .ThenBy(p => p.ProcessId)
            .Select(p => (int?)p.ProcessId)
            .FirstOrDefault();
        return earliest ?? sessionProcessId;
    }
}
