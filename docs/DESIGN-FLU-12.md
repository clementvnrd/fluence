# macOS redesign (FLU-12)

The macOS app's interface as decided by Clement on 2026-10-07, from the approved mock-ups
(01 to 11, mock-up 01 rejected). This file is the record; `AGENTS.md` (Design system) carries
the rules that follow from it.

## The four decisions

1. **Navigation B: a sidebar, Things-3 style.** The main window is a sidebar and a content
   area. Sidebar: the drawn orb, *Fluence*, the AI badge and "language • microphone"; group
   *Dictée* (Transcriptions, Dictionnaire, Snippets with their counts, Styles); group
   *Réunions* (Toutes les réunions with its count and a red dot while a meeting records,
   À venir: calendar calls with a conferencing link, shown only with calendar access, else an
   explanation and a button); at the bottom *Réglages* and a status chip
   ("Raccourci ⌥ · Whisper · Français"). Transcriptions are grouped by day (Aujourd'hui, Hier,
   date). The *Réunions* window is gone: meetings live in the main window. Dark mode follows
   the system (mock-up 11).
2. **Live meeting control A, both surfaces.** A floating card when a call is detected (countdown
   ring, *Enregistrer*, *Pas maintenant*) becomes a compact pill while recording (red dot,
   timer, level, transcript button, stop) that unfolds into a panel (*Garder l'audio*,
   *Consentement*, *Transcription*, *Arrêter*, the live "Vous" / "Les autres" lines). The main
   window shows a "Réunion en cours" banner at the same time. All floating surfaces are
   excluded from screen sharing and never take focus.
3. **Colour A: red means a meeting is recording.** `DS.Color.meetingRecord` is the only
   recording red; dictation stays blue (the *Dicter* pill, the HUD). `DS.Color.destructive`
   (same value) marks delete actions. Amber means "needs attention", green "granted".
4. **Logo B: the drawn orb.** `AquaOrbView` is always drawn in code wherever the small brand
   mark appears (sidebar, settings, onboarding, HUD); `AquaOrb.png` is no longer shipped. The
   Dock icon is unchanged.

Also decided: durations and dates are written the French way (`FrenchFormat`, `FrenchDates`
in FluenceCore: "0,62 s", "1 h 05", "Lun. 5 oct., 14:00"), and a shortcut is shown from the
configured one (`ShortcutLabel`: "⌥ droite", "⌃⌥⌘"), never hard-coded. Speaker labels are
stored in English ("You", "Others", "Speaker 2") and shown in French at display time
("Vous", "Les autres", "Intervenant 2").

## Settings: where every former setting went

The settings window has a sidebar of six sections. Nothing was dropped.

| Former tab / place | Setting | New section |
|---|---|---|
| Général | Push-to-talk key, recorder | Dictée |
| Général | Microphone | Dictée |
| Général | Language (+ 23 others), ⌥L switch | Transcription (⌥L also in Dictée) |
| Général | Engine, Whisper model | Transcription |
| IA & Formatage | Cleanup on/off + smart cleanup | Texte (cleanup level Aucun/Léger/Moyen/Élevé) |
| IA & Formatage | Smart cleanup on Whisper | Transcription |
| IA & Formatage | Code formatting | Texte (and Styles page) |
| IA & Formatage | Snippets on/off | Texte (and Snippets page) |
| IA & Formatage | Command Mode + key | Dictée |
| Texte | Styles per app | Texte (and Styles page) |
| Texte | Learn from edits, frequent terms | Texte |
| Texte | Parakeet vocabulary boost | Transcription |
| Raccourcis | Gesture legend, ⌃⌘V / ⌃⌘C | Dictée |
| Réunions | Detect calls, countdown, max duration, read names, calendar, consent text, delete all meetings | Réunions |
| Réunions | Keep audio by default, meeting retention, voice prints | Confidentialité |
| Confidentialité | Microphone / Accessibility / hotkey status, reset TCC | Confidentialité |
| Confidentialité | History retention | Confidentialité (Ne pas garder / 1 jour / 30 jours / Toujours) |
| Confidentialité | Max dictation duration | Dictée |
| Confidentialité | Assistant (models) | À propos |
| Menu bar only | Sound | Dictée |
| Menu bar only | Compare mode | Transcription |

Meeting retention offers 30 jours / 1 an / Toujours; a different value kept from an older
build (7 or 90 days) stays selected and shown until changed. *Tout effacer* (Confidentialité)
deletes dictations, meetings, notes, audio and voice prints after a confirmation.

## Deliberate differences from the mock-ups

- No "Toutes les apps" filter and no app chip on transcriptions: a dictation does not record
  which app it was typed into. Meetings do record their app, so their list has the filter.
- Next steps have no "done" tick: the notes model has no done state.
- The floating pill's level bars follow recent speech: the meeting recorder has no level meter.
- The privacy page keeps a permissions card (microphone, Accessibility, shortcut, reset),
  which the mock-up left out, so no former setting is lost.

## Screenshots

`FLUENCE_SUPPORT_DIRECTORY` (a scratch folder) unlocks development hooks in
`Support/ScreenshotSeed.swift`: synthetic data (`FLUENCE_SEED_FILE`), the page to open
(`FLUENCE_PREVIEW_*`) and `FLUENCE_PREVIEW_SNAPSHOT`, which makes the app draw its own windows
to PNG files. Run a copy of the bundle under another bundle ID so the owner's data,
keychain item and permissions are never touched.
