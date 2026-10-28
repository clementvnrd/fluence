#!/bin/sh
# A rough "VoIP call" copy of each AMI mix (FLU-33 stress variant), outside the repo:
#   ~/Library/Caches/FluenceBench/ami/voip/<id>.Mix-Headset.wav
# Why: SpeakerConsolidation exists because VoIP audio — gain control, noise suppression, a
# network that changes quality mid-call — splits one person into several voices. The AMI
# headset mix is clean; this copy changes the channel every 60 s, cycling through three
# conditions, all through Opus (libopus, application voip):
#   A  wideband 24 kbit/s
#   B  narrowband: low-pass 3.4 kHz, −6 dB, 8 kbit/s
#   C  high-pass 300 Hz + fast compressor (an AGC), 12 kbit/s
# It is NOT a real call (no packet loss, no echo canceller, no far-end noise suppression):
# say so wherever a number from it is quoted.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC="${MBENCH_DATA:-$HOME/Library/Caches/FluenceBench}/ami/audio"
DST="${MBENCH_DATA:-$HOME/Library/Caches/FluenceBench}/ami/voip"
TMP="$DST/tmp"
mkdir -p "$DST" "$TMP"

ids=$(/usr/bin/python3 -I -c 'import json,sys; print(" ".join(m["id"] for m in json.load(open(sys.argv[1]))["meetings"]))' "$HERE/meetings.json")
for id in $ids; do
  out="$DST/$id.Mix-Headset.wav"
  [ -s "$out" ] && { echo "$id: exists"; continue; }
  in="$SRC/$id.Mix-Headset.wav"
  enc() { # $1 name, $2 filter, $3 bitrate
    ffmpeg -nostdin -loglevel error -y -i "$in" -af "$2" -c:a libopus -b:a "$3" -application voip "$TMP/$id.$1.ogg"
    ffmpeg -nostdin -loglevel error -y -i "$TMP/$id.$1.ogg" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP/$id.$1.wav"
  }
  enc A "anull" 24k
  enc B "lowpass=f=3400,volume=-6dB" 8k
  enc C "highpass=f=300,acompressor=threshold=-30dB:ratio=6:attack=5:release=100:makeup=8" 12k
  # Splice 60 s blocks A, B, C, A, … (same length and alignment as the source).
  /usr/bin/python3 -I - "$in" "$TMP/$id.A.wav" "$TMP/$id.B.wav" "$TMP/$id.C.wav" "$out" <<'EOF'
import sys, wave
src, a, b, c, out = sys.argv[1:6]
with wave.open(src) as w:
    n, params = w.getnframes(), w.getparams()
frames = []
for p in (a, b, c):
    with wave.open(p) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
        data = w.readframes(w.getnframes())
    frames.append(data[: n * 2].ljust(n * 2, b"\0"))
block = 60 * 16000 * 2
outbytes = bytearray()
for i, start in enumerate(range(0, n * 2, block)):
    outbytes += frames[i % 3][start : start + block]
with wave.open(out, "wb") as w:
    w.setparams(params)
    w.writeframes(bytes(outbytes))
EOF
  rm -f "$TMP/$id".*
  echo "$id: done"
done
rmdir "$TMP" 2>/dev/null || true
