# Fluence

Push-to-talk dictation for macOS and Windows. Hold a key, talk, release — cleaned-up text
lands in whatever text field has focus. A Wispr Flow-shaped app, built native and **fully
on-device**: speech, cleanup and storage never leave the machine.

Windows lives in [`windows/`](windows/README.md). This file is about the macOS app.

**Status (October 2026).** Dictation works end to end and was in daily use under the app's
previous name. The October 2026 hardening (encrypted history, no transcript text in logs,
safe clipboard, no clipped words, session races, device changes) is typechecked and unit
tested but has not yet been exercised by hand. Audit: [`docs/AUDIT-2026-10.md`](docs/AUDIT-2026-10.md).

---

## Quick start

```bash
make install     # builds, bundles, signs, copies to /Applications, launches
```

Needs **Xcode 26** (the Command Line Tools alone cannot compile SwiftUI's `@State` macro).
Then grant two permissions — neither is optional, and neither can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | The `CGEventTap` that sees the hotkey, and the AX text insert |
| **Microphone** | Prompted on first dictation | Audio capture |

The hotkey arms itself as soon as Accessibility is granted — no restart. Then hold
**Right ⌥** and talk.

The bundle ID is `io.github.clementvnrd.fluence`. Settings, dictionary and history from the
app's previous identity (`ai.pivotstudio.murmur-youtube`) migrate on first launch; the
permissions have to be granted once more, because macOS keys them to the bundle ID.

### Why grants survive rebuilds here

TCC stores a *code-signing requirement* per entry, not just a path. An ad-hoc signature
changes on every build, so the rebuilt binary stops satisfying the stored requirement —
and the symptom is nasty: the Accessibility toggle still **shows as on** while the app is
reported untrusted, and flipping it changes nothing because the stale row is the problem.

The `Makefile` therefore signs with a stable Developer ID (auto-detected via
`security find-identity`, falling back to ad-hoc). With an ad-hoc signature, expect to
re-grant after rebuilds, and expect one Keychain prompt per rebuild for the encryption key
("Always Allow").

If a grant ever does get wedged, reset that one row and re-add — never toggle:

```bash
tccutil reset Accessibility io.github.clementvnrd.fluence
tccutil reset Microphone   io.github.clementvnrd.fluence
```

Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every** app on the
machine. Then quit System Settings entirely (⌘Q) before reopening.

> **Keep the build out of iCloud.** If the repo lives under a file-provider synced folder,
> the sync engine can corrupt an `.app`'s signature. `make install` stages and signs in
> `~/Library/Caches/FluenceBuild/<checkout>/` and runs the copy in `/Applications`.

Other targets: `make app` (bundle only), `make run` (run in place), `make clean`.

---

## Coexisting with another dictation app

- **Bundle ID** — TCC keys Accessibility and Microphone to it, so grants here never affect
  another app.
- **Executable `Fluence`** — the `Makefile` only ever `pkill -x`es that name.
- **Hotkey is configurable** (Right ⌥ / fn / Right ⌘). Right ⌥ and Right ⌘ are *consumed*
  by Fluence's event tap, so a second app bound to the same key may never see it. Give each
  dictation app its own key.

---

## Data protection

| What | Where | How |
|---|---|---|
| History | `~/Library/Application Support/Fluence/history.sealed` | One AES-256-GCM sealed line per dictation; key in the login Keychain (this device only, never synced). Retention: don't keep / 1 day / **30 days (default)** / forever. If the Keychain refuses, nothing is written. |
| Dictionary | `…/Fluence/dictionary.txt` | Plain text on purpose — it is meant to be edited by hand. |
| The folder | `…/Fluence/` | Owner-only (0700), excluded from Time Machine, never indexed by Spotlight. |
| Logs | unified log, subsystem `io.github.clementvnrd.fluence` | Counts and timings only — never transcript text. |
| Clipboard | only when AX insertion fails | Marked transient + concealed (clipboard managers skip it), kept off Universal Clipboard, previous contents restored. |
| HUD | | Excluded from screen sharing and recordings. |

Network: none, except the one-time Parakeet model download from Hugging Face when that
engine is chosen.

---

## Architecture

```
 hold key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │  (one session token per dictation)
                     ┌──────────┼──────────────┐
                     ▼          ▼              ▼
              AudioCapture  HUDPanel   TranscriptionEngine
         (from key-down, ring          ├─ AppleSpeechEngine (SpeechAnalyzer, streaming)
          buffer, 250 ms tail)         └─ ParakeetEngine (FluidAudio, CoreML)
                     │                         │
                     └──► SpeechGate ──────────┘
                                               ▼
                            TextFormatter (rules, or Foundation Models + CleanupGuard)
                                               ▼
                                DictionaryCorrector (MurmurDictionary)
                                               ▼
                            TextInjector ─► focused app      RunLog ─► history.sealed
```

### Decisions worth knowing

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. If the overlay took key status, the user's text field would lose
focus and there'd be nothing left to inject into.

**The hotkey needs a `CGEventTap`, not `NSEvent`.** `fn` and left/right modifier
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
│   ├── Core/                DictationController, AudioCapture, HotkeyMonitor, TextInjector,
│   │                        EngineComparison, WisprTrigger
│   ├── Transcription/       TranscriptionEngine, AppleSpeechEngine, ParakeetEngine, WisprReader
│   ├── Formatting/          TextFormatter (rules), FoundationModelFormatter
│   ├── Dictionary/          DictionaryStore (file + watcher)
│   ├── Support/             AppPaths, Vault, HistoryFile, RunLog, Settings, Permissions, Log
│   └── UI/                  DesignSystem (tokens), Equipment, MainWindow, SettingsWindow,
│                            DictionaryPanel, ComparisonWindow, HUDPanel, HUDView
├── FluenceCore/             pure logic, unit tested: cleanup guard, speech gate, downmix,
│                            sealed history lines, retention
└── MurmurDictionary/        the correction engine — a cross-platform contract
```

---

## Speech engines

| | Apple SpeechTranscriber | Parakeet v3 (FluidAudio) |
|---|---|---|
| Dependency | none (macOS 26) | SwiftPM |
| Model download | OS-managed | ~470 MB, first use |
| Live text while speaking | yes | no (on release) |
| Languages | many, `Locale.current` | 25 European, auto-detected |
| Dictionary biasing | yes (`contextualStrings`) | not yet |

**Compare mode** (menu bar) runs every engine on one recording and shows them side by side
— and types nothing. If Wispr Flow is installed and its key was held for the same
utterance, its result (read-only from its local database) joins the comparison.

---

## Testing without a Mac app build

```bash
swift test --filter VectorTests        # the cross-platform dictionary contract
swift test --filter FluenceCoreTests   # cleanup guard, speech gate, history lines…
```

CI (`.github/workflows/macos.yml`) builds the whole app with Xcode 26 and runs every test
target on each pull request.

---

## Not built yet

Tracked in Linear (team FLU):

1. **Wispr Flow parity** — hands-free mode, styles per app, snippets, Command Mode, French
   cleanup prompt, Parakeet biasing.
2. **Onboarding** — a first-run window for the permissions.
3. **Notarization**, for distribution beyond this machine.
