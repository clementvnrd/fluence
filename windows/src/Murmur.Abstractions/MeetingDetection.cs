namespace Murmur.Abstractions;

/// <summary>One audio session on a capture (microphone) endpoint.</summary>
/// <param name="ProcessId">The process that owns it.</param>
/// <param name="ProcessName">Its image name without <c>.exe</c>; empty when unreadable.</param>
/// <param name="IsActive">Whether it is capturing right now (<c>AudioSessionStateActive</c>).</param>
public readonly record struct AudioSessionInfo(int ProcessId, string ProcessName, bool IsActive);

/// <summary>One visible top-level window.</summary>
/// <param name="ProcessId">The process that owns it.</param>
/// <param name="ProcessName">Its image name without <c>.exe</c>; empty when unreadable.</param>
/// <param name="Title">The window title. Personal data: never logged.</param>
public readonly record struct WindowInfo(int ProcessId, string ProcessName, string Title);

/// <summary>A running process.</summary>
/// <param name="ProcessId">Its id.</param>
/// <param name="StartedAt">When it started, when readable.</param>
public readonly record struct ProcessStart(int ProcessId, DateTimeOffset? StartedAt);

/// <summary>
/// What the meeting detector polls: which processes use the microphone, and what windows say.
/// Enumeration only — every decision is in <c>Murmur.Core.Meetings.MeetingDetector</c>.
/// </summary>
public interface IMeetingSignals
{
    /// <summary>Every session on every active capture endpoint (<c>IAudioSessionManager2</c>).</summary>
    IReadOnlyList<AudioSessionInfo> CaptureSessions();

    /// <summary>Every visible top-level window with a title.</summary>
    IReadOnlyList<WindowInfo> VisibleWindows();

    /// <summary>Every running process with this image name (without <c>.exe</c>).</summary>
    IReadOnlyList<ProcessStart> ProcessesNamed(string processName);
}
