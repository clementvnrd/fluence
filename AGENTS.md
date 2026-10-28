# Working in this repository

You are a coding agent with no memory of this project: read this whole file before you
change anything. It holds the repo's binding rules and its traps — behaviour that looks broken
but is meant, and steps that look harmless but do real damage.

---

## What Fluence is

**Fluence** — push-to-talk dictation, and (in progress) local meeting notes. Hold a key,
talk, release, and cleaned-up text is typed into whatever had focus. Everything runs
on-device. A macOS app in Swift 6 and SwiftUI, at the repo root; speech by Apple
`SpeechAnalyzer`, Whisper via WhisperKit, or Parakeet Ultra via FluidAudio.

A Windows app (C# / .NET, Avalonia, under `windows/`) was removed from the repository on
Clement's decision (FLU-75) rather than rewritten; it lives on under the tag `windows-archive`.

**The macOS app works and was in daily use** under its previous name, "Murmur YouTube".
The October 2026 hardening (`docs/AUDIT-2026-10.md`) is typechecked and unit tested but not
yet exercised by hand.

The repository is `clementvnrd/fluence`, public since FLU-73. Fluence's own code is under the **PolyForm
Strict 1.0.0** licence (`LICENSE.md`, FLU-42): readable and usable for non-commercial purposes,
no distribution, no changes. It started as a copy of the public `per-simmons/murmur-youtube`,
which has **no licence**, and about 17 % of the lines are still its author's (measured
2026-10-09, FLU-43; re-measured 2026-10-11 by `git blame -w -C -C`: macOS `Sources/` 8.9 %,
the Windows app 27.6 % (removed since, FLU-75), bench / Makefile / Package.swift 62.9 %). Clement chose not to ask that
author (FLU-39). He first decided to go public only once those lines were rewritten (FLU-43,
2026-10-09), then **reversed it on 2026-10-11 (FLU-66): public now, the rewrite (FLU-44) aims at
the next release**. The risk is his and is known: until the rewrite is done, the public repository
and the app contain lines whose author gave no licence. The repository went public with the
0.2.0 release (FLU-73). Publishing a release stays an explicit act: **only when Clement asks
for it** (0.2.1 on 2026-10-26, FLU-79), never as a side effect of other work.

---

## The rule that comes first

**`Tests/FluenceDictionaryTests/dictionary-test-vectors.json` is the specification for the
macOS app's correction behaviour.**

CI runs it on every pull request. If you change how corrections work, change the vectors
first, watch the tests go red, then make them green. A vector changes only because the
intended behaviour changes, never to make failing code pass.

Its `fileCases` section (version 2, FLU-53) does the same for reading `dictionary.txt`: raw
file text, line endings spelled out, and the entries that must come back, run against
`DictionaryFileFormat` (`FileVectorTests`). Any line ending ends a line: `\n`, `\r\n`, or a
lone `\r`.

```bash
swift test --filter VectorTests
```

The meeting logic has the same kind of contracts beside its tests, in
`Tests/FluenceMeetingCoreTests/` (`meeting-test-vectors.json`, `transcript-import-vectors.json`,
`speaker-consolidation-vectors.json`). Each file exists once; there is no copy to keep in step.

---

## Data protection rules

These are product requirements, not style:

- **Never log transcript text, meeting text, names or e-mails.** Counts, lengths, timings.
- **Never write personal data in plaintext.** Use `Vault` (`Support/Vault.swift`): AES-256-GCM
  under a Keychain master key, per-item wrapped keys for meetings. If the Vault fails, do not
  fall back to plaintext — skip the write and show the fault.
- **Personal files live under `AppPaths.support`**, which is owner-only and out of Spotlight.
  Everything in it is out of Time Machine **except `dictionary.txt`** (and its `.bak`), plain
  text the user edits by hand (FLU-36, `SupportFolder`): the folder itself is backed up and
  each other item is excluded, at launch and after each atomic rewrite of a top-level file. A
  new top-level file is excluded by the launch sweep; one rewritten by replacement calls
  `AppPaths.keepOutOfBackup`. Sealed data moves between Macs by the encrypted backup file,
  not Time Machine.
- **Clipboard writes we did not get asked for** are transient + concealed and
  `.currentHostOnly`, and are cleaned up afterwards.
- **Nothing destructive behind a URL scheme.** Any app or web page can open `fluence://`.

---

## Verifying without Xcode

The Command Line Tools cannot expand SwiftUI's `@State` macro, so `make` fails on a Mac
without Xcode. CI builds the whole app on every pull request. Locally:

- Pure logic lives in plain targets (`FluenceDictionary`, `FluenceCore`, and the Notetaker's
  `FluenceMeetingCore` / `FluenceNotesCore`) that build and `swift test` with the Command Line
  Tools. Swift Testing needs `-Xswiftc -plugin-path -Xswiftc
  /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` on `swift build`;
  without it an incremental build silently runs a stale test binary.
- The app can be typechecked by swapping `@State` for a stand-in property wrapper in a copy of
  the sources. A plain `swiftc -typecheck` is **not** enough: after the macro failure it stops
  reporting real errors.

---

## Intended surprises and traps

**A plain `swift build` can fail with `error: input file '<path>' was modified during the build`.**
If the checkout sits in a folder synced by iCloud or another file provider, the sync daemon
writes under the build folder while the compiler reads it. **Always build with `make`**: it passes
`--scratch-path ~/Library/Caches/FluenceBuild/<hash of the checkout path>/scratch`, never synced
and one per checkout, so two worktrees can build at once. A bare `swift build` also creates
`.build/` in the checkout, which a synced folder then syncs, and every later build gets minutes
slower. If the error still shows up, wait a few seconds and run the same command again.

**Compare mode types nothing into the focused app, on purpose** — the most confusing thing in
the app. `Settings.compareMode` (menu bar « Mode comparaison ») gives one recording to Apple, and to
Parakeet and Whisper when their model is already on disk (a comparison never downloads one), then
shows the transcripts side by side: several results cannot all land in one text field. Command
Mode instructions are never compared.

**Speech models are chosen by measurement, in French.** Clement dictates mostly in French,
often through a webcam mic. `bench/french` runs every engine the way the app runs it on
public and synthetic French audio (never anyone's recordings); `docs/SPEECH-MODELS.md` has
the numbers and the verdict on each model proposed so far. A new model or a new default
goes through that bench first, and the result is written there (FLU-24).

**The times in a comparison are not measured the same way.** Apple, Parakeet and Whisper
report on-device compute only, timed once the model is loaded. Wispr Flow's number is its own
end-to-end latency (the `e2eLatency` column of its database): network round trip plus Wispr's
cleanup. Never rank them together; the comparison window ranks the local engines and shows
Wispr's figure apart.

**A release has no Wispr Flow in it, on purpose (FLU-69).** `WisprReader` and `WisprTrigger`
(compare mode reads Wispr's database and presses its hotkey) are fine on Clement's own Mac but
not in a build for someone else. `make release` sets `PUBLIC=1`, which compiles them out
(`-DFLUENCE_WITHOUT_WISPR`); `make install` keeps them. So an update installed by Sparkle on
Clement's Mac replaces a build that has the comparison with one that does not: reinstall with
`make install` to get it back. Any new Wispr call site goes inside `#if !FLUENCE_WITHOUT_WISPR`,
and `strings` on a `make app PUBLIC=1` binary must find neither name.

**The licences shipped in the app are generated, not written.** `Resources/THIRD-PARTY-NOTICES.txt`
comes from `make notices` (FLU-68): the licence files of the versions in `Package.resolved`, plus a
hand-written list of the speech models Fluence downloads. When a dependency moves or a new model
is added, run it and commit the result; `ThirdPartyNoticesTests` fails otherwise.

**`MainActor.assumeIsolated` kills the process when the claim is false.** It checks nothing:
it asserts the code is on the main actor and traps otherwise, and it has crashed the app before.
Do not use it; off the main actor, hop with `await MainActor.run`. The one accepted use is
`HotkeyMonitor`'s event-tap callback, which must answer synchronously and tests
`Thread.isMainThread` first.

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

**The signature is functional, not cosmetic.** For each grant, macOS privacy (TCC) stores a
code-signing requirement, not just the binary's path. An ad-hoc signature differs on every build,
so a rebuilt binary stops matching it, and the symptom misleads: the Accessibility switch in
System Settings still looks on while `AXIsProcessTrusted` says no. The Makefile picks the identity
itself with `security find-identity`: a Developer ID Application certificate, else the free Apple
Development one (Clement's case, FLU-39), else ad-hoc. **Never swap that for `--sign -`** on a
local build; `make release` refuses an ad-hoc signature.

If a grant sticks, never toggle the switch: use « Réparer » in the app, or reset Fluence's row only:

```bash
tccutil reset Accessibility io.github.clementvnrd.fluence
```

Leave out the bundle ID and it clears the Accessibility grant of every app on the Mac. Then quit
System Settings completely (⌘Q) before opening it again: it keeps a cached copy of the Privacy list.

**Closing the last window does not quit: it moves Fluence to the menu bar** (FLU-59, Clement).
One process, two presences. `AppPresence` switches `NSApp.setActivationPolicy` between `.regular`
(Dock icon) while a window is open and `.accessory` (menu bar only) once none is; dictation, the
shortcut, the HUD and meeting detection do not depend on it. ⌘Q and « Quitter Fluence » still
quit. Rules that bite:

- Anything that opens a window from the menu bar calls `AppPresence.shared.becomeRegular()`
  first: Settings does not come to the front from a `.accessory` app.
- Which windows count is `AppPresencePolicy` (FluenceCore, tested): titled, not a panel, visible
  or minimised. Judge a *closing* window by its kind only: `canBecomeMain` is `false` at
  `willClose`, which made the first version never leave the Dock.
- **Launch at login** (FLU-58) is `SMAppService.mainApp`, read back from the system every time
  (`LaunchAtLogin`), and only offered for the copy in `/Applications`: the system would remember
  any other path. A login launch starts in the background, detected from the `lgit` Apple event;
  that detection has only been exercised through `FLUENCE_START_IN_BACKGROUND=1` (honoured under
  `FLUENCE_SUPPORT_DIRECTORY` only), never by a real login.
- **If Fluence quits by itself, find who asked before looking for a defect** (FLU-64). On
  2026-10-11 « the red cross quits the menu bar part too » was Supercharge (Clement's own
  auto-quit tool): it sent `aevt quit` to Fluence 6 s after its last window closed. The dying
  process logs `Handling Quit AppleEvent` (an outside quit) rather than `Termination complete`
  (our own `NSApp.terminate`), and in `RECEIVED:(aevt,quit) {… target=X …}` **X is the sender**.
  Fluence was excluded in Supercharge; refusing outside quit events inside Fluence was rejected,
  because logout, the Dock, Sparkle and scripts use the same event.
- **A test copy carries its own bundle ID** (`make app BUNDLE_ID=io.github.clementvnrd.fluence.bgtest`),
  and the staged bundle's ID is read with `PlistBuddy` before `open`. Launch it by its explicit
  path, never from a glob: a copy with the real ID runs beside the installed app, both holding the
  shortcut.

**Choosing a microphone in Settings must not trust the engine's output format** (FLU-62, Clement:
dictation came out as unreadable text in another language). `AVAudioEngine` takes its rate from the
default *output* device, so right after a USB microphone is chosen `inputNode.outputFormat` still
says 44.1 kHz (headphones) while a webcam delivers 16 kHz. A tap installed with that stale format
got no audio at all, or 16 kHz audio taken for 44.1 kHz, which `StreamConverter` then resampled a
second time: speech sped up 2.75×, and Parakeet answered with confident nonsense. `AudioCapture`
now selects the device with `auAudioUnit.setDeviceID`, installs the tap with `inputFormat`, and
`CaptureConfigurationPolicy` ignores the configuration-change notification that choosing a device
posts while the engine runs on that format (the old code rebuilt the engine on every one until it
gave up). A symptom to recognise in the log: `capture started — 44100Hz` while the input device is
at 16000, and a dictation whose « Parakeet: N s audio » is about 0.36 × the capture time. Measure
with the real class on the real device; the format a node *reports* proved nothing.

**In the user's shell, `log` is a zsh builtin, not the macOS log tool:** call `/usr/bin/log`.

**Never launch a `.app` that sits inside the checkout.** In a synced folder the sync daemon can
break its signature. `make` stages the bundle in `~/Library/Caches/FluenceBuild/<hash>/` (`make run`
opens that copy); the one that really runs is what `make install` puts in `/Applications`.

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

## Text matching in the dictionary

**NFC normalization is load-bearing — don't remove it.** macOS returns decomposed strings,
so without it an accented trigger silently never fires.

---

## Not built, not planned

1. **Context awareness** — reading the text around the caret (opt-in) to spell names right.
2. **Notarization** is not planned: no Developer ID, decided 2026-10-08 (FLU-39); a first
   copy on another Mac needs *Open Anyway* once.
