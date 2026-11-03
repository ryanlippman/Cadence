# Cadence

A native macOS (14+) menu-bar and window app that plays endless, procedurally generated, calm classical-style
piano with an optional rhythmic amplitude-modulation layer. Everything runs offline on your Mac.

> **Honest framing.** The modulation layer is *inspired by published research on rhythmic auditory
> stimulation* (amplitude-modulated sound at specific rates). Effects on focus, relaxation or sleep **vary
> between people**, and some people notice nothing. Cadence is not a medical device and makes no medical or
> therapeutic claims. Turn the modulation off in *Modulation settings* if you simply want the piano.

## What it does

- **Music:** a rules-based generator (Satie / Debussy / Chopin-nocturne / Bach-prelude flavoured) picks a key
  and mode (major, minor, dorian, lydian, mixolydian), walks a slow diatonic chord progression (occasional
  borrowed chords, sometimes a 7th/9th colour tone), plays an Alberti / rolling / Gymnopédie-style / broken-chord
  left hand, and a sparse right-hand melody drawn from chord and scale tones with non-repeating rhythms.
  It modulates to a closely related key every ~5–7 minutes through a pivot chord. Tempo stays 55–80 BPM,
  dynamics sit in a narrow soft band, with human timing and velocity variation.
- **Sampler:** custom polyphonic sampler (Hermite pitch-shifting, velocity-layer crossfade, pedal-like holds)
  using a Salamander Grand Piano subset (~6 MB bundled), plus a light Freeverb-style reverb.
- **Neural-effect layer:** a sample-accurate LFO drives the master gain *after* the reverb (so the reverb
  tail doesn't smear it). Smooth raised-cosine (or "rounded") waveform; rate/depth/waveform changes are
  smoothed per sample so there are no clicks; amplitude makeup keeps loudness steady. Works on speakers
  (it is AM, not binaural beats).

  | Mode  | Default rate | Range     | Notes                          |
  |-------|--------------|-----------|--------------------------------|
  | Focus | 16 Hz        | 12–20 Hz  | tempo 64–78 BPM                |
  | Relax | 9 Hz         | 6–12 Hz   | tempo 58–70 BPM                |
  | Sleep | 2.5 Hz       | 1–4 Hz    | tempo 55–60 BPM, softer, 2 bars/chord |

  Effective depth = *Depth* (default 45 %) × *Intensity* (default 80 %) × mode scale. A ramp-in (default 30 s)
  brings the modulation up smoothly at session start. Optional soft pink-noise bed (unmodulated).
- **App:** Start/Stop, mode, intensity, volume, 25/50/90 min/∞ timer with a 25 s fade-out, settings remembered,
  system sleep prevented while playing (IOKit power assertion), media keys + Now Playing, menu bar item.

## Build, test, run

```bash
swift build
swift test                       # ~100 s; includes the spectrum tests
Scripts/build_app.sh             # -> build/Cadence.app (ad-hoc signed)
open build/Cadence.app
build/Cadence.app/Contents/MacOS/Cadence --selftest 8   # headless-ish launch + playback check
swift run cadence-render --mode focus --seconds 60 out.wav   # offline render (add --no-am to compare)
```

Regenerating the sample subset: `Scripts/prepare_samples.sh <extracted Salamander SFZ+FLAC dir>` (needs ffmpeg).

## Verification

- `GeneratorTests`: notes stay in key (incl. borrowed-chord and pivot rules) over ~40 min × 3 modes × 6 seeds,
  register limits, tempo in 55–80 BPM and per-mode ranges, gradual tempo change, narrow soft dynamics,
  modulation happens via pivot chords, no repeated 8-bar windows, sparse melody.
- `ModulationTests`: renders audio offline, computes the RMS-envelope spectrum and checks a clear peak at the
  configured rate — Focus 16 Hz (≈45× the band median, absent with AM off), Relax 9 Hz, Sleep 2.5 Hz
  (≈35× the AM-off level), a custom 14 Hz rate, depth scaling, ramp-in, fade-out, per-sample gain steps
  (no clicks, including while switching waveform), and the noise toggle.
- `SamplerTests`: bank loads, pitch accuracy (autocorrelation) including shifted notes, velocity monotonicity.

## Not verified / caveats

- **Subjective listening quality** (musicality, reverb taste, loudness) has not been judged by a human ear.
- The window/menu-bar **UI was not visually inspected** in this environment (no screen-capture permission);
  it compiles, launches, and the self-test confirmed the audio engine produced non-silent output.
- Sleep prevention was confirmed with `pmset -g assertions` (PreventUserIdleSystemSleep "Cadence is playing").
- **Media keys / Now Playing** are implemented with `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` but were
  not exercised with a physical keyboard.
- The app is ad-hoc signed only (no notarization); Gatekeeper may require right-click → Open.
- No custom app icon yet.

## License

See [LICENSES.md](LICENSES.md). Piano samples: Salamander Grand Piano, Alexander Holm, CC BY 3.0.
