# Phase 2 audit (baseline = commit 1989a18)

Measured with `cadence-analyze` (offline renders, 44.1 kHz) plus code review.

## Measurements
| Mode  | RMS | Peak | Short-term p10/p50/p90 | Clicks (90 s) | AM peak | CPU |
|-------|-----|------|------------------------|---------------|---------|-----|
| Focus | −18.9 dBFS | −4.2 | −21.9/−19.3/−17.0 | 6 | 15.95 Hz ×25 | 0.9 % RT |
| Relax | −20.3 | −5.9 | −22.4/−20.6/−18.5 | 3 | 6.5 Hz ×6 (wrong bin: ramp-in + rhythmic onsets) | 0.9 % |
| Sleep | −22.6 | −7.6 | −25.4/−22.9/−20.7 | 0 | 2.5 Hz ×17 | 0.8 % |

## Findings (ranked)
1. **Audible artifacts from lossy samples.** The detected "clicks" also occur with AM off and no voice stealing.
   They come from ffmpeg's native AAC encoder: the D♯4 attack has a 4-sample spike (max |Δ²x| 0.041 vs 0.005 in
   the original FLAC). 4 of 66 zones are affected. Apple AAC is clean; ALAC is lossless and only ~2× AAC size.
2. **Composition is not composed.** Flat bar-by-bar Markov chain: no phrases, cadences, harmonic function,
   voice leading (always root-position, fixed voicing), motif, memory or counterpoint. Melody is a random walk.
3. **No pedal model.** "Pedal" was faked by holding every LH note to the bar end; no damper behaviour,
   no re-pedalling, no sympathetic resonance, no release noise. Re-struck notes stack.
4. **Real-time safety.** `SampleBank.select` allocates on the audio thread (`idx.map`); `currentKeyName`
   (a String) is written on the scheduling thread and read on the main thread (data race, crash risk);
   generation runs under the same lock the audio thread try-locks, so a slow top-up delays note onsets.
5. **Gain staging.** `tanh` on the master adds odd harmonics even at normal levels; arbitrary ×2.5 trim.
6. **Mode transitions.** Rate glides over 0.4 s, so switching Focus→Sleep sweeps audibly through every
   rate in between; tempo/dynamics jump at the next bar.
7. **Device changes** re-create the synth (music restarts from a new seed).
8. **Settings** use synthesized `Codable`: adding any field silently resets users' settings.
9. **UI**: one long scrolling form; advanced controls mixed with primary ones; no onboarding,
   visualisation, style choice, or Settings window; limited accessibility labelling.
10. Freeverb reverb is serviceable but metallic on sustained piano; mono input.

## Decision: keep the custom sampler (not AVAudioUnitSampler)
The custom engine is retained and extended. AVAudioUnitSampler cannot be rendered deterministically
offline alongside our own DSP for the spectrum tests, offers no damper/pedal model, sympathetic
resonance, per-note micro-variation, or release-trigger layers without EXS/SF2 authoring, and makes
sample-accurate scheduling from our generator harder. CPU cost of the custom path is <2 % of one core.

## Status after Phase 2
| # | Finding | Resolution |
|---|---------|------------|
| 1 | Lossy-codec spikes | ALAC samples; test asserts no spikes in any zone; 0 clicks in every style × mode render |
| 2 | Not composed | Hierarchical composer (form, periods, functional harmony, voice leading, motifs, memory, counterpoint) |
| 3 | No pedal model | Key/pedal/damper model, legato re-pedalling, sympathetic resonance, release noise |
| 4 | RT safety | Precomputed lookup tables, no audio-thread allocation, split locks, control via copied state |
| 5 | Gain staging | Look-ahead limiter (inactive at normal levels), measured level targets |
| 6 | Mode transitions | Rate dip-and-switch; tempo/dynamics glide; no silence gap (tested) |
| 7 | Device changes | Fixed internal rate; engine restart keeps the composition |
| 8 | Settings | Tolerant decoding; diagnostics never write user defaults |
| 9 | UI | Redesigned window, Settings, onboarding, visualiser, menu bar, accessibility |
| 10 | Reverb | 8-line FDN with early reflections and modulated delays |

Additional issues found and fixed during Phase 2: velocity-layer cross-fades phase-cancelled (now nearest
layer); hard clip at full volume (look-ahead limiter); non-deterministic composition across processes
(dictionary iteration order); consequent phrases copying melody over harmony the cadence had replaced;
turn ornaments creating cross-relations with the preceding chord.
