# FLU-86 — Internal audit: why Fluence loses to Wispr Flow in daily use

Read on `own-bench-flu-74` (main @ e14d5fa), FluidAudio 0.17.5 (`0b1f462`, read from an `git archive` copy in this folder, `fa/`). Code only: nothing built in the tree, the app was not launched, no history, meeting or dictionary content read. Settings read with `defaults read` (allowed keys only). Two probes (in `probe/`) ran the **real** `FluenceCore` cleanup code, plus a verbatim copy of one app-target function.

Clément's settings (non-personal keys): `engine = parakeet`, `dictationLanguage = fr`, `cleanupLevel = light`, `selectedMicrophoneUID = default`, `learnFromEdits = 1`, `learnFrequentTerms = 1`, `parakeetVocabularyBoost` **unset (→ off)**, `whisperModel = small` (not used), `historyRetention = forever`, push-to-talk = a ⌘+key combo.
Models on disk: `parakeet-ultra` 603 MB (in use), `parakeet-tdt-0.6b-v3` 461 MB (**unused**), silero-vad, localvqe, speaker-diarization. **No CTC model** → vocabulary boosting cannot run on this Mac, whatever the setting says.

Short version: the WER bench measures the model, and the model is fine. In daily use, text is lost or mangled **after** the model: a Light rule deletes whole sentences, the dictionary never reaches Parakeet, the auto-learning fills the dictionary with junk, the text is inserted with no idea of what is around the cursor, and a bad dictation can neither be re-run nor reported.

---

## 1. Pipeline map (dictation)

```
key down (HotkeyMonitor → PushToTalkGesture)                     DictationController.swift:1266
  └ beginDictation: ParakeetDownload.refresh() (disk walk), session, HUD .starting   :318-345
     └ startCapture → AudioCapture.start (AVAudioEngine, chosen device via setDeviceID,
        tap at input format, every channel downmixed, float32 at the device rate,
        NO voice processing, NO gain, NO ring buffer) → "Tink"                       AudioCapture.swift:87-126, DC:383
  └ prepare: engine.start() (Parakeet load 0.1–0.9 s warm, 15–20 s cold; audio waits in
     an unbounded AsyncStream = the only "pre-roll")                                  DC:390-488
  └ feed task: StreamConverter (AVAudioConverter → 16 kHz mono) → SpeechGate holds audio
     until 80 ms above −55 dBFS, then flushes in order; a 16 kHz copy is kept for retry  DC:807-871
key up → endDictation: target app + category read now; PostRoll 0–250 ms              DC:492-549, PostRoll.swift
  └ complete: gate verdict (tooShort <0.25 s → silent idle; silent → « Rien entendu »)  DC:553-573
     └ Parakeet: whole buffer in one AsrManager.transcribe(language: .french);
        >15 s → FluidAudio ChunkProcessor (fixed windows, 2 s overlap, token dedupe)  ParakeetEngine.swift:99-139
        └ vocabulary boost (CTC rescoring) only if setting on AND CTC model on disk   ParakeetEngine.swift:63-72,163-180
     └ empty → « Rien entendu »; loop → dropped + auto-retry on another engine        DC:592-627
  └ deliver → DictationPipeline: snippets → language → cleanup level
        none: trim | light: SpeechRepairs.before + RuleCleanup | medium/high: light, then
        Foundation Models (4 s timeout, CleanupGuard 0.6–1.5 ratio, else light)
     → SpeechRepairs.after → DictionaryCorrector (hear→write only) → snippets back    DictationPipeline.swift:28-91
  └ InsertTargetPolicy (same app as at release, else clipboard) → TextInjector:
        AX kAXSelectedText (verified by caret move) → ⌘V paste (transient, concealed,
        restored) → clipboard. No look at the text around the caret.                  TextInjector.swift:45-74
  └ EditWatcher (opt-in, 20 s AX polling) → EditLearner → proposals (in memory, user accepts)  EditWatcher.swift:42-94
  └ AutoLearningEngine.recordInjectedText: with learnFrequentTerms, adds « terms » itself  AutoLearningEngine.swift:38-81
  └ LatencyLog (memory), RunLog history (text, raw text, corrections), recording dropped  DC:780-795
```

Meetings: `MicCapture` (2nd AVAudioEngine, **system default input only**) + `SystemAudioTap` (process tap) → `ChannelPipeline` per channel: LocalVQE echo cancelling on speakers → Silero VAD (4096-sample = 256 ms hops) → `UtteranceSegmenter` (≤14.5 s, 0.1 s padding) → Parakeet per utterance (`language: nil`) → `DictionaryCorrector` → live You/Others → after the call `MeetingFinalizer` (offline diarizer on the system channel, consolidation, word→speaker, naming) → `TranscriptMerger` (mic-echo dedupe, Jaccard > 0.6 within ±1.5 s) → Foundation Models map-reduce notes (`NotesEngine`, 4 k context, retries). Never run on a real call (NOTETAKER.md:7).

---

## 2. Findings

Impact is for Clément's daily use (5 = loses or invents text often or silently). Effort: S ≤ 1 day, M a few days, L a week or more. "Bench" means `bench/french` or a unit test; "live" means a real dictation on his Mac.

### 2.1 Capture and end of speech

| # | Stage | Finding | Evidence | Impact | Fix | Effort | How to verify |
|---|---|---|---|---|---|---|---|
| C1 | Pre-roll | No ring buffer, by decision (ROADMAP "Not doing": no always-open mic). The mic opens on key-down, and the time until the first buffer is never measured. On the C920 or a Bluetooth headset (HFP switch, ~0.3–1 s) the first syllable can be lost. The "Tink" plays when `engine.start()` returns, **before** the first buffer arrives. | DC:342-345, 383; AudioCapture.swift:116-118 | 3 | Log key-down→first-buffer ms (diagnostic D1); play the Tink / show « listening » on the **first buffer**, not on `start()`; call `engine.prepare()` after `stop()` so the next start is faster (prepare does not open the mic). | S | Live: the log line on built-in mic, C920, AirPods |
| C2 | Device choice | Default is "system input". With AirPods connected, that is Bluetooth HFP (8/16 kHz, slow to open, and it degrades the music too). The bench shows the distant webcam costs +37 % errors for Ultra (SPEECH-MODELS.md:37). Nothing detects or steers this. | Settings.swift:292; AudioDevices.swift:56 (transport known); SPEECH-MODELS.md:76-81 | 4 | When the system input is Bluetooth, use the built-in mic (Wispr Flow does the same). Show the mic's name and type on « Rien entendu » and in the diagnostic. | S–M | Live |
| C3 | Format | `ParakeetDownload.refresh()` walks the model folder on the main actor **before** the mic opens, twice per key-down. | DC:18, 324 | 1 | Move it after `startCapture`. | S | Signpost |
| C4 | Gain / noise | No AGC and no denoise (the right call for ASR: Apple's voice processing hurts recognition). Parakeet normalises its features itself. The one untested lever for the webcam case is LocalVQE/denoise, which is already shipped for meetings. | AudioCapture.swift:87-126 | 2 | Bench only: run `fleurs-webcam` through LocalVQE (denoise only) and compare with raw. Keep raw if there is no gain. | S | Bench |
| C5 | Gate | SpeechGate (−55 dBFS, 80 ms) and the trailing-silence post-roll are conservative and lose no words (audio is held, then flushed). A noisy room keeps the full 250 ms. OK. | SpeechGate.swift:19-24; PostRoll.swift:15-45 | 1 | — | — | Existing tests |
| C6 | Very short | Under 0.25 s the dictation ends silently (`.tooShort` → idle, no message). A one-word « oui » held 0.2 s just vanishes. | SpeechGate.swift:19, DC:569-571 | 2 | Show a short « Maintenez la touche » notice the first few times. | S | Unit (CapsuleMessage) |

### 2.2 Engine

| # | Stage | Finding | Evidence | Impact | Fix | Effort | How to verify |
|---|---|---|---|---|---|---|---|
| E1 | Default engine | French gets Parakeet Ultra once downloaded, else Apple (correct, FLU-29/39). Clément runs Ultra. Greedy TDT, `language: .french` (only a **script** filter, not real language forcing). Same as the bench. | EngineDefault.swift:12-29; ParakeetEngine.swift:62,117; TokenLanguageFilter.swift:62-69 | — | — | — | — |
| E2 | **Vocabulary** | **The dictionary never reaches Parakeet by default.** Boost is off by default, its CTC model is only fetched from a settings toggle, and it is not on Clément's disk. So a dictionary **term** (a name with no `hear`) does **nothing** with Parakeet: `DictionaryCorrector` only runs `hear → write` corrections. This is the main thing Wispr's dictionary does better: it feeds the recogniser. | Settings.swift:331; ParakeetEngine.swift:65; CorrectionRule.swift:20; models folder (no `parakeet-ctc-110m`) | **5** (names, jargon) | (1) Add a boost mode to `fbench` (tech sets plus a dictionary of their terms) and measure in French: the CTC 110M spotter is an English-trained model (FluidAudio `CtcModels.swift:7-28`), so a French gain is not a given. (2) If it helps: download it with Parakeet (same consent card) and turn it on by default. (3) If not: say in the dictionary UI that terms only help Apple/Whisper, and suggest a `hear -> write` correction instead. | M | Bench (tech, tech-webcam) |
| E3 | Bias list | At most 40 phrases (`biasLimit`), user's entries **newest first**. Combined with A1 below, the newest entries are auto-learned junk, which pushes real names out. | BiasPhrases.swift:5,20-35; DictionaryStore.swift:103 | 3 | Only user-confirmed entries go first (needs a provenance flag), and raise the cap for Parakeet (CTC rescoring scales to hundreds of terms; measure the cost). | S | Unit (BiasPhrases) |
| E4 | Long dictations | Over 15 s, Parakeet goes through FluidAudio's fixed-window ChunkProcessor (2 s overlap + token dedupe), the very seams the meeting code avoids by cutting at pauses (NOTETAKER.md:29). Seams drop, glue or repeat words. The bench has a single 44 s clip. | ParakeetEngine.swift:117; FA `AsrManager+Transcription.swift:15`, `ChunkProcessor.swift:27-28`; UtteranceSegmenter.swift:44-47 | 3 | Over 14.5 s, cut the kept 16 kHz buffer at VAD pauses (Silero `VadManager` + `UtteranceSegmenter`, already shipped) and join the pieces. | M | Bench: concatenate FLEURS into 30/60/120 s clips, then WER with and without |
| E5 | Warm / unload | Unloaded after 10 idle minutes (FLU-31). The reload happens while the user talks, so it usually costs nothing, but a dictation shorter than the reload waits for it (0.13–0.9 s). | ModelResidency.swift:13; ROADMAP.md:102 | 2 | Keep the 10 min on battery; on AC power, 60 min. | S | Unit (ModelResidency) + signpost |
| E6 | Meetings + dictation | One shared `AsrManager` **actor**: a dictation's pass queues behind meeting utterances during a call. | ParakeetEngine.swift:391; ChannelPipeline.swift:410 | 2 | Measure first (latency log during a meeting). If it hurts, a second manager while a meeting records (+0.6 GB, so measure memory too). | S to measure | Live |
| E7 | Retry engines | Automatic retry after a failure goes to Apple or Whisper Small, both much worse in French (Whisper Small 24 % on webcam). | DictationController.swift:649-673; SPEECH-MODELS.md:40 | 2 | Retry Parakeet once on the same audio first when the failure is a loop/transient; Whisper Small never as automatic fallback in French. | S | Unit (DictationRetry) |

### 2.3 Cleanup (Light is Clément's level)

| # | Stage | Finding | Evidence | Impact | Fix | Effort | How to verify |
|---|---|---|---|---|---|---|---|
| L1 | **Light: cancel phrases** | **`backtrack` deletes everything before the last « supprime ça », « annule ça », « efface ça », « annule tout », « efface tout ».** These are ordinary French instructions. Probe, real code: « Si le fichier est trop vieux supprime ça et on recommence demain » → **« Et on recommence demain. »**; « Pour la réunion de jeudi annule ça s'il te plaît » → **« S'il te plaît. »**; « Le client a dit efface ça de la présentation » → **« De la présentation. »**. Only the English case is tested. | SpeechRepairs.swift:56-66 (regex :58-59); Tests/FluenceCoreTests/ClementBehaviourTests.swift:9 (only test) | **5** | Keep a cancel only when it is the **whole** dictation or comes right after a pause mark, as a separate command (« …, annule ça. »). Better: drop the French words and keep « scratch that », or require a « Fluence, … » prefix. Add the three sentences above to DoNoHarmTests as must-stay cases. | S | Unit (DoNoHarm, red first) |
| L2 | Light: repeats | « si si » → « si » (`emphaticAllowed` lacks si, là, vite, bla, toc, allez…). | SpeechRepairs.swift:140-145; probe | 2 | Add the common French emphatic doubles. | S | Unit |
| L3 | Light: stutters | A 2–4-letter word followed by a longer word with the same start is taken for a stutter: « le mail mailing » → « le mailing », « data dataset » → « dataset ». Rare but real with franglais. | SpeechRepairs.swift:217-238; probe | 2 | Need a pause or a word fragment (Parakeet writes « mai- »), or limit it to prefixes that are not words (check `OrdinaryWords`/TechLexicon). | S | Unit |
| L4 | Light: layout | Always capitalises the first letter and adds a final full stop, whatever the app and wherever the cursor is. That is right for a fresh paragraph and wrong mid-sentence or in a chat. Wispr adapts both from the text around the cursor and the app. | RuleCleanup.swift:41-44,105-113 | 4 | See I1 (context-aware insertion); at Light, no final stop in chat apps (`AppCategory` is already read at release). | S once I1 exists | Unit + live |
| L5 | Typography | U+00A0 before `; : ! ?` and in numbers, at every level, in terminals and code editors too (a `?` in a shell command gets a no-break space). | RuleCleanup.swift:44; FrenchTypography.swift:15-17; SpeechRepairs.swift:31-46 (developer mode doesn't undo it) | 2 | Skip French typography when `DeveloperTools.contains(bundleID)`. | S | Unit |
| L6 | Medium/High | The model session is created at release (no `prewarm()`), with a 4 s timeout. On an M2 a ~50-word clean-up plausibly takes 1–3 s, against Wispr's ~0.5–1 s. Its effect on French WER has never been benched (ROADMAP.md:201). The guard (ratio ≥ 0.6, invented words, commentary) is good. | FoundationModelFormatter.swift:33,61-111,137-148 | 3 | `LanguageModelSession.prewarm()` at key-down when the level uses the model; add a cleanup stage to the bench (P1) to see whether Medium helps or hurts in French. | S + M | Bench |
| L7 | What Light can't do | Light never fixes a misheard word (by design). Wispr's LLM pass does, using context (app, nearby text, names on screen). That is most of the "feels more accurate" gap that WER doesn't show. | CleanupLevel.swift:8-15 | 4 | Medium with **context**: give the model the dictionary names and the field's last sentence (AX, opt-in), and only accept word changes toward a dictionary spelling (CleanupGuard already counts invented words). | M–L | Bench + live |

### 2.4 Dictionary and learning

| # | Stage | Finding | Evidence | Impact | Fix | Effort | How to verify |
|---|---|---|---|---|---|---|---|
| A1 | **Auto-learn of frequent terms** (on for Clément) | It adds dictionary entries **from Fluence's own output**, unasked, after 2 uses. The test `rawWord.contains(".")` makes **every sentence-final word** a candidate, `-` makes every hyphenated French word one, and a capital after a full stop counts as "mid-sentence". Probe (verbatim copy): « Je pense que c'est peut-être prêt. Je t'appelle demain. Merci, à plus. » → `peut-être, prêt., Je, demain., Merci, plus.`; « Est-ce… Vas-y. On… aujourd'hui. » → `Est-ce, Vas-y., On, aujourd'hui.`. These become terms (« demain. » with its full stop), the newest entries, so they lead the bias list (E3), Apple's `contextualStrings` and Whisper's prompt. It also learns misrecognitions as « words ». | AutoLearningEngine.swift:47-81 (:59 the `.` test, :76 add); Settings.swift:341; DictionaryStore.swift:103,108 | **4** (dictionary trust; bias pollution) | Turn it off by default again for existing users, or fix it: strip trailing punctuation before the tests, drop `-`, judge capitals by sentence position, require ≥ 3 uses across ≥ 2 days, file entries as « proposals » (EditLearner's path) instead of `add`. Offer a one-click « retirer les termes appris automatiquement » (needs a provenance mark in the file, e.g. a `# auto` comment). Ask Clément to compare `dictionary.entries` in the diagnostic with what he remembers adding. | S | Unit (move the extractor into FluenceCore) |
| A2 | **Correction sheet** | « Corriger » saves **every** changed word as a global `hear → write` rule with no check: fixing « est » to « et » once rewrites every future « est ». EditLearner (tested) refuses exactly that (`isCorrection` needs a multi-word phrase, or ≥ 3 letters and not a common word). Also the sheet's **preview** compares by word position while the **save** uses LCS, so after an inserted word the preview shows different pairs from the ones saved. | AutoLearningEngine.swift:93-130; CorrectionQuickSheet.swift:136-153; EditLearner.swift:30-34,90 | **4** | Make the sheet use `EditLearner.proposals` for preview and save (one diff, the safe rules), and list what will be added with a checkbox each. Delete `computeWordDiff`/`computeLCSMatrix`. | S | Unit (EditLearner already tested) |
| A3 | Edit watcher | Works for native fields. It gives up on Electron apps and terminals (where Clément dictates a lot), proposals live in memory only (gone at quit), and nothing reaches Parakeet anyway while boost is off (E2). | EditWatcher.swift:7-17,62-94 | 3 | After E2: an accepted proposal becomes a correction when the heard form is known. Keep proposals across launches inside the Vault. | S–M | Unit + live |
| A4 | Dictionary pass | Literal, NFC, fenced, longest first: solid. Meetings use it too. Attendee names are never used for correction or bias (ROADMAP idea « Meeting vocabulary »). | DictionaryCorrector.swift:39-58; ChannelPipeline.swift:452 | 2 | Pass calendar attendees and the call window's names as bias/corrections for that meeting (after E2). | M | Meeting bench (does not exist yet) |

### 2.5 Insertion

| # | Stage | Finding | Evidence | Impact | Fix | Effort | How to verify |
|---|---|---|---|---|---|---|---|
| I1 | **No context at the cursor** | The text goes in exactly as cleaned: no leading space and no lower-casing. Two dictations in a row in the same field give « Bonjour.Comment ça va ? »; a dictation into the middle of a sentence gives « …je pense que Le budget est validé. ». Wispr handles both, and it is the most visible daily difference after accuracy. | TextInjector.swift:45-74 (no read of the text before the caret; grep finds no such code) | **4** | Before inserting, read the character before the caret (`kAXSelectedTextRange` + `kAXStringForRangeParameterizedAttribute`, already-granted AX, no storage). Pure policy in FluenceCore (`InsertSpacing`): add a space after a letter or a mark, lower-case the first word when the previous one is not a sentence end (unless the word is a name in the dictionary), drop the final full stop when text follows the caret. For the paste route with no AX read (Electron): remember the last dictation's target and time, and add a space when it is the same app within 2 min. | M | Unit (policy) + live in Notes, Slack, VS Code, Chrome |
| I2 | AX route | The AX write counts only once the caret moves; otherwise it pastes, with transient/concealed types, and restores the clipboard by changeCount. Sound. | TextInjector.swift:103-150,210-249 | 1 | — | — | — |
| I3 | Focus change | The text is only typed into the app that was in front at release, else it goes to the clipboard with « Copié — ⌘V » (FLU-29). Correct. | DC:757-777 | — | — | — | — |

### 2.6 History, retry, trust

| # | Stage | Finding | Evidence | Impact | Fix | Effort | How to verify |
|---|---|---|---|---|---|---|---|
| H1 | **No retry of a bad success** | The recording is kept 60 s only when the engine **failed**. A dictation that came out wrong but non-empty drops its audio at once, so « réessayer » (another engine, Medium, no cleanup) is impossible. Wispr keeps audio in history and offers retry. | DC:787-788; CapsuleMessage.swift:339-345 | 4 | Keep the last recording in memory for 60 s after a success too. ⌃⌘R or the history card's « Réessayer » replaces the just-typed text (select-back through AX, or retype) with another engine or level. | S–M | Live |
| H2 | Raw vs final | History stores `rawText` when cleanup changed it: good for spotting L1-type deletions, but the UI does not show "N words removed". | DC:1062-1072; RunLog.swift:22-25 | 3 | Show the word count before and after cleanup on the history card; flag it when more than 20 % of the words were removed. | S | Unit |

### 2.7 Meetings

| # | Stage | Finding | Evidence | Impact | Fix | Effort | How to verify |
|---|---|---|---|---|---|---|---|
| M1 | Mic | The meeting mic is **always the system default input**; the dictation mic choice is ignored. It also taps at `inputNode.outputFormat`, the very pattern FLU-62 fixed in dictation (harmless on the default device today, wrong the day a device choice is added). That makes two capture implementations with diverging fixes. | MicCapture.swift:12,70-78 vs AudioCapture.swift:92-113 | 3 | Reuse AudioCapture's device selection and `inputFormat` (one capture class, or a shared helper). | M | Live |
| M2 | VAD onsets | Silero on 256 ms hops; an utterance starts at the first hop ≥ 0.5 **minus only 0.1 s** padding. A word whose onset falls in the previous hop can lose its first ~100–150 ms (hypothesis: no meeting bench). | UtteranceSegmenter.swift:37-48; MeetingSpeechModels.swift:24 | 3 | Padding ≥ one hop (0.3 s) at the start; keep 0.1 s at the end. | S | Unit (segmenter vectors) + meeting bench |
| M3 | Cuts | Continuous speech past 14.5 s is cut at the least likely hop in the second half, inside a word if nobody pauses. | UtteranceSegmenter.swift:30-31,47 | 2 | 0.5 s overlap between forced pieces and a word-level dedupe (TranscriptMerger already has the tools). | M | Bench |
| M4 | Language | Meeting utterances use `language: nil`, while dictation passes `.french`. | ChannelPipeline.swift:439 vs ParakeetEngine.swift:117 | 1 | Pass the dictation language (or the calendar locale). | S | Bench |
| M5 | Echo | LocalVQE is beta; speakers + built-in mic is the hard case. Jaccard dedupe is the backstop. Never measured on a call. | ChannelPipeline.swift:294-347; NOTETAKER.md:178-183 | 3 | The meeting bench from NOTETAKER §5 (WER + cpWER/DER, headphones vs speakers) before any tuning. | L | Meeting bench |
| M6 | Notes | Foundation Models (~3 B, 4 k context) with map-reduce, retries and a "transcript only" fallback; well guarded. Summary quality is below a cloud LLM, and nothing measures it. | NotesEngine.swift:81,271-317; NOTETAKER.md:227-250 | 2 | A handful of reference meetings with expected decisions/actions; score recall. | M | Meeting bench |
| M7 | Status | The whole pipeline has never run on a real call. | NOTETAKER.md:7; ROADMAP.md:199 | 4 (trust) | One supervised real call (Meet in Chrome, headphones, then speakers) with the diagnostic below. | S | Live |

---

## 3. Settings whose defaults are probably wrong for a French user on an M2

| Setting | Default / his value | Problem | Proposal |
|---|---|---|---|
| `parakeetVocabularyBoost` | off; CTC model not downloaded | Dictionary terms are inert with Parakeet (E2). | Bench it, then on by default with the Parakeet download. |
| `learnFrequentTerms` | off by default, **on for Clément** | Fills the dictionary with sentence-final words and hyphenated French words (A1). | Fix it, or force it off for everyone until fixed, and purge. |
| `selectedMicrophoneUID` | `default` (system) | With AirPods: HFP; with the C920: +37 % errors (C2). | Built-in mic when the system input is Bluetooth; the HUD/diagnostic names the mic. |
| `cleanupLevel` | light | Fine as a default, but Light runs L1 (deletions) and L4 (forced capital/stop). | Fix L1/L4; bench Medium in French before suggesting it. |
| `soundEnabled` | on | The Tink plays before the first buffer (C1), and the built-in mic records it. | Play it on the first buffer. |
| Idle unload | 10 min | Reload on the first dictation of each burst (E5). | 60 min on AC power. |
| Retry engine | Apple / Whisper Small | Much worse in French (E7). | Parakeet again first. |
| `historyRetention` | his value: forever | Not accuracy; noted only. | — |
| Disk | v3 (461 MB) kept | Unused since Ultra. | Remove it with Réglages' model list (`SpeechModelStore.swift:24`). |

---

## 4. Dead or duplicated code

- `AutoLearningEngine.learnCorrection` + `computeWordDiff` + `computeLCSMatrix` (AutoLearningEngine.swift:93-210) duplicate `EditLearner.replacedBlocks` (FluenceCore, tested) without its safety rules. `CorrectionQuickSheet.detectedCorrections` (CorrectionQuickSheet.swift:136-150) is a **third** diff (positional) used only for the preview. → one diff: EditLearner.
- `PassthroughFormatter` (TextFormatter.swift:28): no caller.
- `Settings.cleanupEnabled` / `Settings.smartCleanup` computed setters (Settings.swift:356-379): no caller; the migration reads the raw keys directly.
- Two capture classes, `AudioCapture` and `MicCapture`, with diverging device and format handling (M1).
- `prompt-design.txt` at the repo root: an old prompt log, not code.
- `bench/` (root: Apple vs Parakeet v2/v3, recorder, HTML dashboard) predates `bench/french` and is mostly upstream-era (AGENTS.md:27-28, 62.9 % upstream lines); probably superseded.
- The French cancel words in `SpeechRepairs.backtrack` have no tests at all (L1).
- On disk, not in the repo: the `parakeet-tdt-0.6b-v3` model.

---

## 5. Missing diagnostics that need no text

What exists: `DiagnosticExport` (settings, counts, process-time medians, error kinds), `LatencyLog` (memory only, log lines), signposts. Missing: **one dictation's story**. Clément can't say "this one was bad" without pasting its text. Proposal D1: a fixed-field record per dictation (last 20, in memory, or inside the Vault with the history), shown on the history card as « Copier le diagnostic », plus a « Mauvaise dictée » button that adds one tag (mot manquant / mot inventé / nom propre / ponctuation / coupé au début / coupé à la fin) to the diagnostic export.

Fields (numbers and fixed words only):
- engine **actually used** (`activeEngine`, Apple standing in or not; DiagnosticExport.swift:91 reports the *selected* engine), model version, model was cold / warm / reloaded + load ms, boost: on / model missing / N replacements;
- mic: built-in / USB / Bluetooth / other, device sample rate, channel count, **captured seconds vs seconds sent to the engine** (the FLU-62 symptom, 0.36×), key-down → first buffer ms;
- levels: peak dBFS, speech RMS dBFS, noise floor dBFS, clipped-sample share, SpeechGate active seconds;
- post-roll ms + reason, engine ms, cleanup ms, key-up → text ms;
- cleanup: level, path (rules / model accepted / rejected: reason / timeout / unavailable), **word count raw → after cleanup → after dictionary**, repairs fired by name (backtrack, dedupe, stutter, lists), corrections count, snippets count;
- language used, app category, insertion route (AX verified / paste / clipboard: reason), seconds held, hands-free or hold.

`DiagnosticReport` already refuses non-token values, so the same renderer can carry it. Also add to the export: `parakeetReady`, `ctcModelOnDisk`, and the share of dictations with > 20 % of their words removed by cleanup.

---

## 6. Gaps in the bench that let these through

P1. `fbench` feeds files straight to the engine (bench/french/Sources/fbench/main.swift:74-81) and scores after stripping punctuation (SPEECH-MODELS.md:11-12). It never sees the app's resampling (48 kHz capture → `StreamConverter`), the gate, the cleanup or the dictionary. **L1 cannot show up in any WER number Fluence has.** Add a `--pipeline` mode: 48 kHz input through `StreamConverter`, then `LightCleanup` + `SpeechRepairs.after` + a dictionary, scored three ways: raw, final, and **words deleted by cleanup**. Add a set of ordinary French sentences that contain the risky words (« supprime ça », « si si », « en fait », « point »), spoken by the macOS voices.
P2. A boost mode (E2), long concatenated clips (E4), and webcam + LocalVQE (C4).
P3. A meeting bench (NOTETAKER §5), still missing; needed for M2, M3, M5 and M6.

---

## 7. Top 10 fixes, ranked (impact ÷ effort)

| Rank | Fix | Findings | Effort | Verified by |
|---|---|---|---|---|
| 1 | **Stop « supprime/annule/efface ça » from deleting the sentence**: whole-utterance or after-pause only, plus must-stay DoNoHarm cases | L1 | S | Unit, red first (the three probe sentences) |
| 2 | **Fix or switch off frequent-term auto-learning**, mark auto entries, one-click purge; learned entries go through proposals | A1, E3 | S | Unit (extractor moved to FluenceCore) |
| 3 | **Correction sheet on EditLearner** (one diff, no common-word rewrite rules, checkbox per entry) | A2 | S | Unit |
| 4 | **Context-aware insertion**: leading space, lower-case mid-sentence, no final stop before following text; chat apps without a final stop | I1, L4 | M | Unit (policy) + live in 4 apps |
| 5 | **Bench, then enable, Parakeet vocabulary boosting** (or tell the truth in the UI that terms do nothing with Parakeet) | E2, A3 | M | Bench (tech, tech-webcam) |
| 6 | **Per-dictation diagnostic + « Mauvaise dictée »** without text | §5 | M | Self-test (no text leaks) |
| 7 | **Keep the last successful recording 60 s; « Réessayer » replaces the typed text** | H1, E7 | S–M | Live |
| 8 | **Pipeline mode in fbench** (resampling + cleanup + dictionary, deleted-word count) | P1 | M | Itself; would have caught L1–L3 |
| 9 | **Mic sanity**: built-in instead of Bluetooth input; Tink on the first buffer; key-down→first-buffer logged; meetings use the chosen mic and `inputFormat` | C1, C2, M1 | S–M | Live |
| 10 | **Long dictations cut at VAD pauses** instead of FluidAudio's fixed windows | E4 | M | Bench (30/60/120 s clips) |

Next after the ten: FM `prewarm()` + a cleanup bench for Medium (L6), the L2/L3/L5 small rule fixes, meeting VAD padding (M2), the first real supervised call (M7).

---

## 8. Not checked / limits

- Nothing was run live; no audio from Clément exists to replay. Timings for C1 (first buffer), E6 (contention) and L6 (FM latency) are estimates to measure, not measurements.
- The French effect of FluidAudio's CTC 110M boosting is unknown (E2); it may help little.
- The size of A1's pollution in his real dictionary was not looked at (privacy rule). The diagnostic's `dictionary.entries` count is the way to see it.
- `swift test` was not run (no code changed). The probes used the real FluenceCore sources (L1–L3) and a verbatim copy of the app-target function (A1).
- The meeting findings are from code reading only; M2 is a hypothesis.
- AVAudioConverter's sample-rate quality setting (default) was not compared with `.max`; small expected effect.
