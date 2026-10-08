#!/bin/zsh
# run.sh: every engine over $FBENCH_DIR/sets/all.list, one after the other (so timings
# are not shared), then the scores. Whisper models are read from the app's folder.
set -e
HERE=${0:A:h}
B=${FBENCH_DIR:-/tmp/fluence-french-bench}
(cd $HERE/.. && swift build -c release)
T=$HERE/../.build/release/fbench
W="$HOME/Library/Application Support/Fluence/WhisperModels/models/argmaxinc/whisperkit-coreml"
mkdir -p $B/results
run() { local name=$1; shift; echo "== $name"; $T "$@" > $B/results/$name.tsv 2> $B/results/$name.err; }
run parakeet-v3 parakeet-v3 $B/sets/all.list
run parakeet-ultra parakeet-ultra $B/sets/all.list
[[ -d "$W/openai_whisper-small" ]] && run whisper-small whisper $B/sets/all.list "$W/openai_whisper-small"
[[ -d "$W/openai_whisper-large-v3_turbo" ]] && run whisper-turbo whisper $B/sets/all.list "$W/openai_whisper-large-v3_turbo"
run apple apple $B/sets/all.list
FBENCH_DIR=$B python3 -I $HERE/score.py $B/results
