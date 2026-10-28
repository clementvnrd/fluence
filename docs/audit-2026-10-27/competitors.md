# FLU-86 — Competitor study: dictation and meeting notes (October 2026)

Written 2026-10-28. Sources were fetched on 2026-10-28 and are numbered `[n]` (list at the end). Dates in the text are the dates the sources give. "Fluence today" comes from `README.md`, `docs/ROADMAP.md`, `docs/SPEECH-MODELS.md`, `docs/NOTETAKER.md` and the `Sources/` file names on `main` (checkout `own-bench-flu-74`). No code was run.

**Bottom line.** Wispr Flow's French is better than Fluence's for three reasons, and only one of them needs the cloud: (1) its own speech model, trained with reinforcement learning on real dictations and served in the cloud; (2) it gives the model and its formatting LLM **what is on screen** (nearby text, recipients' names, file and variable names) plus the dictionary, on every dictation; (3) the LLM was fine-tuned on real user edits to fix names and formatting without rewriting the text. Fluence can copy (2) and most of (3) on the M2. It cannot copy (1).

---

## 1. Wispr Flow (the one Clément still uses)

**What it is.** Cloud dictation in any app (Mac, Windows, iOS, Android) and, since 2026-08-05, a bot-free Notetaker (Windows since 2026-09-15).[19][18] Free tier with a weekly word cap. Pro costs $15/user/month or $144/year. Growth with Notetaker costs $33/user/month.[9]

### Architecture and models
- **Everything is transcribed in the cloud.** Wispr writes that "Transcription always occurs on the cloud. This is the best way for us to provide accurate, low latency transcription."[7] Its docs say an internet connection is required.[15]
- **ASR.** Until September 2026 it used an *ensemble* of ASR models, choosing the best engine per language. Wispr says this cut error rates by more than half on some languages in internal tests.[5] On 2026-09-17 it shipped **Canto**, its own real-time model, which now runs all dictation.[4][17] Canto starts from a model pretrained on millions of hours. It then gets supervised fine-tuning, then **GRPO reinforcement learning**: several candidate transcripts are sampled per clip, each is scored by WER, and the training favours the better ones.[4] Wispr reports 3.4 % WER on 10 h of real English dictations from 2,300+ speakers. Read off Wispr's own charts, 1–2-word dictations reach 21.4 %, tied with two rivals.[21] An independent summary notes that Wispr ran every system itself on private data, without contextual prompting for the rivals.[22] Canto's successor is reported to be training at more than 10× the scale.[21]
- **LLM formatting step.** It uses **fine-tuned Llama** models served by Baseten on AWS.[1] The whole pipeline (ASR + Llama) targets **< 700 ms end-to-end at p99**, and the LLM must produce 100+ tokens in under 250 ms.[1] The budget the CTO gives: ASR < 200 ms, LLM < 200 ms, network < 200 ms.[2] "We measure latency on a p90 or p99 basis for each user; we don't care at all about p50."[1] Subprocessors listed "for transcription formatting, command mode": OpenAI, Anthropic, Cerebras, Baseten, Fireworks AI.[20]
- **Design choice: no live words.** Wispr deliberately does not stream words while you talk. "Flow can wait, understand, and then write what you meant."[25]

### How it reaches its accuracy (from Wispr's own engineering posts)
- **ASR as a context problem.** To decide what was said, Wispr uses the audio plus "Context from the app they're dictating into", "History of relevant topics they talk about", "Information about names or terms they commonly use" and "Embeddings of the user's voice".[3] Its examples are the cases Clément hits: "Hey Lauren" vs "Hey Laurent" can only be settled from the recipient's address, and whispered audio is ambiguous.[3]
- **Context Awareness (on by default).** On Mac it reads, through Accessibility, "a limited amount of text near your cursor" and the active app. In browsers it identifies the website by URL. It sends "nearby text, proper nouns, app metadata, dictionary entries, and — in coding environments — variable and file names" to the servers during the dictation.[6] It has dedicated conversation context in Slack and Apple Messages.[6] It remembers file names from Cursor and Windsurf across sessions.[6] Password fields are never read.[6]
- **Dictionary entries are injected into the ASR model at runtime.** Canto is trained to use them *selectively*: RL with deliberately wrong "distractor" terms teaches it not to turn "berry" into "Barry" because Barry is in the dictionary.[4] Without that, the model adopted phonetically close distractors about 5× more often after plain RL.[4] Wispr warns its users that "Very large dictionaries can sometimes hurt accuracy … try trimming your dictionary."[16]
- **Learning from corrections.** Wispr aims at "a product that never makes the same mistake twice". It captures edits on the device, decides which ones to repeat and in which contexts, and trains on them.[2] In practice, "Auto-add to Dictionary" watches the text box after pasting and adds re-spelled words.[7] For training, Wispr keeps only the edits that look like recognition errors, using forced-alignment confidence and the location and shape of the edit, and "grafts" them into the reference.[4]
- **Formatting model learned from real edits** (punctuation, spacing, greetings), with language-specific rules. French gets spaces before `; ? !`.[5] French is one of 7 languages "trained and tuned to match English-level performance".[5]
- **Audio hygiene, from the CTO.** Most "it got worse" reports come from the audio: Bluetooth mics, a mic input level set too low, the wrong mic, mumbling.[16] Their fix list: replay the audio, raise the input level, retry from history, trim the dictionary.[16] In 2026 they added a warning when the mic picks up no sound, 14 days of audio replay in History, and support for virtual mics (Krisp, NVIDIA Broadcast).[17]

### Features
- **Backtrack.** "actually", "scratch that", "never mind", or simply restating. It uses the whole dictation as context, and "I actually enjoyed the movie" is kept.[13] Smart Formatting does lists ("one… two…"), spoken punctuation and line breaks.[13] Wispr notes that formatting "does not correct misheard words."[13]
- **Styles.** Four app categories (Personal, Work, Email, Other) with Formal, Casual, Very casual and Excited. The category comes from the app or URL. **Styles apply in English only.**[11] A style changes only capitalisation, punctuation and spacing, never wording.[27] Formatting also follows the surrounding text: lower-case after a mid-sentence caret, a leading space when needed, and the final period dropped according to style and length.[6][13]
- **Command Mode.** Hold Fn+Ctrl, speak an instruction, release. It sends the text box contents and the selection. It can edit, draft, or search with Perplexity.[12] **Transforms** are saved rewrite prompts bound to a key.[78]
- **Languages.** 100+. **One language detected per dictation, not per word**, so "mixed-language speech is less reliable".[15] A "Speaking a different language?" card appears when the speech falls outside the selected languages.[17] French typography is applied automatically, except in coding apps.[14]
- **Whisper / quiet speech.** There is no separate mode: Flow "works reasonably well" when you whisper, with a higher error rate. Sub-audible speech is an open research problem for them.[2]
- **Voice Profile.** An "Insights" report about your speaking, built from local history at word milestones (2,000, 12,000, 37,000…). It is not an acoustic enrolment.[26]
- **Privacy.** Three settings: "Improve the model" (training), "Dictation cloud storage", and "Context awareness". When cloud storage is off, audio is discarded after transcription.[8] Training is always off on Growth and Enterprise.[9] HIPAA BAA on any plan; accepting it turns off Notetaker and Scratchpad.[8] SOC 2 Type II and ISO 27001.[8]
- **What users complain about.** Price: Wispr drew 20 of the 40 price complaints in 290 Reddit verdicts.[24] Cloud-only with no offline mode, a 2.7/5 Trustpilot score citing reliability after the trial, and ~800 MB RAM idle on Windows.[23] Its own docs admit weaker mixed-language results[15] and English-only styles.[11]

## 2. Granola

- **What it is.** An "AI notepad". No bot joins the call: it captures the mic and system audio on the laptop (also iOS, Android, Apple Watch).[32][37][38] **Transcription and summaries run in the cloud**: Deepgram and AssemblyAI for speech, "a blend of different models, primarily OpenAI and Anthropic" for notes.[33][28] Granola says it "initially tried doing these locally on device, but the computation was too much and it slowed down your computer."[40] Audio is not kept; notes live on AWS in the US.[32]
- **Enhanced notes, its core idea.** During the call you type rough notes. Afterwards it combines "the transcription", "Any 'raw' notes you took" and "Information from the calendar event". Your own words stay visually distinct (black) from the AI's additions.[28] You can edit the raw notes and regenerate.[28] Edits do *not* train future notes: consistency comes from templates and profile settings.[28]
- **Capture lifecycle.** Transcription starts only on a click, a notification, or opening a meeting at its start time.[29] It stops when the call app is no longer in use, after 15 minutes without audio, or when the Mac sleeps.[29] A floating live indicator shows while it records.[29]
- **Speakers.** "Me / Them" by default. Real names come from **Google Meet, Zoom and Teams display names read through Accessibility** (or a Chrome extension). It cannot split several people on one room device.[34] Speaker names were the most frequent Reddit complaint (8 of 13 mentions negative); named speakers shipped between July and September 2026.[39]
- **Templates, recipes, chat.** Templates shape the notes. **Recipes** are saved prompts run on one meeting or many, shareable to the workspace, with a choice between standard and "thinking" models.[30][28] **Chat** works across meetings and folders (free plan: last 30 days); it can rewrite note sections and fix names or owners.[31]
- **People and Companies.** A directory built automatically from calendar attendees, enriched with photos, titles and companies. Clicking a person lists every meeting with them.[35]
- **Sharing and integrations.** Private by default; share with your company or anyone with the link.[32] Slack, Notion, HubSpot, Attio, Affinity and Zapier on Business ($14/user/month).[37] **MCP** lets Claude or ChatGPT search notes and transcripts.[36] Snapshots of shared screens shipped on 2026-10-06.[41] 32 languages since 2026-09-02.[38]
- **What users love.** No bot (26 mentions, none negative) and the quality of the notes (20 positive of 26).[39] Complaints: privacy (model training on by default outside Enterprise[40]), reliability, speaker names.[39]

## 3. The others (what each does best)

| Tool | What it does best | Evidence |
|---|---|---|
| **Superwhisper** (Mac/Win/iOS) | **Modes**: voice model + LLM prompt + auto-activation per app or site. **Super Mode** context: selected text (captured at key-down), clipboard (within 3 s), and application text (captured *after* transcription). Its docs warn that unnecessary context hurts quality. Own **S1** models, including **S1-mini, an on-device open-weights cleanup model** with a 5-step tone slider that "will never add content you did not say". Meetings since Oct 2026. | [43][42][44][45][46] |
| **MacWhisper** | File transcription first, plus dictation. Runs local Parakeet, WhisperKit and Qwen3-ASR. Types directly into Chromium apps instead of pasting (Chromium change, Oct 2026). Pastes correctly on any keyboard layout. | [56] |
| **VoiceInk** (open source) | Native, 100 % local. App/URL "Power Modes", screen-aware context, personal dictionary with replacements. $25 one-time. Context sources: selected text, clipboard, visible screen text. | [47][48][49] |
| **Aqua Voice** | Own ASR model **Avalon** (6.24 % average WER on the Open ASR Leaderboard at launch) plus **Deep Context**, which reads the screen for names, code and terms. ~450 ms to insert. Realtime Mode with live words; "send it" voice command; Edit Mode on a selection. | [50] |
| **Willow Voice** | ~200 ms latency claim, auto-learning dictionary, per-app tone, **offline mode** on Mac and iOS. | [51] |
| **Monologue** (Every) | "Deep context" (sees the screen with permission), uses surrounding code for file names in coding agents, keeps the final version after a mid-sentence change of mind; notes and bot-free meetings; MCP/API. | [52][53] |
| **Typeless** | Mid-sentence revisions, lists, per-app tone, **speak-and-translate**; history kept only on the device. | [54] |
| **Spokenly** | Free local Whisper/Parakeet with no word cap, BYO API keys, MCP voice input for coding agents, bot-free meeting capture on Mac. Very few Reddit complaints (30 positive, 3 negative). | [55][24] |
| **Apple Dictation** | Free. Apple says a new on-device model improves dictation accuracy. Systemwide AI dictation announced at WWDC 2026 (iOS 27). One 2026 test measured 11–14 % WER against 3.7 % for Whisper large-v3 on the same audio. | [58][57][59] |
| **Google AI Edge Eloquent** (new, Oct 2026) | Free iOS app, local Gemma-based transcription, optional Gemini cleanup, imports jargon from Gmail. Not available in the EEA. | [60] |
| **Otter** | Bot-based meeting agents. On 2026-10-27: Work Mode pre-meeting briefs drawn from past calls and connected files, live coaching, follow-ups. | [61] |
| **Fathom** | Free capture, "bot or no bot", summaries right after the call, CRM sync, data available inside ChatGPT and Claude. | [62] |
| **Fireflies** | Bot notetaker, 100+ languages, live notes, "AI Apps" (scorecards, reports), channels, CRM and ATS sync. | [63] |
| **tl;dv** | Video recording with a bot, 40+ languages, clips and highlights, CRM sync, insights across hundreds of meetings. | [64] |
| **Jamie** | Bot-free, notes ~30 s after the call, handles mixed-language meetings, task extraction linked to the moment in the meeting. | [65] |
| **Krisp** | Noise cancellation first, then notes; works with any app, in-person and uploaded files. | [66] |
| **Notion AI Meeting Notes** | The desktop app captures system audio and mic; a spoken consent message is played to attendees; custom summary instructions; the notes live where the team's docs are. | [67] |
| **Cluely** | "Undetectable" live answers during calls, screenshots on request. Not a model for Fluence: it conflicts with Fluence's rule that recording is never hidden. | [68] |
| **anarlog** (ex-Hyprnote, MIT) | Open-source, local-first Granola-style notepad. Local transcription on supported Macs, local LLM providers, SQLite + Markdown. Already cited in `NOTETAKER.md` as the reference for meeting detection. | [69] |

## 4. Feature matrix

✅ = has it · ◐ = partial or opt-in · ❌ = no · ? = not found in sources. Fluence column from its README and docs.

| Feature | Wispr Flow | Granola | Superwhisper | VoiceInk | Otter | Fluence today |
|---|---|---|---|---|---|---|
| Push-to-talk dictation in any app | ✅ | ❌ | ✅ | ✅ | ❌ | ✅ (+ hands-free, Esc) |
| Speech processed on device | ❌ cloud[7] | ❌ cloud[33] | ◐ local models or cloud[43] | ✅[47] | ❌ | ✅ (Parakeet/Apple/Whisper) |
| Own trained ASR model | ✅ Canto[4] | ❌ (vendors) | ✅ S1-Voice[45] | ❌ | ✅ proprietary[61] | ❌ (Parakeet Ultra) |
| LLM cleanup | ✅ fine-tuned Llama[1] | n/a | ✅ cloud or S1-mini local[45] | ✅ | n/a | ◐ Apple FM ~3B at Medium/High, guarded |
| Self-correction ("actually…") | ✅[13] | n/a | ✅ | ? | n/a | ✅ rules at Light + FM |
| Styles per app/URL | ✅ (English only)[11] | n/a | ✅ modes[43] | ✅ | n/a | ✅ at High only |
| Context from screen (nearby text, names) | ✅ default on[6] | n/a | ✅ Super Mode[42] | ✅[48] | n/a | ❌ ("Not built yet") |
| Dictionary feeds the ASR | ✅ context-trained[4] | n/a | ? | ✅ | ? | ◐ Apple contextualStrings; Parakeet CTC opt-in |
| Learn from user edits | ✅ auto-add[7] | ❌[28] | ? | ? | ? | ◐ opt-in, asks first |
| Snippets | ✅ | n/a | ? | ✅ replacements | n/a | ✅ |
| Voice command on selection | ✅ Command Mode[12] | chat rewrite[31] | ✅[44] | ✅[48] | n/a | ✅ Command Mode (Apple FM) |
| Code-switching FR/EN | ◐ one language per dictation[15] | ? | ◐ | ◐ | ? | ◐ language toggle + TechLexicon |
| French typography | ✅[14] | ? | ? | ? | ? | ✅ |
| Audio kept for replay/retry | ✅ 14 days[17] | ❌[32] | ✅ history | ? | ✅ | ❌ (never kept) |
| Live words while speaking | ❌ by design[25] | ✅ live transcript | ✅ waveform/realtime | ? | ✅ | ◐ Apple engine only |
| Bot-free meeting capture | ✅[19] | ✅[32] | ✅[46] | ❌ | ❌ (bot) | ✅ (process tap) |
| User's own notes merged into summary | "My thoughts" side notes | ✅ core feature[28] | ? | ❌ | ? | ? (`NotesMerger`/`NotesDraft` exist; not checked) |
| Templates / recipes | ✅ | ✅[30] | ✅ modes | n/a | ✅ | ◐ `NotesTemplate` exists |
| Chat across meetings | ✅ with citations[18] | ✅[31] | ? | ❌ | ✅ | ❌ (roadmap) |
| Speaker names from meeting app | ✅ | ✅ AX[34] | ✅ live | n/a | ✅ | ✅ window reader + diarization |
| People / companies view | contact cards[17] | ✅[35] | ? | n/a | ? | ❌ |
| Pre-meeting brief | ✅[19] | ✅ Business[37] | ? | n/a | ✅[61] | ❌ (roadmap v0.3) |
| MCP / AI-tool access | ✅[19] | ✅[36] | ? | ? | ? | ❌ (Markdown export) |
| Price | $15/mo[9] | $0–14/mo[37] | ? | $25 once[49] | ? | free, own |

## 5. Accuracy techniques they use (with evidence) and what transfers to an M2

| # | Technique | Who | Evidence | On the M2? |
|---|---|---|---|---|
| A | **Context-conditioned recognition**: nearby text, recipient names, app, file and variable names are fed to the ASR and the LLM on each dictation | Wispr, Aqua, Superwhisper, Monologue, VoiceInk | [3][6][50][42][52][48] | **Yes for the LLM and bias lists.** AX is already granted. Apple's `contextualStrings` accepts tagged phrases.[74] Parakeet takes them only through the CTC rescorer. |
| B | **Dictionary as soft context, trained to resist false matches** | Wispr (RL with distractors) | [4] | **Partly.** Fluence can't retrain the model. It can keep biasing precision-first: on 500 real dictations, FluidAudio's default CTC boosting changed 278 transcripts, often wrongly ("Maya → EMEA" ×114). `cbw 0 / minSimilarity 0.7` changed 40, nearly all right.[71] The `ctc110m` spotter "has no non-ASCII pieces", so accented French terms can't be boosted.[71] |
| C | **Small dictionary beats a big one** | Wispr's own guidance | [16]; FluidAudio tested up to 230 terms[70] | Yes. Send a per-dictation subset (terms on screen + starred), not the whole file. |
| D | **LLM rewrite with the user's vocabulary**: fix names, keep the words | Wispr (fine-tuned Llama, <250 ms), Superwhisper S1-mini ("never add content") | [1][45] | **Yes, within limits.** Apple FM on-device has a 4,096-token window per session.[73] Enough for transcript + ~50 terms + 1–2 k chars of screen text. LLM error correction over ASR hypotheses is an established research line (HyPoradise, GenSEC).[77] |
| E | **Learning from edits, filtered to likely recognition errors** | Wispr (auto-add; forced-alignment filter for training) | [7][4] | Yes for the dictionary part (Fluence has `EditWatcher`/`EditLearner`). Retraining the model: no. |
| F | **Per-app formatting at insertion**: lowercase after a mid-sentence caret, spacing, trailing period by style | Wispr | [6][13] | Yes. Deterministic rules from the AX caret context. |
| G | **Wait for the whole utterance, then format** (no streaming of final text) | Wispr | [25] | Fluence already does this. Streaming partials are only worth it for HUD feedback. |
| H | **Latency judged at p99, ~700 ms end-to-end** | Wispr | [1][2] | Fluence measures ≈0.35 s (calculated) for short dictations without the FM. The FM pass is the risk: it needs a budget and a skip rule. |
| I | **Several engines and pick the best** (per language, accent confidence) | Wispr (ensemble before Canto) | [5] | Partly. Parakeet + Apple both run on the M2. For short dictations, run both and let context decide. |
| J | **Audio hygiene in the product**: no-sound warning, replay, retry, virtual mics | Wispr | [16][17] | Yes. macOS Voice Isolation mic mode exists, but only in apps that support Mic Modes.[75] |
| K | **Hotword retrieval then prompt** (top-k terms from a large list, then the model) | Research 2025 | [76] | Yes in spirit. Retrieve on-screen and recent terms first, then bias. |
| L | **Post-meeting re-read with more context** (dictionary, invite names) | Wispr Notetaker | [19] | Yes. Fluence already does a final pass; it can also add attendee names and the dictionary. |

## 6. What Fluence should add or change — ranked

Ranked by expected effect on "Wispr transcribes better", then by cost. Effort: S ≤ 1 day, M = days, L = a week or more. "M2" = can it run on the MacBook Air M2 16 GB.

| # | What Clément sees | Why (evidence) | M2? | Effort | Privacy risk |
|---|---|---|---|---|---|
| 1 | **Context awareness (opt-in, on-device).** Names and terms visible near the caret, the recipient, the window title and the selected text are spelled right. Nothing is stored or logged. | Wispr's #1 lever for names: "uses names and context visible on screen (such as email recipients)".[6] Its CTO calls short and name-only dictations impossible without context.[3] Aqua, Superwhisper, Monologue and VoiceInk all do it.[50][42][52][48] Fluence lists it as "Not built yet". | yes | M | medium (AX reads; same rules as today's URL read: used once, never stored, password fields refused) |
| 2 | **Context-aware insertion formatting.** No capital after a mid-sentence caret, a space added when needed, trailing period dropped in chats per style. | Wispr documents exact rules.[6][13] Small errors like these make dictation feel wrong even when every word is right. | yes | S | low |
| 3 | **Per-dictation vocabulary**: on-screen terms + starred + recent, never the whole file, sent to Apple `contextualStrings`[74], Whisper's prompt, and the CTC rescorer. | Wispr warns large dictionaries hurt.[16] The FluidAudio measurement shows false swaps grow with a broad list.[71] | yes | S | low |
| 4 | **Precision-first Parakeet boosting by default**: `cbw 0`, similarity ≥ 0.7, only for terms seen on screen or starred. Accented French terms go through the text layer, since the spotter can't spell them. | 40 of 500 transcripts changed, nearly all right, vs 278 with many wrong.[71] The non-ASCII limitation is stated in the same report.[71] | yes | S | none |
| 5 | **LLM "name fixer" pass (Medium)**: Apple FM gets the transcript + candidate terms (screen + dictionary). It may only swap words for phonetically close candidates. `CleanupGuard` rejects anything else. | How Wispr's LLM gets "Laurent" from the recipient.[3][6] Superwhisper S1-mini's "never add content" contract.[45] The 4,096-token window fits.[73] | yes | M | low |
| 6 | **Edits learned by default with visible undo**: a corrected name becomes a dictionary entry, shown as « appris : X » with Annuler, only when the edit is a short swap of one word. | Wispr auto-adds on spelling changes.[7] Its training keeps only edits that look like recognition errors.[4] Fluence's learning is opt-in and asks every time. | yes | S | low (text field already re-read for 20 s; nothing stored but the word) |
| 7 | **Coding-context memory**: file, branch and symbol names from the frontmost editor or terminal title are kept as session vocabulary. | Wispr remembers Cursor and Windsurf file names across sessions[6]; Monologue uses surrounding code.[53] Clément dictates "pull request", "merge", repository names. | yes | S | low |
| 8 | **Microphone doctor in the capsule**: « Micro loin / niveau bas / aucun son » with one action (switch to the MacBook mic). A one-time tip on Voice Isolation. | Wispr: the mic is usually the cause of "it got worse"; it added a no-sound warning.[16][17] Fluence's own bench: the webcam costs Parakeet ~1/3 more errors (`SPEECH-MODELS.md`). | yes | S | none |
| 9 | **Retry and compare the last dictation**: keep the last audio in memory for 60 s, offer « Réessayer avec Apple / Whisper ». | Wispr's retry-from-history and 14-day replay.[16][17] Already on Fluence's roadmap (FLU-29). | yes | S | low (memory only) |
| 10 | **Short-utterance mode**: for 1–3-word dictations, run Parakeet and Apple together and pick with context; skip the LLM rewrite. | Short dictations have the highest WER for every model (21.4 % for Canto).[21][4] | yes | S | none |
| 11 | **Formatting-only styles at Light**: capitals, punctuation and spacing per app category, applied by rules without the LLM. | Wispr's styles change only these, never wording.[27] Fluence offers styles only at High (LLM). | yes | S | none |
| 12 | **Better French⇄English handling**: keep French as the language, protect English tech terms (TechLexicon + screen terms), show « Vous parlez une autre langue ? » when detection disagrees. | Wispr itself is weak on mixed speech (one language per dictation)[15] and added a language card.[17] This is where Fluence can beat it. | yes | S–M | none |
| 13 | **p99 latency budget for the FM pass**: measure p90/p99 per user, skip the FM above a budget (e.g. 300 ms) and type the Light result. | Wispr optimises "the p99 experience".[1] Budget breakdown.[2] | yes | S | none |
| 14 | **Live words in the capsule with Parakeet** (streaming partials), final text from batch Parakeet on release. | Aqua Realtime Mode and Superwhisper show live words.[50][46] FluidAudio has streaming models, but vocabulary boosting is batch-only.[70] Wispr chose not to.[25] | yes | M | none |
| 15 | **Highlight uncertain words** in history and the capsule, with one click to fix → dictionary. | Wispr lists "Communicating uncertainty" as a goal.[2] | yes (token confidences) | M | none |
| 16 | **Saved transforms on a key** (« plus court », « en anglais », « formel ») for selected text. | Wispr Transforms/Polish[78]; Superwhisper commands.[44] Fluence's Command Mode already does free-form instructions. | yes | S | none |
| 17 | **Your notes + transcript = the notes** (meetings): a scratch pad during the call whose lines anchor the summary sections, your words shown apart from the model's. | Granola's core idea and what users praise.[28][39] | yes | M (check `NotesMerger` first) | none |
| 18 | **Meeting vocabulary**: attendee names + dictionary + the invite's words bias the final pass. | Wispr Notetaker: names from the invite, acronyms from the dictionary, re-read after the call.[19] Already a ranked idea in Fluence's roadmap. | yes | S | none |
| 19 | **Recipes on finished meetings** (saved prompts: « relance mail », « décisions », « risques »), run by Apple FM. | Granola recipes[30]; Notion custom instructions.[67] | yes | S–M | none |
| 20 | **« Demandez à vos réunions »** with [mm:ss] citations, local index. | Granola chat[31], Wispr Notetaker Q&A with citations.[18] Apple FM 4,096-token limit means retrieval first.[73] | partly (small context) | M–L | medium (index must be sealed) |
| 21 | **People view**: everyone from calendar attendees and named speakers, with their meetings and open next steps. | Granola People and Companies.[35] | yes | M | medium (names; local only) |
| 22 | **Pre-meeting brief**: open next steps from the last meetings with the same people. | Wispr briefs[19], Otter Work Mode[61], Granola Business.[37] On Fluence's roadmap (v0.3). | yes | S–M | low |
| 23 | **Local MCP server** exposing meetings and dictation history read-only to Claude or Codex on this Mac. | Granola MCP[36], Wispr MCP[19], Spokenly MCP voice input.[55] | yes | M | medium (local socket, explicit opt-in) |
| 24 | **Snapshots of shared slides** into the meeting notes. | Granola shipped it on 2026-10-06.[41] | yes but needs Screen Recording | M | high (screen content) |
| 25 | **Test an on-device cleanup model other than Apple FM** (e.g. an open-weights cleanup model in the style of S1-mini) against `CleanupGuard` and the do-no-harm set. | Superwhisper ships an on-device, open-weights cleanup model with a strict "never add content" contract.[45] | to measure (RAM next to Parakeet) | M | none |

**Not recommended.** Cloud ASR or an LLM to catch up with Canto: it breaks Fluence's promise, and Wispr itself pays for 200 ms of network.[2] A Cluely-style hidden assistant.[68] Training a model on Clément's audio: no data is kept, and it is a large job.

## 7. What this means for Clément in one paragraph

Part of the gap is the model: Canto is trained on millions of real dictations with RL, and Fluence will not match that on an M2. But Wispr's own posts say the hard cases (names, short dictations, quiet or distant speech) are settled by **context and the user's own words**, not by a better model alone.[3][4] Fluence already has the pieces: Accessibility, a dictionary, edit watching, Apple FM, Parakeet. What it lacks is the wiring that brings what is on screen into each dictation (items 1–7). Those items are mostly S/M work, all on-device. Two more levers cost little: the microphone (item 8; Fluence's bench shows the webcam alone adds a third more errors) and precision-first boosting (item 4, measured).

## Not verified / gaps

- Wispr's real French accuracy: no public French WER exists; Canto's numbers are English only.[4][21]
- Whether Fluence already merges typed meeting notes (`NotesMerger`, `NotesDraft`) or has templates (`NotesTemplate`): only file names were read.
- Whether Apple's new on-device dictation model runs on the M2: Apple's page names no hardware list in what was fetched.[58]
- Pricing for Superwhisper and Otter was not fetched.
- The FluidAudio boosting measurements come from another developer's app (issue #967), not from Fluence's own bench.[71]
- Granola's "tried locally" quote is reproduced by a third-party audit page, not read on Granola's own site.[40]

## Sources

[1] https://www.baseten.co/resources/customers/wispr-flow
[2] https://wisprflow.ai/research/technical-challenges
[3] https://wisprflow.ai/post/speech-recognition-challenges
[4] https://wisprflow.ai/canto
[5] https://wisprflow.ai/research/supporting-languages
[6] https://docs.wisprflow.ai/articles/4678293671-Context-Awareness
[7] https://wisprflow.ai/data-controls
[8] https://wisprflow.ai/privacy
[9] https://docs.wisprflow.ai/articles/9559327591-flow-plans-and-what-s-included
[11] https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles
[12] https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode
[13] https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack
[14] https://docs.wisprflow.ai/articles/3191899797
[15] https://docs.wisprflow.ai/articles/4048537120-what-to-expect-from-flow-accuracy-and-known-limitations
[16] https://wisprflow.ai/post/transcription-quality
[17] https://releases.sh/wispr-flow
[18] https://wisprflow.ai/whats-new
[19] https://wisprflow.ai/post/wispr-flow-notetaker
[20] https://sub-processors.com/company/docs.wisprflow.ai
[21] https://www.creativeainews.com/articles/wispr-canto-dictation-wer-by-condition-2026
[22] https://benchlm.ai/voice-benchmarks/wispr-canto-launch-evaluation
[23] https://spokenly.app/blog/wispr-flow-review
[24] https://metawhisp.com/blog/best-mac-dictation-app-reddit
[25] https://wisprflow.ai/post/designing-a-natural-and-useful-voice-interface
[26] https://docs.wisprflow.ai/articles/7470830521-voice-profile-updates-when-the-update-your-voice-profile-notification-appears
[27] https://wisprflow.ai/post/personalized-style
[28] https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes
[29] https://docs.granola.ai/help-center/taking-notes/transcription.md
[30] https://docs.granola.ai/help-center/getting-more-from-your-notes/recipes
[31] https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings
[32] https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs
[33] https://www.granola.ai/security
[34] https://docs.granola.ai/help-center/taking-notes/speaker-attribution
[35] https://docs.granola.ai/help-center/people-and-companies
[36] https://docs.granola.ai/help-center/sharing/integrations/mcp
[37] https://www.granola.ai/pricing
[38] https://www.granola.ai/updates
[39] https://metawhisp.com/blog/granola-reddit-reviews
[40] https://getroutines.ai/transparency/granola-ai
[41] https://www.granola.ai/blog
[42] https://superwhisper.com/docs/common-issues/context
[43] https://superwhisper.com/docs/modes/modes
[44] https://superwhisper.com/docs/modes/built-in
[45] https://superwhisper.com/blog/s1
[46] https://superwhisper.com/changelog
[47] https://github.com/Beingpax/VoiceInk
[48] https://tryvoiceink.com/docs/context-awareness
[49] https://blazingfasttranscription.com/blog/voiceink-review
[50] https://aquavoice.com/llms.txt
[51] https://willowvoice.com/features/dictation
[52] https://every.to/on-every/introducing-monologue-effortless-voice-dictation
[53] https://www.monologue.to
[54] https://typeless.cc/en/faq.html
[55] https://spokenly.app
[56] https://releasebot.io/updates/macwhisper
[57] https://techcrunch.com/2026/06/08/apple-introduces-systemwide-dictation
[58] https://www.apple.com/apple-intelligence
[59] https://metawhisp.com/blog/macos-tahoe-dictation
[60] https://ground.news/article/google-quietly-releases-an-offline-first-ai-dictation-app-on-ios
[61] https://otter.ai/blog/otter-rethinks-the-meeting-new-ai-preps-you-coaches-you-and-follows-through
[62] https://www.fathom.ai
[63] https://fireflies.ai/product/features
[64] https://www.g2.com/products/tl-dv/reviews
[65] https://www.meetjamie.ai/blog/llm-info
[66] https://krisp.ai/ai-note-taker
[67] https://www.notion.com/help/ai-meeting-notes
[68] https://cluely.com
[69] https://github.com/fastrepl/anarlog
[70] https://docs.fluidinference.com/asr/custom-vocabulary
[71] https://github.com/FluidInference/FluidAudio/issues/967
[73] https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
[74] https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings
[75] https://support.apple.com/guide/mac-help/use-mic-modes-on-your-mac-mchle82b42f0/mac
[76] https://www.arxiv.org/abs/2512.21828
[77] https://papers.nips.cc/paper_files/paper/2023/hash/6492267465a7ac507be1f9fd1174e78d-Abstract-Datasets_and_Benchmarks.html
[78] https://docs.wisprflow.ai/articles/8068950331-how-to-use-transforms-beta
