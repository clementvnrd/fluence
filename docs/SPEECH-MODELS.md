# Speech models for French dictation (FLU-24)

Clement, 2026-10-08: "les modèles sont catastrophiques, la dictée ne marche pas". He dictates
mostly in French, on a MacBook Air M2 (16 GB), often through a C920 webcam a metre away. His
settings were Whisper, model Small, which the app labelled "Recommandé".

## The bench

`bench/french` runs each engine **the way the app runs it** (same models, same decoding
options, French) on four sets, and scores the share of words wrong (WER, corpus level, after
lowercasing and removing punctuation; numbers are left as written, so "30" for "trente" counts
as an error for every engine alike):

| Set | What | Size |
|---|---|---|
| `fleurs` | Real people reading French sentences (Google FLEURS `fr_fr` dev, first 100, CC-BY-4.0) | 16.8 min |
| `fleurs-webcam` | The same through a simulated distant webcam: room reflections, 150–5500 Hz band, pink noise ~19 dB below the speech | 16.8 min |
| `tech` | 16 synthetic dictations full of English tech words ("pull request sur GitHub", "Node.js", "Vercel", "la CI"), four macOS French voices, plus one 44 s dictation | 3.6 min |
| `tech-webcam` | The same through the webcam | 3.6 min |

No one's recordings are used. Synthetic voices are cleaner than people; they are there for the
vocabulary, the FLEURS sets for real voices.

```bash
cd bench/french
scripts/make-sets.sh        # downloads FLEURS (~140 MB), builds the four sets in /tmp/fluence-french-bench
scripts/run.sh              # every engine, one after the other, then the scores
```

## Results (MacBook Air M2, 16 GB, macOS 27, 2026-10-08)

Words wrong, lower is better. "× real time": seconds of audio per second of computing, higher
is faster. "44 s dictation": the wait after releasing the key on the long dictation.

| Engine | fleurs | fleurs-webcam | tech | tech-webcam | × real time | 44 s dictation |
|---|---:|---:|---:|---:|---:|---:|
| **Parakeet Ultra** | 6.7 % | **9.2 %** | 9.7 % | **11.5 %** | **100×** | **0.3 s** |
| Parakeet v3 (before) | **6.3 %** | 10.1 % | **9.4 %** | 14.7 % | 61× | 0.4 s |
| Apple SpeechTranscriber | 7.6 % | 12.1 % | 18.6 % | 24.1 % | 50×¹ | 0.7 s¹ |
| Whisper Small (Clement's setting) | 13.1 % | 24.2 % | 19.9 % | 45.5 % | 13× | 5.1 s |
| Whisper Large v3 Turbo² | 7.8 % | — | 9.2 % | 11.3 % | **0.6×** | **46 s** |

¹ On a file. In the app Apple streams while you talk, so the wait after release is shorter.
² Slower than real time on the M2, so only 35 of the FLEURS sentences and the tech sets were
run. On those same 35 sentences: Turbo 7.8 %, Parakeet v3 6.9 %, Ultra 9.1 %, Apple 9.3 %,
Whisper Small 13.4 %.

What goes wrong with Whisper Small, on the synthetic dictations: whole sentences invented
("Je vous remercie d'un autre compte…" for "Je veux une réunion de trente minutes…"), others
dropped entirely, tech words mangled ("le baccès dans les subscriptes" for "le back-end en
TypeScript").

## Decision

* **Parakeet uses Ultra** (`ParakeetModels.version`), for dictation and for meetings. Same
  architecture and decoding as v3, so nothing else changes; ~600 MB instead of ~470 MB, fetched
  once on first use. It is level with v3 on clean speech, better through the webcam, faster.
* **Parakeet is the engine to use in French.** Réglages › Transcription says so in one amber
  line when another engine is chosen with French or Auto; Whisper Small is no longer labelled
  "Recommandé".
* Whisper and Apple stay available: Apple for live text while talking, Whisper for its
  punctuation. Turbo matches Ultra's accuracy but is unusable for dictation on an M1/M2.
* The default engine for a new install stays Apple (nothing to download before the first
  dictation); changing that is a separate choice.

## The models proposed (and why they are not in)

| Model | What it is | Verdict for French dictation |
|---|---|---|
| [FermionResearch/Phonon-2](https://huggingface.co/FermionResearch/Phonon-2) | Parakeet v3 retrained with ~2-bit weights, 164 MB | **English only.** FluidAudio supports it (`.phonon2`); worth it for an English-only mode, not for French. |
| [moondream/parakeet-redux](https://huggingface.co/moondream/parakeet-redux) | Parakeet v3 with ternary weights, 178 MB | Smaller but **worse in French** (FLEURS fr 7.71 vs 4.81 for v3, upstream card) and in noise. Its sibling **Parakeet Ultra**, same authors, is the one adopted. |
| [Cactus-Compute/whistle](https://huggingface.co/Cactus-Compute/whistle) | 17 MB model, 7 languages incl. French, its own engine (`.cact`) | No published French score in text, no Swift/Core ML runtime; a 17 MB model is not expected to beat a 600 M-parameter one. Not benched. |
| [nvidia/nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | Streaming model, 40 languages | Streams (text while talking) but **~9–11 % on FLEURS French** (upstream card; FluidAudio's Core ML build: 9.4–9.8 %), against ~5–6 % for the Parakeet family. A candidate to replace Apple's live text one day, not Parakeet. |
| Cohere Transcribe 03-2026 (in FluidAudio) | 2 B parameters, 14 languages | Accurate (FLEURS fr 6.2 %) but 2.2× real time on an M4 Pro, so slower than real time on an M2. |

## Beyond the model

A distant mic costs every engine (compare `fleurs` and `fleurs-webcam`): a third more
errors for Parakeet Ultra, half again for Apple and v3, nearly double for Whisper Small. A
closer mic (the MacBook's own, or a headset) is worth trying before blaming a model; the bench
cannot measure a real room, so this one is for Clement to try.
