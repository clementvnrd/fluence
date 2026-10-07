using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Dictionary;
using Murmur.Testing;
using NetArchTest.Rules;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>
/// Exercises the entire dictation path with fakes.
/// </summary>
/// <remarks>
/// This is the substitute for a Windows machine. Everything here runs on any platform, so a
/// regression in the state machine, the timing rules, the chunking or the correction pass is
/// caught on the developer's own machine rather than discovered by a user on Windows.
/// </remarks>
public sealed class DictationEngineTests
{
    /// <summary>No hold minimum, no post-roll, a fast watchdog: tests control timing explicitly.</summary>
    private static DictationOptions Fast(DictationOptions? with = null) => (with ?? new DictationOptions()) with
    {
        MinimumHold = TimeSpan.Zero,
        PostRoll = TimeSpan.Zero,
        WatchdogInterval = TimeSpan.FromMilliseconds(5),
    };

    private static DictationEngine Build(
        IAudioCapture capture,
        FakeHotkeySource hotkey,
        ITranscriber transcriber,
        RecordingTextInjector injector,
        params DictionaryEntry[] dictionary) =>
        new(capture, hotkey, transcriber, injector, () => dictionary, new FakeClock(), Fast());

    private static async Task WaitFor(Func<bool> condition, string because)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException(because);
            await Task.Delay(2);
        }
    }

    /// <summary>Presses, waits for audio, then releases and waits for the engine to settle.</summary>
    private static async Task DictateAsync(FakeHotkeySource hotkey, DictationEngine engine, FakeClock? clock = null)
    {
        hotkey.Press();
        await WaitFor(() => engine.State == DictationState.Recording, "recording should start");
        await Task.Delay(20);   // let the capture task run; silence never raises the level

        clock?.Advance(TimeSpan.FromSeconds(1));
        hotkey.Release();
        await WaitFor(() => engine.State is DictationState.Idle or DictationState.Error, "dictation should finish");
    }

    [Fact]
    public async Task Speech_is_transcribed_corrected_and_injected()
    {
        var hotkey = new FakeHotkeySource();
        var transcriber = new FakeTranscriber("I use cloud code every day");
        var injector = new RecordingTextInjector();

        await using var engine = Build(
            FakeAudioCapture.Tone(1.0), hotkey, transcriber, injector,
            DictionaryEntry.Correction("cloud code", "Claude Code"));

        DictationResult? completed = null;
        engine.Completed += (_, r) => completed = r;

        await DictateAsync(hotkey, engine);

        injector.Injected.ShouldHaveSingleItem();
        injector.Injected[0].ShouldBe("I use Claude Code every day");

        completed.ShouldNotBeNull();
        completed.RawText.ShouldBe("I use cloud code every day");
        completed.Delivery.ShouldBe(DeliveryOutcome.Typed);
        completed.Corrections.ShouldHaveSingleItem();
        completed.Corrections[0].To.ShouldBe("Claude Code");
    }

    [Fact]
    public async Task Silence_injects_nothing()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector();

        // An engine that heard nothing returns empty — and empty must never be typed.
        await using var engine = Build(
            FakeAudioCapture.Silence(0.5), hotkey, new FakeTranscriber(""), injector);

        await DictateAsync(hotkey, engine);

        injector.Injected.ShouldBeEmpty();
        engine.State.ShouldBe(DictationState.Idle);
    }

    [Fact]
    public async Task Release_without_press_is_ignored()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector();
        await using var engine = Build(
            FakeAudioCapture.Tone(0.2), hotkey, new FakeTranscriber("hello"), injector);

        hotkey.Release();
        await Task.Delay(50);

        engine.State.ShouldBe(DictationState.Idle);
        injector.Injected.ShouldBeEmpty();
    }

    [Fact]
    public async Task Dictionary_terms_are_offered_to_the_engine_as_bias()
    {
        var hotkey = new FakeHotkeySource();
        var transcriber = new FakeTranscriber("anything");

        await using var engine = Build(
            FakeAudioCapture.Tone(0.4), hotkey, transcriber, new RecordingTextInjector(),
            DictionaryEntry.Term("Anthropic"),
            DictionaryEntry.Correction("cloud code", "Claude Code"));

        await DictateAsync(hotkey, engine);

        // Both the plain term and the *write* side of the correction get biased — the whole
        // point is to nudge the recogniser toward the correct spelling.
        transcriber.LastBias.ShouldContain("Anthropic");
        transcriber.LastBias.ShouldContain("Claude Code");
    }

    [Fact]
    public async Task State_returns_to_idle_after_a_dictation()
    {
        var hotkey = new FakeHotkeySource();
        await using var engine = Build(
            FakeAudioCapture.Tone(0.3), hotkey, new FakeTranscriber("done"), new RecordingTextInjector());

        engine.State.ShouldBe(DictationState.Idle);
        await DictateAsync(hotkey, engine);
        engine.State.ShouldBe(DictationState.Idle);
        engine.Level.ShouldBe(0);
    }

    // ---- B2: the hook thread only enqueues ------------------------------------------------

    [Fact]
    public async Task The_hotkey_handler_returns_at_once_even_when_the_device_is_slow_to_open()
    {
        var hotkey = new FakeHotkeySource();
        var capture = new FakeAudioCapture(new float[3200]) { OpenDelay = TimeSpan.FromMilliseconds(600) };
        await using var engine = Build(capture, hotkey, new FakeTranscriber("x"), new RecordingTextInjector());

        var timer = System.Diagnostics.Stopwatch.StartNew();
        hotkey.Press();
        timer.Stop();

        // Windows removes a low-level hook whose callback takes over ~1 s, silently.
        timer.Elapsed.ShouldBeLessThan(TimeSpan.FromMilliseconds(100));
        await WaitFor(() => capture.Opens == 1, "the device should still be opened, elsewhere");
    }

    // ---- B4: minimum hold and chords --------------------------------------------------------

    [Fact]
    public async Task A_tap_shorter_than_the_minimum_hold_is_discarded()
    {
        var hotkey = new FakeHotkeySource();
        var clock = new FakeClock();
        var transcriber = new FakeTranscriber("room noise");
        var injector = new RecordingTextInjector();
        await using var engine = new DictationEngine(
            FakeAudioCapture.Live(), hotkey, transcriber, injector, () => [], clock,
            Fast() with { MinimumHold = TimeSpan.FromMilliseconds(250) });

        hotkey.Press();
        await WaitFor(() => engine.State == DictationState.Recording, "recording should start");
        clock.Advance(TimeSpan.FromMilliseconds(120));
        hotkey.Release();

        await WaitFor(() => engine.State == DictationState.Idle, "a tap should end quietly");
        await Task.Delay(30);

        injector.Injected.ShouldBeEmpty();
        transcriber.SegmentLengths.ShouldBeEmpty("nothing should even be transcribed");
        engine.LastError.ShouldBeNull("a tap is not an error");
    }

    [Fact]
    public async Task A_shortcut_like_right_ctrl_c_cancels_the_dictation()
    {
        var hotkey = new FakeHotkeySource();
        var clock = new FakeClock();
        var injector = new RecordingTextInjector();
        await using var engine = new DictationEngine(
            FakeAudioCapture.Live(), hotkey, new FakeTranscriber("typed by accident"), injector, () => [], clock, Fast());

        hotkey.Press();
        await WaitFor(() => engine.State == DictationState.Recording, "recording should start");
        hotkey.PressOtherKey();
        await WaitFor(() => engine.State == DictationState.Idle, "the chord should cancel");

        clock.Advance(TimeSpan.FromSeconds(2));
        hotkey.Release();
        await Task.Delay(30);

        injector.Injected.ShouldBeEmpty();
        engine.LastError.ShouldBeNull();
    }

    // ---- B3: stuck keys, locks and the length limit ---------------------------------------

    [Fact]
    public async Task Recording_stops_at_the_length_limit_and_the_text_is_kept_but_not_typed()
    {
        var hotkey = new FakeHotkeySource { PhysicallyDown = true };
        var clock = new FakeClock();
        var injector = new RecordingTextInjector();
        await using var engine = new DictationEngine(
            FakeAudioCapture.Live(), hotkey, new FakeTranscriber("ten minutes of room"), injector, () => [], clock,
            Fast(new DictationOptions { MaxRecording = TimeSpan.FromMinutes(10) }));

        DictationResult? completed = null;
        engine.Completed += (_, r) => completed = r;

        hotkey.Press();
        await WaitFor(() => engine.Level > 0, "audio should arrive");
        clock.Advance(TimeSpan.FromMinutes(11));

        await WaitFor(() => completed is not null, "the limit should end the recording");
        completed!.Delivery.ShouldBe(DeliveryOutcome.LimitReached);
        injector.Injected.ShouldBeEmpty("a stuck key must not type into whatever has focus later");
        await WaitFor(() => engine.State == DictationState.Error, "the user should be told");
        engine.LastError.ShouldNotBeNull().ShouldContain("10-minute limit");
    }

    [Fact]
    public async Task Locking_the_session_cancels_the_recording_and_says_so()
    {
        var hotkey = new FakeHotkeySource();
        var session = new FakeSessionMonitor();
        var injector = new RecordingTextInjector();
        await using var engine = new DictationEngine(
            FakeAudioCapture.Live(), hotkey, new FakeTranscriber("behind the lock screen"), injector, () => [],
            new FakeClock(), Fast(new DictationOptions { Session = session }));

        engine.Start();
        session.Started.ShouldBeTrue();

        hotkey.Press();
        await WaitFor(() => engine.State == DictationState.Recording, "recording should start");
        session.Lock();

        await WaitFor(() => engine.State == DictationState.Error, "the lock should cancel");
        engine.LastError.ShouldNotBeNull().ShouldContain("locked");
        injector.Injected.ShouldBeEmpty();
    }

    [Fact]
    public async Task A_secure_desktop_cancels_the_recording()
    {
        var hotkey = new FakeHotkeySource();
        var session = new FakeSessionMonitor();
        var injector = new RecordingTextInjector();
        await using var engine = new DictationEngine(
            FakeAudioCapture.Live(), hotkey, new FakeTranscriber("x"), injector, () => [],
            new FakeClock(), Fast(new DictationOptions { Session = session }));

        hotkey.Press();
        await WaitFor(() => engine.State == DictationState.Recording, "recording should start");
        session.IsInputDesktopActive = false;   // a UAC prompt took the keyboard

        await WaitFor(() => engine.State == DictationState.Error, "the watchdog should cancel");
        engine.LastError.ShouldNotBeNull().ShouldContain("secure desktop");
    }

    [Fact]
    public async Task A_lost_key_up_is_caught_by_the_watchdog()
    {
        var hotkey = new FakeHotkeySource { PhysicallyDown = true };
        var clock = new FakeClock();
        var injector = new RecordingTextInjector();
        await using var engine = new DictationEngine(
            FakeAudioCapture.Live(), hotkey, new FakeTranscriber("x"), injector, () => [], clock, Fast());

        hotkey.Press();
        await WaitFor(() => engine.State == DictationState.Recording, "recording should start");
        await Task.Delay(30);
        engine.State.ShouldBe(DictationState.Recording, "the key is still physically down");

        // The key is up, but the hook never reported it.
        hotkey.PhysicallyDown = false;
        clock.Advance(TimeSpan.FromSeconds(1));

        await WaitFor(() => engine.State == DictationState.Error, "the watchdog should notice");
        engine.LastError.ShouldNotBeNull().ShouldContain("release was never received");
        injector.Injected.ShouldBeEmpty();
    }

    // ---- R2 / B5: post-roll, drain, and no buffer race --------------------------------------

    [Fact]
    public async Task Audio_captured_after_release_is_drained_and_transcribed()
    {
        var hotkey = new FakeHotkeySource();
        var capture = FakeAudioCapture.Live();
        capture.TailChunks = 5;
        var transcriber = new FakeTranscriber("the last word");
        await using var engine = Build(capture, hotkey, transcriber, new RecordingTextInjector());

        await DictateAsync(hotkey, engine);

        capture.ChunksAfterStop.ShouldBe(5, "stopping must drain, not cancel the reads");
        transcriber.SegmentLengths.Sum().ShouldBe(capture.SamplesDelivered,
            "every sample handed over — the drained tail included — must reach the transcriber");
    }

    [Fact]
    public async Task Post_roll_keeps_recording_briefly_after_release()
    {
        var hotkey = new FakeHotkeySource();
        var capture = FakeAudioCapture.Live();
        await using var engine = new DictationEngine(
            capture, hotkey, new FakeTranscriber("x"), new RecordingTextInjector(), () => [], new FakeClock(),
            Fast() with { PostRoll = TimeSpan.FromSeconds(3) });

        hotkey.Press();
        await WaitFor(() => engine.Level > 0, "audio should arrive");
        hotkey.Release();

        // Wait for the next chunk rather than a fixed delay: a busy CI runner can take longer
        // than any fixed sleep to deliver it, which made this test flaky on Windows.
        var atRelease = capture.SamplesDelivered;
        await WaitFor(() => capture.SamplesDelivered > atRelease, "audio keeps arriving after release");
        capture.ChunksAfterStop.ShouldBe(0, "stop is not requested during the post-roll");
    }

    // ---- W3, B8: where the text goes --------------------------------------------------------

    [Fact]
    public async Task With_typing_switched_off_nothing_is_typed_but_the_result_is_kept()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector();
        await using var engine = new DictationEngine(
            FakeAudioCapture.Tone(0.5), hotkey, new FakeTranscriber("private note"), injector, () => [],
            new FakeClock(), Fast(new DictationOptions { InjectText = () => false }));

        DictationResult? completed = null;
        engine.Completed += (_, r) => completed = r;

        await DictateAsync(hotkey, engine);

        injector.Injected.ShouldBeEmpty();
        completed.ShouldNotBeNull().Delivery.ShouldBe(DeliveryOutcome.TypingDisabled);
        engine.LastError.ShouldBeNull("the user chose this");
    }

    [Fact]
    public async Task Text_is_not_typed_into_a_window_that_took_focus_after_release()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector { Focus = new FocusTarget(100, false) };
        var queries = 0;
        injector.OnFocusQuery = i => { if (++queries == 2) i.Focus = new FocusTarget(200, false); };
        await using var engine = Build(FakeAudioCapture.Tone(0.5), hotkey, new FakeTranscriber("for the editor"), injector);

        DictationResult? completed = null;
        engine.Completed += (_, r) => completed = r;

        await DictateAsync(hotkey, engine);

        injector.Injected.ShouldBeEmpty();
        completed.ShouldNotBeNull().Delivery.ShouldBe(DeliveryOutcome.FocusChanged);
        engine.State.ShouldBe(DictationState.Error);
    }

    [Fact]
    public async Task An_elevated_target_is_reported_instead_of_failing_silently()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector { Focus = new FocusTarget(100, IsBlocked: true) };
        await using var engine = Build(FakeAudioCapture.Tone(0.5), hotkey, new FakeTranscriber("x"), injector);

        await DictateAsync(hotkey, engine);

        injector.Injected.ShouldBeEmpty();
        engine.LastError.ShouldNotBeNull().ShouldContain("administrator");
    }

    [Fact]
    public async Task A_failed_injection_is_reported()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector { Succeeds = false };
        await using var engine = Build(FakeAudioCapture.Tone(0.5), hotkey, new FakeTranscriber("x"), injector);

        await DictateAsync(hotkey, engine);

        engine.State.ShouldBe(DictationState.Error);
        engine.LastError.ShouldNotBeNull().ShouldContain("failed");
    }

    // ---- R4: nothing fails silently ---------------------------------------------------------

    [Fact]
    public async Task A_transcription_exception_becomes_a_visible_error_and_is_logged()
    {
        var hotkey = new FakeHotkeySource();
        var log = new RecordingDiagnosticLog();
        var transcriber = new FakeTranscriber("x") { TranscribeError = new InvalidOperationException("native boom") };
        await using var engine = new DictationEngine(
            FakeAudioCapture.Tone(0.5), hotkey, transcriber, new RecordingTextInjector(), () => [],
            new FakeClock(), Fast(new DictationOptions { Log = log }));

        await DictateAsync(hotkey, engine);

        engine.State.ShouldBe(DictationState.Error);
        engine.LastError.ShouldNotBeNull().ShouldContain("Transcription failed");
        log.Events.ShouldContain(e => e.Name == "transcription.failed" && e.Exception is InvalidOperationException);
    }

    [Fact]
    public async Task A_model_that_will_not_load_is_reported()
    {
        var hotkey = new FakeHotkeySource();
        var host = new TranscriberHost(new FakeTranscriber("x") { LoadError = new InvalidDataException("truncated") }, "/m");
        await using var engine = new DictationEngine(
            FakeAudioCapture.Tone(0.5), hotkey, host, new RecordingTextInjector(), () => [], new FakeClock(), Fast());

        await DictateAsync(hotkey, engine);

        engine.LastError.ShouldNotBeNull().ShouldContain("speech model is not loaded");
    }

    [Fact]
    public async Task A_microphone_that_will_not_open_is_reported()
    {
        var hotkey = new FakeHotkeySource();
        var capture = new FakeAudioCapture(new float[100]) { OpenError = new InvalidOperationException("no device") };
        await using var engine = Build(capture, hotkey, new FakeTranscriber("x"), new RecordingTextInjector());

        hotkey.Press();
        await WaitFor(() => capture.Opens == 1, "the device should be tried");
        hotkey.Release();

        await WaitFor(() => engine.State == DictationState.Error, "the failure should surface");
        engine.LastError.ShouldNotBeNull().ShouldContain("microphone");
    }

    [Fact]
    public async Task A_failing_history_write_does_not_cost_the_typed_text()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector();
        await using var engine = Build(FakeAudioCapture.Tone(0.5), hotkey, new FakeTranscriber("keep me"), injector);
        engine.Completed += (_, _) => throw new IOException("disk full");

        await DictateAsync(hotkey, engine);

        injector.Injected.ShouldBe(["keep me"]);
    }

    [Fact]
    public async Task A_new_press_clears_the_previous_error()
    {
        var hotkey = new FakeHotkeySource();
        var injector = new RecordingTextInjector { Succeeds = false };
        await using var engine = Build(FakeAudioCapture.Tone(0.5), hotkey, new FakeTranscriber("x"), injector);

        await DictateAsync(hotkey, engine);
        engine.State.ShouldBe(DictationState.Error);

        injector.Succeeds = true;
        await DictateAsync(hotkey, engine);
        engine.State.ShouldBe(DictationState.Idle);
    }

    // ---- B1-style re-press, and shutdown ----------------------------------------------------

    [Fact]
    public async Task Two_quick_dictations_are_both_typed_in_order()
    {
        var hotkey = new FakeHotkeySource();
        var gate = new TaskCompletionSource();
        var transcriber = new FakeTranscriber("first", "second") { TranscribeGate = gate.Task };
        var injector = new RecordingTextInjector();
        var capture = FakeAudioCapture.Live();
        await using var engine = Build(capture, hotkey, transcriber, injector);

        hotkey.Press();
        await WaitFor(() => engine.Level > 0, "first audio");
        hotkey.Release();

        // Re-press while the first is still being transcribed.
        await WaitFor(() => engine.State == DictationState.Transcribing, "first is processing");
        hotkey.Press();
        await WaitFor(() => engine.State == DictationState.Recording && capture.Opens == 2, "second records");
        hotkey.Release();

        gate.SetResult();
        await WaitFor(() => injector.Injected.Count == 2, "both should be typed");
        injector.Injected.ShouldBe(["first", "second"]);
    }

    [Fact]
    public async Task Quitting_mid_decode_waits_for_the_decode_before_freeing_the_engine()
    {
        var hotkey = new FakeHotkeySource();
        var gate = new TaskCompletionSource();
        var transcriber = new FakeTranscriber("x") { TranscribeGate = gate.Task };
        var host = new TranscriberHost(transcriber, "/m");
        var injector = new RecordingTextInjector();
        var engine = new DictationEngine(
            FakeAudioCapture.Tone(0.5), hotkey, host, injector, () => [], new FakeClock(), Fast());

        hotkey.Press();
        await WaitFor(() => engine.Level > 0, "audio");
        hotkey.Release();
        await WaitFor(() => transcriber.IsTranscribing, "decode running");

        var disposing = engine.DisposeAsync().AsTask();
        await Task.Delay(50);
        disposing.IsCompleted.ShouldBeFalse();

        gate.SetResult();
        await disposing;

        transcriber.Disposal.ShouldBe((true, false), "freed only after the decode returned");
        injector.Injected.ShouldBeEmpty("nothing is typed after the user asked to quit");
    }

    /// <summary>
    /// The boundary is enforced by the compiler via CA1416, but this fails louder and names
    /// the reason: anything reachable from Core must run in CI on any platform.
    /// </summary>
    [Fact]
    public void Core_does_not_depend_on_any_platform_project()
    {
        var result = Types.InAssembly(typeof(DictationEngine).Assembly)
            .That().ResideInNamespace("Murmur.Core")
            .ShouldNot().HaveDependencyOn("Murmur.Platform")
            .GetResult();

        result.IsSuccessful.ShouldBeTrue(
            "Murmur.Core must stay platform-neutral: " +
            string.Join(", ", result.FailingTypeNames ?? []));
    }
}

/// <summary>The push-to-talk key policy the hook applies.</summary>
public sealed class PushToTalkKeysTests
{
    [Fact]
    public void Only_caps_lock_is_swallowed()
    {
        PushToTalkKeys.ShouldSwallow(PushToTalkKeys.CapsLock).ShouldBeTrue();
        PushToTalkKeys.ShouldSwallow(PushToTalkKeys.RightControl).ShouldBeFalse(
            "a swallowed modifier whose key-up escapes is stuck down forever");
        PushToTalkKeys.ShouldSwallow(PushToTalkKeys.RightAlt).ShouldBeFalse();
    }

    [Fact]
    public void A_swallowed_key_cannot_be_polled()
    {
        PushToTalkKeys.CanPollPhysicalState(PushToTalkKeys.CapsLock).ShouldBeFalse();
        PushToTalkKeys.CanPollPhysicalState(PushToTalkKeys.RightControl).ShouldBeTrue();
    }

    [Fact]
    public void Any_other_key_is_a_chord_but_auto_repeat_and_altgr_phantom_ctrl_are_not()
    {
        PushToTalkKeys.IsChord(PushToTalkKeys.RightControl, 0x43 /* C */, 0x2E).ShouldBeTrue();
        PushToTalkKeys.IsChord(PushToTalkKeys.RightControl, PushToTalkKeys.RightControl, 0x1D).ShouldBeFalse();
        PushToTalkKeys.IsChord(PushToTalkKeys.RightAlt, PushToTalkKeys.LeftControl,
            PushToTalkKeys.AltGrPhantomControlScanCode).ShouldBeFalse();
        PushToTalkKeys.IsChord(PushToTalkKeys.RightAlt, PushToTalkKeys.LeftControl, 0x1D).ShouldBeTrue(
            "a real Left Ctrl is a chord");
    }
}

/// <summary>Chunking behaviour around the encoder's hard limit.</summary>
public sealed class AudioSegmenterTests
{
    private static ReadOnlyMemory<float> Seconds(int n) =>
        new float[n * AudioChunk.SampleRate];

    [Fact]
    public void Short_audio_is_one_segment_and_is_not_copied()
    {
        var audio = Seconds(5);
        var pieces = AudioSegmenter.Split(audio);

        pieces.ShouldHaveSingleItem();
        pieces[0].Length.ShouldBe(audio.Length);
    }

    [Fact]
    public void Audio_at_the_limit_is_still_one_segment()
    {
        AudioSegmenter.Split(Seconds(AudioSegmenter.MaxSegmentSeconds)).ShouldHaveSingleItem();
    }

    [Fact]
    public void Long_audio_is_split_and_every_piece_is_under_the_limit()
    {
        var pieces = AudioSegmenter.Split(Seconds(200));

        pieces.Count.ShouldBeGreaterThan(1);
        foreach (var piece in pieces)
        {
            piece.Length.ShouldBeLessThanOrEqualTo(
                AudioSegmenter.MaxSegmentSeconds * AudioChunk.SampleRate);
            piece.Length.ShouldBeGreaterThan(0);
        }
    }

    [Fact]
    public void Splitting_loses_no_samples()
    {
        var pieces = AudioSegmenter.Split(Seconds(200));
        pieces.Sum(p => p.Length).ShouldBe(200 * AudioChunk.SampleRate);
    }

    /// <summary>
    /// 410 seconds is past the point where the encoder's position table overflows and
    /// inference throws rather than degrading. Nothing may reach it.
    /// </summary>
    [Fact]
    public void Nothing_ever_reaches_the_encoder_ceiling()
    {
        var pieces = AudioSegmenter.Split(Seconds(AudioSegmenter.EncoderCeilingSeconds + 100));

        foreach (var piece in pieces)
        {
            var seconds = (double)piece.Length / AudioChunk.SampleRate;
            seconds.ShouldBeLessThan(AudioSegmenter.EncoderCeilingSeconds);
        }
    }

    [Fact]
    public void A_short_dip_inside_a_word_does_not_attract_the_cut()
    {
        // Loud speech-like signal with a 40 ms gap (a plosive's closure) near the ideal cut,
        // and a genuine 400 ms pause earlier in the search window. A 20 ms window would pick
        // the plosive; a 200 ms window cannot fit inside it.
        var total = AudioSegmenter.MaxSegmentSeconds * 2 * AudioChunk.SampleRate;
        var samples = new float[total];
        for (var i = 0; i < total; i++) samples[i] = 0.4f * MathF.Sin(i * 0.05f);

        var plosive = (AudioSegmenter.MaxSegmentSeconds - 1) * AudioChunk.SampleRate;
        Array.Clear(samples, plosive, AudioChunk.SampleRate * 40 / 1000);

        var pause = (AudioSegmenter.MaxSegmentSeconds - 5) * AudioChunk.SampleRate;
        Array.Clear(samples, pause, AudioChunk.SampleRate * 400 / 1000);

        var cut = AudioSegmenter.SplitWithSeams(samples)[0].Samples.Length;

        cut.ShouldBeGreaterThanOrEqualTo(pause);
        cut.ShouldBeLessThanOrEqualTo(pause + (AudioChunk.SampleRate * 400 / 1000));
    }

    [Fact]
    public void A_cut_in_a_pause_does_not_overlap_and_a_cut_through_speech_does()
    {
        var withPause = new float[AudioSegmenter.MaxSegmentSeconds * 2 * AudioChunk.SampleRate];
        AudioSegmenter.SplitWithSeams(withPause).Skip(1).ShouldAllBe(s => !s.OverlapsPrevious);

        var continuous = new float[AudioSegmenter.MaxSegmentSeconds * 2 * AudioChunk.SampleRate];
        for (var i = 0; i < continuous.Length; i++) continuous[i] = 0.4f * MathF.Sin(i * 0.05f);

        var pieces = AudioSegmenter.SplitWithSeams(continuous);
        pieces.Count.ShouldBeGreaterThan(1);
        pieces.Skip(1).ShouldAllBe(s => s.OverlapsPrevious);
        pieces.Sum(p => p.Samples.Length).ShouldBeGreaterThan(continuous.Length, "overlap re-hears the seam");
        foreach (var piece in pieces)
        {
            piece.Samples.Length.ShouldBeLessThanOrEqualTo(AudioSegmenter.MaxSegmentSeconds * AudioChunk.SampleRate);
        }
    }

    [Fact]
    public void A_cut_lands_in_the_quiet_part_rather_than_mid_word()
    {
        // Loud throughout, with one silent second placed inside the search window that
        // precedes the ideal cut point. The cut should be drawn to it.
        var total = AudioSegmenter.MaxSegmentSeconds * 2 * AudioChunk.SampleRate;
        var samples = new float[total];
        Array.Fill(samples, 0.5f);

        var quietStart = (AudioSegmenter.MaxSegmentSeconds - 3) * AudioChunk.SampleRate;
        Array.Clear(samples, quietStart, AudioChunk.SampleRate);

        var pieces = AudioSegmenter.Split(samples);
        var firstCut = pieces[0].Length;

        firstCut.ShouldBeGreaterThanOrEqualTo(quietStart);
        firstCut.ShouldBeLessThanOrEqualTo(quietStart + AudioChunk.SampleRate);
    }
}

/// <summary>Joining segment texts at the seams.</summary>
public sealed class TranscriptJoinerTests
{
    [Fact]
    public void Overlapped_words_appear_once()
    {
        TranscriptJoiner.Join([("we shipped the new", false), ("the new release today", true)])
            .ShouldBe("we shipped the new release today");
    }

    [Fact]
    public void Repeats_are_only_removed_where_the_audio_overlapped()
    {
        TranscriptJoiner.Join([("I said that", false), ("that is fine", false)])
            .ShouldBe("I said that that is fine");
    }

    [Fact]
    public void Deduplication_ignores_case_and_punctuation()
    {
        TranscriptJoiner.Join([("send it to Alice.", true), ("Alice, then Bob", true)])
            .ShouldBe("send it to Alice. then Bob");
    }

    [Fact]
    public void Punctuation_is_never_doubled_at_a_seam()
    {
        TranscriptJoiner.Join([("first part.", false), (". second part", false)])
            .ShouldBe("first part. second part");
        TranscriptJoiner.Join([("first,", false), ("…and then", false)])
            .ShouldBe("first, and then");
    }

    [Fact]
    public void Empty_pieces_leave_no_stray_spaces()
    {
        TranscriptJoiner.Join([("", false), ("  hello ", false), ("   ", true), ("world", false)])
            .ShouldBe("hello world");
    }
}
