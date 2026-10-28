# FLU-86 — Getting Fluence's French dictation to Wispr Flow accuracy, on device

MacBook Air M2 (16 GB), macOS 27.2, 2026-10-28. Every number in §1–§4 was measured on this Mac
for this report. §5–§6 are from the literature (sources linked). No audio went to any cloud API,
nothing was read from `~/Library/Application Support/Fluence`, nothing was committed.

## TL;DR

* **One model clearly beats Parakeet Ultra in French: Qwen3-ASR 1.7B with the vocabulary as
  hotwords.** Same audio, same scoring: tech 6.5 % vs 9.7 %, tech-webcam 7.9 % vs 11.5 % (−31–33 %
  relative), FLEURS 4.8 % vs 8.7 %, tech-term recall 88 % vs 67 %, no false tech terms on
  FLEURS. It does **not** help through the simulated webcam on FLEURS (10.2 % vs 10.2 %). Cost:
  3.2× real time on the M2 GPU (MLX, 8-bit), so a 4 s dictation waits 1.7 s instead of 0.07 s and
  the 44 s one 10.8 s instead of 0.35 s; 3.7 GB of GPU memory.
* **Everything else measured is level with Ultra or worse**: Whisper large-v3-turbo (MLX, 4-bit),
  Qwen3-ASR 0.6B, Voxtral Mini 4B Realtime (0.5× real time, one sentence came out in Japanese).
* **The app's Parakeet vocabulary boost makes French worse everywhere** (FLEURS 6.7 → 10.2 %,
  tech 9.7 → 15.2 %, tech-webcam 11.5 → 18.1 %): its English CTC model rewrites ordinary French
  words into dictionary terms (« place » → « Slack », « son » → « JSON », « fleuve » →
  « Fluence »). FluidAudio's over-fire controls do not fix it. Turn it off for French.
* **LLM post-correction, free-form, is harmful** (Apple Foundation Models: tech 9.7 → 24.1 %; the
  app's own Medium cleanup prompt answers or rewrites dictations: tech 53.9 %). **Constrained to
  "swap a look-alike span for a dictionary term"** it is a safe win: Apple FM tech 9.7 → 8.9 %,
  tech-webcam 11.5 → 10.2 % (~1.3 s median); Qwen3-4B (MLX) tech 7.6 %, tech-webcam 9.9 % but
  5.2 s per dictation on the M2. FLEURS unchanged and 0 false terms in both.
* **Exact-string « learned corrections » barely transfer** across acoustic conditions: corrections
  learnt from the clean tech set take tech-webcam only from 11.5 to 11.0 % (the same word is
  misheard differently through the webcam).
* **Neural denoising before ASR (LocalVQE) hurts** (fleurs-webcam 9.2 → 12.9 % on the full set).

## 0. Setup and reproduction

Workspace: `<workspace>/` (below `$A`).

| Item | Version |
|---|---|
| Bench | `bench/french` from `own-bench-flu-74` (main @ c5a52e6 + bench rewrite), copied to `$A/fbench-src`; one engine block added in `Sources/fbench/main.swift` (`parakeet-ultra-boost`, `parakeet-ultra-vqe`) — the scoring and sets are untouched |
| Swift / FluidAudio / WhisperKit | Swift 6.4, FluidAudio 0.17.6 (ca0cbe7), argmax-oss-swift 1.1.0 |
| Python venv `$A/venv` | Python 3.12.0, mlx 0.32.4, mlx-audio 0.6.2, mlx-lm 0.32.2, mlx-whisper 0.4.3, soundfile 0.14.0 |
| MLX models (HF cache `~/Library/Caches/audit-flu-86-hf`, 8.7 GB) | `mlx-community/Qwen3-ASR-1.7B-8bit`@a8379a2, `Qwen3-ASR-0.6B-8bit`@89e96d9, `whisper-large-v3-turbo-q4`@660c343, `Voxtral-Mini-4B-Realtime-2602-4bit`@fdebf7b, `Qwen3-4B-Instruct-2507-4bit`@50d4277 |
| Core ML models | FluidAudio `parakeet-ultra`, `localvqe` (already on the Mac), `parakeet-ctc-110m-coreml` (fetched for the boost test, ~98 MB, deleted afterwards — see §7) |

Sets (built with the bench's own script, `FBENCH_DIR=$A/bench zsh fbench-src/scripts/make-sets.sh`):
`tech` (17 synthetic dictations incl. the 44 s one), `tech-webcam` (17), and for the slow engines
the **first 40** sentences of `fleurs` and `fleurs-webcam` (the full sets have 100). The list is
`$A/bench/sets/sub.list` (114 items). Parakeet was run on all 234 and scored on both.

Scoring: `scripts/subscore.py` execs the header of the bench's `score.py`, so normalisation
(`norm`) and edit distance (`edits`) are byte-identical to the bench (lowercase, NFKC, apostrophes /
hyphens / dots split words, punctuation dropped, **numbers left as written**). It reports corpus WER
per set on the subset keys only. `scripts/terms.py` adds **tech-term recall** (occurrences of the
40 vocabulary terms in the reference that the output also has) and **false terms** (vocabulary
terms present in the 80 FLEURS outputs but not in their references).

```bash
A=<workspace>; cd $A
export FBENCH_DIR=$A/bench HF_HOME=~/Library/Caches/audit-flu-86-hf
(cd fbench-src && swift build -c release --scratch-path ~/Library/Caches/FluenceBuild/audit-flu-86)
T=~/Library/Caches/FluenceBuild/audit-flu-86/release/fbench
/usr/bin/time -l $T parakeet-ultra bench/sets/all.list > results/main/parakeet-ultra.tsv
/usr/bin/time -l $T parakeet-ultra-boost bench/sets/all.list vocab.txt > results/main/parakeet-ultra-boost.tsv
/usr/bin/time -l $T parakeet-ultra-vqe bench/sets/all.list > results/main/parakeet-ultra-vqe.tsv
source venv/bin/activate
for e in qwen3-asr qwen3-asr-hot qwen3-asr-06-hot whisper-turbo voxtral-rt; do
  /usr/bin/time -l python -I scripts/mlxrun.py $e bench/sets/sub.list vocab.txt > results/mlx/$e.tsv; done
python -I fbench-src/scripts/score.py results/main      # full sets, the bench's own scorer
python -I scripts/subscore.py results/cmp -v            # subset, same normalisation
python -I scripts/terms.py results/cmp vocab.txt
# §3 LLM post-correction (input = Ultra's output on the subset)
xcrun swiftc -swift-version 5 -O scripts/fmcorrect.swift -o scripts/fmcorrect
scripts/fmcorrect prompt-correct.txt results/llm/ultra-raw.tsv "Corrige cette transcription :" > results/llm/ultra+fm-correct.tsv
scripts/fmcorrect prompt-app-cleanup.txt results/llm/ultra-raw.tsv > results/llm/ultra+fm-appcleanup.tsv  # app's frenchBase, verbatim
python -I scripts/llmcorrect.py mlx-community/Qwen3-4B-Instruct-2507-4bit prompt-correct.txt results/llm/ultra-raw.tsv > results/llm/ultra+qwen3-4b-correct.tsv
python -I scripts/constrain.py results/llm/ultra-raw.tsv results/llm/ultra+fm-correct.tsv vocab.txt > results/llm/ultra+fm-correct+vocabmerge.tsv
guard/guard results/llm/ultra-raw.tsv results/llm/ultra+fm-correct.tsv > results/llm/ultra+fm-correct+guard.tsv   # app's CleanupGuard
# §4 dictionary / learned corrections (app's DictionaryCorrector + TechLexicon)
python -I scripts/learn.py results/main/parakeet-ultra.tsv tech vocab.txt > learned-from-tech.tsv
dict/dict learned-from-tech.tsv results/dict/ultra.tsv lexicon > results/dict/ultra+lexicon+learned.tsv
python -I scripts/subscore.py results/llm; python -I scripts/subscore.py results/dict; python -I scripts/subscore.py results/boost
```
`guard/guard` and `dict/dict` are compiled straight from the repo's `Sources/FluenceCore/{CleanupGuard,FrenchNumberWords,DictationLanguage}.swift`
and `Sources/FluenceDictionary/*.swift` with a 20-line `main.swift` each (in `$A/guard`, `$A/dict`).
Every raw output is kept as TSV under `$A/results/` (`id, audio s, compute s, text`).

`vocab.txt` = 40 terms, the app's bias limit (`BiasPhrases.biasLimit`): the 24 tech terms that the
tech set contains (pull request, GitHub, Linear, Vercel, back-end, TypeScript, Node.js, Claude,
merge, CI, Slack, Notion, Mac, Neural Engine, issue, backlog, label, bug, webcam, JSON, macOS,
Windows, Whisper, Parakeet) + 16 distractors from `TechLexicon` (Claude Code, Anthropic, OpenAI,
Wispr Flow, Superwhisper, Fluence, Cursor, VSCode, Ghostty, Figma, Supabase, WhisperKit, CoreML,
Docker, Kubernetes, PostgreSQL). It is the realistic « my dictionary » case: every word the user
needs is in it, plus words he does not say this time.

Memory: `/usr/bin/time -l` maximum resident set size; MLX engines also report
`mx.get_peak_memory()` (GPU allocations). Core ML / ANE memory is **not** visible in RSS, so the
Parakeet figure underestimates (the app's own note: ~0.6 GB of ANE memory).

## 1. ASR models measured (same audio, same scoring)

Subset (40 + 40 FLEURS, 17 + 17 tech). WER %, lower is better. « × RT » = seconds of audio per
second of compute over the subset; « 4 s dict. » = median wait on the 16 short tech dictations
(mean 4.3 s of audio); « 44 s » = the long dictation.

| Engine (runtime) | fleurs | fleurs-webcam | tech | tech-webcam | term recall tech / webcam | × RT | 4 s dict. | 44 s | Memory |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| **Parakeet Ultra** (Core ML/ANE, FluidAudio, as the app) | 8.7 | 10.2 | 9.7 | 11.5 | 67 % / 63 % | **89.5×** | **0.07 s** | **0.35 s** | RSS 0.63 GB (+ANE) |
| **Qwen3-ASR 1.7B 8-bit + hotwords** (MLX GPU) | **4.8** | 10.2 | **6.5** | **7.9** | **88 % / 77 %** | 3.2× | 1.67 s | 10.8 s | GPU peak 3.69 GB |
| Qwen3-ASR 1.7B 8-bit, no hotwords | 5.4 | 10.3 | 7.3 | 9.4 | 79 % / 72 % | 3.9× | 1.61 s | 11.2 s | GPU peak 3.69 GB |
| Qwen3-ASR 0.6B 8-bit + hotwords | 9.2 | 15.9 | 11.8 | 12.8 | 86 % / 74 % | 9.5× | 0.54 s | 4.1 s | GPU peak 2.14 GB |
| Whisper large-v3-turbo 4-bit (mlx-whisper GPU) | 9.2 | 12.6 | 11.0 | 12.8 | 65 % / 63 % | 3.5× | 2.39 s | 6.0 s | GPU peak 1.14 GB |
| Voxtral Mini 4B Realtime 4-bit (mlx-audio) | stopped | — | 29.1¹ | — | — | **0.50×** | 8.9 s | — | GPU peak 5.08 GB, footprint 6.4 GB |

¹ Stopped by the audit rule after 10 items (slower than real time). On those same 10 tech items:
Voxtral 29.1 %, Parakeet Ultra 12.8 %, Qwen3-ASR-hot 4.1 %, Whisper turbo 14.9 %. It wrote
`tech/t10` in Japanese (« オナンスシグラ… ») — mlx-audio's Realtime path has no language lock — and
mangled t07 (« Magdo à Sodor à Longines »). Mistral's own card gives FLEURS-fr 6.42 % at 480 ms
delay, so this M2/MLX/4-bit result is likely partly a runtime/quantisation problem, but it is
slower than real time either way.

Full sets, Parakeet Ultra through the bench's own `score.py` (reproduces `docs/SPEECH-MODELS.md`
exactly): fleurs 6.7 %, fleurs-webcam 9.2 %, tech 9.7 %, tech-webcam 11.5 %, 96× real time,
0.35 s on the 44 s dictation. The first 40 FLEURS sentences are harder than the 100 (8.7 vs 6.7 %).

Reading:
* **Qwen3-ASR 1.7B** is the only model that clearly beats Ultra, and its hotword list (passed in
  the system prompt, `generate(..., hotwords=[...])`) is genuine contextual biasing: +4–9 points of
  tech-term recall, tech WER 7.3 → 6.5 %, **zero** false insertions on FLEURS. The FLEURS-webcam
  tie is partly number style: Qwen writes « mille quatre cents », « deux mille dix », « treizième »
  where the references have digits, which the bench counts as errors for every engine alike.
  Remaining errors are the hard names (« Parakeet » → « par a qui est »).
* The cost is speed: on the M2 GPU it needs ~0.4 s per second of audio. A typical 4–8 s dictation
  waits 1.5–3 s, a 44 s one 11 s, against a near-instant Ultra. Qwen3-ASR has a native streaming
  mode (upstream README; only in its vLLM backend today, not in mlx-audio) which would hide most of
  that while the user talks — not measured here.
* Whisper large-v3-turbo on MLX/GPU is **6× faster than the WhisperKit/ANE build** measured in
  SPEECH-MODELS.md (3.5× vs 0.6× real time) but at 4-bit it is slightly behind Ultra everywhere.
* Qwen3-ASR 0.6B is not an alternative: worse than Ultra on every set.

## 2. Contextual biasing: the app's Parakeet vocabulary boost (FluidAudio CTC rescoring)

Exactly the app's path (`ParakeetEngine.boosted`): `VocabularyBoostingSession(vocabulary:
CustomVocabularyContext(terms: …), ctcModels: CtcModels.downloadAndLoad(variant: .ctc110m))`, then
`session.rescore(text:tokenTimings:audioSamples:)` on Ultra's output, 40-term `vocab.txt`.

| Ultra + … | fleurs | fleurs-webcam | tech | tech-webcam | term recall | false terms / 80 FLEURS | × RT | 44 s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| nothing (baseline) | 8.7 | 10.2 | 9.7 | 11.5 | 67 % / 63 % | 0 | 89.5× | 0.35 s |
| vocabulary boost, defaults (as the app) | 13.1 | 14.3 | 15.2 | 18.1 | 84 % / 77 % | **76** | 19.5× | 1.48 s |
| boost + FluidAudio « short-vocab » over-fire controls² | 12.9 | 14.2 | 15.2 | 18.1 | 84 % / 77 % | 73 | 15.8× | 2.00 s |
| boost + controls + spotter rescue off | 12.9 | 14.1 | 15.2 | 18.1 | 84 % / 77 % | 73 | 24.1× | 1.56 s |

Full sets with defaults (`score.py`): fleurs 6.7 → **10.2 %**, fleurs-webcam 9.2 → **12.7 %**,
tech 9.7 → **15.2 %**, tech-webcam 11.5 → **18.1 %**; 117 of 234 transcripts changed. Peak RSS
0.18 GB extra.

² `FLUID_CBW_TAPER_PIVOT=5 FLUID_SPOTTER_MIN_SIM=0.30 FLUID_SPOTTER_MIN_SIM_MULTI=0.50`, the
values FluidAudio's `CustomVocabulary.md` recommends against over-firing; `FLUID_SPOTTER_RESCUE=0`.

What it does (diff of Ultra vs Ultra+boost): it finds real terms (« subscript » → « TypeScript »,
« l'Inear » → « Linear », « surversel » → « Vercel », « Macros » → « macOS ») — recall goes up
17 points — but it also rewrites ordinary French: « place » → « Slack » (every « 13e place »),
« son » → « JSON », « fleuve » → « Fluence », « large » → « merge », « Terre » → « Merge »,
« latence » → « Fluence », « le code » → « VSCode », « en trois » → « Anthropic », « lister » →
« Whisper », « ouvertes » → « Kubernetes ». The CTC 110M spotter is an **English** model
(1024-token English BPE) and FluidAudio's guards (stop-words, similarity floors) are English-tuned;
a French word that shares a few phonemes with a term has no competing English hypothesis to lose
to. The over-fire controls change almost nothing. **Verdict: harmful for French as shipped**
(Settings toggle `parakeetVocabularyBoost`, off by default).

## 3. LLM post-correction (raw Ultra transcript + the 40 dictionary terms)

Prompt `$A/prompt-correct.txt` (French; « replace a span only if it sounds like a dictionary term
or is an obvious recognition error; never rephrase, translate, add, answer; keep numbers as
written; return only the text »; its two examples use Supabase/Figma, which are not in the tech
sentences). Greedy decoding. Apple FM via `$A/scripts/fmcorrect` (Swift, `FoundationModels`,
`LanguageModelSession(instructions:)`, `GenerationOptions(sampling: .greedy)`, one session per
dictation, as the app does); MLX via `$A/scripts/llmcorrect.py`.

Three ways to use the answer: **raw** (insert the LLM's text), **+guard** (the app's own
`CleanupGuard.evaluate(original:cleaned:language: .french)`, compiled from `Sources/FluenceCore`,
falls back to the raw transcript when it rejects), **constrained** (`$A/scripts/constrain.py`: keep
only edits that replace ≤3 words by a dictionary term that looks like them, difflib ratio ≥ 0.5 on
letters; every other edit is dropped).

| Ultra + … | fleurs | fleurs-webcam | tech | tech-webcam | term recall | false terms | latency median / 44 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| nothing | 8.7 | 10.2 | 9.7 | 11.5 | 67 % / 63 % | 0 | — |
| Apple FM, correction prompt, raw | 8.7 | 9.8 | **24.1** | 11.3 | 79 % / 79 % | 3 | 1.29 s / 4.9 s |
| Apple FM, correction prompt, +CleanupGuard (44/114 rejected) | 8.8 | 10.2 | 9.7 | 11.5 | 67 % / 63 % | 0 | same |
| **Apple FM, correction prompt, constrained** | 8.7 | 10.2 | **8.9** | **10.2** | 74 % / 74 % | **0** | same |
| Apple FM, **the app's Medium cleanup prompt**, raw | 28.4 | 28.2 | **53.9** | 35.9 | 53 % / 60 % | 0 | 1.37 s / 7.1 s |
| Apple FM, app's Medium cleanup prompt, +CleanupGuard (89/114 rejected) | 10.5 | 12.0 | 9.9 | 11.8 | 67 % / 63 % | 0 | same |
| Qwen3-4B-Instruct-2507 4-bit (MLX), correction prompt, raw | 9.2 | 10.1 | **7.6** | **8.4** | 86 % / 84 % | 1 | 5.2 s / 17.4 s |
| Qwen3-4B, +CleanupGuard (48/114 rejected) | 8.7 | 10.4 | 9.7 | 11.5 | 67 % / 63 % | 0 | same |
| **Qwen3-4B, constrained** | 8.7 | 10.2 | **7.6** | **9.9** | 81 % / 74 % | **0** | same (GPU peak 2.99 GB) |

Hallucinations seen (Apple FM, raw):
* correction prompt: `tech/t14` came back as the vocabulary list itself; « back-end » inserted where
  « l'équipe » / « la CI » / « maire » were (« … avec le back-end »); 2 dictations refused by the
  guardrail (« May contain unsafe content »): an ordinary encyclopaedic FLEURS sentence on the word
  « Gitan » (clean and webcam). The raw transcript is kept in that case.
* app cleanup prompt: dictations that read as requests are **answered or turned into lists**:
  `tech/t14` « La transcription doit garder la ponctuation… » → « 1. Quelle est la différence
  entre un endpoint et un token ? 2. … », `tech/t12` → « Quel est le contenu du fichier JSON ? »,
  `tech/t06` → « 1. À quelle heure ? 2. Avec qui ? ». 6 guardrail refusals on harmless FLEURS news
  sentences (bombs, an accident, the « Gitan » one, a ski result). In the app the 4 s
  timeout and `CleanupGuard` (which rejected 89 of 114 here) catch most of it, so users mostly get
  the Light text back — but then Medium costs ~1.3 s for nothing on most dictations. Part of the
  WER rise is legitimate cleanup (numbers to digits, typography) that WER cannot credit.

Qwen3-4B (MLX) is a much better corrector than Apple's model — raw it takes tech-webcam from 11.5
to 8.4 % — but it still rewrites clean French a little (FLEURS 8.7 → 9.2 %: « dix km de large »,
dropped words) and inserts one false term; constrained it keeps tech 7.6 % / tech-webcam 9.9 % with
FLEURS untouched. It costs 5.2 s per short dictation and 17 s on the 44 s one on the M2 GPU, mostly
prefill of the ~700-token instructions (reusing a KV cache of the fixed system prompt would cut
that; not measured), and 3 GB of GPU memory.

Verdict: a small on-device LLM is a bad free-form corrector of an already-good French transcript
(the « Denoising LM » / GER literature says the same: LLMs help at 20–30 % WER, not at 5–10 %, and
need N-best lists or acoustic evidence). Restricted to dictionary-term swaps it is a safe, modest
gain on tech dictation and harmless elsewhere.

## 4. Learning from corrections, dictionary, denoising (measured)

The app already has: `TechLexicon` (seeded hear→write corrections + terms, applied by
`DictionaryCorrector`), and `EditLearner` (watches the field after insertion and *proposes* a
correction when the user fixes a name or jargon). Simulation with the app's real
`DictionaryCorrector` (compiled from `Sources/FluenceDictionary`, `$A/dict/dict`):
`scripts/learn.py` aligns Ultra's clean-`tech` outputs with the references and keeps each
substitution whose corrected side is a dictionary term — the fixes a user would make:
`GHub→GitHub, Macros→macOS, VCL→Vercel, dans subscript→en TypeScript, l'Inear→Linear,
le node JS→Node.js, scie→CI`.

| Ultra + … | fleurs | fleurs-webcam | tech | tech-webcam | term recall |
|---|---:|---:|---:|---:|---:|
| nothing | 8.7 | 10.2 | 9.7 | 11.5 | 67 % / 63 % |
| TechLexicon (fresh install) | 8.7 | 10.2 | 9.2 | 11.5 | 70 % / 63 % |
| TechLexicon + the 40 terms as terms | 8.7 | 10.2 | 9.2 | 11.5 | 70 % / 63 % |
| TechLexicon + the 7 learnt corrections | 8.7 | 10.2 | 6.8³ | **11.0** | 86 %³ / 67 % |
| LocalVQE denoise/dereverb before Ultra (full sets) | 6.9 | **12.9** | 11.5 | 13.1 | — |

³ Self-test (learnt on these very dictations), an upper bound. The honest number is the transfer
to the **same sentences through the webcam: 11.5 → 11.0 %**. Through the webcam, Ultra hears
« GitHub » as « JE » / « Gub », not « GHub »; exact-string corrections only fire on the exact
mishearing. They never hurt FLEURS (no French word matched), but « scie → CI » would have rewritten
any real « scie » — `EditLearner.isCommon` is the guard that has to catch that one.

LocalVQE (FluidAudio, 19 MB, already used by the Notetaker for echo): 7.7× real time and worse on
every set, most on the webcam sets it is meant to help (9.2 → 12.9 %). Apple's voice processing
(`setVoiceProcessingEnabled` / VoiceProcessingIO) only runs when rendering to a live device, not
offline (WWDC19 « What's new in AVAudioEngine »), so it could not be measured on files; the LocalVQE
result and the literature (enhancement front-ends usually hurt robust end-to-end ASR unless trained
jointly) say to not expect a gain from it either. Not verified live.

## 5. Literature: on-device candidates (French)

| Model (date) | Size / licence | French WER published | Apple-silicon runtime | Streaming | Vocabulary biasing | Verdict for Fluence |
|---|---|---|---|---|---|---|
| Parakeet TDT 0.6B v3 (NVIDIA, 08-2025) | 0.6 B, CC-BY-4.0 | FLEURS-fr 4.81 ([Ultra card](https://huggingface.co/moondream/parakeet-ultra)); 9.0 on 20 clips ([OpenCaptions](https://docs.opencaptions.app/project/speech-model-benchmarks/)) | FluidAudio Core ML/ANE | sliding window | CTC boost (English, §2) | superseded by Ultra |
| **Parakeet Ultra** (moondream, 2026) | 0.6 B, CC-BY-4.0 | FLEURS-fr **4.32** (card); 7.9 on 20 clips (OpenCaptions) | FluidAudio Core ML/ANE (current) | sliding window | same | current default; fastest by far |
| **Qwen3-ASR 1.7B / 0.6B** (Alibaba, 01-2026, [arXiv 2601.21337](https://arxiv.org/abs/2601.21337)) | 1.7 B / 0.6 B, Apache-2.0 | 12-language FLEURS avg 4.90 (1.7B, [README](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)); fr **4.6** (1.7B) / 9.0 (0.6B) on 20 clips (OpenCaptions) | mlx-audio (measured); Core ML 0.6B by [FluidInference](https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml) (2.8× RT on M4 Pro), [soniqo/speech-swift](https://github.com/soniqo/speech-swift); community 1.7B Core ML INT8 (UniMocha, no card) | yes, unified streaming/offline (upstream: vLLM backend only) | **yes**, context/hotwords in the prompt (measured, §1) | **best accuracy measured**; speed is the blocker on M2 |
| Voxtral Mini 4B Realtime 2602 (Mistral, 02-2026) | 4 B, Apache-2.0 | FLEURS-fr 6.42 @480 ms, 5.68 @960 ms, 5.23 @2.4 s ([card](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)) | mlx-audio (measured 0.5× RT on M2) | **yes**, native | no (open model) | too slow on M2 |
| Voxtral Mini 3B 2507 | 3 B, Apache-2.0 | [Voxtral paper](https://mistral.ai/news/voxtral/) FLEURS multi; MLX only bf16 (9.4 GB) | mlx-audio | no | prompt | too big for 16 GB alongside the app; not measured |
| Voxtral Mini Transcribe 2 / 3 (API) | 4 B, API only | Transcribe 2: FLEURS-fr **4.32** (card above) | cloud | Realtime API | **context biasing** (API) | see §6 |
| Canary-1B-v2 (NVIDIA, 09-2025, [arXiv 2509.14128](https://arxiv.org/abs/2509.14128)) | 1 B, CC-BY-4.0 | 25 EU langs; paper's FLEURS-25 average ~10.7–11.0 % (no French figure extracted); community int8 export: fr 5.9 but en 38.6 (broken, OpenCaptions) | FluidAudio `Canary` = English prompt only; MLX ports lack tokenizer files | no | FluidAudio `CanaryKeywordBooster` | no official Apple-silicon build; not measured |
| Canary-1B-flash | 1 B, CC-BY-4.0 | en/de/es/fr | GGUF/ONNX only | no | — | no |
| Whisper large-v3-turbo | 0.8 B, MIT | FLEURS-fr 7.4 / int8 8.3 (OpenCaptions) | WhisperKit ANE 0.6× RT (SPEECH-MODELS.md); mlx-whisper GPU 3.5× RT (measured) | no | initial prompt (made Whisper loop, FLU-20) | level/worse than Ultra |
| bofenghuang whisper-large-v3-french(-distil-dec2/4/8/16) | 0.8–1.5 B, MIT | dec16: CV13 7.18, MLS 3.57, VoxPopuli 8.76 ([card](https://huggingface.co/bofenghuang/whisper-large-v3-french-distil-dec16)) | HF/CT2 only; would need an MLX or WhisperKit conversion | no | prompt | the only French fine-tune with a real eval; worth one conversion if Whisper stays (dec2 has half turbo's 4 decoder layers) |
| Cohere Transcribe 03-2026 | 2 B, Apache-2.0 | FLEURS-fr 6.2 (SPEECH-MODELS.md), 6.7 int8 (OpenCaptions) | FluidAudio Core ML (2.2× RT on M4 Pro → <1× on M2), MLX 8-bit 4.1 GB | no | no | slower than real time on M2 |
| IBM Granite Speech 4.1 2B / 4.0 1B | 2 B / 1 B, Apache-2.0 | en/fr/de/es/pt/ja; English leaderboard 5.33 / 5.52 mean; no French FLEURS number in the card | mlx-community 4/5/8-bit (2–4.5 GB) | no (NAR variant fast) | **yes, « Keywords: … » prompt** | next candidate to measure (not run: download budget) |
| Kyutai stt-1b-en_fr (06-2025) | 1 B, CC-BY-4.0 | no French number published in text | MLX (moshi-mlx, aufklarer 4/8-bit) | **yes**, 0.5 s delay | no | streaming-only niche; not measured |
| Nemotron 3.5 ASR streaming 0.6B | 0.6 B | FLEURS-fr 9–11 % (SPEECH-MODELS.md) | FluidAudio | yes | FluidAudio vocab benchmark | live-text candidate only |
| Moonshine (tiny/base/streaming) | MIT | no French ASR model (STT languages: en, es, zh, ja, ko, vi, uk, ar) | ONNX/Core ML | yes | — | no French |

## 6. Optional cloud engine (literature only, nothing sent)

| Service | French accuracy published | Latency | Price / hour | Biasing | Data retention (default) |
|---|---|---|---|---|---|
| **Mistral Voxtral Mini Transcribe 2/3** | FLEURS-fr 4.32 % (Transcribe 2); Transcribe 3 « 3rd on FLEURS multilingual » | batch; Realtime API (~480 ms) | **$0.18–0.21** (batch $0.003–0.0035/min); realtime $0.36 ($0.006/min) | **context biasing** (terms + free text) | API inputs/outputs kept 30 days for abuse monitoring; ZDR on request ([docs](https://docs.mistral.ai/admin/monitor-comply/zero-data-retention.md)); EU company |
| ElevenLabs Scribe v2 | FLEURS-fr 3.1 % (Scribe v1, [vendor page](https://elevenlabs.io/speech-to-text/french)) | batch; Realtime 150 ms | **$0.22**; realtime $0.39 ([pricing](https://elevenlabs.io/pricing/api)) | keyterm prompting | retained per privacy policy; Zero Retention Mode enterprise-only |
| OpenAI gpt-4o-transcribe / gpt-transcribe | FLEURS chart, no French figure in text; 14.8 % avg on an independent 34-model bench | batch + streaming | $0.36 ($0.006/min); gpt-transcribe $0.27; mini $0.18 | prompt | API abuse logs up to 30 days; ZDR by agreement; gpt-4o-transcribe deprecated 2027-02-26 |
| Deepgram Nova-3 (multilingual / fr) | vendor: −14 % relative vs Nova-2 in French streaming; no absolute fr WER published | streaming < 300 ms | ~$0.26–0.29 ($0.0043–0.0048/min) | keyterm prompting (multilingual) | **list price opts you into the Model Improvement Program** (audio kept for training) unless `mip_opt_out=true` (higher price) |
| Groq whisper-large-v3-turbo / v3 | = Whisper (FLEURS-fr ~7.4 turbo) | very fast batch | **$0.04** / $0.111 | prompt | not retained by default; no training by contract; temporary logs ≤30 days for abuse |
| *Wispr Flow (reference)* | not published | streaming | subscription | personal dictionary + context | cloud-only; ZDR with its AI providers; training on user data opt-out |

Cost for Clément-scale use (~1 h of dictation a month): $0.04–0.40 a month at any of these. The
real costs are the data path (every dictation leaves the Mac) and needing an API key; Mistral
(EU, context biasing, best published French WER per dollar) or ElevenLabs (best published French
WER) would be the ones to offer.

## 7. Fine-tuning and self-improvement (literature + what the measurements imply)

* **Is it feasible?** Parakeet (NeMo) fine-tuning needs CUDA: not on the M2. A rented 24 GB GPU
  (L4/A10G, ~$0.5–1/h) fine-tunes the 0.6B with LoRA/PEFT or partial fine-tuning in 1–3 h on a few
  hours of audio. Community results: German medical PEFT on Parakeet v3, WER 11.73 → 3.28 % on its
  own 122-sample domain set ([NeMo featured checkpoints](https://docs.nvidia.com/nemo/speech/nightly/asr/featured_community_checkpoints.html));
  a full pipeline including Core ML conversion exists ([parakeet-asr-finetuning-pipeline](https://github.com/furkanksl/parakeet-asr-finetuning-pipeline/blob/master/docs/coreml-conversion.md)),
  and shipping goes through FluidAudio's [möbius](https://docs.fluidinference.com/mobius/converting-models)
  export → validate → quantise flow, i.e. the same `.mlmodelc` layout `AsrModels.load(from:)` reads.
  Whisper LoRA on MLX is feasible on the M2 itself (unsloth-mlx « Whisper encoder-decoder LoRA »),
  shipped through WhisperKit's Core ML conversion.
* **How much data / what gain?** Personal adaptation literature: LoRA/hypernetwork adaptation
  halves WER for atypical speakers with very few parameters ([arXiv 2406.04240](https://arxiv.org/html/2406.04240v4));
  personalised LoRA gives ~22–23 % relative WER reduction ([arXiv 2505.12991](https://arxiv.org/html/2505.12991v1));
  EvolveCaptions cut WER for every user within an hour using ~5 min of recordings
  ([arXiv 2510.02181](https://arxiv.org/html/2510.02181)). For a typical speaker the gain comes from
  the **vocabulary and the mic**, not the voice: expect 10–25 % relative on jargon with 30–60 min of
  corrected dictations, little on general French; with < 10 min there is a real risk of
  overfitting / forgetting.
* **The blocker is data, not compute.** Fluence never keeps dictation audio (privacy rule), and a
  « learn from my corrections » loop needs (audio, corrected text) pairs. Any fine-tuning plan
  means an explicit opt-in that stores audio locally, encrypted, with a size cap and delete-all.
* **What works without audio**: (a) the dictionary/hotword list, fed to an engine that really
  biases (Qwen3-ASR hotwords: +9 points term recall, no false terms; measured), (b) the constrained
  LLM swap (§3), (c) EditLearner proposals — but §4 shows exact-string corrections only fix the
  exact same mishearing, so a learnt correction should be stored as a **term** (bias list) more than
  as a hear→write rule, and hear→write rules need the `isCommon` guard (« scie → CI »).
* **Safe loop**: correction observed → proposal (exists) → user accepts → term added to the bias
  list (+ a hear→write rule only if `heard` is not an ordinary French word) → every new rule
  replayed against a fixed French « do-no-harm » corpus (FLEURS 100 + the DoNoHarm tests) and
  refused if it changes any line → per-entry counter of later user reverts, auto-disable after 2.
  No model weights change, so nothing can silently degrade.
* **Noise / far mic**: measured denoising hurt (§4). The webcam costs Ultra +2.5 points absolute on
  FLEURS and +1.8 on tech; the cheapest fix remains the mic (SPEECH-MODELS.md).

## 8. Ranked plan for Fluence

| # | Change | Expected gain (evidence) | Effort | Where | Risks |
|---|---|---|---|---|---|
| 1 | **Disable Parakeet vocabulary boost for French** (hide the toggle or force off when dictation language is fr/auto) | removes up to +3.5 (FLEURS) / +6.6 (tech-webcam) points of WER for anyone who turned it on (§2) | S | on-device | users who liked its hits lose them; keep for English |
| 2 | **Fix the Medium/High Foundation-Models cleanup for French**: it answers or rewrites dictations that read as requests; either retire it for French or replace it by #3 | the raw prompt answers dictations (tech 53.9 %); CleanupGuard rejects 89/114, so Medium mostly costs ~1.4 s for the Light text (§3) | S | on-device | less punctuation polish; check CleanupGuard keeps catching answers |
| 3 | **Constrained dictionary-term LLM swap** after Parakeet: Apple FM with the dictionary in the prompt, keep only « span → dictionary term » edits that look alike (port of `constrain.py`, ~40 lines) | Apple FM: tech 9.7 → 8.9, tech-webcam 11.5 → 10.2, FLEURS ±0, 0 false terms; with a stronger LLM (Qwen3-4B) 7.6 / 9.9 (§3) | M | on-device | +1.2 s median (5 s on 44 s → run only when the transcript contains a near-miss of a term; 4 s timeout already in place); Apple FM availability/guardrail refusals |
| 4 | **Prototype Qwen3-ASR 1.7B as an « Précis » engine** (MLX via mlx-swift, or speech-swift / Core ML), dictionary passed as hotwords | −31–33 % relative WER on tech sets, −45 % on clean FLEURS, term recall 67 → 88 % (§1) | L | on-device | 1.7 s on a 4 s dictation, 11 s on 44 s on the M2; 3.7 GB GPU memory next to a meeting; new runtime (MLX) to ship and sign; Apache-2.0 fine |
| 5 | **Measure Qwen3-ASR streaming** (feed audio while the key is held) and an ANE build of the 1.7B | could turn #4's wait into ~Parakeet-like release latency | M | on-device | Core ML 0.6B port is only 2.8× RT on an M4 Pro; may not reach real time on M2 |
| 6 | **Hybrid by length**: Qwen3-ASR for dictations ≤ 10 s (≤ ~3 s wait), Parakeet Ultra above / for meetings | keeps most of #4's accuracy where people dictate short messages | S (after #4) | on-device | two engines' memory; inconsistent style between short and long |
| 7 | **Learned corrections → bias terms**: when EditLearner's proposal is accepted, also add `written` to the hotword list (Qwen) / FM-swap list (#3), and keep hear→write rules only for non-ordinary words, each replayed against a French do-no-harm corpus | exact rules transfer poorly (11.5 → 11.0 %), acoustic biasing generalises (§4, §1) | M | on-device | dictionary bloat; cap at 40 like today |
| 8 | **Add `--terms` and FLEURS-number-normalised scoring to the bench** (term recall, false-term count, digits vs words) | makes #1–#7 measurable in CI; FLEURS-webcam tie for Qwen is partly number style | S | dev tooling | none |
| 9 | **Record a real webcam set** (Clément reads the 16 tech sentences + 30 FLEURS once, through the C920 and the MacBook mic, kept outside the app's data) | the synthetic webcam is the main unknown; LocalVQE and Qwen conclusions on far-field rest on it | S | dev tooling | personal audio: keep in the bench folder, never in the app |
| 10 | **Optional cloud engine (Mistral Voxtral Transcribe, context biasing)**, off by default, user's own key, per-app allow-list | FLEURS-fr 4.32 % published, ~$0.2/h; closest to Wispr's model | M | optional cloud | data leaves the Mac (30-day retention unless ZDR); network latency; key handling in Keychain |
| 11 | **Do not ship**: LocalVQE before ASR (worse on every set), Whisper turbo as French default (level/worse than Ultra), Qwen3-ASR 0.6B, Voxtral Realtime on M2 (0.5× RT) | avoids regressions (§1, §4) | — | — | — |
| 12 | **Fine-tuning only after an opt-in audio corpus exists**: 30–60 min of corrected dictations → LoRA on Parakeet (rented GPU, ~$5) → möbius Core ML export → A/B on the bench + the user's held-out dictations | 10–25 % relative on jargon (literature, §7) | L | on-device result, cloud GPU to train | privacy (stored audio), overfitting, a model per user to sign/ship |
| 13 | **Measure Granite Speech 4.0 1B / 4.1 2B (keyword-biased prompt)** with the same harness | another biasable model, 1–2 B; may be faster than Qwen 1.7B | S | on-device | French accuracy unpublished |

## 9. Not verified / caveats

* Synthetic voices (tech) and a simulated webcam; 40 FLEURS sentences for the slow engines (the
  first 40 are harder than the 100). Differences under ~1 point on 40 sentences are noise.
* Speed is on a warm, plugged-in M2 with nothing else running; MLX shares the GPU with the UI.
  Parakeet's ANE memory is not in RSS.
* Voxtral Realtime was run offline through mlx-audio 0.6.2 without a language lock, 4-bit; a
  better runtime might do better, but not 2× faster.
* Apple voice isolation could not be tested offline; Qwen3-ASR streaming, Granite, Kyutai, Canary,
  Cohere and the French Whisper fine-tunes were not run (budget/runtime).
* The FluidAudio CTC 110M model I downloaded for §2 went to FluidAudio's shared cache
  (`~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`); it was **deleted
  after the run** so the app's `isVocabularyModelDownloaded` is back to what it was.
