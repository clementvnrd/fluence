# Meeting speaker bench (FLU-33)

Measures how well Fluence tells meeting speakers apart: **DER** (diarization error rate) and
**speaker-count error**, on public meetings, with the app's own code. FLU-22 fixed phantom
speakers by guessing thresholds; this bench is what keeps them from coming back.

## What runs

1. **Diarizer**: FluidAudio 0.17.5's offline diarizer with exactly the configuration
   `MeetingFinalizer.diarize` uses (`OfflineDiarizerConfig.default`, `maxSpeakers` = the cap
   when one is known). `prepare` (segmentation + embeddings) runs once per meeting and
   `cluster` runs with and without the cap; `--check-process` proves on the first meeting
   that this equals the app's single `process` call.
2. **Consolidation**: `FluenceMeetingCore.SpeakerConsolidation`, compiled from the app's own
   sources (`Sources/FluenceMeetingCore` is a symlink, not a copy), with the cap the app's own
   `SpeakerConsolidation.speakerCap` / `ParticipantRoster` derive.
3. **Scoring** (`Sources/MeetingBench/DER.swift`, unit tested): md-eval / dscore DER —
   missed + false alarm + confusion over total reference speech, overlapped speech scored,
   one-to-one speaker mapping that maximises co-active time (Hungarian), **±0.25 s collar**
   around reference boundaries, scored inside the AMI UEM. A no-collar DER is reported too.
   Checked against `pyannote.metrics` `DiarizationErrorRate(collar=0.5, skip_overlap=False)`
   on the 10 meetings × 2 runs × 2 collars: identical to 0.001 percentage point.

Not scored: words (cpWER would need the app's ASR on every meeting; not done), naming (AMI
has no call window or calendar), and which mic voice is the user in the in-room mode.

## Data

[AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/), **CC BY 4.0**
(<https://groups.inf.ed.ac.uk/ami/corpus/license.shtml>): real 3–4 person meetings in one
room. Reference speaker turns: `only_words` RTTMs and UEMs of
[pyannote/AMI-diarization-setup](https://github.com/pyannote/AMI-diarization-setup)
(Apache-2.0, pinned commit). `meetings.json`: 6 dev meetings (calibration) and 4 test meetings
(held out), about 5 h 42 min of audio, with the SHA-256 of each download.

Three conditions of the same meetings:

| Condition | Audio | Stands for |
|---|---|---|
| `headset` | `Mix-Headset`, as published | a clean call |
| `voip` | `Mix-Headset` through `scripts/voipify.sh`: Opus at 24 / 8 / 12 kbit/s, narrowband, high-pass + fast compressor (an AGC), the channel changing every 60 s | **the remote side of a call** (the system-audio channel the app diarizes). Not a real call: no packet loss, echo canceller or far-end noise suppression |
| `array` | `Array1-01`, one far-field table microphone | **people in one room** on one mic: the hidden in-room mode |

No audio, words or names enter the repository: downloads, caches and results live under
`$MBENCH_DATA` (default `~/Library/Caches/FluenceBench`). The only derived data committed is
the rounded 256-d embeddings in `Tests/FluenceMeetingCoreTests/speaker-consolidation-vectors.json`
(`scripts/vectors.py`).

## Run

```sh
cd bench/meetings
export MBENCH_DATA=~/Library/Caches/FluenceBench     # outside the repo and iCloud
scripts/fetch.sh --array        # ~1.3 GB: AMI audio + references (drop --array: ~650 MB)
scripts/voipify.sh              # needs ffmpeg with libopus
scripts/run.sh headset          # build, diarize (~4 min on Apple silicon), score, sweep
scripts/run.sh voip
scripts/run.sh array
scripts/run.sh voip --skip-diarize 0.65,8,0.03   # score other consolidation settings
swift test --scratch-path ~/Library/Caches/FluenceBuild/mbench   # DER unit tests
```

Each run writes `$MBENCH_DATA/results/<condition>-<time>/results.{md,json}`: pooled and
per-meeting scores for the raw diarizer, the app without and with a cap, the « call window
shows 1 name » case on `fluence/main` vs this branch, a sweep of the consolidation settings on
dev, and the cosine distribution of same-person vs different-people voices.

## Results (2026-10-28, FluidAudio 0.17.5)

DER % (pooled over the 10 meetings, time-weighted) and mean absolute speaker-count error.
`main` is `fluence/main` 68a7309; the branch adds FLU-33 (the call window's names count only
when the list looks complete). Both share the consolidation code and thresholds, so they
differ only when the call window shows a partial list.

| Condition | Pipeline | DER % | Missed % | False alarm % | Confusion % | count error | exact count |
|---|---|---:|---:|---:|---:|---:|---:|
| headset | raw diarizer | 17.2 | 13.5 | 1.3 | 2.5 | 0.10 | 9/10 |
| headset | app, no cap (main = branch) | 17.2 | 13.5 | 1.3 | 2.5 | 0.10 | 9/10 |
| headset | app, window shows 1 name: **main** | 65.8 | 13.5 | 1.3 | 51.1 | 2.90 | 0/10 |
| headset | app, window shows 1 name: **branch** | 17.2 | 13.5 | 1.3 | 2.5 | 0.10 | 9/10 |
| voip | raw diarizer | 39.2 | 18.5 | 0.8 | 20.0 | 1.60 | 2/10 |
| voip | app, no cap (main = branch) | 32.1 | 18.5 | 0.8 | 12.8 | 0.40 | 6/10 |
| voip | app, cap = N (main = branch) | 23.2 | 18.3 | 0.8 | 4.1 | 0.10 | 9/10 |
| voip | app, window shows 1 name: **main** | 67.2 | 18.5 | 0.8 | 47.9 | 2.90 | 0/10 |
| voip | app, window shows 1 name: **branch** | 32.1 | 18.5 | 0.8 | 12.8 | 0.40 | 6/10 |
| array | raw diarizer | 18.5 | 14.2 | 1.5 | 2.8 | 0.20 | 8/10 |
| array | app, no cap = in-room mode | 20.9 | 14.2 | 1.5 | 5.1 | 0.20 | 8/10 |

Per meeting, VoIP condition: DER % (voices kept − people).

| Meeting | split | people | raw diarizer | app, no cap (0.68) | 0.65 | 0.70 | app, cap = N | 1 name: main | 1 name: branch |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ES2011a | dev | 4 | 38.9 (+0) | 38.9 (+0) | 27.9 (-1) | 38.9 (+0) | 38.9 (+0) | 56.6 (-3) | 38.9 (+0) |
| ES2011c | dev | 4 | 33.4 (+2) | 28.0 (+1) | 28.0 (+1) | 33.4 (+2) | 16.8 (+0) | 70.0 (-3) | 28.0 (+1) |
| IB4001 | dev | 4 | 47.9 (+1) | 36.9 (+0) | 28.6 (-1) | 36.9 (+0) | 24.9 (-1) | 56.3 (-3) | 36.9 (+0) |
| IS1008b | dev | 4 | 37.9 (+3) | 18.8 (+1) | 11.9 (+0) | 18.8 (+1) | 11.8 (+0) | 72.3 (-3) | 18.8 (+1) |
| TS3004c | dev | 4 | 42.9 (+2) | 49.4 (+0) | 49.4 (+0) | 42.9 (+2) | 22.9 (+0) | 74.5 (-3) | 49.4 (+0) |
| IB4010 | dev | 4 | 45.8 (+3) | 32.9 (+1) | 32.9 (+1) | 32.9 (+1) | 19.5 (+0) | 71.4 (-3) | 32.9 (+1) |
| EN2002c | test | 3 | 37.7 (+1) | 37.7 (+1) | 30.3 (+0) | 37.7 (+1) | 30.2 (+0) | 66.4 (-2) | 37.7 (+1) |
| EN2002a | test | 4 | 37.5 (+2) | 29.6 (+0) | 29.6 (+0) | 33.7 (+1) | 28.7 (+0) | 65.1 (-3) | 29.6 (+0) |
| ES2004b | test | 4 | 29.2 (+2) | 11.2 (+0) | 11.2 (+0) | 19.5 (+1) | 10.6 (+0) | 70.8 (-3) | 11.2 (+0) |
| IS1009a | test | 4 | 45.2 (+0) | 45.2 (+0) | 45.2 (+0) | 45.2 (+0) | 45.2 (+0) | 44.0 (-3) | 45.2 (+0) |
| **pooled** | | | **39.2** (1.60) | **32.1** (0.40) | **29.0** (0.40) | **33.2** (0.90) | **23.2** (0.10) | **67.2** (2.90) | **32.1** (0.40) |

Merge threshold (`mergeSimilarity`; minor floor 8 s / 3 % throughout), DER % (count error):

| merge | split | headset, no cap | voip, no cap | voip, cap = N | array, no cap | mean |
|---:|---|---:|---:|---:|---:|---:|
| 0.60 | dev | 19.5 (0.33) | 27.6 (0.33) | 23.9 (0.50) | 22.0 (0.50) | 23.2 |
| 0.60 | test | 19.8 (0.00) | 26.2 (0.00) | 25.7 (0.00) | 21.4 (0.00) | 23.3 |
| 0.65 | dev | 15.1 (0.17) | 31.3 (0.67) | 23.9 (0.50) | 22.0 (0.50) | 23.1 |
| 0.65 | test | 19.8 (0.00) | 26.2 (0.00) | 25.7 (0.00) | 21.4 (0.00) | 23.3 |
| **0.68** | dev | 15.1 (0.17) | 34.5 (0.50) | 21.1 (0.17) | 20.5 (0.33) | 22.8 |
| **0.68** | test | 19.8 (0.00) | 29.1 (0.25) | 25.7 (0.00) | 21.4 (0.00) | 24.0 |
| 0.70 | dev | 15.1 (0.17) | 33.9 (1.00) | 22.6 (0.00) | 16.1 (0.17) | 21.9 |
| 0.70 | test | 19.8 (0.00) | 32.4 (0.75) | 25.7 (0.00) | 21.4 (0.00) | 24.8 |

What it says:

- **The partial-list fix is the big win.** When the call window shows one name of four,
  `main` folds everyone into one voice (DER 67 %, count −2.9); the branch ignores the list
  (32 %, the no-cap result).
- **Consolidation helps on VoIP** (39.2 → 32.1 % without a cap, count error 1.6 → 0.4) and
  changes nothing on clean audio. **A known cap helps most** (23.2 %): the diarizer itself
  clusters better with `maxSpeakers`.
- **The thresholds stay** (0.68, 8 s, 3 %). Same-person VoIP splits sit at cosine 0.53–0.77
  (median 0.68) and different people reach 0.71 (0.70 on the room mic), so no merge
  threshold separates them; from 0.60 to 0.70 the mean DER is flat (23.2–23.3 %), and 0.70,
  the best on dev, loses on test (VoIP no cap 29.1 → 32.4 %, count error 0.25 → 0.75). The
  minor-voice floor changes nothing on AMI (no participant speaks under 8 s), so the « 7 s in
  1 h is absorbed » case cannot be measured here.
- **In-room mode** (array): 20.9 % DER, right count in 8/10, worse than the raw diarizer
  (18.5 %) because consolidation merged two different people at cosine 0.698 in TS3004c
  (16.3 → 37.9 %). Which voice is the user is not measured.
