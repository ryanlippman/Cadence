# Cadence

A native macOS (14+) app that composes calm, original classical-style piano music in real time, forever,
with an optional rhythmic amplitude-modulation layer. Everything runs offline on your Mac.

> **Honest framing.** The modulation layer is *inspired by published research on rhythmic auditory
> stimulation* (amplitude-modulated sound at specific rates). Effects on focus, relaxation or sleep **vary
> between people**, and some people notice nothing. Cadence is not a medical device and makes no medical or
> therapeutic claims. Switch the modulation off in Settings if you simply want the piano.

## How it works

```
Composer ─ bars ─▶ scheduler ─ note/pedal events ─▶ Sampler ─▶ sympathetic resonance ─▶ FDN reverb
   (form, harmony, voices)        (sample-accurate)    (keys + pedal)                           │
                                                                                                ▼
                       limiter ◀─ master volume / fades ◀─ pink-noise bed ◀─ amplitude modulation (LFO)
```

### Composition (`Sources/CadenceCore/Music`)
Hierarchical, rules-based — no machine learning, no recordings:

- **Form.** Each *movement* is: theme (a period), often a varied restatement, a pivot-chord transition to a
  related key, a contrasting period, a transition home, the theme's return (recalled from memory with light
  variation), a plagal codetta, and a transition to the next movement's key. Key areas change every minute
  or two; the home key every few minutes.
- **Periods & cadences.** Antecedent phrases end on half cadences; consequents restate the antecedent's
  opening (parallel period) and close with authentic, plagal or deceptive cadences (a deceptive cadence
  gets a cadential extension). Cadential 6/4 in romantic/baroque.
- **Harmony.** Functional grammar (tonic → pre-dominant → dominant), secondary dominants and leading-tone
  sevenths, borrowed chords from the parallel mode, descending-fifth sequences, ostinati (minimalist),
  added-note colour (impressionist).
- **Voice leading.** Bass inversion and three inner voices chosen by minimising motion, holding common tones,
  completing chords, sensible doubling, resolving sevenths and leading tones, and avoiding parallel fifths
  and octaves.
- **Melody.** A motif (rhythm + contour) is stated, answered, varied and fragmented within phrases and developed
  across movements; an arch-shaped contour plan; chord tones on structural beats; passing and neighbour
  tones, suspensions (prepared, resolved down by step), appoggiaturas and turns — every dissonance resolves.
- **Independent voices.** Counter-melody that moves when the melody rests; walking bass (baroque).
- **Styles** (original music in broad traditions, not imitations): *Minimalist* (spacious ostinati,
  Gymnopédie-like 3/4), *Impressionist* (lydian/mixolydian colour, rolled pedalled chords), *Romantic*
  (nocturne arpeggios, lyrical melody, chromatic harmony), *Baroque* (prelude figuration, walking bass,
  counterpoint, sequences). *Varied* changes style between movements; changing style mid-piece goes through a
  codetta and a modulation, so the music never stops.
- **Modes** are orthogonal to style: Focus 64–76 BPM, Relax 58–68, Sleep 55–60 (softer, sparser, darker
  reverb). Switching mode glides tempo and dynamics over a few bars.

### Piano (`Sampler.swift`, `DSP.swift`)
- Custom sampler (kept instead of `AVAudioUnitSampler`: deterministic offline rendering for the analysis
  tests, a real pedal/damper model, release triggers, and sample-accurate scheduling).
- Lossless Salamander subset, 4 velocity layers chosen by nearest layer with continuous, loudness-normalised
  gain (cross-fading two different strikes phase-cancels), Hermite pitch-shifting, onset-trimmed.
- Key + sustain pedal: legato re-pedalling (lift just after each harmony, re-catch within 80 ms), two-stage
  dampers (slower in the bass), undamped top register, re-struck notes replace their previous vibration,
  pseudo round-robin on repeated notes, micro-variation in tuning and level, release noise at −37 dB.
- Sympathetic resonance (24 tuned strings ring while the pedal is down); 8-line FDN reverb with early
  reflections and modulated delays; per-mode reverb time.

### Modulation & output
- Sample-accurate LFO on the full mix after the reverb (so reverb tails don't blur it); double-precision phase,
  no drift (tested over 10 minutes); smoothed depth; large rate changes (e.g. Focus → Sleep) dip out, switch
  and fade back in rather than sweeping audibly.

  | Mode  | Default rate | Range     |
  |-------|--------------|-----------|
  | Focus | 16 Hz        | 12–20 Hz  |
  | Relax | 9 Hz         | 6–12 Hz   |
  | Sleep | 2.5 Hz       | 1–4 Hz    |

  Effective depth = Depth (45 %) × Intensity (80 %) × mode scale. 30 s ramp-in. AM, not binaural beats, so it
  works on speakers.
- Optional pink-noise bed (high- and low-passed), look-ahead limiter (inactive at normal levels), squared
  volume and fade curves.

### Engine & reliability
- Fixed 48 kHz internal rate; the mixer converts to the device rate. Output changes restart the engine
  without resetting the music.
- Audio thread: no allocation, no blocking (try-locks only), events dispatched at their exact sample.
  Composition runs on a background queue under its own lock.
- Sleep prevention via an IOKit power assertion while playing; Now Playing + media keys.

## Build, test, run

```bash
swift build
swift test -c release                     # 37 tests, ~1.5 minutes
Scripts/build_app.sh                      # -> build/Cadence.app
open build/Cadence.app
```
Diagnostics:
```bash
build/Cadence.app/Contents/MacOS/Cadence --selftest 10 --style baroque --mode focus
swift run -c release cadence-analyze report 90 --long 30    # writes docs/ANALYSIS.md
swift run -c release cadence-analyze renders renders 90     # WAVs per style × mode for listening
swift run -c release cadence-analyze score romantic 32      # bar-by-bar harmony and melody
swift run -c release cadence-render --style impressionist --mode sleep --seconds 120 out.wav
```
Regenerating samples: `Scripts/prepare_samples.sh <extracted Salamander SFZ+FLAC dir>` (needs ffmpeg).

## Verification
See [docs/AUDIT.md](docs/AUDIT.md) (what was wrong in the first version and what changed) and
[docs/ANALYSIS.md](docs/ANALYSIS.md) (measured results). Tests cover: notes in key/chord/local scale,
every melodic dissonance resolving by step, outer-voice parallels < 3 %, cadence correctness, paced
modulations through transitions, theme recall, style distinctness, tempo 55–80 BPM and per-mode ranges,
narrow velocity ranges, 3-hour composer runs, pedal sustain/damping/re-catch, no codec spikes, pitch
accuracy, velocity monotonicity, envelope-spectrum peaks at 16/9/2.5 Hz in every style (absent with AM
off), drift-free LFO phase, click-free parameter changes, mode switches without gaps, fade/resume,
concurrent control while rendering, and a 20-minute stability run.

## Not verified / caveats
- **Listening.** All sound judgements here are from measurements (spectra, levels, clicks, voice-leading
  statistics), not human ears. Musical taste — reverb amount, voicing colour, how "composed" it feels over an
  hour — needs listening; renders are produced by `cadence-analyze renders`.
- **Output device changes** (plugging in headphones, AirPods) are handled by restarting the engine, but were
  not exercised with real hardware here.
- **Media keys / Now Playing** are wired up but not tested with a keyboard.
- The UI was reviewed through off-screen renders (`--snapshot`), not interactively with VoiceOver.
- Memory: ~240 MB resident while playing (decoded samples are ~150 MB of 16-bit PCM).
- Ad-hoc signed only (no notarization); Gatekeeper may ask for right-click → Open.

## License
See [LICENSES.md](LICENSES.md). Piano samples: Salamander Grand Piano, Alexander Holm, CC BY 3.0.
