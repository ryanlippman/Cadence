#!/bin/bash
# Usage: prepare_samples.sh <path-to-extracted-Salamander-SFZ-dir> [out-dir]
# Selects a subset of pitches (A1..C7, every minor third) and 3 soft/medium velocity
# layers, trims length, applies a fade-out and encodes to AAC (.m4a).
set -euo pipefail
SRC="${1:?source dir}/samples"
OUT="${2:-$(dirname "$0")/../Sources/CadenceCore/Resources/Samples}"
mkdir -p "$OUT"
PITCHES="A1 C2 D#2 F#2 A2 C3 D#3 F#3 A3 C4 D#4 F#4 A4 C5 D#5 F#5 A5 C6 D#6 F#6 A6 C7"
LAYERS="4 7 10"
for p in $PITCHES; do
  for v in $LAYERS; do
    name="${p/\#/s}_v${v}"
    # lower notes ring longer
    case "$p" in A1|C2|D#2|F#2|A2|C3|D#3|F#3) dur=10;; A3|C4|D#4|F#4|A4|C5) dur=8;; *) dur=5;; esac
    fade=$(echo "$dur - 1.5" | bc)
    ffmpeg -v error -y -i "$SRC/${p}v${v}.flac" -t "$dur" -ar 44100 \
      -af "afade=t=out:st=${fade}:d=1.5" -c:a aac -b:a 96k "$OUT/${name}.m4a"
  done
done
du -sh "$OUT"
