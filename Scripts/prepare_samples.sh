#!/bin/bash
# Usage: prepare_samples.sh <path-to-extracted-Salamander-SFZ+FLAC-dir> [out-dir]
#
# Builds Cadence's bundled piano subset from Salamander Grand Piano V3 (CC BY 3.0, Alexander Holm):
#   * 22 pitches (A1–C7, every minor third), 4 soft-to-medium velocity layers (v3, v5, v7, v9 of 16)
#   * the matching release ("damper/hammer") noise samples
#   * trimmed by register, 1.5 s fade-out, 44.1 kHz, Apple Lossless (ALAC) in .caf — no lossy stage.
set -euo pipefail
SRC="${1:?source dir}/samples"
OUT="${2:-$(dirname "$0")/../Sources/CadenceCore/Resources/Samples}"
TMP="$(mktemp -d)"
rm -rf "$OUT"; mkdir -p "$OUT"
PITCHES="A1 C2 D#2 F#2 A2 C3 D#3 F#3 A3 C4 D#4 F#4 A4 C5 D#5 F#5 A5 C6 D#6 F#6 A6 C7"
LAYERS="3 5 7 9"
midi_of() { # A1 -> 33
  local n="${1%[0-9]}" o="${1: -1}"
  case "$n" in C) b=0;; D#) b=3;; F#) b=6;; A) b=9;; esac
  echo $(( b + (o + 1) * 12 ))
}
for p in $PITCHES; do
  case "$p" in A1|C2|D#2|F#2) dur=10;; A2|C3|D#3|F#3) dur=9;; A3|C4|D#4|F#4|A4|C5) dur=7;; D#5|F#5|A5|C6|D#6|F#6) dur=5;; *) dur=4;; esac
  fade=$(echo "$dur - 1.5" | bc)
  name="${p/\#/s}"
  for v in $LAYERS; do
    ffmpeg -v error -y -i "$SRC/${p}v${v}.flac" -t "$dur" -ar 44100 -af "afade=t=out:st=${fade}:d=1.5" -c:a pcm_s16le "$TMP/x.wav"
    afconvert -f caff -d alac "$TMP/x.wav" "$OUT/${name}_v${v}.caf"
  done
  m=$(midi_of "$p"); r=$(( m - 20 ))
  ffmpeg -v error -y -i "$SRC/rel${r}.flac" -t 1.5 -ar 44100 -af "afade=t=out:st=1.0:d=0.5" -c:a pcm_s16le "$TMP/x.wav"
  afconvert -f caff -d alac "$TMP/x.wav" "$OUT/rel_${name}.caf"
done
rm -rf "$TMP"
du -sh "$OUT"; ls "$OUT" | wc -l
