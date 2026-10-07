namespace Murmur.Core;

/// <summary>What to do with the clipboard once a paste has gone through.</summary>
public enum ClipboardRestore
{
    /// <summary>Put the user's previous text back.</summary>
    RestorePrevious,

    /// <summary>The clipboard held no text before (empty, or an image): empty it rather than leave the dictation on it.</summary>
    Clear,

    /// <summary>Something else replaced the dictation meanwhile — the user copied something. Leave it.</summary>
    LeaveAlone,
}

/// <summary>
/// Keeps dictated text out of clipboard history, cloud sync and clipboard managers.
/// </summary>
/// <remarks>
/// <para>
/// Windows reads three registered clipboard formats alongside the data
/// (<see href="https://learn.microsoft.com/windows/win32/dataxchg/clipboard-formats#cloud-clipboard-and-clipboard-history-formats">docs</see>):
/// </para>
/// <list type="bullet">
/// <item><c>ExcludeClipboardContentFromMonitorProcessing</c> — present at all: clipboard
/// monitors and managers should ignore this content.</item>
/// <item><c>CanIncludeInClipboardHistory</c> — DWORD 0: keep it out of Win+V history.</item>
/// <item><c>CanUploadToCloudClipboard</c> — DWORD 0: never sync it to the user's other devices.</item>
/// </list>
/// <para>
/// A paste performed on the user's behalf is transient — it exists for 500 ms so Ctrl+V can
/// read it — so it gets all three. An explicit COPY from the history is the user's own action
/// and may reasonably appear in Win+V, so it only opts out of cloud upload: a dictation is
/// never sent off the machine.
/// </para>
/// </remarks>
public static class ClipboardPrivacy
{
    /// <summary>Tells clipboard monitors to ignore the content.</summary>
    public const string ExcludeFromMonitoring = "ExcludeClipboardContentFromMonitorProcessing";

    /// <summary>DWORD; 0 keeps the content out of Win+V history.</summary>
    public const string CanIncludeInHistory = "CanIncludeInClipboardHistory";

    /// <summary>DWORD; 0 stops Cloud Clipboard syncing it.</summary>
    public const string CanUploadToCloud = "CanUploadToCloudClipboard";

    private static byte[] DwordZero => [0, 0, 0, 0];

    /// <summary>Formats for text pasted on the user's behalf and removed again.</summary>
    public static IReadOnlyList<(string Format, byte[] Data)> ForTransientPaste() =>
    [
        (ExcludeFromMonitoring, DwordZero),
        (CanIncludeInHistory, DwordZero),
        (CanUploadToCloud, DwordZero),
    ];

    /// <summary>Formats for an explicit copy by the user.</summary>
    public static IReadOnlyList<(string Format, byte[] Data)> ForUserCopy() =>
    [
        (CanUploadToCloud, DwordZero),
    ];

    /// <summary>
    /// Decides how to leave the clipboard after pasting <paramref name="injected"/>.
    /// </summary>
    /// <param name="previous">The clipboard's text before the paste; null if it held no text.</param>
    /// <param name="current">The clipboard's text now.</param>
    /// <param name="injected">What was pasted.</param>
    /// <remarks>
    /// The check on <paramref name="current"/> matters: if the user copied something during
    /// the paste window, restoring blindly would overwrite it — or worse, paste the
    /// <i>previous</i> clipboard (a password, say) on their next Ctrl+V.
    /// </remarks>
    public static ClipboardRestore AfterPaste(string? previous, string? current, string injected)
    {
        if (!string.Equals(current, injected, StringComparison.Ordinal)) return ClipboardRestore.LeaveAlone;
        return previous is null ? ClipboardRestore.Clear : ClipboardRestore.RestorePrevious;
    }
}
