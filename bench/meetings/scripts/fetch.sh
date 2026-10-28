#!/bin/sh
# Downloads the bench's public data OUTSIDE the repo (FLU-33):
#   $MBENCH_DATA/ami/setup/repo  pyannote/AMI-diarization-setup (reference RTTMs, UEMs; Apache-2.0)
#   $MBENCH_DATA/ami/audio       AMI Mix-Headset wav per meeting (CC BY 4.0), about 650 MB
#   $MBENCH_DATA/ami/array       with --array: one far-field room mic, Array1-01 (same size again)
# MBENCH_DATA defaults to ~/Library/Caches/FluenceBench. Checks the Mix-Headset files and the
# RTTMs against the SHA-256 in meetings.json. Never put this data in the repo.
# Usage: scripts/fetch.sh [--array]
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
DATA="${MBENCH_DATA:-$HOME/Library/Caches/FluenceBench}/ami"
SETUP_COMMIT=67c2d539286e89f68952d5dcf83912bd9f01dfae
ARRAY="${1:-}"
mkdir -p "$DATA/audio" "$DATA/setup"
[ "$ARRAY" != "--array" ] || mkdir -p "$DATA/array"

get() { # $1 url, $2 file; the mirror answers 403 now and then under load: wait and try again.
  [ -s "$2" ] && return 0
  for attempt in 1 2 3 4 5; do
    if curl -sS -f -o "$2.part" "$1"; then mv "$2.part" "$2"; return 0; fi
    rm -f "$2.part"; echo "$(basename "$2"): download failed (attempt $attempt), waiting"; sleep $((attempt * 20))
  done
}

if [ ! -d "$DATA/setup/repo/.git" ]; then
  git clone -q https://github.com/pyannote/AMI-diarization-setup.git "$DATA/setup/repo"
fi
git -C "$DATA/setup/repo" fetch -q origin "$SETUP_COMMIT" 2>/dev/null || true
git -C "$DATA/setup/repo" checkout -q "$SETUP_COMMIT"

# id split wavSHA rttmSHA, one line per meeting (python3 -I: ignore the cwd and env).
/usr/bin/python3 -I -c 'import json,sys; [print(m["id"], m["split"], m.get("wavSHA256",""), m.get("rttmSHA256","")) for m in json.load(open(sys.argv[1]))["meetings"]]' "$HERE/meetings.json" |
while read -r id split wavsha rttmsha; do
  base="https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/$id/audio"
  wav="$DATA/audio/$id.Mix-Headset.wav"
  get "$base/$id.Mix-Headset.wav" "$wav"
  if [ "$ARRAY" = "--array" ]; then
    get "$base/$id.Array1-01.wav" "$DATA/array/$id.Array1-01.wav"
    [ -s "$DATA/array/$id.Array1-01.wav" ] || { echo "$id: no array audio"; exit 1; }
  fi
  [ -s "$wav" ] || { echo "$id: no audio"; exit 1; }
  got=$(shasum -a 256 "$wav" | cut -d' ' -f1)
  [ -z "$wavsha" ] || [ "$got" = "$wavsha" ] || { echo "$id: wav SHA-256 mismatch ($got)"; exit 1; }
  rttm="$DATA/setup/repo/only_words/rttms/$split/$id.rttm"
  got=$(shasum -a 256 "$rttm" | cut -d' ' -f1)
  [ -z "$rttmsha" ] || [ "$got" = "$rttmsha" ] || { echo "$id: rttm SHA-256 mismatch ($got)"; exit 1; }
  echo "$id ($split) ok"
done
