using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Dictionary;
using Murmur.Speech;

namespace Murmur.App;

/// <summary>The Notetaker's half of the object graph.</summary>
/// <param name="Controller">The state machine, or null when meetings cannot be recorded here.</param>
/// <param name="Store">The encrypted meetings, or null without a vault.</param>
/// <param name="VoicePrints">Opt-in voice prints, or null without a vault.</param>
/// <param name="Problem">Why meetings are unavailable or degraded, for the Meetings window.</param>
public sealed record MeetingParts(
    MeetingController? Controller, MeetingStore? Store, VoicePrintStore? VoicePrints, string? Problem)
{
    /// <summary>Nothing: no platform layer or no secure key storage.</summary>
    public static MeetingParts None(string problem) => new(null, null, null, problem);
}

/// <summary>Wires the Notetaker: vault, store, detection, captures, models.</summary>
internal static class MeetingComposition
{
    /// <summary>Builds the Notetaker, or explains why it cannot run.</summary>
    public static MeetingParts Create(
        AppSettings settings,
        DictionaryFile dictionary,
        TranscriberHost model,
        ISessionMonitor? sessionMonitor,
        bool platformAvailable,
        IDiagnosticLog log)
    {
        var vault = MeetingVault.Open(MeetingStore.DefaultRoot, PlatformFactory.CreateSecretProtector(), SystemClock.Instance, log, out var problem);
        if (vault is null) return MeetingParts.None(problem ?? "Meetings cannot be stored on this system.");

        var voicePrints = new VoicePrintStore(MeetingStore.DefaultRoot, vault, () => settings.Data.NotetakerVoicePrints, log: log);
        var store = new MeetingStore(MeetingStore.DefaultRoot, vault, voicePrints, log);

        // Retention: at launch and whenever the setting changes.
        store.Purge(settings.Data.NotetakerRetentionDays, DateTimeOffset.Now);

        if (!platformAvailable)
        {
            // Past meetings stay readable; nothing can be recorded without audio capture.
            return new MeetingParts(null, store, voicePrints, problem ?? "Recording needs the Windows audio layer.");
        }

        var models = AppPaths.ModelsDirectory;
        var vadPath = MeetingModels.LocateVad(models);
        if (vadPath is not null && !MeetingModels.Verify(Path.GetDirectoryName(vadPath)!, [MeetingModels.SileroVad], CancellationToken.None).IsUsable)
        {
            log.Warning("meeting.vad_rejected");
            vadPath = null;
        }

        // The diarization models are 32 MB to hash: checked once, on the first final pass.
        var diarization = new Lazy<string?>(() =>
        {
            var folder = MeetingModels.LocateDiarization(models);
            if (folder is null) return null;
            var check = MeetingModels.Verify(folder, [MeetingModels.Segmentation, MeetingModels.Embedding], CancellationToken.None);
            if (check.IsUsable) return folder;
            log.Warning("meeting.diarization_rejected");
            return null;
        });

        var controller = new MeetingController(new MeetingServices
        {
            Store = store,
            Detector = PlatformFactory.CreateMeetingSignals() is { } signals
                ? new MeetingDetector(signals, Environment.ProcessId, log)
                : null,
            CreateMicrophone = PlatformFactory.CreateAudioCapture,
            Loopback = PlatformFactory.CreateLoopbackCapture(),
            WindowsBuild = Environment.OSVersion.Version.Build,
            Transcriber = model,
            CreateVoiceActivity = () => vadPath is null ? new EnergyVoiceActivity() : Silero(vadPath, log),
            CreateDiarizer = () => diarization.Value is { } folder ? Native(() => new SherpaDiarizer(folder), log) : null,
            CreateEmbedder = () => diarization.Value is { } folder
                ? Native(() => new SherpaSpeakerEmbedder(Path.Combine(folder, "embedding.onnx")), log)
                : null,
            VoicePrints = voicePrints,
            Correct = text => new DictionaryCorrector(dictionary.Entries).Apply(text).Text,
            Options = () => Options(settings.Data),
            HostClock = HostClock.Instance,
            Clock = SystemClock.Instance,
            Log = log,
        });

        var voicePrintsWereOn = settings.Data.NotetakerVoicePrints;
        var retention = settings.Data.NotetakerRetentionDays;
        settings.Changed += (_, _) =>
        {
            if (settings.Data.NotetakerRetentionDays != retention)
            {
                retention = settings.Data.NotetakerRetentionDays;
                store.Purge(retention, DateTimeOffset.Now);
            }

            if (voicePrintsWereOn != settings.Data.NotetakerVoicePrints)
            {
                voicePrintsWereOn = settings.Data.NotetakerVoicePrints;
                controller.VoicePrintSettingChanged(voicePrintsWereOn);
            }
        };

        // Locking the workstation or sleeping ends the recording, as on macOS.
        if (sessionMonitor is not null)
        {
            sessionMonitor.Interrupted += (_, _) => _ = controller.StopAsync(Meeting.StopReason.ScreenLocked);
        }

        return new MeetingParts(controller, store, voicePrints, problem);
    }

    /// <summary>The Notetaker settings as the controller reads them.</summary>
    public static MeetingOptions Options(SettingsData data) => new()
    {
        DetectMeetings = data.NotetakerDetectMeetings,
        CountdownSeconds = Math.Clamp(data.NotetakerCountdownSeconds, 0, 60),
        KeepAudioByDefault = data.NotetakerKeepAudioByDefault,
        MaxDurationMinutes = Math.Clamp(data.NotetakerMaxMinutes, 5, 600),
        VoicePrints = data.NotetakerVoicePrints,
    };

    private static IVoiceActivityDetector Silero(string path, IDiagnosticLog log)
    {
        try
        {
            return new SileroVoiceActivity(path);
        }
        catch (Exception e) when (e is DllNotFoundException or BadImageFormatException or InvalidOperationException
                                      or EntryPointNotFoundException or TypeInitializationException)
        {
            log.Error("meeting.vad_load_failed", e);
            return new EnergyVoiceActivity();
        }
    }

    private static T? Native<T>(Func<T> create, IDiagnosticLog log) where T : class
    {
        try
        {
            return create();
        }
        catch (Exception e) when (e is DllNotFoundException or BadImageFormatException or InvalidOperationException
                                      or EntryPointNotFoundException or TypeInitializationException)
        {
            log.Error("meeting.model_load_failed", e);
            return null;
        }
    }
}
