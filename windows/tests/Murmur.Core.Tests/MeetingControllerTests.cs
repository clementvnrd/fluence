using Murmur.Abstractions;
using Murmur.Core;
using Murmur.Core.Meetings;
using Murmur.Meeting;
using Murmur.Testing;
using Shouldly;
using Xunit;

namespace Murmur.CoreTests;

/// <summary>The Notetaker's state machine, end to end on fakes: detection, card, recording, final pass.</summary>
public sealed class MeetingControllerTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"fluence-controller-{Guid.NewGuid():N}");
    private readonly FakeHostClock _host = new() { Now = 1_000 * 10_000_000L };
    private readonly FakeClock _clock = new();
    private readonly FakeMeetingSignals _signals = new();
    private readonly RecordingDiagnosticLog _log = new();
    private readonly MeetingVault _vault;
    private readonly MeetingStore _store;
    private MeetingOptions _options = new() { CountdownSeconds = 3 };
    private ITimedTranscriber _transcriber = new FakeTimedTranscriber(_ => "hello there");
    private FakeDiarizer? _diarizer;
    private INotesModel _notes = NoNotesModel.Instance;
    private bool _withLoopback = true;
    private bool _withMic = true;

    public MeetingControllerTests()
    {
        _vault = MeetingVault.Open(_dir, new FakeSecretProtector(), _clock, NullDiagnosticLog.Instance, out _)!;
        _store = new MeetingStore(_dir, _vault, null);
    }

    public void Dispose()
    {
        _vault.Dispose();
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private static float[] Speech(double toneSeconds, double silenceSeconds) =>
    [
        .. Enumerable.Range(0, (int)(toneSeconds * 16_000)).Select(i => MathF.Sin(i * 0.2f) * 0.5f),
        .. new float[(int)(silenceSeconds * 16_000)],
    ];

    private MeetingController Controller() => new(new MeetingServices
    {
        Store = _store,
        Detector = new MeetingDetector(_signals, ownProcessId: 1, _log),
        CreateMicrophone = () => _withMic ? new FakeAudioCapture(Speech(1.5, 2)) : null,
        Loopback = _withLoopback
            ? new FakeLoopbackCapture(_ => true, _ => [FakeLoopbackCapture.Pcm16(Speech(3, 2), 16_000, 1, _host.Now + 20_000_000)])
            : null,
        WindowsBuild = 22631,
        Transcriber = _transcriber,
        CreateVoiceActivity = () => new EnergyVoiceActivity(),
        CreateDiarizer = () => _diarizer,
        Correct = t => t,
        Notes = _notes,
        Options = () => _options,
        HostClock = _host,
        Clock = _clock,
        Log = _log,
    });

    private void ZoomOnMic() => _signals.Sessions.Add(new AudioSessionInfo(4242, "Zoom.exe", true));

    private static async Task WaitForAsync(Func<bool> condition, string what)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException($"Timed out waiting for {what}.");
            await Task.Delay(5);
        }
    }

    private async Task TickAsync(MeetingController controller, int times = 1)
    {
        for (var i = 0; i < times; i++)
        {
            _host.Advance(1);
            await controller.TickAsync();
        }
    }

    [Fact]
    public async Task A_detected_call_counts_down_on_the_card_then_records_and_is_finalised()
    {
        ZoomOnMic();
        await using var controller = Controller();

        await TickAsync(controller);
        controller.State.ShouldBe(MeetingState.Detected);
        controller.Detected!.App.Name.ShouldBe("Zoom");
        controller.Countdown.ShouldBe(3);

        await TickAsync(controller, 2);
        controller.Countdown.ShouldBe(1);
        await TickAsync(controller);
        controller.State.ShouldBe(MeetingState.Recording);
        controller.Current!.Title.ShouldBe("Zoom call");
        controller.Current.Trigger.ShouldBe(MeetingTrigger.Detected);
        var id = controller.Current.Id;
        File.Exists(_store.MarkerPath(id)).ShouldBeTrue();

        await TickAsync(controller, 3);
        await controller.StopAsync(StopReason.User);

        controller.State.ShouldBe(MeetingState.Idle);
        controller.LastStopReason.ShouldBe(StopReason.User);
        var saved = _store.Load(id).ShouldNotBeNull();
        saved.EndedAt.ShouldNotBeNull();
        saved.Notes.ShouldBeNull();   // no notes model: no notes, never invented
        saved.Segments.ShouldNotBeEmpty();
        saved.Segments.ShouldAllBe(s => s.IsFinal);
        saved.Segments.ShouldContain(s => s.Source == AudioSource.System && s.SpeakerId == Speaker.OthersId);
        File.Exists(_store.MarkerPath(id)).ShouldBeFalse();
        File.Exists(MeetingAudioSpool.PathFor(_store.DirectoryFor(id), AudioSource.Microphone)).ShouldBeFalse();
        File.Exists(MeetingAudioSpool.PathFor(_store.DirectoryFor(id), AudioSource.System)).ShouldBeFalse();
    }

    [Fact]
    public async Task Not_now_holds_for_the_rest_of_the_call()
    {
        ZoomOnMic();
        await using var controller = Controller();
        await TickAsync(controller);
        controller.Dismiss();
        controller.State.ShouldBe(MeetingState.Idle);

        await TickAsync(controller, 5);
        controller.State.ShouldBe(MeetingState.Idle);
    }

    [Fact]
    public async Task The_card_goes_away_when_the_call_ends_before_anyone_answers()
    {
        ZoomOnMic();
        _options = _options with { CountdownSeconds = 0 };
        await using var controller = Controller();
        await TickAsync(controller);
        controller.Countdown.ShouldBeNull();   // waits for a click

        _signals.Sessions.Clear();
        await TickAsync(controller, 7);
        controller.State.ShouldBe(MeetingState.Idle);
    }

    [Fact]
    public async Task Detection_off_offers_nothing()
    {
        ZoomOnMic();
        _options = _options with { DetectMeetings = false };
        await using var controller = Controller();
        await TickAsync(controller, 3);
        controller.State.ShouldBe(MeetingState.Idle);
    }

    [Fact]
    public async Task The_call_releasing_the_microphone_for_30_s_stops_the_recording()
    {
        ZoomOnMic();
        await using var controller = Controller();
        await TickAsync(controller);
        await controller.AcceptAsync();
        controller.State.ShouldBe(MeetingState.Recording);

        _signals.Sessions.Clear();
        await TickAsync(controller, 35);
        controller.State.ShouldBe(MeetingState.Idle);
        controller.LastStopReason.ShouldBe(StopReason.CallEnded);
    }

    [Fact]
    public async Task Without_loopback_only_the_microphone_is_recorded_and_the_user_is_told()
    {
        _withLoopback = false;
        await using var controller = Controller();
        await controller.TakeNotesAsync();
        controller.State.ShouldBe(MeetingState.Recording);
        controller.Current!.Trigger.ShouldBe(MeetingTrigger.Manual);
        controller.Notice.ShouldNotBeNull().ShouldContain("Only your microphone");
        await controller.StopAsync(StopReason.User);
    }

    [Fact]
    public async Task Without_a_loaded_model_or_a_microphone_nothing_is_recorded()
    {
        _transcriber = new NotReadyTranscriber();
        await using (var controller = Controller())
        {
            await controller.TakeNotesAsync();
            controller.State.ShouldBe(MeetingState.Failed);
            controller.Problem.ShouldNotBeNull().ShouldContain("speech model");
            controller.DismissProblem();
            controller.State.ShouldBe(MeetingState.Idle);
        }

        _transcriber = new FakeTimedTranscriber(_ => "x");
        _withMic = false;
        await using (var controller = Controller())
        {
            await controller.TakeNotesAsync();
            controller.Problem.ShouldNotBeNull().ShouldContain("microphone");
        }

        _store.Summaries.ShouldBeEmpty();
    }

    [Fact]
    public async Task Kept_audio_stays_and_remote_speech_is_diarized_from_the_spool()
    {
        _diarizer = new FakeDiarizer([new DiarizedTurn(4, 0, 4)]);
        _transcriber = new FakeTimedTranscriber(_ => "one two three four five six seven eight nine ten");
        await using var controller = Controller();
        await controller.TakeNotesAsync();
        controller.KeepAudio = true;
        await TickAsync(controller, 5);
        // The loopback is read on its own task: stopping before it delivered left no remote
        // speech to diarize, which failed this test on slow CI runners.
        await WaitForAsync(() => controller.LiveSegments.Any(s => s.Source == AudioSource.System),
            "the remote channel to produce a segment");
        var id = controller.Current!.Id;
        await controller.StopAsync(StopReason.User);

        _diarizer.Calls.ShouldHaveSingleItem(customMessage: string.Join("\n", _log.Events.Select(e =>
            $"{e.Level} {e.Name} {e.Exception?.GetType().Name} {e.Exception?.Message} "
            + string.Join(",", (e.Fields ?? new Dictionary<string, object?>()).Select(p => $"{p.Key}={p.Value}")))));
        var saved = _store.Load(id)!;
        saved.KeepAudio.ShouldBeTrue();
        saved.Segments.Where(s => s.Source == AudioSource.System).ShouldAllBe(s => s.SpeakerId == "S1");
        saved.Speakers.Select(s => s.Id).ShouldBe(["me", "S1"]);
        File.Exists(MeetingAudioSpool.PathFor(_store.DirectoryFor(id), AudioSource.System)).ShouldBeTrue();
    }

    [Fact]
    public async Task A_notes_model_writes_notes_and_a_failing_one_leaves_none()
    {
        _notes = new ScriptedNotes(new FinalNotesDraft { Recap = "We said hello." });
        await using (var controller = Controller())
        {
            await controller.TakeNotesAsync();
            var id = controller.Current!.Id;
            await controller.StopAsync(StopReason.User);
            _store.Load(id)!.Notes.ShouldNotBeNull().Recap.ShouldBe("We said hello.");
        }

        _notes = new ScriptedNotes(null) { Failure = new InvalidOperationException("model crashed") };
        await using (var controller = Controller())
        {
            await controller.TakeNotesAsync();
            var id = controller.Current!.Id;
            await controller.StopAsync(StopReason.User);
            _store.Load(id)!.Notes.ShouldBeNull();
            _log.Events.ShouldContain(e => e.Name == "meeting.notes_failed");
        }
    }

    [Fact]
    public async Task An_interrupted_meeting_is_finished_at_the_next_launch()
    {
        var meeting = new MeetingRecord
        {
            StartedAt = _clock.Now,
            Speakers = [Speaker.Me(), Speaker.Others],
            Segments = [new TranscriptSegment { Source = AudioSource.Microphone, SpeakerId = "me", Start = 0, End = 4, Text = "a" }],
        };
        _store.Save(meeting);
        File.WriteAllBytes(_store.MarkerPath(meeting.Id), []);

        await using var controller = Controller();
        await controller.RecoverInterruptedAsync(CancellationToken.None);

        var recovered = _store.Load(meeting.Id)!;
        recovered.EndedAt.ShouldBe(meeting.StartedAt.AddSeconds(4));
        recovered.Segments.ShouldAllBe(s => s.IsFinal);
        _store.Interrupted().ShouldBeEmpty();
    }

    [Fact]
    public async Task Logs_carry_no_titles_or_transcript_text()
    {
        ZoomOnMic();
        await using var controller = Controller();
        await controller.TakeNotesAsync();
        await TickAsync(controller, 3);
        await controller.StopAsync(StopReason.User);

        var everything = string.Join("\n", _log.Events.Select(e => e.Name + " " + string.Join(",", (e.Fields ?? new Dictionary<string, object?>()).Select(p => $"{p.Key}={p.Value}"))));
        everything.ShouldNotContain("hello there");
        everything.ShouldNotContain("Zoom call");
    }

    private sealed class NotReadyTranscriber : ITimedTranscriber
    {
        public bool IsReady => false;

        public ValueTask<TimedTranscript> TranscribeTimedAsync(ReadOnlyMemory<float> samples, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("not loaded");
    }

    private sealed class ScriptedNotes(FinalNotesDraft? draft) : INotesModel
    {
        public Exception? Failure { get; init; }

        public string Name => "scripted";

        public bool IsAvailable => true;

        public Task<FinalNotesDraft?> WriteAsync(MeetingRecord meeting, CancellationToken cancellationToken) =>
            Failure is null ? Task.FromResult(draft) : throw Failure;
    }
}
