# Fluence

Push-to-talk dictation for macOS. Hold a key, talk, release — cleaned-up text
lands in whatever text field has focus. The macOS app is in French, in Clement's own look:
light canvas, rounded white cards, an aqua-blue accent and the Aqua orb (see the design
system in [`AGENTS.md`](AGENTS.md)). A Wispr Flow-shaped app, built native and **fully
on-device**: speech, cleanup and storage never leave the machine.

**Status (October 2026).** Dictation works end to end and was in daily use under the app's
previous name. The October 2026 hardening (encrypted history, no transcript text in logs,
safe clipboard, no clipped words, session races, device changes) is typechecked and unit
tested but has not yet been exercised by hand. Audit: [`docs/AUDIT-2026-10.md`](docs/AUDIT-2026-10.md).

---

## Installing a release (for someone who is not building it)

Download `Fluence-<version>.zip` from the release page, unzip it, drag **Fluence** to
Applications. It needs a Mac with Apple silicon on macOS 26 or newer. The build is signed
but **not notarized** (no Developer ID, FLU-39), so macOS blocks the first launch of a
downloaded copy until System Settings › Privacy & Security › *Open Anyway*; updates then
install without that step. The step-by-step guide, in French:
[`docs/installer-sur-un-autre-mac.md`](docs/installer-sur-un-autre-mac.md). The licences of
what Fluence is built on are in [`Resources/THIRD-PARTY-NOTICES.txt`](Resources/THIRD-PARTY-NOTICES.txt)
(`make notices` regenerates it).

## Quick start (building it yourself)

```bash
make install   # compile, bundle, sign, then quit the old copy, replace it in /Applications, launch
```

Needs **Xcode 26** (the Command Line Tools alone cannot compile SwiftUI's `@State` macro).
It needs two permissions for normal use, granted by you in a macOS prompt or System Settings:

| Permission | Granted in | Used for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | The AX text insert and ⌘V paste; the event tap for Esc, ⌃⌘V/⌃⌘C and modifier-only shortcuts |
| **Microphone** | The macOS prompt, the first time Fluence needs it (after a refusal: System Settings) | Recording your voice, for dictation and for the meeting notes |

On first launch a **Set up Fluence** window walks through both, plus the two optional grants
the meeting notes use (System Audio Recording, Calendar): what each is for, a lamp that lights
when it is on, one button to the right System Settings pane, and it moves on by itself once a
grant lands. Reopen it any time from the menu bar: *Set up Fluence…*

A shortcut with a key (the default **⌥ Espace**) is registered with Carbon and works at once,
even before Accessibility is granted (the paste then goes through System Events); the event
tap arms itself as soon as Accessibility is granted — no restart. Hold **⌥ Espace** and talk.

### Shortcuts

| Press | Does |
|---|---|
| Hold the shortcut (⌥ Espace by default) | Dictate; let go to type |
| Tap the shortcut | Hands-free: keeps recording until the next press |
| Press again (or the HUD's ✓) | End hands-free and type |
| Modifier-only shortcut (e.g. ⌃ ⌥) + Space | Hands-free, from a hold |
| Esc | Cancel the dictation in progress — nothing is typed |
| The Command Mode shortcut (⌘ ⌥ by default) | **Command Mode**: say how to change the selected text ("make it shorter", "traduis en anglais"); with nothing selected, the whole field is rewritten |
| ⌥L | Switch the dictation language (Français ⇄ English, ⇄ Auto with Whisper) |
| ⌃⌘V / ⌃⌘C | Paste / copy the last transcript |

Both shortcuts are recorded in Réglages ▸ Général and IA & Formatage: any combination of at
least two keys (a modifier and a key, or two modifiers).

Space and Esc are only swallowed while they act on a dictation; otherwise they reach the app
as usual. Command Mode rewrites with Apple Intelligence on this Mac — never in the cloud —
refuses password fields, and replaces nothing if the selection changed while it worked. Its
shortcut and the ⌃⌘V / ⌃⌘C pair are in Réglages; Réglages ▸ Raccourcis lists every gesture.

The bundle ID is `io.github.clementvnrd.fluence`. Settings, dictionary, history and snippets
from the app's previous identity (`ai.pivotstudio.murmur-youtube`) migrate on first launch,
**file by file** (FLU-11): `MurmurYouTube/dictionary.txt` is moved into
`Application Support/Fluence/` or merged entry by entry into the one already there;
`MurmurYouTube/runs.jsonl` is sealed into the encrypted history and the plaintext removed only
after the sealed write succeeded; `ai.pivotstudio.murmur-youtube/snippets.json` is sealed into
`snippets.sealed` the same way; Whisper models already live in `Fluence/WhisperModels/`. The
permissions have to be granted once more, because macOS keys them to the bundle ID.

### Why rebuilding keeps the permissions

macOS's privacy database (TCC) records, for every grant, the app's code-signing requirement as
well as its path. An ad-hoc signature is new at each build, so a rebuilt app no longer matches
what was stored. Misleadingly, System Settings still shows the Accessibility switch on while
macOS treats the app as untrusted, and toggling it changes nothing: the entry itself is stale.

So the Makefile signs every build with a stable identity (Developer ID or Apple Development, via
`security find-identity`, falling back to ad-hoc). With an ad-hoc signature, expect to
re-grant after rebuilds, and expect one Keychain prompt per rebuild for the encryption key
("Always Allow").

Stuck permission? Don't flip the switch: « Réparer » in the app, or reset Fluence's entry and re-grant:

```bash
tccutil reset Accessibility io.github.clementvnrd.fluence
tccutil reset Microphone   io.github.clementvnrd.fluence
```

Always give the bundle ID: `tccutil reset Accessibility` without one clears it for every app on the
machine. Then quit System Settings entirely (⌘Q) before reopening.

> **Keep the build out of iCloud.** If the repo lives under a file-provider synced folder,
> the sync engine can corrupt an `.app`'s signature. `make install` stages and signs in
> `~/Library/Caches/FluenceBuild/<checkout>/` and runs the copy in `/Applications`.

Other targets: `make app` builds and signs the bundle in `~/Library/Caches/FluenceBuild/<hash>/`
without installing; `make run` then opens that staged copy; `make check-app` adds the bundle
checks and a `--selftest` launch, as CI does (`PUBLIC=1` for a build for others); `make notices`,
`make icon`, `make release` (`docs/RELEASING.md`); `make clean` removes the scratch and staging folders.

---

## What happens to the words

Everything below runs on the Mac. Settings ▸ Cleanup, Language, Styles, Dictionary; the
main window's Snippets tab.

**Cleanup levels.** *None* types what the engine heard. *Light* (the default) applies
Clement's repairs — "scratch that" / "efface tout", self-corrections ("mardi, en fait
mercredi"), stutters and repeated words, spoken lists ("premièrement…", "tiret") — removes
fillers, turns spoken punctuation into marks ("new line", "open paren"; in French "à la
ligne", "virgule", "point d'interrogation", "ouvrez les guillemets"…) and fixes spacing and
capitals — deterministic, instant. *Medium* adds Apple's on-device model as a name fixer
(`NameFixer`, FLU-92): when the text holds a near-miss of a dictionary term (« guit hub »), the
model may only swap that span for the term; anything else it writes is dropped. *High*, outside
French, rewrites in the style chosen for the kind of app instead, checked by `CleanupGuard`; in
French it is Medium (the free rewrite answered or reworded French dictations, FLU-91). Every
model pass falls back to Light when the model is unavailable, fails or times out. The
old on/off and "smart cleanup" switches migrate to None / Light / Medium, and remain in
Réglages ▸ IA & Formatage as two switches over the level. With **Whisper**, whose output is
already punctuated, the model passes are skipped unless *Post-traitement LLM sur Whisper* is
on. *Formatage code & terminaux* (on by default) turns spoken symbols into code ("double tiret
amend" → `--amend`, "accolade ouvrante" → `{`) and drops the final full stop of a one-line
command, in editors and terminals.

**Languages.** Auto, or one of Parakeet v3's 25 European languages. Apple's engine listens
in that language (Auto: the Mac's language); Parakeet gets it as a script hint. In Auto,
cleanup detects each dictation's language. English and French have their own fillers,
spoken punctuation and model instructions; French also gets its typography (non-breaking
space before `; : ! ?` and inside « »). Fillers that are also words — "ben", "genre", "du
coup", "point", "deux points" — are only removed or converted where they can't be words;
"voilà" is left alone.

**Styles (level High).** Personal messages, Work messages, Email, Other — chosen from the
frontmost app at key release (Messages, WhatsApp, Telegram, Signal, Discord / Slack, Teams
/ Mail, Outlook, Spark, Superhuman…) and, in a browser, from the front tab's address read
through Accessibility (Gmail and Outlook on the web → Email, Slack and Teams → Work,
WhatsApp Web and Messenger → Personal). The address is used once, never stored or logged.
Each category is Formal, Casual or Very casual; Casual for personal messages, Formal
elsewhere by default.

**Snippets.** Say a trigger (≤ 60 characters) and get a stored text (≤ 4,000), on its own
or inside a sentence — matched as whole words, ignoring case and accents, longest trigger
first. The text is typed exactly as stored: cleanup, style and the dictionary never touch
it. A snippet can be switched off without deleting it, and "insert / colle / insère" before
a trigger still expands it. Sealed on disk like history.

**Dictionary helpers.** *Boost dictionary words in Parakeet* (off by default) runs
FluidAudio's CTC keyword spotter over the audio and rescores Parakeet's transcript toward
your dictionary's words; it downloads a second ~100 MB model once, from Settings, never
during a dictation. *Learn from my corrections* (off by default) re-reads the text field for
20 seconds after typing; when you correct a name Fluence wrote, the main window offers to
add it. Nothing is added without you, nothing read is kept, password fields are never read.
*Apprendre les termes fréquents* (off by default) adds a name, acronym or technical term to
the dictionary once you have dictated it twice — without asking, which is why it is opt-in.
The *Corriger* button on a transcription (or ⌥⌫ from the menu bar) opens a sheet where you
fix the text; the changed words become dictionary corrections. *Lexique Tech* seeds the
dictionary with developer vocabulary and franglais, and *Scanner projet…* reads a project's
name, dependencies and branch.

---

## Running beside another dictation app

- **Bundle ID** — TCC keys Accessibility and Microphone to it, so grants here never affect
  another app.
- **Executable `Fluence`** — the `Makefile` only ever `pkill -x`es that name.
- **Shortcuts are configurable.** A shortcut with a key is registered with Carbon, which
  gives it to the first app that asks: a second dictation app bound to the same combination
  will not see it. Give each dictation app its own shortcut.

---

## Data protection

| What | Where | How |
|---|---|---|
| History | `~/Library/Application Support/Fluence/history.sealed` | One AES-256-GCM sealed line per dictation; key in the login Keychain (this device only, never synced). Retention: don't keep / 1 day / **30 days (default)** / forever. If the Keychain refuses, nothing is written. |
| Dictionary | `…/Fluence/dictionary.txt` | Plain text on purpose — it is meant to be edited by hand. |
| Snippets | `…/Fluence/snippets.sealed` | Sealed like history (they hold addresses, numbers, signatures). If the Keychain refuses, nothing is written and the file is never overwritten. |
| The folder | `…/Fluence/` | Owner-only (0700), excluded from Time Machine, never indexed by Spotlight. |
| Logs | unified log, subsystem `io.github.clementvnrd.fluence` | Counts and timings only — never transcript text. |
| Clipboard | only when AX insertion fails | Marked transient + concealed (clipboard managers skip it), kept off Universal Clipboard, previous contents restored. |
| HUD | | Excluded from screen sharing and recordings. |
| Last transcript (⌃⌘V / ⌃⌘C) | memory only | Gone at quit; never written to disk, whatever the history setting. ⌃⌘C copies to this Mac only. |

Network — every outgoing connection, and nothing else:

* **Speech models, once, on first use**, from Hugging Face: Parakeet (when that engine is
  chosen, plus the ~100 MB CTC model when dictionary boosting is on), Whisper (when chosen),
  and the meeting models (voice activity, speaker separation) at the first meeting. Apple's
  French speech asset is downloaded by macOS itself.
* **Updates** (release builds only, FLU-26): the feed baked into the app (`SUFeedURL`) is read
  at launch and once a day, then the new version's archive is downloaded. No system profile is
  sent (`SUEnableSystemProfiling` off); like any HTTP request it carries a User-Agent with the
  app and Sparkle versions. Réglages › À propos turns it off. See `docs/RELEASING.md`.

Never sent: audio, transcripts, names, history, meeting notes.

---

## Architecture

```
 shortcut ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │  (one session token per dictation)
                     ┌──────────┼──────────────┐
                     ▼          ▼              ▼
               AudioCapture  HUDPanel  TranscriptionEngine (protocol)
         (from key-down, ring          ├─ AppleSpeechEngine (SpeechAnalyzer, streaming)
          buffer, 250 ms tail)         └─ ParakeetEngine (FluidAudio, CoreML)
                     │                         │
                     └──► SpeechGate ──────────┘
                                               ▼
                     DictationPipeline: snippets → language → cleanup level
                     (rules, + name fixer, or at High outside French + model + CleanupGuard + style)
                                               ▼
                                DictionaryCorrector (FluenceDictionary)
                                               ▼  (snippet expansions restored)
                            TextInjector ─► focused app      RunLog ─► history.sealed
```

### Design decisions to know first

**The HUD never takes keyboard focus.** `HUDPanel` is a borderless `.nonactivatingPanel` whose
`canBecomeKey == false`. If the overlay took key status, the user's text field would lose
focus and there'd be nothing left to inject into.

**Key shortcuts use Carbon; everything else takes a `CGEventTap`.** Esc swallowing and modifier-only
discrimination only surface through a session event tap — which is why Accessibility is a
hard requirement.

**Capture starts on key-down, before the engine is ready.** Audio waits in memory and is fed
in order once the engine has started, so the first words are not lost; capture runs 250 ms
past release and the converter is drained, so the last word is not either. The mic is
never open while idle.

**Audio ordering is explicit, buffers are copied.** `AudioCapture` yields into an
`AsyncStream` drained by a single task, and always copies the buffer `AVAudioEngine` hands
the tap, because the engine recycles it the instant the callback returns.

**Typing comes before bookkeeping.** Text is injected first; history is written afterwards,
off the main thread.

**Two swappable seams.** `TranscriptionEngine` and `TextFormatter` are protocols.

### Layout

```
Sources/
├── Fluence/                 the app
│   ├── FluenceApp.swift     @main, AppDelegate, menu bar
│   ├── Core/                DictationController, AudioCapture, AudioDevices (mic picker),
│   │                        HotkeyMonitor + CarbonHotkey, TextInjector, CommandTarget,
│   │                        AutoLearningEngine, EngineComparison, WisprTrigger
│   ├── Transcription/       TranscriptionEngine, AppleSpeechEngine, WhisperEngine + WhisperModels,
│   │                        ParakeetEngine, WisprReader
│   ├── Formatting/          TextFormatter (rules), FoundationModelFormatter, DictationPipeline,
│   │                        CommandRewriter
│   ├── Dictionary/          DictionaryStore (file + watcher), EditWatcher (auto-learn), TechLexicon
│   ├── Snippets/            SnippetStore (sealed)
│   ├── Support/             AppPaths, Vault, HistoryFile, RunLog, Settings, Permissions, Log
│   ├── Notetaker/           meeting notes: capture, library, settings
│   └── UI/                  DesignSystem (tokens), Equipment, AquaOrbView, MainWindow,
│                            SettingsWindow (+ Text/Shortcuts sections), DictionaryPanel,
│                            SnippetPanel, CorrectionQuickSheet, ComparisonWindow, HUDPanel,
│                            HUDView, OnboardingWindow
├── FluenceCore/             pure logic, unit tested: cleanup guard and rules (EN/FR),
│                            languages, French typography, model prompts, app categories,
│                            snippet matching, edit learning, push-to-talk gestures,
│                            Command Mode checks, speech gate, downmix, sealed history, retention,
│                            Clement's speech repairs, the legacy-data merge
└── FluenceDictionary/        the correction engine, specified by its test vectors
```

---

## Speech engines

| | Apple SpeechTranscriber | Whisper (WhisperKit) | Parakeet Ultra (FluidAudio) |
|---|---|---|---|
| Dependency | none (macOS 26) | SwiftPM (`argmax-oss-swift`) | SwiftPM |
| Model download | OS-managed | Base ~140 MB / Small ~480 MB / Large Turbo ~1.5 GB, first use | ~600 MB, first use |
| French, words wrong (FLU-24 bench, M2) | 7.6 % clean, 24 % tech words via webcam | Small: 13 % / 45 % · Turbo: slower than real time | **6.7 % / 11.5 %**, 100× real time |
| Live text while speaking | yes | no (on release) | no (on release) |
| Languages | many — Réglages (Auto = the Mac's) | French, English, Auto-detect (code-switching) | 25 European, auto-detected or hinted |
| Dictionary biasing | yes (`contextualStrings`) | one short sentence: the last sentence and up to 8 of your own terms (FLU-20) | opt-in CTC rescoring (~100 MB model) |

Parakeet is the engine to use in French (`docs/SPEECH-MODELS.md`: the bench, and why the
newer models people suggest are not in). The engine and the Whisper model are chosen in
Réglages ▸ Transcription; the microphone too (any
input, without changing the Mac's default).

**Compare mode** (menu bar) runs every engine on one recording and shows them side by side
— and types nothing. If Wispr Flow is installed and its key was held for the same
utterance, its result (read-only from its local database) joins the comparison.

---

## Testing without a Mac app build

```bash
swift test --filter VectorTests        # the dictionary contract (test vectors)
swift test --filter FluenceCoreTests   # cleanup guard, speech gate, history lines…
```

CI (`.github/workflows/macos.yml`) builds the whole app with Xcode 26 and runs every test
target on each pull request.

---

## Not built yet

Tracked in Linear (team FLU):

1. **Context awareness** — reading the text around the caret to spell names right (opt-in).

Not planned: **notarization**. There is no Developer ID (decided 2026-10-08, FLU-39), so the
first copy of Fluence on another Mac opens only after System Settings › Privacy & Security ›
*Open Anyway*; the updates it then receives install without that step.

---

## Licence

**Français.** Fluence est sous licence **PolyForm Strict 1.0.0** (`LICENSE.md`) : vous pouvez lire
le code et utiliser l'application pour vous-même, sans but commercial ; vous ne pouvez ni la
redistribuer, ni la modifier, ni la vendre. Ce n'est pas une licence « open source » : le code est
visible, il n'est pas libre.

**English.** Fluence is licensed under the **PolyForm Strict License 1.0.0** (`LICENSE.md`): you may
read the code and use the software for non-commercial purposes; you may not distribute it, change
it or build on it. Source-available, not open source.

The lines still carried over from the project Fluence started from are not covered by this
licence (see `LICENSE.md`).

### Lines still identical to the starting project (macOS app)

In October 2026 every block of the macOS app still attributed to the starting project's author
(426 blocks, 1,275 lines, measured with `git blame -w -C -C` against upstream `b3b45ab`) was cut
out, described in words only, and written again by people who had never seen it (FLU-76). Only
101 lines came back different. The rest came back **identical**: declarations
(`private let hotkey = HotkeyMonitor()`), single calls into Apple's frameworks
(`try engine.start()`) and view settings dictated by the design system. Anyone writing that
behaviour writes those lines that way, so Git still attributes them to the old author. Clement
chose to keep them as they are rather than rename the app's types to lower the count (FLU-76,
answer « A »). The git history keeps the original code.
