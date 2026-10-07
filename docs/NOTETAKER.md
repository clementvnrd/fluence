# Meeting Notetaker — design

A local, bot-free meeting note-taker: detect the meeting, capture **my voice (mic)** and
**everyone else (system audio)**, transcribe on-device, attribute every word to a named
speaker, and produce notes. Nothing leaves the machine.

Status: **built for macOS (milestones 1–3), never run on a real call yet.** The pure logic
(`FluenceMeetingCore`, `FluenceNotesCore`) is unit tested and shares
`shared/meeting-test-vectors.json` with the future Windows port; the app code is compiled by
CI. Windows (milestone 4) is not started. Versions checked 2026-10-07.

### Where things are

| Piece | Code |
|---|---|
| Model, merge, echo dedupe, word→speaker, naming, VAD cutting | `Sources/FluenceMeetingCore/` |
| Detection (mic in use, browser titles, calendar) | `Notetaker/MeetingDetector.swift`, `CalendarContext.swift`, `MeetingWindowReader.swift` |
| Capture (process tap, meeting mic, encrypted spool) | `SystemAudioTap.swift`, `MicCapture.swift`, `MeetingAudioSpool.swift` |
| Echo cancellation, VAD, Parakeet per utterance | `ChannelPipeline.swift`, `MeetingSpeechModels.swift` |
| Final pass: diarization, naming, voice prints | `MeetingFinalizer.swift`, `VoicePrintStore.swift` |
| Orchestration and panels | `MeetingController.swift`, `MeetingSession.swift`, `MeetingPanels.swift` |
| Notes (Foundation Models map-reduce), library, export, settings | `Notetaker/Notes/`, `Notetaker/Library/`, `Notetaker/Settings/`, `Sources/FluenceNotesCore/` |
| Encrypted storage | `MeetingStore.swift` |

The panels, the meetings library and the Réunions settings tab are in French and use the
app's design system (Clement's look, `AGENTS.md` ▸ Design system) since FLU-11; a fuller
redesign of these screens is FLU-12.

Deviations from the design below: utterances are capped at **14.5 s** (Parakeet's single-pass
window, to avoid FluidAudio's chunk seams); live labels are **You / Others** by channel and
speaker names arrive with the final pass (no live diarizer); voice prints only match
calendar attendees.

## Decisions (FLU-9, Clement, 2026-10-07)

| # | Decision |
|---|---|
| 1 | Hardening first (FLU-1…FLU-4), then the Notetaker (FLU-6…FLU-8). |
| 2 | Meeting audio is **not kept** by default; a per-meeting checkbox keeps it. |
| 3 | Voice prints are **opt-in, off by default**; names come first from Zoom/Teams/Meet and the calendar. |
| 4 | FluidAudio is upgraded 0.15.6 → 0.17.5 at the start of the Notetaker. |
| 6 | The product is named **Fluence**. |
| 7 | Windows hardware testing later; the Windows port (FLU-10) waits. |

---

## 1. What Wispr Flow does, and where we differ

Wispr Flow Notetaker (macOS since 2026-08-05, Windows since 2026-09-15):

- Bot-free: records mic + system audio locally, **transcribes and summarises in the cloud**.
- Detection: Google/Outlook calendar reminders + "automatically detect any call", with a
  *Meeting detected* card and a 5–60 s countdown (default 10 s); browser meetings need
  Accessibility. Shortcut ⌥M. Stops on call end, 10 min of silence, event end, max 2–3 h.
- Speakers: live labels "You / Others" by audio source; names read from **Zoom/Teams/Meet
  display names via Accessibility**; numbered elsewhere; rename once, applied everywhere;
  post-processing removes mic echo. Independent reviews rate attribution its weakest part.
- Notes: Recap, Next Steps (owner + verb), Decisions, Transcript; "My thoughts" side notes;
  Ask-your-meetings chat; Markdown export; MCP access.
- Consent: automatic notice posted in the meeting chat (default on).
- 22 languages for Notetaker. Transcripts kept forever by default, audio 7 days.

**We keep** the UX (detection card + countdown, You/Others by channel, names from the
meeting window, rename-once, Recap/Next steps/Decisions, Markdown export, consent notice).
**We differ** on processing: everything on-device, audio discarded by default, encrypted
storage, and real acoustic diarization of the remote side instead of relying on display
names alone.

---

## 2. Architecture (macOS first)

```
 Detector ──► MeetingSession ◄── Calendar (EventKit, attendees)
                 │
      ┌──────────┴──────────┐
  MicCapture            SystemCapture (Core Audio process tap,
  (AVAudioEngine)        scoped to the meeting app)
      │                      │  (reference)
      ▼                      │
  Echo canceller ◄───────────┘   FluidAudio LocalVqeManager, bypassed on headphones
      │                      │
  VAD (Silero)          VAD (Silero)
      │                      │
  ASR per utterance     ASR per utterance          Parakeet v3 / ultra, word timings
      │  speaker = Me         │
      │                  Diarizer (system channel only)
      │                      │  speaker = S1…Sn → names
      └──────► Merger ◄──────┘   time-ordered, dedupe mic/system echo
                 │
          Encrypted store ──► Notes (Foundation Models map-reduce) ──► Markdown export
```

### 2.1 Detection
- Listener on `kAudioDevicePropertyDeviceIsRunningSomewhere` (same signal as the orange
  mic dot) → enumerate audio process objects, filter `kAudioProcessPropertyIsRunningInput`
  → PID → bundle ID. Poll per-process properties on device change; their own listeners are
  unreliable.
- Browser meetings (Meet in Chrome/Arc/Safari): read window/tab titles through
  **Accessibility**, which the app already holds — not `CGWindowList`, which needs Screen
  Recording.
- EventKit: match an event with a conferencing URL in the current window; gives title and
  attendees.
- UX: *Meeting detected* card, cancellable countdown, **never record silently**.
  Reference implementation: Hyprnote/anarlog `crates/detect`.

### 2.2 Capture
- System audio: **Core Audio process tap** (`CATapDescription.bundleIDs`, macOS 26) →
  private aggregate device hosted on the **built-in output** (survives Bluetooth profile
  switches). Permission: `NSAudioCaptureUsageDescription` (TCC "System Audio Recording
  Only"), lighter than Screen Recording. Browsers render from helper processes: tap the
  whole helper family, resolved at runtime. Reference: insidegui/AudioCap.
- Known traps: permission denied = `noErr` + all-zero buffers; taps can go silent after a
  sample-rate change or AirPods sleep → **zero-buffer watchdog** that rebuilds the tap when
  the meeting app is outputting but samples are zero for N seconds.
- Mic: a second `AVAudioEngine`, independent of the dictation one. Both streams stamped on
  the host clock (`AudioChunk` gains `hostTime` and `source`).
- ScreenCaptureKit only as a fallback.

### 2.3 Echo and bleed
On speakers, the mic hears the remote side → duplicated text attributed to "Me".
1. `LocalVqeManager` (FluidAudio ≥ 0.17.5, Apache-2.0, **beta**): `enhance(mic:reference:)`
   with the tap as reference; ~1.2 ms per 16 ms hop. Bypassed when output is headphones.
2. Backstop, always on: drop a mic segment whose normalised tokens match a system segment
   (Jaccard > 0.6 within ±1.5 s).

### 2.4 Transcription
- Per channel: **Silero VAD** (`VadManager`) → utterances capped at 15–25 s → Parakeet per
  utterance → word timings offset by utterance start. Avoids chunk-seam errors (dropped,
  glued or duplicated words) that FluidAudio documents for fixed windows.
- Model: Parakeet v3 (25 EU languages incl. French, auto language ID, FLEURS FR ≈ 5 % WER),
  or **Parakeet ultra** (FluidAudio ≥ 0.17.3, same API, better on all 24 measured languages).
  Not Phonon-2 (English-only).
- Dictionary: `DictionaryCorrector` per segment; FluidAudio `CustomVocabularyContext` for
  biasing Parakeet (also fixes the dictation gap).
- Live transcript in a window that never takes focus; final pass replaces it.
- Memory bounded: audio spooled to an encrypted temp file, never one growing `[Float]`.

### 2.5 Speaker diarization and naming
- **Mic = Me. Diarize the system channel only.** Fewer speakers to separate, and my own
  voice can never be split into clusters.
- Live: Sortformer (4 slots) or `Nemotron3Diarizer` (8 speakers, ~2.9 s latency — **licence
  to check**: final model OpenMDW 1.1, preview evaluation-only; French untested).
- Final, after the meeting: `OfflineDiarizerManager` (pyannote-style segmentation +
  WeSpeaker + VBx; 15.1 % DER on VoxConverse at 122× real-time) relabels everything.
- Word → speaker: each word goes to the speaker with the most activity over its time span.
- Names, in order of confidence:
  1. Display names read from the Zoom/Teams/Meet window via Accessibility, matched to the
     active-speaker indicator over time (what Wispr and Granola do).
  2. Opt-in **voice prints** (256-d embeddings), matched by Hungarian assignment
     restricted to calendar attendees, confirmed by the user the first time.
  3. Calendar attendees as the candidate list and the speaker-count hint.
  4. Manual rename, applied to every segment of that speaker and remembered.
- Voice prints are **biometric data (GDPR art. 9)**: explicit opt-in, per-person delete,
  never exported, wiped by "delete everything".

### 2.6 Notes
- Apple Foundation Models: 4,096-token context shared by prompt and output → **map-reduce**.
  Chunks of ~2.5 k tokens on speaker-turn boundaries; map = `@Generable` extraction
  (decisions, action items with owner and due date, open questions, quotes with
  timestamps); reduce = merge + final prose. Size chunks with `tokenCount(for:)`.
- Output: Recap, Next steps, Decisions, full Transcript with speakers and timestamps, my
  side notes. Templates (1:1, client call, stand-up) as prompt presets.
- Search across meetings (local full-text index). Export Markdown; copy uses concealed /
  transient pasteboard types.
- Fallback when Foundation Models is unavailable: transcript only, no invented summary.

### 2.7 Data protection
- Per-meeting AES-256-GCM key, wrapped by a master key in the Keychain
  (`WhenUnlockedThisDeviceOnly`); deleting a meeting destroys its key.
- Raw audio **not kept** by default: encrypted spool until the final diarization pass, then
  deleted. Keeping audio is an explicit per-meeting choice.
- Retention setting for transcripts/notes; purge on launch; data folder excluded from
  Spotlight and backups.
- No transcript text, names or e-mails in logs.
- Consent: visible recording indicator, one-click consent notice (FR/EN) to paste in the
  meeting chat, "mic only" mode. France: Code pénal art. 226-1 (recording private speech
  without consent).

---

## 3. Windows

Status (FLU-10, 2026-10-07): **implemented and tested on fakes and on macOS, not yet run on
Windows hardware.** Same pipeline as macOS; the platform-neutral logic is a C# port that runs
the same `shared/meeting-test-vectors.json`. Code: `windows/src/Murmur.Meeting` (the port of
FluenceMeetingCore and the notes core), `windows/src/Murmur.Core/Meetings` (pipeline, store,
controller), `windows/src/Murmur.Speech` (sherpa-onnx), `windows/src/Murmur.Platform.Windows`
(loopback and detection bindings only).

| Piece | Windows, as built |
|---|---|
| System audio | **Process loopback** (`ActivateAudioInterfaceAsync("VAD\Process_Loopback")`, build ≥ 20348) on the call's process tree, trying 16 kHz float, 16 kHz s16, then 44.1 kHz stereo; falls back to **whole-system loopback** (the recording panel says so). NAudio stays on **2.3.0**: its public `IAudioClient` / `AudioCaptureClient.GetBuffer` with QPC timestamps are enough, and only `ActivateAudioInterfaceAsync` is P/Invoked (3.1 would also drag `System.Numerics.Tensors`, which the publish glob drops). Loopback delivers nothing during silence: a heartbeat pads the timeline up to 0.5 s ago — only once the loopback has been quiet that long, so late packets are never trimmed as overlaps — and packet timestamps place speech. |
| Microphone | A second WASAPI capture beside dictation's, timed by sample count (not arrival). |
| Detection | Every second: active WASAPI **capture sessions** → process names (Teams, Zoom, Webex, Slack, Discord, GoTo), and for browsers the **visible window titles** (Meet, Teams, Zoom, Webex…). One offer per call; "Not now" holds until the app releases the microphone. **No UI Automation**: a call in a background browser tab is missed. **No calendar** on Windows. |
| Card and panel | Always-on-top panel: "<service> call detected", visible countdown (default 10 s, or wait for a click), Record / Not now; then the recording strip with the **red lamp lit only while recording**, counter, Stop, **Keep audio**, and **Consent FR / EN** keys copying the macOS `ConsentNotice` text word for word (a test compares it with the Swift source). The panel cannot be closed while recording. |
| Echo | **No echo canceller on Windows yet.** The text dedupe (`TranscriptMerger`) is the backstop, as on macOS. |
| ASR | sherpa-onnx **1.13.8** (from 1.13.5): Silero VAD (512-sample hops into the ported segmenter; energy fallback when not installed) + Parakeet with token timestamps. Token durations from 1.13.8 are unreliable, so a word ends at the next token's start (capped). SentencePiece pieces are merged into words, then the dictionary corrects. |
| Diarization | After the meeting, on the **system channel only**: `OfflineSpeakerDiarization` (pyannote segmentation 3.0 + WeSpeaker ResNet34-LM), cluster threshold **0.45** (measured on one two-speaker clip: 0.5 merged both, 0.4 split one), on the speech only. Word → speaker as on macOS. Without the models, remote speech stays "Others". |
| Voice prints | **Opt-in, off by default**, sealed with the meetings key, deletable (turning the setting off deletes all). They are only ever matched against **calendar attendees**, and Windows has no calendar source, so on Windows **names come from the user's renames only**; a rename still enrols the voice for the day a calendar exists. |
| Notes | Behind `INotesModel`. The default is **no model → no notes, never invented**: the Meetings window and the export say so. The macOS map-reduce prompts are not ported yet (nothing on Windows would run them). |
| Storage | `%LOCALAPPDATA%\Fluence\meetings`: a master key wrapped by **DPAPI** (the FLU-2 history crypto), one **AES-256-GCM key per meeting** wrapped by it, the meeting and the index sealed, the audio spooled in sealed one-second records bound to meeting, channel and index. The spool is deleted after processing unless Keep audio. Retention (Forever / 7 / 30 / 90 days / 1 year, default Forever) purges at launch and on change; "Delete all meetings" in Settings and the Meetings window. No DPAPI → nothing is recorded (no plaintext fallback). |
| Meetings window | MEETINGS section of the main window: search (decrypts, case- and accent-insensitive), transcript with speakers and timestamps, rename a speaker everywhere, Copy as Markdown, Export (the macOS `MarkdownRenderer`, ported with its tests), Delete. |
| Stops | Stop, the call releasing the microphone for 30 s, 10 min of silence, 180 min, workstation lock. A crashed recording is finished from its spool at the next launch. |

Optional models and their pinned hashes: `docs/PARAKEET-WINDOWS.md` → Meeting models.
The WeSpeaker weights' licence must be confirmed before Fluence redistributes them.

**Not verified until it runs on Windows:** process-loopback activation and the formats it
accepts, capture-session enumeration and the process names Teams/Zoom actually use, window
titles of real calls, microphone/loopback clock drift over an hour, DPAPI for the meetings
key, the panel's placement and focus behaviour. `Fluence.exe --selftest` checks the store,
the sherpa VAD/diarization types, loopback activation and session enumeration on a real
machine; the first real test should then be a short Teams call.

---

## 4. Milestones

1. **Capture & local transcript** (macOS): detection, dual capture, AEC + dedupe, VAD +
   Parakeet per channel, live "Me / Others" transcript, encrypted store, consent.
2. **Speakers**: system-channel diarization, word→speaker, names (window, attendees,
   voice prints, rename).
3. **Notes**: map-reduce summary, templates, search, Markdown export, retention.
4. **Windows port**.

## 5. Evaluation

"Complete and perfect transcription" needs a number. Before milestone 2, add a meeting
benchmark to `bench/`: a handful of real recordings (FR and EN, headphones and speakers,
2–6 speakers) with reference transcripts, scored on **WER** and **cpWER / DER** (speaker
attribution). Every change to VAD, AEC, model or diarizer is judged against it.
