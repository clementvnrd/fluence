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

Same pipeline, after the Windows dictation app has run on real hardware.

| Piece | Windows |
|---|---|
| System audio | **NAudio 3.1** `WasapiRecorderBuilder().WithProcessLoopback(pid, IncludeTargetProcessTree)` — requires moving off the NAudio 2.3 pin. Loopback sends nothing during silence: pad from QPC timestamps. |
| Detection | Poll WASAPI capture sessions (`IAudioSessionManager2`, active sessions → PID) every 1 s + UI Automation for browser titles + calendar |
| Echo | LocalVQE / DTLN-aec via ONNX Runtime + the same dedupe |
| ASR | sherpa-onnx **1.13.8** Parakeet v3 int8 + `VoiceActivityDetector`, token timestamps |
| Diarization | `OfflineSpeakerDiarization` (pyannote seg 3.0 + embeddings) after the meeting; `SpeakerEmbeddingManager` for voice prints |
| Notes | Foundry Local (GA) or llama.cpp; Phi Silica on Copilot+ PCs only |
| Storage | DPAPI-wrapped AES-GCM key |

Merge, dedupe and word→speaker assignment are platform-neutral logic: give them shared
test vectors under `shared/`, like the dictionary.

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
