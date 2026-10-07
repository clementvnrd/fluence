# Fluence for Windows

The Windows port of Fluence — push-to-talk dictation, on-device. (Formerly Murmur; see
[Naming](#naming).)

> **Status: every layer exists; real-hardware use has only just begun.** CI builds, tests and
> publishes a single-file `Fluence.exe` and runs its self-test on Windows. A first real-machine
> run by an outside contributor found five bugs that CI could not (the model was never
> loaded, NAudio did not ship, UI updates from the wrong thread, paste never wired, close
> crashed the tray); those are fixed. The October 2026 audit's Windows items are addressed
> in code and tests, but most of them still need a person holding the key to confirm — see
> [Honesty](#honesty).

---

## Why this is a rewrite, not a port

Almost every layer of the macOS app is Apple-specific:

| Layer | macOS | Windows |
|---|---|---|
| UI | SwiftUI | Avalonia |
| Audio capture | `AVAudioEngine` | WASAPI via NAudio |
| **Default speech engine** | `SpeechAnalyzer` (ships with macOS 26) | **nothing equivalent exists** |
| Parakeet | FluidAudio → CoreML | sherpa-onnx → ONNX Runtime |
| Hotkey | `CGEventTap` | `SetWindowsHookEx(WH_KEYBOARD_LL)` |
| Text injection | Accessibility API | `SendInput` |

The consequence that shapes everything: **Windows has no counterpart to Apple's
`SpeechAnalyzer`.** On macOS, Parakeet is the optional upgrade. On Windows it is the only
engine, and the app cannot transcribe until the model is downloaded —
see [`docs/PARAKEET-WINDOWS.md`](../docs/PARAKEET-WINDOWS.md).

What *is* genuinely shared is the dictionary's behaviour, and it is shared as a contract
rather than as code: [`shared/dictionary-test-vectors.json`](../shared/dictionary-test-vectors.json).
Both implementations run those vectors in CI. Changing correction semantics starts there.

---

## Decisions, and why

**Avalonia, not WPF or WinUI 3.** WPF cannot be run or UI-tested on macOS, so every mistake
would cost a full CI round-trip. Avalonia's headless test platform runs on macOS in ~100 ms,
including simulated keyboard input and real pixel capture. Win32 interop is unaffected —
hooks, `SendInput` and WASAPI are P/Invoke, not UI-framework code. WinUI 3 was rejected
outright: Microsoft's own docs contradict each other on whether unpackaged single-file
publishing works, with open bugs reporting an exe that won't launch.

**.NET 10, not .NET 8.** .NET 8 reaches end-of-life on **2026-11-10**.

**Right Ctrl is the default hotkey, not Right Alt.** Right Alt is AltGr on German, Polish,
UK, Nordic and most Latin-American layouts — it is how those users type `@`, `€`, `\`, `|`.
Binding push-to-talk there would break basic typing for a large fraction of users. Right
Ctrl produces no character on any layout.

**The hotkey is observed, not swallowed.** The macOS build consumes Right Option because
on macOS that key types characters. On Windows, suppression buys nothing and risks a much
worse failure: if the key-down is swallowed but the key-up escapes — a hook that timed out
mid-gesture, or focus crossing into an elevated window — the target app believes Ctrl is
held down forever. The single exception is **Caps Lock**, which is swallowed when bound: it
is a toggle that acts on key-down, so passing it through would flip Caps Lock on every
dictation, and nothing can get stuck.

**CPU-only inference.** sherpa-onnx ships no GPU package; DirectML is five versions behind
and forbids the variable tensor shapes this model requires; CUDA would force every user to
install a toolkit. On CPU with int8 weights, transcription runs ~40× faster than real time.

**Three pinned versions that would break at "latest":**

| Package | Pinned | Why |
|---|---|---|
| `NAudio` | **2.3.0** | Kept for the Notetaker (FLU-10): 2.3 already exposes `IAudioClient`, `AudioClient(IAudioClient)` and `AudioCaptureClient.GetBuffer` with QPC timestamps, so process loopback needs one P/Invoke (`ActivateAudioInterfaceAsync`), not 3.x. 3.x is a new major version whose `NAudio.Core` pulls `System.Numerics.Tensors`, which the `NAudio*.dll` publish glob would silently drop, and moving would also touch the dictation microphone path |
| `Avalonia.Headless.XUnit` | **11.3.20** | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | **1.13.8** | Bundles ONNX Runtime; never also reference `Microsoft.ML.OnnxRuntime`. Moved from 1.13.5 for the Notetaker (FLU-10): same package layout — the `win-x64` runtime still ships `onnxruntime.dll` beside `sherpa-onnx-c-api.dll` — and the VAD, speaker-diarization and speaker-embedding types the meeting pipeline uses. The three `org.k2fsa.sherpa.onnx*` pins move together |

---

## Layout

```
windows/
├─ Directory.Build.props          strict analysis, applied to every project
├─ Directory.Packages.props       central version pinning
├─ global.json                    SDK pin
├─ src/
│  ├─ Murmur.Dictionary/          corrections + biasing                      net10.0
│  ├─ Murmur.Meeting/             Notetaker logic ported from macOS, notes   net10.0
│  ├─ Murmur.Abstractions/        platform interfaces, key policy, log API   net10.0
│  ├─ Murmur.Core/                engine, segmenter, sealed history, paths,  net10.0
│  │                              meeting pipeline, store and controller
│  ├─ Murmur.Speech/              Parakeet via sherpa-onnx, model verifier   net10.0
│  ├─ Murmur.Testing/             fakes for the interfaces                   net10.0
│  ├─ Murmur.App/                 Avalonia UI → Fluence.exe                  net10.0
│  └─ Murmur.Platform.Windows/    the ONLY Win32 code                        net10.0-windows
└─ tests/
   ├─ Murmur.Dictionary.Tests/    the shared vectors                          24 tests
   ├─ Murmur.Meeting.Tests/       the shared meeting vectors, notes core      58 tests
   ├─ Murmur.Core.Tests/          engine, storage, crypto, meetings, log     156 tests
   ├─ Murmur.Speech.Tests/        model search/verification, native load      18 tests
   └─ Murmur.App.Tests/           headless Avalonia UI                        23 tests
```

**Only one project targets `-windows`.** Everything else is platform-neutral, so `CA1416`
turns an accidental Win32 call into a build error — and, more usefully, the whole app
builds, runs and tests on macOS.

`Murmur.App` loads the platform layer **by reflection** rather than referencing it. A direct
reference would drag the UI onto `net10.0-windows` and destroy the local loop. Its
dependencies (NAudio, `System.Security.Cryptography.ProtectedData`,
`Microsoft.Win32.SystemEvents`) ship as loose DLLs beside `Fluence.exe` and are found by an
assembly resolver that answers for any DLL in that folder. **The exe alone is not the app** —
CI uploads the whole publish folder. The published self-test exercises each dependency for
real, because when this breaks the app starts perfectly and then does nothing at all when the
key is pressed.

Keeping the platform layer logic-free is deliberate: anything that lives there is code CI
cannot exercise. Each class there is a binding — the hook filters and raises events, the
injector calls `SendInput`, the session monitor reports — and every decision (minimum hold,
chords, watchdog, which window to type into, retention, encryption) is in the neutral
projects, behind an interface, under test.

### Naming

The product is **Fluence**: `Fluence.exe`, window titles, the tray, the manifest, and the data
folder `%LOCALAPPDATA%\Fluence`. On first launch the pre-rename `%LOCALAPPDATA%\Murmur` folder
is moved (not copied) there; if both exist they are merged without overwriting anything new.
Projects and namespaces keep their `Murmur.*` names on purpose — renaming them would touch every
file for no user-visible gain and bury the real changes in an unreviewable diff.

---

## How a dictation flows

1. **Key down.** The low-level hook (own thread, own message pump) raises an event; the
   engine's handler timestamps it and enqueues it. Nothing else happens on the hook thread —
   Windows silently removes a hook that is slow.
2. **Recording.** The engine's control loop opens the microphone on a worker task. WASAPI
   shared mode is asked for 16 kHz mono float; failing that, the device format is converted
   in managed code. A watchdog runs every 250 ms.
3. **Key up.** A press under **250 ms** is a tap and is dropped. Another key pressed during
   the hold (Right Ctrl+C) makes it a shortcut and it is dropped. Otherwise the focused window
   is snapshotted, capture continues **250 ms** (post-roll), then stops and drains — nothing
   already captured is discarded.
4. **Transcription**, strictly in order (a quick second dictation queues behind the first).
   Long audio is cut into 52–60 s pieces at the quietest 200 ms window; the dictionary
   corrects the text.
5. **Typing** — only if typing is on, the same window still has focus, and it is not running
   as administrator (UIPI would drop the input silently). Short text is typed as Unicode
   keystrokes; long or multi-line text is pasted. Then the history entry is written.

The watchdog cancels — and says why — when the key's release was lost (the OS reports the key
up but the hook never did), when the session locks or a secure desktop (UAC, Ctrl+Alt+Del)
takes the keyboard, and stops at **10 minutes** without typing (`MaxRecordingMinutes`).

**Nothing fails silently.** Every failure on this path — microphone, model, transcription,
typing — puts a sentence on the main window and an entry in the diagnostic log.

**Known gap:** the first ~20–100 ms of speech (more on Bluetooth) can be lost while the device
opens. Closing it would mean keeping the microphone open permanently behind a ring buffer,
which lights the Windows microphone indicator all the time — rejected.

---

## Privacy

- **History is encrypted at rest.** Each line of `transcripts.jsonl` is sealed with
  AES-256-GCM under a random key that is itself protected with DPAPI for your Windows account
  (`transcripts.key`). Another account, another machine, or a backup sees only ciphertext.
  Older plaintext histories are converted once on first launch; the plaintext is gone from
  the file (though not wiped from the disk blocks — on an SSD that cannot be done reliably).
- **Retention:** never / 1 day / **30 days** (default) / forever, applied at startup, on
  change, and after every dictation. The raw (pre-dictionary) text is kept alongside.
- **Clipboard:** text pasted on your behalf carries the formats that keep it out of clipboard
  managers, Win+V history and Cloud Clipboard, and the clipboard is restored (or cleared)
  afterwards. COPY from the history may appear in Win+V but is never uploaded to the cloud.
- **Logs** (`%LOCALAPPDATA%\Fluence\logs`, JSON lines, 3 × 512 KB) record event names,
  exception types and numbers — never what you said.
- **Typing off** (Settings → Behaviour) sends dictations to the history only.
- No network access, except downloading the model by hand.

---

## Building

**On Windows** — everything, including the platform layer:

```bash
cd windows
dotnet build Murmur.sln -c Release --no-incremental -warnaserror
dotnet test  Murmur.sln -c Release
```

**On macOS or Linux** — the platform layer *compiles* (analyzers included) with
`EnableWindowsTargeting`, which is worth doing before every push; it just cannot run:

```bash
cd windows
dotnet build Murmur.sln -c Release --no-incremental -warnaserror -p:EnableWindowsTargeting=true
dotnet test  Murmur.CrossPlatform.slnf -c Release     # ~5 s, 279 tests
```

Without `-p:EnableWindowsTargeting=true`, `dotnet build Murmur.sln` fails off Windows with
`NETSDK1073`; the solution filter omits the platform layer and needs no flag. The sherpa-onnx
package ships native libraries for macOS and Linux too, so the native-load test runs there.

`--no-incremental` is not optional in CI. Roslyn does not re-emit analyzer warnings on an
incremental build, so `-warnaserror` would pass on cached results and prove nothing.

---

## <a id="honesty"></a>Honesty about what is verified

**Verified, on Windows, every push:** 279 tests — 24 dictionary (the shared vectors), 58
meeting (the shared meeting vectors and the notes core, ported from macOS), 156 core (the
dictation state machine with its timing rules, watchdog and error paths; chunking and seam
joining; sealed history, migration and retention; the dictionary file; logging; the meeting
capture, pipeline, detector, final pass, store, spool and controller on fakes), 18 speech
(model search, verification, real native calls into sherpa-onnx), 23 headless Avalonia UI. CI then publishes a self-contained single-file `Fluence.exe`, checks the loose
platform DLLs are present (and that SystemEvents is the real implementation, not the stub),
**runs it with `--selftest`**, and the binary reports back: the dictionary works, history
seals and round-trips, the sherpa-onnx native library loads from the bundle, the platform
layer loads, NAudio enumerates capture devices, DPAPI round-trips, session events subscribe,
and for the Notetaker: the meeting store and spool round-trip sealed, the sherpa-onnx VAD and
diarization types load, process loopback activates and capture sessions enumerate (the last
two warn rather than fail on a runner with no audio device).

**Verified on macOS:** the same 279 tests, and the platform layer compiles with every
analyzer. The self-test runs too, minus the platform checks.

**Known divergences between the two regex engines**, measured across 30 cases — 9 differed.
The two that affect this code are both handled: culture-sensitive case-insensitive matching
(fixed by `CultureInvariant`) and NFC/NFD mismatch (fixed by normalizing both sides). Two
that are *not* fixable are simply avoided: ICU folds `ß` to `ss` and .NET does not, and
.NET's `.` splits surrogate pairs. Neither is reachable from the patterns this code builds.

**Cannot be verified anywhere but a real machine** — the bindings are thin, but untested:

- Text landing in a foreground app, via typing and via paste. Runners cannot take the
  foreground.
- Whether Windows honours the clipboard privacy formats as Avalonia writes them (Win+V
  history and Cloud Clipboard should not show pasted dictations).
- A real microphone: format negotiation, drain-on-stop delivering the last word, the OS
  privacy block, unplugging mid-capture, how long a Bluetooth headset takes to open.
- The keyboard hook on a physical keypress: chord detection, Caps Lock swallowing, the AltGr
  phantom Ctrl, and `GetAsyncKeyState` agreeing with the hook.
- Lock screen / UAC detection (`SessionSwitch`, `OpenInputDesktop`) and the elevated-window
  check, against real sessions.
- DPAPI across a password change or profile reset (the code sets the old history aside
  rather than deleting it).
- Parakeet transcribing real speech, and whether the ~2 GB working set is tolerable.
- The meeting Notetaker (`docs/NOTETAKER.md` §3): process-loopback activation and the formats
  Windows accepts, capture-session enumeration and the process names real Teams/Zoom builds
  use, real call window titles, microphone/loopback clock drift over an hour, the panel's
  placement and focus. Silero VAD, Parakeet timings and diarization were checked on macOS
  with the real sherpa-onnx library and models; the diarization threshold was tuned on one
  clip.

Everything those feed into is behind an interface and exercised with fakes. **A first
real-hardware run should start with `Fluence.exe --selftest` in a console, then a single
short dictation into Notepad**, then one into an elevated Notepad (expect the "runs as
administrator" message), then Win+L mid-dictation (expect "cancelled").
