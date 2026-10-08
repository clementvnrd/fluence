#!/bin/zsh
# make-sets.sh: builds the four French test sets in $FBENCH_DIR (default /tmp/fluence-french-bench).
#   fleurs         100 sentences read by real people (Google FLEURS fr_fr dev split, CC-BY-4.0)
#   fleurs-webcam  the same through a simulated distant webcam mic (webcam.sh)
#   tech           16 synthetic dictations full of English tech words (macOS voices), plus a 44 s one
#   tech-webcam    the same through the webcam
# Needs ffmpeg and the French macOS voices (Thomas, Flo, Jacques, Eddy).
set -e
HERE=${0:A:h}
B=${FBENCH_DIR:-/tmp/fluence-french-bench}
mkdir -p $B/fleurs $B/sets/{fleurs,fleurs-webcam,tech,tech-webcam}
cd $B/fleurs
[[ -f dev.tsv ]] || curl -sfL -o dev.tsv "https://huggingface.co/datasets/google/fleurs/resolve/main/data/fr_fr/dev.tsv"
[[ -d dev ]] || { curl -sfL -o dev.tar.gz "https://huggingface.co/datasets/google/fleurs/resolve/main/data/fr_fr/audio/dev.tar.gz" && tar xzf dev.tar.gz && rm dev.tar.gz; }

cd $B/sets
head -100 $B/fleurs/dev.tsv | awk -F'\t' '{print $2"\t"$3}' > fleurs.ref
: > fleurs.list; : > fleurs-webcam.list
cut -f1 fleurs.ref | while read f; do
  id=${f%.wav}
  echo "$id\t$B/fleurs/dev/$f" >> fleurs.list
  $HERE/webcam.sh $B/fleurs/dev/$f fleurs-webcam/$id.wav
  echo "$id\t$B/sets/fleurs-webcam/$id.wav" >> fleurs-webcam.list
done

voices=("Thomas" "Flo (French (France))" "Jacques" "Eddy (French (France))")
cp $HERE/tech.ref tech.ref
long=$(cut -f2 tech.ref | head -10 | tr '\n' ' ')
echo "long\t$long" >> tech.ref
: > tech.list; : > tech-webcam.list; i=0
while IFS=$'\t' read id text; do
  v=${voices[$(( i % 4 + 1 ))]}; i=$((i+1)); [[ $id == long ]] && v=Thomas
  say -v "$v" -o tech/$id.aiff "$text"
  ffmpeg -v error -y -i tech/$id.aiff -ar 16000 -ac 1 tech/$id.wav && rm tech/$id.aiff
  $HERE/webcam.sh tech/$id.wav tech-webcam/$id.wav
  echo "$id\t$B/sets/tech/$id.wav" >> tech.list
  echo "$id\t$B/sets/tech-webcam/$id.wav" >> tech-webcam.list
done < tech.ref

for s in fleurs fleurs-webcam tech tech-webcam; do sed "s|^|$s/|" $s.list; done > all.list
echo "$(wc -l < all.list) recordings in $B/sets/all.list"
