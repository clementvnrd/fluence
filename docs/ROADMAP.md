# Fluence roadmap

Written 2026-10-08 from a full audit of `main` @ 9c52e26 (FLU-25). The live plan is in Linear
(team FLU, projects *Releases & updates*, *Dictation: French, fast, light*, *Meeting
Notetaker*, *Reliability & privacy hardening*, *Experience & accessibility*); this file keeps
the reasoning, the numbers and what we decided **not** to do, so they survive without Linear.

## Vision

Fluence is the French-first dictation and meeting memory of one person's Mac. Hold a key,
speak, and the right words land where the cursor is; take a call, and an honest record of who
said what is there afterwards. Everything runs on the Mac: no audio, text or name leaves it.

Trust comes before features. A dictation that changes what was said, or a meeting that
silently disappears, costs more than any new capability earns. The order of work follows:
first do no harm (v0.1.1), then the right defaults and honest feedback (v0.2), then speed and
new uses (v0.3).

## Milestones

| Version | Theme | Issues |
|---|---|---|
| **v0.1** (2026-10-08) | Versioned build, `make release`, one-click updates (Sparkle 2), signed not notarized; installed on Clement's Mac on 2026-10-09 with the trust fixes inside | FLU-26, FLU-27, FLU-41, decisions FLU-39 |
| **v0.1.x** | Trust fixes (cleanup that deleted real words, names that never reached the engine, meetings index overwrite, import crash, double instance, voice prints kept for nothing): merged before 0.1.0 was built, so they shipped in it. The first update through Sparkle is the next version, once the repository is public | FLU-27, FLU-43 |
| **v0.2** | Record only after a click (FLU-34, first); meetings prepared before the first call, not during it (FLU-45); right engine and honest feedback (FLU-29, FLU-30); meetings that survive real calls (FLU-32); a speaker bench (FLU-33); diagnostics and CI that launches the app (FLU-35); data you don't lose and an encrypted backup (FLU-36); first dictation without a doubt and accessibility (FLU-37, FLU-38); public distribution, never notarized (FLU-28, after FLU-43) | |
| **v0.3** | Faster and lighter (FLU-31); regular voices (opt-in); next steps to Reminders, pre-meeting brief, Markdown export | FLU-31, ideas below |

## Decisions (Clement, 2026-10-08, FLU-39)

| Question | Answer | What follows |
|---|---|---|
| Where installed copies find updates | The `clementvnrd/fluence` repository itself, made public | 0.1.0 points there (FLU-41); updates start once the repository is public (FLU-43) |
| Install 0.1.0 on Clement's Mac | Yes | Done on 2026-10-09 (FLU-41), the draft release stays a draft |
| The code Fluence started from | Do not ask its author; Fluence's own code under a licence that forbids copying, changing and selling | PolyForm Strict 1.0.0 (`LICENSE.md`, FLU-42); ~17 % of the lines are still that author's: publish after rewriting them or now (FLU-43, FLU-44) |
| Developer ID | Never | No notarization (`docs/RELEASING.md`) |
| Parakeet as the French default for new installs | Yes | FLU-29 |
| Meetings record only after a click | Yes | FLU-34: the card asks; recording without a click is a setting, off by default (`docs/NOTETAKER.md` §2.1) |
| Encrypted backup of the user's data | Yes | FLU-36 |
| Update-signing key backed up | Done, by Clement | — |
| Internship / networking companion | No, ever: another project | Removed from this roadmap |
| Linear initiatives | No | — |

## Ideas, ranked

Impact 1–5 for Clement's daily use; effort S (≤ 1 day) / M (days) / L (a week+); measured or
reasoned feasibility on the MacBook Air M2 16 GB.

| Idea | Impact | Effort | On the M2 | Privacy risk | Depends on | Where |
|---|---|---|---|---|---|---|
| "Do no harm" French test set run in CI; fixes the word deletions | 5 | S | n/a | none | — | FLU-27 |
| Parakeet Ultra as the French default, consented visible download | 5 | S | yes (62–98× real time) | none | decided yes (FLU-39) | FLU-29 |
| Honest capsule: download progress, « Rien entendu », « Copié — ⌘V », errors with one action | 5 | S | yes | none | — | FLU-29 |
| Wedged-Accessibility detector with one *Réparer* button; *Essayez* step in onboarding | 5 | S–M | yes | none | — | FLU-37 |
| Meeting robustness: back-to-back calls, quit/crash safety, failed saves keep audio | 5 | M | yes | none | — | FLU-32 |
| Keep the last recording 60 s in memory: *Réessayer* with another engine | 4 | S | yes | low (memory only) | — | FLU-29 |
| Meeting vocabulary: bias Parakeet with attendee names and the dictionary | 4 | S | yes | none | FLU-27 (bias order) | FLU-33 follow-up |
| Next steps → Reminders / a Calendar follow-up in one click | 4 | S | yes | medium (iCloud sync) | EventKit reminders | v0.3, not yet an issue |
| Pre-meeting brief: open next steps from the last meeting with the same people | 4 | S–M | yes, no model | low | reliable names (FLU-33) | v0.3, not yet an issue |
| Voice edits of the last dictation (« remplace mardi par mercredi ») | 4 | M | yes | none | Foundation Models | later |
| Bias engines toward what is on screen (recipients, channel names), opt-in | 4 | M | yes | medium (AX reads, never stored) | Accessibility | later |
| « Demandez à vos réunions »: sealed local embeddings + Apple model with [mm:ss] citations | 4 | M–L | yes, ~5 snippets fit | medium (index sealed, deleted with its meeting) | search index (M15) | later |
| Recognise regular voices: enrol on rename, « C'est Marie ? » chip, people list with delete and consent date | 5 | M | yes (256-d cosine) | **high** (biometric, GDPR art. 9; DPIA) | FLU-33 bench, FLU-27 cleanup | v0.3, opt-in only |
| Adaptive post-roll and transcription while holding | 3 | M–L | yes | none | — | FLU-31 |
| French typography (15 h 30, 2 500 €, 4,2 %) and spoken commands that respect engine punctuation | 3 | S | yes | none | FLU-27 test set | FLU-30 |
| Chapters from the timed summary, in the app and the Markdown export | 3 | S | yes | none | notes | later |
| Live FR⇄EN subtitles of the remote side (Apple Translation) | 2 | M | yes | low | language packs | later |

## Not doing

* **No internship-search or networking companion**, in Fluence or beside it: decided by Clement
  on 2026-10-08 (FLU-39) — « c'est un autre projet ». Fluence stays dictation and meeting notes.
* **No cloud transcription, cloud summaries or meeting bot.** It breaks the one promise that
  makes Fluence worth using, and the GDPR transfer story with it.
* **No Developer ID and no notarization**: decided on 2026-10-08 (FLU-39). A first copy on
  another Mac needs *Open Anyway* once; the EdDSA key is the only way to keep updating
  installed copies (`docs/RELEASING.md`).
* **No emotion, sentiment or "engagement" scores from voices.** Biometric inference; EU AI Act
  art. 5(1)(f) bans emotion recognition at work.
* **No always-open microphone** to catch the syllable before the key press: a permanent
  orange dot breaks the privacy promise.
* **No Whisper Turbo or Cohere 2B for dictation**: slower than real time on the M2 (46 s wait
  for a 44 s dictation).
* **No live speaker separation during calls** next to Parakeet on 16 GB, and no
  evaluation-only models (Nemotron preview) in a build. Calibrate the after-meeting pass first.
* **No new French filler-deletion rules, and no larger bias list, before the "do no harm" test
  set exists** (FLU-27): both drift the output.
* **No auto-download of Parakeet at first launch without asking**, no silent default change.
* **No coach marks or sentences under settings**: explanations stay behind ⓘ (design system).
* **No red for updates or errors**: red means "recording".
* **No token inside the app to read the private repository** for updates: a secret in every copy.

## Performance budgets (MacBook Air M2 16 GB)

Measured 2026-10-08 unless marked *calculated*. A pull request that touches these paths states
its numbers against the budget.

| Metric | Today | Budget | Issue |
|---|---|---|---|
| End of speech → text, short dictation (≤ 10 s) | ≈ 0.32–0.35 s *calculated* (250 ms fixed post-roll + 67–100 ms Parakeet) | p50 ≤ 250 ms | FLU-31 |
| End of speech → text, 44 s dictation | ≈ 0.55–0.65 s *calculated* (290–400 ms Parakeet) | ≤ 400 ms | FLU-31 |
| Parakeet Ultra speed | 98.6× real time (perf bench), 62× (dictation corpus, 252 s audio) | ≥ 50× | — |
| Parakeet load | 19.8 s cold (first run after an OS update; 14.9 s on another run), 0.13–0.9 s warm | warm ≤ 0.5 s; cold shown, never blocking | FLU-31 |
| Idle app | 120 MB footprint, 0 % CPU, 0 wake-ups | ≤ 150 MB, 0 wake-ups | — |
| Parakeet resident | 86 MB footprint + 607 MB neural, never unloaded | neural 0 after 15 min idle | FLU-31 |
| Models on Clement's disk not in use | 3.9 GB (Whisper Turbo 3.0 GB labelled « ~1,5 Go ») | removable in one click | FLU-31 |
| App binary | 30 MB unstripped (19.8 MB stripped); bundle 32 MB with Sparkle | bundle ≤ 25 MB | FLU-31 |
| Update check | 1 small request at launch + 1 per 24 h, no profile | unchanged | FLU-26 |

Accuracy, from FLU-24 and this audit (share of words wrong; 2 synthetic voices, 15 sentences —
small samples): Parakeet Ultra 9.8 % on numbers/dates, 9.5 % on proper nouns, 0 % on accented
words, 4.7 % on lists/commands (clean audio); Apple 10.8 %, 13.1 %, 6.5 %, 13.5 %.

## Audit 2026-10-08: findings

IDs: F dictation, M meetings, R robustness, U interface, D distribution and legal. Severity is
for Clement's own use; "P0 public" blocks distribution to others only. Full evidence (file:line,
probes) is in each issue.

| ID | Finding | Sev | Effort | Issue |
|---|---|---|---|---|
| D2 | Private repo cannot serve updates; Sparkle also refuses `file://` (tested) | P0 | S | decided: feed on the repository, live once public (FLU-41, FLU-43) |
| D1 | ~18 % of the code comes from an upstream project with no licence (17.3 % re-measured 2026-10-09) | P0 public | L rewrite | FLU-43, FLU-44 |
| D3 | No third-party notices (FluidAudio, WhisperKit, Sparkle, models) | P0 public | S | FLU-28 |
| D4–D7 | No Developer ID (decided: never) → no notarization; Sparkle key/identity rotation rules | P1 | S | FLU-28, `docs/RELEASING.md` |
| D5 | The build could not embed Sparkle; build number fixed at 1 | P1 | M | **fixed in FLU-26** |
| U1 | Wedged Accessibility grant not detected; ad-hoc fallback would wedge it at every update | P1 (ad-hoc now refused by `make release`) | S | FLU-37 |
| F1, F2 | Default cleanup deletes real words (« en fait », « je voulais dire », short words) — 8/8 clips | P1 | S | FLU-27 |
| F3 | The user's names never bias the engine (lexicon first in the 40 phrases) | P1 | S | FLU-27 |
| R1/M12 | Meetings index overwritten after a failed read | P1 | S | FLU-27 |
| R4 | Import with an absurd timestamp crashes (proven) | P1 | S | FLU-27 |
| M4 | Voice-print candidates collected for nothing, kept after deletion (biometric) | P1 | M | FLU-27 |
| R5 | No single-instance guard | P1 | S | FLU-27 |
| U2/R12 | Text only copied, success sound plays | P1 | S | FLU-27 |
| M1 | Back-to-back calls not offered | P1 | S | FLU-32 |
| M5/R3, R2, M13 | Quit/crash loses audio; failed save or transcription deletes it | P1 | S–M | FLU-32 |
| U10/D8 | Meetings auto-record after 10 s while the app says nothing records without you | P1 | S | FLU-34 |
| M17 | A first meeting asks the microphone, calendar and system-audio permissions and downloads the models during the call | P2 | M | FLU-45 |
| U3/F7 | Model download invisible, inside a dictation | P1 | M | FLU-29 |
| U4/U5 | Errors cut at the start, English, no action | P1 | S | FLU-29 |
| U6–U8 | VoiceOver, keyboard focus, AA contrast | P1 | M | FLU-38 |
| M2, M3 | Speaker thresholds uncalibrated; one name given to all remote speech | P1 / P2 | M | FLU-33 |
| F4–F6, F8–F10 | Spoken punctuation, code formatting in terminals, lexicon « colle → call », fallback below Light, list rules | P2 | S | FLU-30 |
| M6, M7, M8, M10, M11, M14, R10, R14 | Watchdog, lock, default mic only, global tap not shown, notes not retried, copy not concealed, spool errors silent, user switch | P2 | S | FLU-32 (M8, M10 later) |
| R6 | Lost Keychain key silent; no backup; folder out of Time Machine | P2 | M–L | FLU-36 (backup decided) |
| R7, R8 | No diagnostics; CI never builds release or launches the app | P2 | S–M | FLU-35 |
| D10 | README network claims incomplete | P2 | S | **fixed in FLU-26** |
| D11 | Wispr Flow interop in the build | P2 public | S | FLU-28 |
| U11, U13, U15, U16 | Shortcut conflicts, wrong shortcut label, mic state, onboarding friction | P2 | S–M | FLU-37 |
| U14 | No French localisation declared | P2 | S | **fixed in FLU-26** (`CFBundleDevelopmentRegion` fr) |
| U9 | No Reduce Motion / Increase Contrast | P2 | S | FLU-38 |
| M9 | Everyone in the room is « Vous » | P2 | M | FLU-33 |
| F11–F15 | Tap filter, loop guard drops real speech, typography, auto-learn, repeats | P3 | S | FLU-30 |
| R9, R11, R13 | Voice prints overwrite, torn history, corrupted setting crash | P3 | S | FLU-36 |
| M15, M16 | Search on the main thread, minor meeting items | P3 | S–M | later |
| U17–U20 | Leftover text, terminology, deletes without undo, long menu | P3 | S | later |
| D12, D13 | `fluence://correct` window shareable; school e-mail in the signature | P3 | S | later, FLU-28 |

## Ten risks to the v0.1 release

Status on 2026-10-09, after Clement's answers (FLU-39) and the install (FLU-41).

1. ~~No update feed decided~~: the feed is the `fluence` repository; 0.1.0 points there. Until
   the repository is public it answers 404: background checks stay silent (log: `updates: check
   ended — SUSparkleErrorDomain 2001`), a manual check shows an error.
2. **Permissions on the switch from 1.0.0 to 0.1.0**: designated requirement identical;
   Accessibility kept (event tap installed at the first launch, 2026-10-09). Microphone not
   verified (the TCC database is not readable without Full Disk Access): Clement's next
   dictation tells.
3. ~~EdDSA key not backed up~~: backed up by Clement (2026-10-08). With no Developer ID ever,
   it is the only way to keep updating installed copies.
4. **Not notarized, and never will be** (no Developer ID): a copy downloaded by a browser is
   blocked until *Open Anyway*; updates installed by Sparkle are not (tested).
5. **Publishing redistributes code others wrote** (~17 %): the repository stays private and the
   release a draft until FLU-43 is answered.
6. **CI does not build the release bundle or launch it** (R8): the custom Sparkle embedding is
   proven only by today's local end-to-end test (FLU-35).
7. **The update question takes focus**: in the test, the question was answered *Installer*
   within 3–10 s five times, not by the test script (someone at the Mac, or a keystroke). It
   only shows while Fluence is the active app and nothing records, so the worst case is an
   unplanned relaunch, never a lost recording.
8. **"Plus tard" waits for a quit**: a menu-bar app may run for weeks; the version waits in the
   menu (*Installer Fluence x…*) until Clement quits or clicks.
9. ~~Known word deletions ship in 0.1.0~~: FLU-27 was merged before 0.1.0 was built, so the
   installed 0.1.0 has the fixes. The updater's first real use moves to the next version.
10. **Meetings still auto-record after 10 s** (U10/D8) in 0.1.0: decided against, fixed by
   FLU-34; installed copies get it with the next version.

## Could not be verified

* A browser-downloaded (quarantined) first copy of 0.1.0 on this Mac — Gatekeeper behaviour
  stated from Apple's rules, not re-tested.
* The Microphone grant on Clement's real copy after the switch to 0.1.0 (risk 2; Accessibility
  was verified).
* The 24-hour re-check (`SUScheduledCheckInterval` 86400) — only the launch check was observed.
* The "never during a recording" path end to end: covered by `UpdatePolicy` tests and code
  reading; no real dictation or meeting was run on the test copy (it had no permissions).
* Muting in Meet, Teams, Slack or Zoom ending a recording (hypothesis B1, would be P0) — needs a
  real call (FLU-32).
* Power use (`powermetrics` needs sudo); Medium/High cleanup with Foundation Models; Whisper
  (its models live in a folder the audit did not read); real speakers (the corpus used two
  synthetic voices).
* The GitHub account plan (the Developer ID question is closed: never).
* Windows: `dotnet` is not installed on this Mac; Windows CI is the only evidence.
