#!/bin/zsh
# webcam.sh <in.wav> <out.wav>: a laptop-desk webcam a metre away.
# Speech normalised to -26 LUFS, room reflections, a band-limited mic, pink room noise ~18 dB below.
ffmpeg -v error -y -i "$1" -filter_complex \
 "[0:a]aresample=16000,aformat=channel_layouts=mono,loudnorm=I=-26:TP=-3:LRA=11,aecho=0.8:0.6:23|47|81:0.35|0.22|0.12,highpass=f=150,lowpass=f=5500[s];anoisesrc=color=pink:amplitude=0.012:sample_rate=16000:seed=7[n];[s][n]amix=inputs=2:duration=first:normalize=0" \
 -ar 16000 -ac 1 "$2"
