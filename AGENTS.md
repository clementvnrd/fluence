# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

**Fluence** — push-to-talk dictation, and (in progress) local meeting notes. Hold a key,
talk, release, and cleaned-up text is typed into whatever had focus. Everything runs
on-device. Two independent implementations:

| | macOS | Windows |
|---|---|---|
| Language | Swift 6 | C# / .NET 10 |
| UI | SwiftUI | Avalonia |
| Speech | Apple `SpeechAnalyzer`, Whisper via WhisperKit, or Parakeet Ultra via FluidAudio | Parakeet v3 via sherpa-onnx |
| Location | repo root | `windows/` |

**The macOS app works and was in daily use** under its previous name, "Murmur YouTube".
The October 2026 hardening (`docs/AUDIT-2026-10.md`) is typechecked and unit tested but not
yet exercised by hand.

**The Windows app has run on real hardware once, by an outside contributor** (upstream
pull request #1 on `per-simmons/murmur-youtube`): it did not transcribe at all until their
five fixes, which are merged here. The later audit fixes have not been on hardware yet.
Describe it that way — not as "working", not as "unfinished".

The repository is `clementvnrd/fluence` (private). Fluence's own code is under the **PolyForm
Strict 1.0.0** licence (`LICENSE.md`, FLU-42): readable and usable for non-commercial purposes,
no distribution, no changes. It started as a copy of the public `per-simmons/murmur-youtube`,
which has **no licence**, and about 17 % of the lines are still its author's (measured
2026-10-09, FLU-43). Clement chose not to ask that author (FLU-39). **Never make the repository
public or publish a binary before FLU-43 is answered** (and, if he chooses so, FLU-44 has
rewritten those lines).

---

## The one rule that matters

**`shared/dictionary-test-vectors.json` is the specification for correction behaviour.**

Both implementations run it in CI. If you change how corrections work, change the vectors
first, watch both sides go red, then make them green. Changing one implementation to "fix"
a failing vector without changing the other is how the two silently diverge — and only one
of them can be exercised by hand.

```bash
swift test --filter VectorTests                    # macOS side
cd windows && dotnet test Murmur.CrossPlatform.slnf # Windows side, runs anywhere
```

The Swift copy at `Tests/MurmurDictionaryTests/dictionary-test-vectors.json` is a copy, and
CI fails if it drifts from `shared/`. After editing the shared file:

```bash
cp shared/dictionary-test-vectors.json Tests/MurmurDictionaryTests/
```

---

## Data protection rules

These are product requirements, not style:

- **Never log transcript text, meeting text, names or e-mails.** Counts, lengths, timings.
- **Never write personal data in plaintext.** Use `Vault` (`Support/Vault.swift`): AES-256-GCM
  under a Keychain master key, per-item wrapped keys for meetings. If the Vault fails, do not
  fall back to plaintext — skip the write and show the fault.
- **Personal files live under `AppPaths.support`**, which is owner-only, out of Time Machine
  and out of Spotlight.
- **Clipboard writes we did not get asked for** are transient + concealed and
  `.currentHostOnly`, and are cleaned up afterwards.
- **Nothing destructive behind a URL scheme.** Any app or web page can open `fluence://`.

---

## Verifying without Xcode

The Command Line Tools cannot expand SwiftUI's `@State` macro, so `make` fails on a Mac
without Xcode. CI builds the whole app on every pull request. Locally:

- Pure logic lives in plain targets (`MurmurDictionary`, `FluenceCore`, and the Notetaker's
  `FluenceMeetingCore` / `FluenceNotesCore`) that build and `swift test` with the Command Line
  Tools. Swift Testing needs `-Xswiftc -plugin-path -Xswiftc
  /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` on `swift build`;
  without it an incremental build silently runs a stale test binary.
- The app can be typechecked by swapping `@State` for a stand-in property wrapper in a copy of
  the sources. A plain `swiftc -typecheck` is **not** enough: after the macro failure it stops
  reporting real errors.

---

## Things that look like bugs and are not

**`dotnet build Murmur.sln` fails on macOS** with `NETSDK1073` — unless you pass
`-p:EnableWindowsTargeting=true`, which compiles `Murmur.Platform.Windows` (and runs its
analyzers) on a Mac too. `Murmur.CrossPlatform.slnf` omits it and holds every test (149);
the whole UI suite runs headless on macOS in about a second.

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**Speech models are chosen by measurement, in French.** Clement dictates mostly in French,
often through a webcam mic. `bench/french` runs every engine the way the app runs it on
public and synthetic French audio (never anyone's recordings); `docs/SPEECH-MODELS.md` has
the numbers and the verdict on each model proposed so far. A new model or a new default
goes through that bench first, and the result is written there (FLU-24).

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. Wispr Flow's number is its own
`e2eLatency`, which includes a network round trip and its cleanup pass. Don't present them
as one ranking.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

---

## Design system

`Sources/Fluence/UI/DesignSystem.swift` holds the tokens (colours, type, spacing, radii,
shadows, motion, window and panel sizes), `UI/Components.swift` the FLU-12 building blocks
(sidebar items, pills, chips, avatars, section cards, settings rows, search well, empty
state) and `UI/Equipment.swift` the older ones (`BrushedPanel`, `Well`, `TransportKey`,
`Silkscreen`, `Lamp`, `VUMeter`). New screens use them; prefer adding a token to inlining a
value. The Equipment names are historical — they no longer draw anything field-recorder-like.

The art direction is **Clement's own** (FLU-11, then FLU-12 — see `docs/DESIGN-FLU-12.md`):
pure, understated native macOS craftsmanship — Things 3, Apple Notes — in French. Light
paper-mist canvas (`chassis`), rounded white cards (`panel`, radius 12–16, continuous corners)
with a hairline `seam` border and a soft shadow, a deep slate-blue dark mode. Pill-shaped tab
bars and buttons, SF symbols in the accent colour, rounded monospaced digits for timings.

- **Navigation is a sidebar** (FLU-12 decision 1): the main window holds dictation
  (Transcriptions, Dictionnaire, Snippets, Styles) and meetings (Toutes les réunions, À venir);
  there is no separate meetings window. `MainNavigation.shared.show(_:openWindow:)` opens it on
  a section. Settings use the same sidebar layout, six sections.
- **One accent: electric aqua blue** (`DS.Color.accent`, #0084FF / #38BDF8 in dark), the colour
  of the Aqua orb. The small brand mark is always the **drawn** `AquaOrbView` (decision 4);
  `Resources/AquaOrb.png` is not shipped and the Dock icon is unchanged.
- **The blue→cyan gradient is reserved for the Aqua identity**: the orb, the "AI" badge and the
  primary *Dicter* button. Nothing else gets a gradient, and there are no neon glows or
  purple/pink "AI" gradients.
- **Red means a meeting is recording** (decision 3): `DS.Color.meetingRecord` for the meeting
  dot, pill, banner and its *Arrêter*; `DS.Color.destructive` for delete actions. A dictation
  is never red — it stays blue. Amber means "needs attention" (permission banners), green
  "granted / done". None of them is used as decoration.
- The HUD is a floating capsule with the orb, light level bars, the live text, a language pill
  and a finish button; the meeting surfaces are a detection card, a pill and an unfolded panel
  (decision 2). All are excluded from screen sharing and never take focus.
- UI text is **French**; engine names and technical terms stay as they are. Numbers, durations
  and dates go through `FrenchFormat` / `FrenchDates` (FluenceCore, tested: "0,62 s",
  "1 h 05", "Aujourd'hui, 10:00"), shortcuts through `ShortcutLabel` (from the configured
  shortcut, never hard-coded), and stored English speaker labels are translated at display
  time (`SpeakerLabel.french`).
- **Little text on screen** (FLU-19, Clement: "bien trop de texte dans l'UI"). A page title
  has no sentence under it; a subtitle is only a count or a state ("4 dictées", "Français ⇄
  English", "1 réunion stockée"). A setting is a short label and its control: what it does
  goes behind the ⓘ next to the title (`SettingsRow(info:)`, `InfoButton`), not under it.
  What stays visible is what the user must not miss: a state that limits a feature (amber
  `RowNote`: "Nécessite Apple Intelligence", a language cleanup barely knows), a legal or
  biometric duty in one short line (consent, voice prints) and an irreversible action
  ("irréversible"). Per-item details and actions show on hover (transcription cards).

---

## macOS specifics

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility io.github.clementvnrd.fluence
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

**A second copy quits at launch (FLU-27).** Two copies each typed every dictation. A copy
whose bundle ID is already running brings that one forward and exits before anything starts
(`SingleInstance`, rule in `FluenceCore/SingleInstancePolicy`). To run a build beside
Clement's app, give it another bundle ID (`BUNDLE_ID=io.github.clementvnrd.fluence.updatetest`)
or a scratch folder (`FLUENCE_SUPPORT_DIRECTORY`). `make run` / `make install` still work:
a copy on its way out does not count.

**Releases and updates (FLU-26) — `docs/RELEASING.md`.** The version lives only in
`Resources/Info.plist`; the build number is derived from it (a test checks). Sparkle 2 updates
the app from the feed baked in at build time (`FEED_URL`; empty in dev builds, so no updater).
Facts measured on 2026-10-08, not assumptions:

* Sparkle refuses a `file://` feed ("must use http or https"): a feed needs an http(s) host.
* An update installed by Sparkle carries no quarantine and launches although `spctl` rejects
  an Apple Development signature; only a first copy downloaded by a browser meets Gatekeeper.
* The update question is shown only while Fluence is the active app and nothing records;
  *Plus tard* installs at quit without relaunching.
* The EdDSA private key is in the login Keychain (account `ed25519`), never in the repo.
* Test updates only with another bundle ID (`make … BUNDLE_ID=io.github.clementvnrd.fluence.updatetest`),
  which gets its own data folder, settings and Keychain item — never over
  `/Applications/Fluence.app`.

---

## Windows specifics

The specifics below were expensive to establish and several were found the hard way. Treat
them as load-bearing. Full detail in `windows/README.md` and `docs/PARAKEET-WINDOWS.md`.

**The look stays as it is for now** (FLU-14, Clement, 2026-10-08: « 3 B »): the Windows app
keeps its dark field-recorder look; the macOS design (FLU-12, FLU-19) is not ported until he
asks for it.

**Three pinned versions that break silently at "latest":**

| Package | Pin | Why |
|---|---|---|
| `NAudio` | 2.3.0 | 3.x is a new major version — moving is a port that needs real-hardware testing. 3.1 is needed later for the Notetaker's process loopback (FLU-10) |
| `Avalonia.Headless.XUnit` | 11.3.20 | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | 1.13.8 | Bundles ONNX Runtime — never also reference `Microsoft.ML.OnnxRuntime` |

**Right Alt is AltGr** on German, Polish, UK, Nordic and most Latin-American layouts. Binding
push-to-talk there — and especially suppressing it — breaks typing `@`, `€`, `\`, `|` for
those users. Default is **Right Ctrl**, and the hook **observes without swallowing**: if the
key-down is swallowed and the key-up escapes, the target app believes Ctrl is held forever.

**UI Automation cannot inject text.** `TextPattern` is documented read-only and
`ValuePattern` replaces a whole field rather than inserting at the caret. `SendInput` is the
primary path, not a fallback.

**`Murmur.App` loads the platform layer by reflection, not by reference.** A direct
reference would force the UI onto `net10.0-windows` and you would lose the ability to run it
on your own machine. Two consequences that have already bitten once: the assembly is
invisible to `PublishSingleFile`, so it is published as a loose file beside the exe *and*
resolved by an explicit `AssemblyLoadContext` handler; and the published self-test checks
this, because when it breaks the app starts perfectly and then does nothing at all when the
key is pressed.

**Keep `Murmur.Platform.Windows` logic-free.** Anything living there is code CI cannot
exercise. Retries, debouncing and device-change handling belong in the platform-neutral
projects behind an interface — those target plain `net10.0`, so `CA1416` turns any accidental
Win32 call into a build error.

**CI is the only place the Windows code is compiled.** Warnings are errors and the analyzers
are strict on purpose. `--no-incremental` is mandatory: Roslyn does not re-emit analyzer
warnings on a cached build, so without it the gate proves nothing.

---

## Regex, if you touch the dictionary

The two engines are not identical. Measured across 30 cases, **9 diverged**. Two affect this
code and are handled — don't remove either:

- `RegexOptions.CultureInvariant` on the C# side, or Turkish `İ` matches `i`.
- **NFC normalization on both sides.** macOS returns decomposed strings, so without it an
  accented trigger silently never fires.

Two more are unfixable and simply avoided: ICU folds `ß` to `ss` and .NET doesn't; .NET's `.`
splits surrogate pairs. Stay inside the safe subset — `\b`, `\d`, `\w`, `\s`, character
classes, greedy/lazy quantifiers, alternation, `(?<name>…)`, fixed-length lookbehind,
lookahead, `\p{L}`, and `$1`–`$9` in replacements. Nothing else.

---

## What isn't built

1. **Context awareness** — reading the text around the caret (opt-in) to spell names right.
2. **Code signing** (Windows): unsigned for distribution, so Windows users will meet
   SmartScreen. macOS **notarization is not planned**: no Developer ID, decided 2026-10-08
   (FLU-39); a first copy on another Mac needs *Open Anyway* once.
3. **An installer** for Windows, and model download from inside the app rather than by
   following `docs/PARAKEET-WINDOWS.md` by hand.

## What no amount of CI can verify

On Windows, nobody has yet held the key and spoken. Specifically unverified:

- Text injection landing in a foreground app — runners have an interactive desktop but
  cannot take the foreground.
- A real microphone: format negotiation, the OS privacy block, unplugging mid-capture.
- The keyboard hook firing on a physical keypress.
- Parakeet transcribing real speech, and whether ~2 GB resident is tolerable.

Everything those feed into is behind an interface and tested with fakes. The bindings
themselves are not. **First real-hardware run should start with `--selftest`, then a single
short dictation into Notepad.**
