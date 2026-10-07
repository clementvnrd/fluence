using System.Runtime.InteropServices;
using Microsoft.Win32;
using Murmur.Abstractions;

namespace Murmur.Platform.Windows;

/// <summary>
/// Reports the workstation locking or switching, and whether the normal desktop has input.
/// </summary>
/// <remarks>
/// <para>
/// Two signals, because neither covers everything. <see cref="SystemEvents.SessionSwitch"/>
/// (which runs <c>WTSRegisterSessionNotification</c> on a hidden window for us) reports
/// lock, log-off and remote/console disconnects. It says nothing about the <b>secure
/// desktop</b> — the UAC prompt and the Ctrl+Alt+Del screen — which also takes the keyboard
/// away mid-gesture. For that the engine polls <see cref="IsInputDesktopActive"/>: an ordinary
/// process cannot open the secure or Winlogon desktop, so failing to open the input desktop,
/// or finding it is not <c>Default</c>, means the user is not at their desktop.
/// </para>
/// <para>
/// A binding only. What to do about it (cancel, and say why) is decided in
/// <c>DictationEngine</c>.
/// </para>
/// </remarks>
public sealed class WindowsSessionMonitor : ISessionMonitor
{
    private const uint DESKTOP_READOBJECTS = 0x0001;
    private const int UOI_NAME = 2;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseDesktop(IntPtr desktop);

    [DllImport("user32.dll", EntryPoint = "GetUserObjectInformationW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserObjectInformation(IntPtr handle, int index, [Out] char[] info, uint length, out uint needed);

    private bool _started;

    /// <inheritdoc />
    public event EventHandler? Interrupted;

    /// <inheritdoc />
    public bool IsInputDesktopActive
    {
        get
        {
            var desktop = OpenInputDesktop(0, false, DESKTOP_READOBJECTS);
            if (desktop == IntPtr.Zero) return false;

            try
            {
                var name = new char[64];
                if (!GetUserObjectInformation(desktop, UOI_NAME, name, (uint)(name.Length * sizeof(char)), out _))
                {
                    return true;   // opened it, so it is ours; the name is a refinement
                }

                return string.Equals(new string(name).TrimEnd('\0'), "Default", StringComparison.OrdinalIgnoreCase);
            }
            finally
            {
                CloseDesktop(desktop);
            }
        }
    }

    /// <inheritdoc />
    public void Start()
    {
        if (_started) return;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        _started = true;
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock
            or SessionSwitchReason.SessionLogoff
            or SessionSwitchReason.ConsoleDisconnect
            or SessionSwitchReason.RemoteDisconnect)
        {
            Interrupted?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (!_started) return;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        _started = false;
    }
}
