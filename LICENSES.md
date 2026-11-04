# Licenses & attribution

## Piano samples — Salamander Grand Piano V3 (CC BY 3.0)

- **Work:** Salamander Grand Piano V3 (Yamaha C5), recorded 48 kHz/24-bit by **Alexander Holm**.
- **Distributed via:** FreePats — https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html
  (archive `SalamanderGrandPiano-SFZ+FLAC-V3+20200602.tar.gz`, assembled by roberto@zenvoid.org).
- **License:** Creative Commons Attribution 3.0 Unported — https://creativecommons.org/licenses/by/3.0/
  (stated in the archive's `readme.txt` and in the `.sfz` header: "License: CC-by"). CC BY permits
  redistribution and adaptation, including inside an app, provided credit is given and changes are indicated.
- **Changes made** (`Scripts/prepare_samples.sh`):
  - subset of 22 pitches (A1–C7, every minor third) × 4 velocity layers (original layers 3, 5, 7, 9 of 16);
  - the 22 matching release ("hammer/damper") noise samples;
  - trimmed by register (4–10 s; release noises 1.5 s), 1.5 s fade-out, resampled to 44.1 kHz/16-bit,
    stored as Apple Lossless (ALAC). No lossy encoding.
  - At playback, notes between recorded pitches are pitch-shifted; leading silence is skipped.
- **In-app credit:** About sheet (ⓘ in the main window) and Settings → About.
- No samples from commercial libraries are used.

## Cadence source code

The Cadence source code in this repository is original work by its author; choose a license of your
own before distributing. The CC BY attribution above must travel with any build that bundles the samples.
