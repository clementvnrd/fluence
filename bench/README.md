# bench — Apple vs Parakeet, on your own voice

A command-line race between two speech recognisers that run entirely on the Mac:

- **Apple `SpeechTranscriber`**, the on-device engine of macOS 26;
- **Parakeet TDT 0.6B**, NVIDIA's model, run on the ANE (Apple Neural Engine) as CoreML.

Both get the identical audio file and both are scored the same way.

Self-contained — it doesn't build or touch the Fluence app.

## Try it

From `bench/`:

```bash
swift run bench record demo.wav   # talk, then hit Return
swift run bench run demo.wav      # both engines, then the report opens
```

The first `run` downloads Parakeet's CoreML models once (469 MB measured for v3 INT8);
later runs reuse them.

## Measuring accuracy

Type what you really said into a text file beside the clip, for example `demo.txt`
containing « Pack my box with five dozen liquor jugs. », and hand it over:

```bash
swift run bench run demo.wav --ref demo.txt
```

Both engines then get a word error rate (WER) and a character error rate (CER).

## Options

| Flag | Effect |
|---|---|
| `--ref FILE` | score against the text in `FILE` |
| `--v2` | Parakeet v2: English only, better recall |
| `--int4` | 4-bit encoder: smaller and faster |

## What you get

With the example above, in the directory you ran the command from:

- `demo-results.json` — the raw numbers, one object per engine;
- `demo-dashboard.html` — the report, opened in your browser straight away.

Neither should be committed.

## Where Parakeet comes from

- **The model.** Parakeet is NVIDIA's speech recogniser, trained with NeMo and released as
  PyTorch weights. The Neural Engine cannot run those as they are.
- **The conversion.** The open-source Fluid Inference project converts audio models to CoreML
  and publishes FluidAudio, a Swift SDK to run them — much as Argmax's WhisperKit does for Whisper.
  The converted weights are public on Hugging Face.
- **The repo used here.**
  [`FluidInference/parakeet-tdt-0.6b-v3-coreml`](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml),
  derived from `nvidia/parakeet-tdt-0.6b-v3`, licensed CC-BY-4.0, 25 languages (English and
  the European languages).

### Looking inside the repo

`curl` is enough (`jq` makes it readable); the Hugging Face API needs no account and no token.

```bash
MODEL=FluidInference/parakeet-tdt-0.6b-v3-coreml

# A few facts about the model
curl -s "https://huggingface.co/api/models/$MODEL" \
  | jq '{id, downloads, likes, pipeline_tag}'

# Every file with its size, biggest first (LFS size when the file has one)
curl -s "https://huggingface.co/api/models/$MODEL/tree/main?recursive=true" \
  | jq -r '[.[] | select(.type == "file") | {path, bytes: (.lfs.size // .size)}]
           | sort_by(-.bytes) | .[:8][] | "\(.bytes)\t\(.path)"'

# Fetch a single file, here the encoder weights
curl -L -o weight.bin \
  "https://huggingface.co/$MODEL/resolve/main/Encoder.mlmodelc/weights/weight.bin"
```

### Repo size is not download size

The repo weighs about 3 GB because it keeps the same network in several shapes: `.mlpackage`
sources, compiled `.mlmodelc` bundles and an INT4 variant of the encoder. A measured first run pulled only
four compiled models, 469 MB in all, into
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`:

| Size | File | Role |
|---:|---|---|
| 433 MB | `Encoder.mlmodelc` | INT8 acoustic network |
| 23 MB | `Decoder.mlmodelc` | prediction network of the transducer |
| 12 MB | `JointDecisionv3.mlmodelc` | joint layer |
| < 1 MB | `Preprocessor.mlmodelc` | audio to mel features |

FluidAudio skips `MelEncoder` (595 MB) and uses the small preprocessor instead, and prefers
the compiled INT8 encoder to the `.mlpackage` sources: about a sixth of the repo in the end.
The size of a repo tells you nothing about what a client will download.

### Fetching the models yourself

You never have to: FluidAudio's download-and-load call does it and keeps them. To fill a
cache ahead of time or work offline, the official Hugging Face CLI copies the entire repo
to `~/.cache/huggingface/`:

```bash
pip install -U "huggingface_hub[cli]"
hf download FluidInference/parakeet-tdt-0.6b-v3-coreml
```

FluidAudio keeps its own copy in `~/Library/Application Support/FluidAudio/Models/`. Remove
either folder and the next run downloads again.

## What the numbers mean

- **Process time** runs from handing over the audio to receiving the final text. Getting the
  model ready is timed apart and shown as *load*: Apple's models already live in the
  operating system, while Parakeet loads its own once per process.
- **RTF** (real-time factor) is clip length divided by process time, i.e. seconds of audio
  processed per wall-clock second. Higher is quicker: at 100, a one-minute clip is done in 0.6 s.
- **WER / CER** are Levenshtein edit distances over words / characters, divided by the
  length of the reference. Both texts are normalised first (lower case, punctuation dropped,
  single spaces). That step matters: Apple adds punctuation on its own, and a reference typed
  without punctuation would otherwise collect errors that are not errors. CER is there because WER
  counts a technical word missed by one letter (« Kubernetes » coming out as « Cubernetis »)
  as entirely wrong.

## What the numbers do not tell you

Here each engine works in batch: the whole file goes in, the finished text comes out. That
is the right setting for comparing throughput, and the wrong one for judging how dictation
feels.

Apple's transcriber is built to stream. With volatile results turned on it shows words while
you are still speaking, so the wait you notice is close to nothing, whatever its RTF.
In batch, Parakeet only starts once you have stopped talking. The fair test of perceived
latency would use FluidAudio's streaming manager, `SlidingWindowAsrManager`; this tool does
not run it.

So RTF says which engine clears a pile of recordings sooner, not which one feels quicker in
the middle of a sentence. With push-to-talk, once the key is up you are simply waiting for the text,
which makes the batch delay a fair stand-in for what you experience — but still not the
whole story.

## French and the app's own engines

To compare every engine Fluence ships, in French and set up exactly as the app runs them,
use `bench/french` (`fbench`); its results and verdicts are in `docs/SPEECH-MODELS.md`.
