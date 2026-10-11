#!/bin/bash
# Rebuilds Resources/THIRD-PARTY-NOTICES.txt (FLU-68) from the licence files of the package
# versions pinned in Package.resolved, so the notices shipped in the app always match the code
# linked into it. `make notices` fetches the packages and runs this; run it again whenever
# Package.resolved changes, and commit the result (a test fails when they drift apart).
#
#   Tools/generate_third_party_notices.sh <checkouts-dir>      # e.g. $(SCRATCH)/checkouts
#
# The models section is written by hand below: models are downloaded at runtime, so no package
# carries their licence. Each entry was read on its Hugging Face model card on 2026-10-11.
set -euo pipefail

CHECKOUTS="${1:?usage: $0 <SwiftPM checkouts directory>}"
OUT="Resources/THIRD-PARTY-NOTICES.txt"

version_of() {
    python3 -I -c '
import json, sys
pins = json.load(open("Package.resolved"))["pins"]
print(next(p["state"]["version"] for p in pins if p["identity"] == sys.argv[1]))
' "$1"
}

rule() { printf '\n%s\n' "================================================================================"; }

# library <heading> <identity> <checkout dir> <url> <licence name>  <files…>
library() {
    local heading="$1" identity="$2" dir="$3" url="$4" licence="$5"
    shift 5
    rule
    echo "$heading $(version_of "$identity")"
    echo "$url"
    echo "Licence: $licence"
    echo "================================================================================"
    local f
    for f in "$@"; do
        test -f "$CHECKOUTS/$dir/$f" || { echo "missing $CHECKOUTS/$dir/$f" >&2; exit 1; }
        printf '\n--- %s ---\n\n' "$f"
        cat "$CHECKOUTS/$dir/$f"
    done
}

{
    cat <<'HEADER'
THIRD-PARTY NOTICES — Fluence

Fluence is built on the open-source libraries listed first, and downloads the speech models
listed last the first time a feature needs them. Their licences are reproduced below, as
those licences require. Fluence's own code is under its own licence (LICENSE.md).
HEADER

    library "WhisperKit (argmax-oss-swift)" argmax-oss-swift argmax-oss-swift \
        "https://github.com/argmaxinc/argmax-oss-swift" "MIT, plus the notices of the code it includes" \
        LICENSE NOTICES

    library "FluidAudio" fluidaudio FluidAudio \
        "https://github.com/FluidInference/FluidAudio" "Apache-2.0, plus the licences of the code it bundles" \
        LICENSE \
        ThirdPartyLicenses/vbx-LICENSE.md \
        ThirdPartyLicenses/fastcluster-LICENSE.md \
        ThirdPartyLicenses/NemoTextProcessing-LICENSE.md \
        ThirdPartyLicenses/JapaneseG2P-LICENSE.md \
        ThirdPartyLicenses/KokoroAneSpanishFrenchG2P-LICENSE.md

    library "Sparkle" sparkle Sparkle \
        "https://github.com/sparkle-project/Sparkle" "MIT, plus the licences of the code it bundles" \
        LICENSE

    library "swift-argument-parser (a dependency of FluidAudio)" swift-argument-parser swift-argument-parser \
        "https://github.com/apple/swift-argument-parser" "Apache-2.0" \
        LICENSE.txt

    rule
    cat <<'MODELS'
Speech models downloaded on first use (not part of the app bundle)
================================================================================

Each model stays under the licence of its authors. Fluence downloads them from Hugging Face
and runs them on this Mac.

* Parakeet TDT 0.6B v3, Core ML build by FluidInference
  (FluidInference/parakeet-tdt-0.6b-v3-coreml), from NVIDIA's parakeet-tdt-0.6b-v3.
  Licence: CC-BY-4.0, https://creativecommons.org/licenses/by/4.0/
  Copyright NVIDIA. Converted to Core ML and quantized by FluidInference.

* Parakeet Ultra, Core ML build by FluidInference (FluidInference/parakeet-ultra-coreml), a
  post-training of NVIDIA's parakeet-tdt-0.6b-v3 by moondream (moondream/parakeet-ultra).
  Licence: CC-BY-4.0, https://creativecommons.org/licenses/by/4.0/
  Copyright NVIDIA and moondream. Converted to Core ML and quantized by FluidInference.

* Parakeet CTC 110M, Core ML build by FluidInference (FluidInference/parakeet-ctc-110m-coreml),
  from NVIDIA's parakeet-tdt_ctc-110m (used to spot the words of the user's dictionary).
  Licence: CC-BY-4.0, https://creativecommons.org/licenses/by/4.0/
  Copyright NVIDIA. Converted to Core ML and quantized by FluidInference.

* Speaker diarization, Core ML conversion by FluidInference of pyannote's
  speaker-diarization-community-1 (FluidInference/speaker-diarization-coreml).
  Licence: CC-BY-4.0 for the converted artifacts; the scope and attribution are in
  https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/NOTICE.md
  Copyright pyannote / Hervé Bredin and contributors. Converted by FluidInference.

* Silero VAD, Core ML build by FluidInference (FluidInference/silero-vad-coreml).
  Licence: MIT. Copyright Silero Team, https://github.com/snakers4/silero-vad

* OpenAI Whisper (base, small, large-v3 turbo), Core ML builds by Argmax
  (argmaxinc/whisperkit-coreml).
  Licence: MIT. Copyright OpenAI (https://github.com/openai/whisper) and Argmax, Inc.

Apple's own speech recognition (SpeechAnalyzer) and Foundation Models are part of macOS and
are used under Apple's licence for the operating system.
MODELS
} > "$OUT"

echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
