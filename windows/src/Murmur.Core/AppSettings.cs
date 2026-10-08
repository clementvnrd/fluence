using System.Text.Json;
using System.Text.Json.Serialization;

namespace Murmur.Core;

/// <summary>User preferences.</summary>
public sealed record SettingsData
{
    /// <summary>
    /// Virtual-key code of the push-to-talk key. Defaults to Right Ctrl (0xA3).
    /// </summary>
    /// <remarks>
    /// <b>Not Right Alt.</b> On German, Polish, UK, Nordic and most Latin-American layouts
    /// Right Alt is AltGr — it is how those users type <c>@</c>, <c>€</c>, <c>\</c> and
    /// <c>|</c>. Right Ctrl produces no character on any layout.
    /// </remarks>
    public int PushToTalkKey { get; init; } = 0xA3;

    /// <summary>Where the speech model lives, or null to search the default locations.</summary>
    public string? ModelDirectory { get; init; }

    /// <summary>
    /// Whether to type the transcript into the focused app. When false, dictations go to the
    /// history only.
    /// </summary>
    public bool InjectText { get; init; } = true;

    /// <summary>
    /// Recording stops on its own after this many minutes (1–60), in case the key's release
    /// is lost. Not shown in the UI; edit settings.json to change it.
    /// </summary>
    public int MaxRecordingMinutes { get; init; } = 10;

    /// <summary>How long dictations stay in the (sealed) history. Defaults to 30 days.</summary>
    public HistoryRetention HistoryRetention { get; init; } = HistoryRetention.ThirtyDays;

    /// <summary>Notetaker: offer to record when a call starts. On by default, as on macOS.</summary>
    public bool NotetakerDetectMeetings { get; init; } = true;

    /// <summary>
    /// Notetaker, "record without a click": seconds on the "call detected" card before recording
    /// starts by itself; 0, the default, waits for a click (FLU-34). Replaces
    /// <c>NotetakerCountdownSeconds</c> (10 s by default), which is not carried over.
    /// </summary>
    public int NotetakerAutoRecordSeconds { get; init; }

    /// <summary>Notetaker: the "keep audio" checkbox's starting value. Off: audio is deleted after processing.</summary>
    public bool NotetakerKeepAudioByDefault { get; init; }

    /// <summary>
    /// Notetaker: opt-in voice prints (biometric data). Off by default; turning it off deletes
    /// every print.
    /// </summary>
    public bool NotetakerVoicePrints { get; init; }

    /// <summary>Notetaker: days meetings are kept; null keeps them until deleted.</summary>
    public int? NotetakerRetentionDays { get; init; }

    /// <summary>Notetaker: a recording stops by itself after this many minutes.</summary>
    public int NotetakerMaxMinutes { get; init; } = 180;

    /// <summary>
    /// The pre-retention on/off switch. Read once from old settings files so "off" becomes
    /// <see cref="HistoryRetention.Never"/>, and never written again.
    /// </summary>
    [JsonPropertyName("KeepHistory")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? LegacyKeepHistory { get; init; }

    /// <summary>Folds legacy fields into their replacements.</summary>
    public SettingsData Normalize() => LegacyKeepHistory switch
    {
        false => this with { HistoryRetention = HistoryRetention.Never, LegacyKeepHistory = null },
        true => this with { LegacyKeepHistory = null },
        null => this,
    };
}

/// <summary>Settings, persisted as JSON.</summary>
public sealed class AppSettings
{
    private readonly string _path;

    /// <summary>Loads settings from <paramref name="path"/>, or defaults if absent.</summary>
    public AppSettings(string path)
    {
        _path = path;
        Data = Load(path);
    }

    /// <summary>The default location.</summary>
    public static string DefaultPath => AppPaths.SettingsFile;

    /// <summary>Current values.</summary>
    public SettingsData Data { get; private set; }

    /// <summary>Raised after a successful save.</summary>
    public event EventHandler? Changed;

    /// <summary>Replaces and persists the settings.</summary>
    public void Update(SettingsData data)
    {
        Data = data;

        // Atomic: a crash mid-write must leave the previous settings, not an empty file.
        AtomicFile.WriteAllText(_path, JsonSerializer.Serialize(data, SettingsJsonContext.Default.SettingsData));

        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static SettingsData Load(string path)
    {
        // Corrupt or unreadable settings must never stop the app launching — defaults are
        // always a working configuration.
        try
        {
            if (!File.Exists(path)) return new SettingsData();

            return (JsonSerializer.Deserialize(File.ReadAllText(path), SettingsJsonContext.Default.SettingsData)
                    ?? new SettingsData()).Normalize();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            return new SettingsData();
        }
    }
}

/// <summary>Source-generated JSON for settings.</summary>
[JsonSourceGenerationOptions(WriteIndented = true, UseStringEnumConverter = true)]
[JsonSerializable(typeof(SettingsData))]
public sealed partial class SettingsJsonContext : JsonSerializerContext;
