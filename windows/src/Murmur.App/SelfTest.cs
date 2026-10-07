using System.Runtime.InteropServices;
using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Dictionary;
using Murmur.Meeting;
using Murmur.Speech;

namespace Murmur.App;

/// <summary>
/// A headless check that the published binary actually works.
/// </summary>
/// <remarks>
/// <para>
/// Run in CI against the real single-file executable. It cannot show a window on a runner, so
/// it verifies the things that only break <i>after</i> publishing: assemblies resolving out
/// of the bundle, native libraries extracting, and paths resolving against
/// <c>AppContext.BaseDirectory</c> rather than the current directory.
/// </para>
/// <para>
/// <b>Every check touches the real thing</b>, not just a constructor: a WASAPI enumeration
/// through NAudio, a P/Invoke into sherpa-onnx's native library (and a real decode when a
/// model is installed), a DPAPI round trip, a session-event subscription. Constructing types
/// was not enough — the app once passed this test and then threw FileNotFoundException for
/// NAudio on the first key press.
/// </para>
/// <para>Exit code 0 only if every check passed.</para>
/// </remarks>
public static class SelfTest
{
    /// <summary>Runs the checks.</summary>
    /// <returns>0 if everything passed.</returns>
    public static int Run()
    {
        var failures = 0;

        failures += CheckDictionary();
        failures += CheckStorage();
        failures += CheckMeetingStore();
        failures += CheckNativeSpeech();
        failures += CheckMeetingNative();
        failures += CheckModelDiscovery();
        failures += CheckPlatformLayer();

        Console.WriteLine(failures == 0 ? "self-test: PASS" : $"self-test: {failures} FAILED");
        return failures == 0 ? 0 : 1;
    }

    private static int CheckDictionary()
    {
        var failures = 0;

        var corrector = new DictionaryCorrector([DictionaryEntry.Correction("cloud code", "Claude Code")]);
        var (text, applied) = corrector.Apply("I use CloudCode daily.");

        failures += Check("dictionary rewrites glued words",
            text == "I use Claude Code daily." && applied.Count == 1);

        failures += Check("dictionary leaves similar words alone",
            corrector.Apply("Cloudflare is fine.").Text == "Cloudflare is fine.");

        return failures;
    }

    private static int CheckStorage()
    {
        // Exercises the source-generated JSON, which is the part most likely to have been
        // silently broken by trimming or single-file publishing.
        var directory = Path.Combine(Path.GetTempPath(), $"murmur-selftest-{Guid.NewGuid():N}");

        try
        {
            Directory.CreateDirectory(directory);

            // The real DPAPI protector on Windows; an in-process stand-in elsewhere, so the
            // sealing and JSON paths are still exercised.
            var protector = PlatformFactory.CreateSecretProtector() ?? new SelfTestProtector();
            var path = Path.Combine(directory, "transcripts.jsonl");

            using (var store = new TranscriptStore(path, protector))
            {
                store.Add(new TranscriptRecord
                {
                    At = DateTimeOffset.UtcNow,
                    Text = "Claude Code",
                    Corrections = [new AppliedCorrection("cloud code", "Claude Code", 1)],
                });
            }

            using var reopened = new TranscriptStore(path, protector);
            var ok = reopened.Records.Count == 1
                     && reopened.Records[0].Corrections?[0].To == "Claude Code";
            var sealedOnDisk = !File.ReadAllText(path).Contains("Claude", StringComparison.Ordinal);

            var settings = new AppSettings(Path.Combine(directory, "settings.json"));
            settings.Update(settings.Data with { PushToTalkKey = 0x7C });
            var settingsOk = new AppSettings(Path.Combine(directory, "settings.json")).Data.PushToTalkKey == 0x7C;

            return Check("history round-trips through source-generated JSON", ok)
                 + Check("history is sealed on disk", sealedOnDisk)
                 + Check("settings round-trip", settingsOk);
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { /* best effort */ }
        }
    }

    /// <summary>A real call into sherpa-onnx's native library, extracted from the bundle.</summary>
    private static int CheckNativeSpeech()
    {
        try
        {
            var version = ParakeetTranscriber.NativeVersion();
            Console.WriteLine($"  sherpa-onnx native: {version}");
            return Check("sherpa-onnx native library loads", !string.IsNullOrWhiteSpace(version));
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException
                                      or TypeLoadException or FileNotFoundException)
        {
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("sherpa-onnx native library loads", false);
        }
    }

    private static int CheckModelDiscovery()
    {
        var failures = Check("model search paths are absolute",
            ParakeetTranscriber.SearchPaths(null, AppPaths.ModelsDirectory).All(Path.IsPathRooted));

        // A fresh machine has no model, and that must be a friendly message rather than a
        // crash on launch.
        var located = ParakeetTranscriber.Locate(null, AppPaths.ModelsDirectory);
        Console.WriteLine($"  model: {located ?? "(not installed — expected on a clean runner)"}");
        if (located is null) return failures;

        // Installed: verify it, load it, and decode a second of silence — the whole path the
        // first dictation would take, minus the microphone.
        var host = new TranscriberHost(new ParakeetTranscriber(located), located);
        try
        {
            var loaded = host.LoadAsync(CancellationToken.None).AsTask().GetAwaiter().GetResult();
            if (!loaded) Console.WriteLine($"  model failed: {host.Detail}");
            failures += Check("installed model verifies and loads", loaded);

            if (loaded)
            {
                var text = host.TranscribeAsync(new float[AudioChunk.SampleRate], [], CancellationToken.None)
                    .AsTask().GetAwaiter().GetResult();
                failures += Check("installed model decodes a second of silence", text is not null);
            }
        }
        finally
        {
            host.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }

        return failures;
    }

    /// <summary>
    /// Verifies the platform layer resolves from inside the published bundle.
    /// </summary>
    /// <remarks>
    /// This is the riskiest thing in the app's structure. <c>Murmur.App</c> targets plain
    /// <c>net10.0</c> and loads <c>Murmur.Platform.Windows</c> by reflection, which is what
    /// lets the UI be built and headless-tested on macOS. Reflection into a single-file
    /// bundle is exactly where that arrangement would fail — and it would fail at the moment
    /// the user first pressed the hotkey, not at startup. So it is checked here, on Windows,
    /// against the real published executable.
    /// </remarks>
    private static int CheckPlatformLayer()
    {
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            Console.WriteLine("  [skip] platform layer (not Windows)");
            return 0;
        }

        var failures = Check("Windows platform assembly loads from the bundle", PlatformFactory.IsAvailable);
        if (!PlatformFactory.IsAvailable) return failures;

        failures += Check("audio capture constructs", PlatformFactory.CreateAudioCapture() is not null);
        failures += CheckAudioStack();

        var injector = PlatformFactory.CreateTextInjector();
        failures += Check("text injector constructs", injector is not null);
        if (injector is not null)
        {
            // GetForegroundWindow plus the elevation query; a runner may have no foreground
            // window at all, which is fine — it must simply not throw.
            var target = injector.GetFocusTarget();
            Console.WriteLine($"  focus target: window={target.Window}, blocked={target.IsBlocked}");
        }

        // Constructed, not started: installing a real low-level keyboard hook on a CI runner
        // is neither useful nor polite. The physical-state query is harmless and real.
        var hotkey = PlatformFactory.CreateHotkeySource(0xA3);
        failures += Check("hotkey source constructs with Right Ctrl", hotkey is not null);
        if (hotkey is not null) Console.WriteLine($"  right ctrl down: {hotkey.IsKeyDown()}");
        hotkey?.Dispose();

        failures += CheckDpapi();
        failures += CheckSessionMonitor();
        failures += CheckLoopback();
        failures += CheckMeetingSignals();

        return failures;
    }

    /// <summary>NAudio's WASAPI types, loaded and used through the reflection-loaded layer.</summary>
    private static int CheckAudioStack()
    {
        try
        {
            Console.WriteLine($"  audio: {PlatformFactory.ProbeAudio()}");
            return Check("NAudio WASAPI enumeration runs", true);
        }
        catch (COMException e)
        {
            // NAudio loaded and called into Windows; the audio service itself refused. That
            // is the runner's environment (no audio service), not a packaging failure.
            Console.WriteLine($"  [warn] audio endpoint service unavailable: 0x{e.HResult:X8}");
            return 0;
        }
        catch (Exception e)
        {
            // FileNotFoundException / TypeLoadException: NAudio did not ship or did not resolve.
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("NAudio WASAPI enumeration runs", false);
        }
    }

    private static int CheckDpapi()
    {
        try
        {
            var protector = PlatformFactory.CreateSecretProtector();
            if (protector is null) return Check("DPAPI protector constructs", false);

            byte[] secret = [1, 2, 3, 4, 5, 6, 7, 8];
            var wrapped = protector.Protect(secret);
            var ok = !wrapped.AsSpan().SequenceEqual(secret) && protector.Unprotect(wrapped).AsSpan().SequenceEqual(secret);
            return Check("DPAPI round-trips the history key", ok);
        }
        catch (Exception e)
        {
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("DPAPI round-trips the history key", false);
        }
    }

    private static int CheckSessionMonitor()
    {
        try
        {
            using var monitor = PlatformFactory.CreateSessionMonitor();
            if (monitor is null) return Check("session monitor constructs", false);

            // Subscribing is what fails if the SystemEvents stub shipped instead of the
            // Windows implementation.
            monitor.Start();
            Console.WriteLine($"  input desktop active: {monitor.IsInputDesktopActive}");
            return Check("session lock notifications subscribe", true);
        }
        catch (Exception e)
        {
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("session lock notifications subscribe", false);
        }
    }

    /// <summary>
    /// The meeting store end to end: vault (DPAPI on Windows), a sealed meeting through the
    /// source-generated JSON, the index, the audio spool, rename, export, delete.
    /// </summary>
    private static int CheckMeetingStore()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"murmur-selftest-meetings-{Guid.NewGuid():N}");
        try
        {
            var protector = PlatformFactory.CreateSecretProtector() ?? new SelfTestProtector();
            using var vault = MeetingVault.Open(directory, protector, SystemClock.Instance, NullDiagnosticLog.Instance, out var problem);
            if (vault is null)
            {
                Console.WriteLine($"  {problem}");
                return Check("meeting vault opens", false);
            }

            var store = new MeetingStore(directory, vault, null);
            var meeting = new MeetingRecord
            {
                Title = "Self-test",
                StartedAt = DateTimeOffset.UtcNow,
                EndedAt = DateTimeOffset.UtcNow.AddMinutes(1),
                Speakers = [Speaker.Me(), new Speaker("S1")],
                Segments = [new TranscriptSegment { Source = AudioSource.System, SpeakerId = "S1", Start = 1, End = 2, Text = "Claude Code" }],
            };
            var saved = store.Save(meeting);
            var renamed = store.RenameSpeaker(meeting.Id, "S1", "Ada");
            var reopened = new MeetingStore(directory, vault, null);
            var loaded = reopened.Load(meeting.Id);
            var roundTrip = saved && renamed is not null && loaded?.Segments.Single().Text == "Claude Code"
                            && loaded.SpeakerById("S1")?.Name == "Ada" && reopened.Summaries.Count == 1;
            var sealedOnDisk = Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories)
                .All(f => !File.ReadAllText(f).Contains("Claude", StringComparison.Ordinal));

            float[] samples = [.. Enumerable.Range(0, 20_000).Select(i => (i % 100) / 200f)];
            using var key = store.OpenKey(meeting.Id, create: false);
            var spoolPath = MeetingAudioSpool.PathFor(store.DirectoryFor(meeting.Id), AudioSource.System);
            using (var spool = new MeetingAudioSpool(spoolPath, key!, meeting.Id, AudioSource.System)) spool.Append(samples);
            var back = new float[samples.Length];
            using (var reader = MeetingAudioSpoolReader.Open(spoolPath, key!, meeting.Id, AudioSource.System))
            {
                reader?.Read(0, back);
            }

            var spoolOk = Math.Abs(back[150] - samples[150]) < 1e-3f && Math.Abs(back[19_999] - samples[19_999]) < 1e-3f;
            var markdown = loaded?.Markdown(TimeZoneInfo.Utc) ?? string.Empty;

            store.Delete(meeting.Id);
            return Check("meeting store round-trips through source-generated JSON", roundTrip)
                 + Check("meetings are sealed on disk", sealedOnDisk)
                 + Check("meeting audio spool round-trips", spoolOk)
                 + Check("meeting exports as Markdown", markdown.Contains("**[00:01] Ada:** Claude Code", StringComparison.Ordinal))
                 + Check("meeting delete removes its folder", !Directory.Exists(store.DirectoryFor(meeting.Id)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
        {
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("meeting store round-trips", false);
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch (IOException) { /* best effort */ }
        }
    }

    /// <summary>The VAD and speaker-diarization halves of sherpa-onnx, and the meeting models when installed.</summary>
    private static int CheckMeetingNative()
    {
        int failures;
        try
        {
            Console.WriteLine($"  meetings: {SherpaMeetingProbe.Run()}");
            failures = Check("sherpa-onnx VAD and diarization types load", true);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException
                                      or TypeLoadException or FileNotFoundException or InvalidOperationException)
        {
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("sherpa-onnx VAD and diarization types load", false);
        }

        var models = AppPaths.ModelsDirectory;
        if (MeetingModels.LocateVad(models) is { } vad)
        {
            failures += Check("installed Silero VAD verifies",
                MeetingModels.Verify(Path.GetDirectoryName(vad)!, [MeetingModels.SileroVad], CancellationToken.None).IsUsable);
        }
        else
        {
            Console.WriteLine("  Silero VAD: (not installed — meetings cut on energy)");
        }

        if (MeetingModels.LocateDiarization(models) is { } folder)
        {
            failures += Check("installed diarization models verify",
                MeetingModels.Verify(folder, [MeetingModels.Segmentation, MeetingModels.Embedding], CancellationToken.None).IsUsable);
        }
        else
        {
            Console.WriteLine("  diarization: (not installed — remote speech stays \"Others\")");
        }

        return failures;
    }

    /// <summary>Process loopback activation. A runner without an audio device skips rather than fails.</summary>
    private static int CheckLoopback()
    {
        try
        {
            Console.WriteLine($"  loopback: {PlatformFactory.ProbeLoopback()}");
            return Check("process loopback activates", true);
        }
        catch (Exception e) when (e is FileNotFoundException or TypeLoadException or EntryPointNotFoundException or MissingMethodException)
        {
            // The platform layer or NAudio did not ship or did not resolve: a packaging failure.
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("process loopback activates", false);
        }
        catch (Exception e)
        {
            // Activation reached Windows and was refused: no render device or audio service.
            Console.WriteLine($"  [warn] process loopback unavailable here: {e.GetType().Name} 0x{e.HResult:X8}");
            return 0;
        }
    }

    /// <summary>Meeting detection's enumeration: capture sessions, windows, processes.</summary>
    private static int CheckMeetingSignals()
    {
        var signals = PlatformFactory.CreateMeetingSignals();
        if (signals is null) return Check("meeting signals construct", false);
        try
        {
            var sessions = signals.CaptureSessions().Count;
            var windows = signals.VisibleWindows().Count;
            Console.WriteLine($"  meeting signals: {sessions} capture sessions, {windows} windows");
            return Check("meeting detection enumerates", true);
        }
        catch (Exception e) when (e is FileNotFoundException or TypeLoadException or MissingMethodException)
        {
            Console.WriteLine($"  {e.GetType().Name}: {e.Message}");
            return Check("meeting detection enumerates", false);
        }
        catch (Exception e)
        {
            // No audio service on the runner: Windows refused, the code shipped.
            Console.WriteLine($"  [warn] audio session enumeration unavailable: {e.GetType().Name} 0x{e.HResult:X8}");
            return 0;
        }
    }

    /// <summary>Stands in for DPAPI off Windows. Not protection — only exercises the code path.</summary>
    private sealed class SelfTestProtector : ISecretProtector
    {
        public byte[] Protect(byte[] secret) => [.. secret];

        public byte[] Unprotect(byte[] protectedSecret) => [.. protectedSecret];
    }

    private static int Check(string name, bool passed)
    {
        Console.WriteLine($"  [{(passed ? "ok" : "FAIL")}] {name}");
        return passed ? 0 : 1;
    }
}
