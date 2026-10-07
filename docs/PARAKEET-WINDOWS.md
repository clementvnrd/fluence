# Getting the speech model on Windows

Windows has **no equivalent to Apple's `SpeechAnalyzer`**. On macOS that framework ships with
the OS, manages its own model assets, and needs no download. There is nothing comparable on
Windows — so Parakeet is not the optional upgrade it is on macOS, it is the *only* engine.
The app cannot transcribe until these files are on disk.

This page is written to be followed by a person **or handed to a coding agent verbatim**.

---

## What you are downloading

**NVIDIA Parakeet TDT 0.6B**, converted to ONNX and quantized to int8, run through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx).

| | |
|---|---|
| Download size | **~661 MB** |
| Working set once loaded | **~2 GB** — see [Memory](#memory) |
| Speed | ~40× real time on CPU (a 10 s utterance transcribes in ~250 ms) |
| Load | A few seconds at app start (verification + model load), in the background |
| Network | Needed **once**, for the download. Transcription is fully offline. |
| Licence | Model weights **CC-BY-4.0**; sherpa-onnx **Apache-2.0**. Commercial use permitted with attribution — see [Licence](#licence). |

Two variants. Pick one:

| Repo | Languages | `tokens.txt` | Pinned commit |
|---|---|---|---|
| `csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` | **English only** | 1025 entries | `1ab9323565ddb038682214b292f588070a538ce2` |
| `csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` | **25 languages** | 8193 entries | `2bda32ec70b097a55adaa07d9a7173915b43cc78` |

**Default to v2** unless you dictate in something other than English. Same encoder size, same
speed; v3 simply carries a larger vocabulary.

**Download from the pinned commit, not `resolve/main`.** `main` can change under you; the
commit cannot, and the app knows the exact size and SHA-256 of every file at these commits
(see [Verifying](#verifying-it-worked)).

---

## Where the files go

```
%LOCALAPPDATA%\Fluence\models\parakeet-v2\      (or parakeet-v3\)
    encoder.int8.onnx     ~652 MB
    decoder.int8.onnx     ~7 MB      (v3: ~11.8 MB)
    joiner.int8.onnx      ~1.7 MB    (v3: ~6.4 MB)
    tokens.txt            ~9 KB      (v3: ~94 KB)
    SHA256SUMS            optional — written by the script below
```

Search order, first complete folder wins:

1. `ModelDirectory` in `%LOCALAPPDATA%\Fluence\settings.json`, **if set — and then nothing
   else** (a model you pointed at is never silently replaced by another one).
2. `%LOCALAPPDATA%\Fluence\models\parakeet-v3`, then `…\parakeet-v2`.
3. The same two folders under `models\` next to `Fluence.exe`.

v3 is preferred when both are installed: that folder only exists if someone chose it. Builds
before the rename used `%LOCALAPPDATA%\Murmur`; the app moves that folder, models included,
to `%LOCALAPPDATA%\Fluence` on first launch.

Settings → Model shows the real state: not installed (with every folder checked), loading,
**loaded**, or **failed — with the reason**. "Loaded" means the model was actually loaded, not
merely that the files exist.

> **Do not put these inside the app folder if you install to `Program Files`.** That location
> needs administrator rights to write, so the app cannot download or update the model itself.

---

## Option A — PowerShell, no extra tools *(recommended)*

Nothing to install. Paste this into PowerShell:

```powershell
$dir    = "$env:LOCALAPPDATA\Fluence\models\parakeet-v2"
$commit = "1ab9323565ddb038682214b292f588070a538ce2"
$base   = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/$commit"
$sha256 = @{
  "encoder.int8.onnx" = "a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab"
  "decoder.int8.onnx" = "b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e"
  "joiner.int8.onnx"  = "7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2"
  "tokens.txt"        = "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d"
}

New-Item -ItemType Directory -Force $dir | Out-Null

foreach ($f in $sha256.Keys) {
    Write-Host "Downloading $f ..."
    curl.exe -L --fail --progress-bar -o "$dir\$f" "$base/$f"
    $got = (Get-FileHash -Algorithm SHA256 "$dir\$f").Hash.ToLower()
    if ($got -ne $sha256[$f]) { Write-Host "HASH MISMATCH: $f" -ForegroundColor Red }
}

# The app checks the files against this before every first load (and caches the result).
$sha256.GetEnumerator() | ForEach-Object { "$($_.Value)  $($_.Key)" } |
    Set-Content -Encoding ascii "$dir\SHA256SUMS"

Get-ChildItem $dir | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}}
```

For **v3**, use `parakeet-v3`, the `…-v3-int8` repository, commit
`2bda32ec70b097a55adaa07d9a7173915b43cc78`, and the v3 hashes from the table under
[Verifying](#verifying-it-worked).

> **`curl.exe`, with the `.exe`.** Bare `curl` in PowerShell is an alias for
> `Invoke-WebRequest`, which is a different program. And if you do use
> `Invoke-WebRequest`, you **must** pass `-OutFile` — without it PowerShell buffers the
> whole 650 MB in memory.

Expected output:

```
Name                MB
----                --
decoder.int8.onnx   6.9
encoder.int8.onnx   622.0
joiner.int8.onnx    1.7
tokens.txt          0.0
```

---

## Option B — Hugging Face CLI

The command is **`hf`**. `huggingface-cli` is deprecated.

```powershell
pip install -U "huggingface_hub[cli]"

hf download csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 `
  --revision 1ab9323565ddb038682214b292f588070a538ce2 `
  --include "encoder.int8.onnx" "decoder.int8.onnx" "joiner.int8.onnx" "tokens.txt" `
  --local-dir "$env:LOCALAPPDATA\Fluence\models\parakeet-v2"
```

**No Hugging Face token is required.** These repositories are public. If you are prompted to
log in, you have a typo in the repo name.

---

## Option C — git

```powershell
git lfs install
git clone https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8
git -C sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 checkout 1ab9323565ddb038682214b292f588070a538ce2
```

Clones extra files you don't need (fp32 weights, test audio) — roughly 3 GB. Fine if you
already have `git-lfs`; otherwise use Option A.

---

## Verifying it worked

**The app verifies the files itself before loading them.** It uses `SHA256SUMS` in the model
folder if there is one; otherwise it recognises v2 or v3 by the size of `tokens.txt` and
checks every file against the sizes and hashes built into it (`ModelVerifier.cs`), which are:

| File | v2 bytes | v2 SHA-256 | v3 bytes | v3 SHA-256 |
|---|---|---|---|---|
| `encoder.int8.onnx` | 652,184,296 | `a32b12d1…a2acd651ab` | 652,184,281 | `acfc2b44…3a55fd2247` |
| `decoder.int8.onnx` | 7,257,753 | `b6bb6496…5b31a15c6b4e` | 11,845,275 | `179e50c4…b24248db4e` |
| `joiner.int8.onnx` | 1,739,080 | `79461643…d057c3c43d2` | 6,355,277 | `3164c13f…101719c0948b3` |
| `tokens.txt` | 9,384 | `ec182b70…7f53977d497d` | 93,939 | `d5854467…c7d37e3c35d` |

Full hashes are in the script above (v2) and in `windows/src/Murmur.Speech/ModelVerifier.cs`
(both). They come from the Hugging Face API at the pinned commits (the LFS `oid` *is* the
SHA-256); `tokens.txt` is not in LFS, so it was downloaded and hashed, and its git blob id
checked against the API. To refresh them for a newer commit:

```bash
curl -s https://huggingface.co/api/models/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/tree/<commit> \
  | python3 -c "import json,sys; [print(f['path'], f.get('size'), (f.get('lfs') or {}).get('oid')) for f in json.load(sys.stdin)]"
```

A size mismatch is reported immediately; hashing 660 MB takes a second or two and is done
once — a `.fluence-verified` stamp records each file's size and modification time, and an
unchanged file is not hashed again. A folder that matches no known variant and has no
`SHA256SUMS` is loaded unverified.

**Why this matters: a truncated download does not announce itself.** A partial
`encoder.int8.onnx` fails inside native code with an opaque protobuf error at best, and can
abort the process at worst. Checked first, it becomes a sentence in Settings → Model telling
you which file to download again.

To check by hand:

```powershell
Get-FileHash -Algorithm SHA256 "$env:LOCALAPPDATA\Fluence\models\parakeet-v2\*" | Format-Table Hash, Path
```

`tokens.txt` should be plain text, one `token id` pair per line, starting:

```
<unk> 0
▁t 1
▁th 2
```

---

## <a id="memory"></a>Memory: read this before choosing a machine

**The model needs roughly 2 GB of RAM resident, even for a two-second utterance.** That is
the int8 weights plus the inference runtime's memory arena — it is not a leak and it is not
specific to this app (the same footprint appears running the model from Python).

Measured peak working set by clip length:

| Audio | Peak RAM |
|---|---|
| 7 s | 2.0 GB |
| 60 s | 2.5 GB |
| 300 s | 4.3 GB |

**On an 8 GB machine, expect the app to be a noticeable tenant.** 16 GB is comfortable.

### The 400-second ceiling

The exported encoder carries a fixed relative-position table sized for **5000 frames**. At
80 ms per frame that is **400 seconds**, and beyond it inference *fails* rather than
degrading:

```
Non-zero status code returned while running Add node.
Attempting to broadcast an axis by a dimension other than 1. 126 by 5126
```

The app splits audio into 52–60 second segments, cutting in the quietest 200 ms of the last
8 seconds before the limit (with a short overlap and de-duplication when there is no real
pause), so you will not hit this dictating normally. Recording also stops on its own after
10 minutes (`MaxRecordingMinutes` in settings.json).

---

## Hardware and acceleration

**CPU only. This is deliberate, not a limitation we forgot to lift.**

- sherpa-onnx ships **no GPU package**. Setting a CUDA provider silently falls back to CPU.
- The DirectML runtime is five minor versions behind mainline, forbids parallel inference,
  and wants fixed tensor shapes — which this model, with its variable-length audio input,
  cannot provide.
- CUDA would force every user to install a matching CUDA toolkit.

None of it is worth it. Measured on CPU with int8 weights, transcription runs ~40× faster
than real time. Four threads is the sweet spot — eight measured *slower* than four.

**ARM64 Windows:** no ARM64 build is published yet — CI builds `win-x64` only. The x64 build
runs under emulation and transcription will be much slower. (The project references the
`win-arm64` runtime package, so `dotnet publish -r win-arm64` is the starting point.)

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Model not installed" | Files are in the wrong folder. Settings → Model lists every folder checked. If `ModelDirectory` is set in settings.json, only that folder is checked. |
| "Parakeet failed to load: … is N bytes but should be M" | Truncated download. Delete that file and download it again. |
| "… does not match the published file (SHA-256 differs)" | Corrupt, or a different version. Download again from the pinned commit, or delete `SHA256SUMS` if you deliberately use other files. |
| Protobuf / parse error on load | A damaged file the verifier could not recognise. Run the hash check above. |
| Loads, but every transcript is empty | Windows is blocking microphone access. Settings → Privacy & security → Microphone → **Let desktop apps access your microphone**. WASAPI returns *silence*, not an error, when this is off. |
| "Loading Parakeet…" for a few seconds after launch | Normal: verification (hashing only the first time) and model load, in the background. |
| Consistently slow | You may be running the x64 build on an ARM64 machine. |
| Fails on audio over ~7 minutes | The 400-second ceiling above. |

---

## <a id="licence"></a>Licence and attribution

**Model weights: CC-BY-4.0.** Commercial use is permitted. If you redistribute the model
inside a product you must:

1. **Credit NVIDIA**, name the model, and link both the model card and
   <https://creativecommons.org/licenses/by/4.0/>.
2. **State that it was modified** — the int8 quantization and ONNX export are modifications.
3. **Add no further restrictions.** If your EULA forbids extracting bundled files, it must
   carve out the model weights.

A `THIRD-PARTY-NOTICES.txt` plus a line in the About box satisfies this.

**sherpa-onnx** is Apache-2.0. **ONNX Runtime** is MIT.

> Not legal advice. CC-BY-4.0 is a content licence rather than a software one and carries no
> patent grant. If you are shipping this commercially, have counsel confirm.

---

## For a coding agent

Minimum to reproduce a working setup:

```
Repo:    csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8   (HuggingFace, public, no token)
Files:   encoder.int8.onnx, decoder.int8.onnx, joiner.int8.onnx, tokens.txt
Commit:  1ab9323565ddb038682214b292f588070a538ce2   (v3: 2bda32ec70b097a55adaa07d9a7173915b43cc78)
Target:  %LOCALAPPDATA%\Fluence\models\parakeet-v2\   (or parakeet-v3)
NuGet:   org.k2fsa.sherpa.onnx 1.13.5
         org.k2fsa.sherpa.onnx.runtime.win-x64 1.13.5   (or .win-arm64)
```

Config that actually works — every field verified against a running transcription:

```csharp
var cfg = new OfflineRecognizerConfig();
cfg.FeatConfig.SampleRate  = 16000;
cfg.FeatConfig.FeatureDim  = 128;                  // NOT the default 80
cfg.ModelConfig.Transducer.Encoder = $"{dir}/encoder.int8.onnx";
cfg.ModelConfig.Transducer.Decoder = $"{dir}/decoder.int8.onnx";
cfg.ModelConfig.Transducer.Joiner  = $"{dir}/joiner.int8.onnx";
cfg.ModelConfig.Tokens     = $"{dir}/tokens.txt";
cfg.ModelConfig.ModelType  = "nemo_transducer";    // REQUIRED — omit it and loading fails
cfg.ModelConfig.NumThreads = 4;
cfg.ModelConfig.Provider   = "cpu";
cfg.DecodingMethod         = "greedy_search";
```

Hotwords (biasing toward dictionary terms) exist in sherpa-onnx but need
`modified_beam_search`; the app uses `greedy_search` and does not bias yet. The dictionary's
correction pass after transcription is what guarantees spellings.

Four things that will cost an hour each if missed:

1. **`ModelType = "nemo_transducer"` is mandatory.** Without it the model will not load.
2. **`FeatureDim = 128`**, not the default 80.
3. **Set a `RuntimeIdentifier`** (`-r win-x64`). Without one, native libraries land in
   `runtimes/<rid>/native/` and you get `DllNotFoundException` at runtime.
4. **`WaveReader` is not in the NuGet package** — it's an example helper. Write your own WAV
   parsing, or feed `float[]` samples in `[-1, 1]` directly.

Audio must be **16 kHz mono float32**. On Windows, WASAPI shared mode will resample for you
if you request that format before opening the device.
