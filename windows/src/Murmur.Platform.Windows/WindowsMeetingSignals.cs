using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Murmur.Abstractions;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Murmur.Platform.Windows;

/// <summary>
/// Enumerates what the meeting detector looks at: audio sessions on capture endpoints
/// (<c>IAudioSessionManager2</c> through NAudio), visible top-level windows
/// (<c>EnumWindows</c>), and processes by name. A binding: every decision is in
/// <c>Murmur.Core.Meetings.MeetingDetector</c>.
/// </summary>
/// <remarks>
/// Window titles come from <c>GetWindowText</c>, not UI Automation: the managed UI Automation
/// client lives in the WindowsDesktop framework, and referencing it would make the SDK treat
/// other dependencies as framework-provided — the trap NAudio's meta-package once set.
/// </remarks>
public sealed class WindowsMeetingSignals : IMeetingSignals
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", EntryPoint = "GetWindowTextLengthW")]
    private static extern int GetWindowTextLength(IntPtr window);

    [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, [Out] char[] text, int maxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    /// <inheritdoc />
    public IReadOnlyList<AudioSessionInfo> CaptureSessions()
    {
        var result = new List<AudioSessionInfo>();
        var names = new Dictionary<int, string>();
        using var enumerator = new MMDeviceEnumerator();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            using (device)
            {
                var manager = device.AudioSessionManager;
                manager.RefreshSessions();
                var sessions = manager.Sessions;
                for (var index = 0; index < sessions.Count; index++)
                {
                    using var session = sessions[index];
                    var processId = (int)session.GetProcessID;
                    result.Add(new AudioSessionInfo(
                        processId, NameOf(processId, names), session.State == AudioSessionState.AudioSessionStateActive));
                }
            }
        }

        return result;
    }

    /// <inheritdoc />
    public IReadOnlyList<WindowInfo> VisibleWindows()
    {
        var result = new List<WindowInfo>();
        var names = new Dictionary<int, string>();
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window)) return true;
            var length = GetWindowTextLength(window);
            if (length <= 0) return true;

            var buffer = new char[length + 1];
            var copied = GetWindowText(window, buffer, buffer.Length);
            if (GetWindowThreadProcessId(window, out var processId) == 0) return true;   // window already gone
            result.Add(new WindowInfo((int)processId, NameOf((int)processId, names), new string(buffer, 0, Math.Max(0, copied))));
            return true;
        }, IntPtr.Zero);
        return result;
    }

    /// <inheritdoc />
    public IReadOnlyList<ProcessStart> ProcessesNamed(string processName)
    {
        var result = new List<ProcessStart>();
        foreach (var process in Process.GetProcessesByName(processName))
        {
            using (process)
            {
                DateTimeOffset? started = null;
                try { started = process.StartTime; }
                catch (Exception e) when (e is Win32Exception or InvalidOperationException) { /* exited, or not ours to read */ }
                result.Add(new ProcessStart(process.Id, started));
            }
        }

        return result;
    }

    private static string NameOf(int processId, Dictionary<int, string> cache)
    {
        if (cache.TryGetValue(processId, out var cached)) return cached;
        string name;
        try
        {
            using var process = Process.GetProcessById(processId);
            name = process.ProcessName;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception)
        {
            name = string.Empty;   // exited between enumeration and lookup
        }

        cache[processId] = name;
        return name;
    }
}
