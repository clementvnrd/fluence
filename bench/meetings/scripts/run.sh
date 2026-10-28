#!/bin/sh
# Builds the bench (release, scratch outside the repo), diarizes every meeting of
# meetings.json the way the app does, then scores, sweeps and writes, all outside the repo:
#   $MBENCH_DATA/results/<condition>-<timestamp>/results.{json,md}
# Usage: scripts/run.sh [headset|voip|array] [--skip-diarize] [MERGE,SECONDS,SHARE]
#   --skip-diarize reuses the cached diarizer output; MERGE,SECONDS,SHARE scores those
#   consolidation settings as "recommended" (e.g. a point chosen across conditions).
#   headset  AMI Mix-Headset as published (fetch.sh)
#   voip     its VoIP-like copy (voipify.sh): the remote side of a call
#   array    one far-field room microphone, Array1-01 (fetch.sh --array): the in-room mode
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
BENCH="${MBENCH_DATA:-$HOME/Library/Caches/FluenceBench}"
SCRATCH="$HOME/Library/Caches/FluenceBuild/mbench"
CONDITION="${1:-headset}"
case "$CONDITION" in
  headset) AUDIO="$BENCH/ami/audio"; SUFFIX=Mix-Headset ;;
  voip) AUDIO="$BENCH/ami/voip"; SUFFIX=Mix-Headset ;;
  array) AUDIO="$BENCH/ami/array"; SUFFIX=Array1-01 ;;
  *) echo "unknown condition $CONDITION"; exit 2 ;;
esac
CACHE="$BENCH/cache/$CONDITION"
cd "$HERE"
mkdir -p "$CACHE"
swift build -c release --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/mbench"
if [ "${2:-}" != "--skip-diarize" ]; then
  "$BIN" diarize meetings.json "$AUDIO" "$CACHE" --audio "$SUFFIX" --models "$BENCH/models" --check-process \
    2> "$BENCH/diarize-$CONDITION.log"
  grep -E '^(check|models|diarize total|[A-Z]{2}[0-9]{4})' "$BENCH/diarize-$CONDITION.log" || true
fi
OUT="$BENCH/results/$CONDITION-$(date +%Y%m%d-%H%M%S)"
SETTINGS="${3:+--settings $3}"
# SETTINGS is empty or two words: leave it unquoted.
"$BIN" evaluate meetings.json "$BENCH/ami/setup/repo" "$CACHE" "$OUT" --condition "$CONDITION" $SETTINGS > /dev/null
echo "results: $OUT/results.md"
