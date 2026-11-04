import Foundation
import CadenceCore

// cadence-analyze score <style> [bars]          print a bar-by-bar score summary
// cadence-analyze report [seconds] [--long N]   full audio + composition report → docs/ANALYSIS.md
// cadence-analyze renders <dir> [seconds]       write listening renders for every style/mode
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "report"
func mod12(_ x: Int) -> Int { ((x % 12) + 12) % 12 }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }


func composeMinutes(_ style: CompositionStyle, seed: UInt64, minutes: Double = 60, mode: FocusMode = .focus) -> [Bar] {
    let c = Composer(mode: mode, style: style, seed: seed)
    var bars: [Bar] = []
    var mins = 0.0
    while mins < minutes { let b = c.nextBar(); bars.append(b); mins += Double(b.beats) / b.tempo }
    return bars
}
let salienceHeader = "| Style | Leaps>6th | Static runs | Outer ∥5/8 | Unresolved | Velocity jumps >8 (max) | Density jumps | Silent gaps | Melody > C6 | Accomp. over melody |\n|---|---|---|---|---|---|---|---|---|---|\n"
func salienceRow(_ style: CompositionStyle, _ r: CompositionReport) -> String {
    "| \(style.title) | \(r.melodicLeapsOverSixth) | \(r.staticRepeats) | \(r.outerParallels)/\(r.chordChanges) | \(r.unresolvedDissonances) | \(r.velocityJumps) (\(r.maxVelocityJump)) | \(r.densityJumps) | \(r.silentGaps) | \(r.registerPeaks) | \(r.maskedMelody) |"
}

if cmd == "comp" {
    // quick composition-quality check across seeds: cadence-analyze comp [seeds]
    let seeds = args.count > 2 ? Int(args[2]) ?? 3 : 3
    print(salienceHeader, terminator: "")
    for style in CompositionStyle.allCases {
        var bars: [Bar] = []
        for sd in 0..<seeds { bars += composeMinutes(style, seed: UInt64(5 + sd * 17)) }
        let r = CompositionAnalysis.analyze(bars)
        print(salienceRow(style, r) + " oot=\(r.outOfKey) keys=\(r.keyChanges) chords=\(r.distinctChordSymbols) uniq=\(f2(r.uniqueFourBarWindows)) mean=\(f2(r.meanAbsMelodicInterval)) npb=\([VoiceRole.melody, .counter, .bass, .inner].map { f1(r.notesPerBar[$0] ?? 0) }.joined(separator: "/"))")
    }
    exit(0)
}

if cmd == "salience" {
    // cadence-analyze salience <style>: show contexts of static runs, leaps, density jumps
    let style = CompositionStyle(rawValue: args.count > 2 ? args[2] : "romantic")!
    let bars = composeMinutes(style, seed: 5)
    var mel: [(Bar, GeneratedNote)] = []
    for b in bars { for n in b.notes where n.voice == .melody { mel.append((b, n)) } }
    var shown = 0
    for i in 2..<mel.count where shown < 12 {
        let a = mel[i - 2].1.midi, b = mel[i - 1].1.midi, c = mel[i].1.midi
        let leap = abs(c - b) > 9
        if (a == b && b == c) || leap {
            shown += 1
            let ctx = mel[max(0, i - 4)...min(mel.count - 1, i + 1)].map { "\($0.1.midi)\($0.1.kind.rawValue.prefix(3))\($0.1.durBeats)@\($0.0.index):\($0.1.beat)" }.joined(separator: " ")
            print("\(leap ? "LEAP" : "STATIC") \(mel[i].0.section) \(mel[i].0.chords.map { $0.chord.symbol }) | \(ctx)")
        }
    }
    // outer-voice parallels at chord changes (same rule as CompositionAnalysis)
    var prevPair: (Int, Int, Bar, Double)? = nil
    var par = 0, joins = 0
    for b in bars {
        for c in b.chords {
            guard let bass = b.notes.filter({ $0.voice == .bass && abs($0.beat - c.beat) < 0.15 }).map({ $0.midi }).min(),
                  let m = b.notes.last(where: { $0.voice == .melody && $0.beat <= c.beat + 0.3 })?.midi ?? mel.last(where: { $0.0.index < b.index })?.1.midi
            else { prevPair = nil; continue }
            if let (pm, pb, pbar, _) = prevPair, pm != m, pb != bass {
                let x = mod12(pm - pb), y = mod12(m - bass)
                if x == y && (x == 0 || x == 7) && (m - pm).signum() == (bass - pb).signum() {
                    par += 1
                    let join = pbar.phraseEnd && pbar.index != b.index
                    if join { joins += 1 }
                    if par <= 6 { print("PAR \(x == 0 ? "8ve" : "5th") \(join ? "JOIN" : "in-phrase") \(b.section) bar \(b.index) mel \(pm)→\(m) bass \(pb)→\(bass) \(c.chord.symbol)") }
                }
            }
            prevPair = (m, bass, b, c.beat)
        }
    }
    print("parallels \(par), at phrase joins \(joins)")
    var last: Bar? = nil
    shown = 0
    for b in bars {
        if let l = last {
            let c0 = l.notes.count * 4 / l.beats, c1 = b.notes.count * 4 / b.beats
            if max(c0, c1) > 2 * min(c0, c1) && abs(c0 - c1) > 6 && shown < 8 {
                shown += 1
                print("DENSITY bar \(b.index) \(l.section)→\(b.section) \(c0)→\(c1) voices \(Dictionary(grouping: l.notes, by: { $0.voice }).mapValues { $0.count }) → \(Dictionary(grouping: b.notes, by: { $0.voice }).mapValues { $0.count })")
            }
        }
        last = b
    }
    exit(0)
}

if cmd == "score" {
    let style = CompositionStyle(rawValue: args.count > 2 ? args[2] : "romantic")
    let n = args.count > 3 ? Int(args[3]) ?? 16 : 16
    let c = Composer(mode: .focus, style: style, seed: 7)
    for _ in 0..<n {
        let b = c.nextBar()
        let chords = b.chords.map { "\($0.chord.symbol)@\($0.beat)" }.joined(separator: " ")
        let mel = b.notes.filter { $0.voice == .melody }.map { "\($0.midi)\($0.kind == .chordTone ? "" : String($0.kind.rawValue.prefix(3)))" }.joined(separator: " ")
        print("\(b.index) \(b.keyName) \(b.section) \(Int(b.tempo))bpm | \(chords) | \(mel)\(b.phraseEnd ? "  ‖\(b.cadence!.rawValue)" : "")")
    }
    exit(0)
}

if cmd == "debug" {
    let style = CompositionStyle(rawValue: args.count > 2 ? args[2] : "romantic")!
    let seed = UInt64(args.count > 3 ? args[3] : "5") ?? 5
    let c = Composer(mode: .focus, style: style, seed: seed)
    var bars: [Bar] = []
    var mins = 0.0
    while mins < 30 { let b = c.nextBar(); bars.append(b); mins += Double(b.beats) / b.tempo }
    var shown = 0
    var mel: [(Bar, GeneratedNote)] = []
    for b in bars { for n in b.notes where n.voice == .melody { mel.append((b, n)) } }
    for (i, (b, n)) in mel.enumerated() {
        let bc = b.chord(at: n.beat)
        let pc = n.midi % 12
        let nct = !bc.chord.pcs.contains(pc)
        let ook = nct && !bc.scale.pcs.contains(pc) && !bc.key.contains(pc)
        let unres = nct && (i + 1 >= mel.count || abs(mel[i + 1].1.midi - n.midi) > 2)
        let leap = i + 1 < mel.count && abs(mel[i + 1].1.midi - n.midi) > 12
        if (ook || unres || leap) && shown < 14 {
            shown += 1
            let ctx = mel[max(0, i - 2)...min(mel.count - 1, i + 2)].map { "\($0.1.midi)\($0.1.kind.rawValue.prefix(3))@\($0.0.index):\($0.1.beat)" }.joined(separator: " ")
            print("\(b.section) [\(b.chords.map { "\($0.chord.symbol)@\($0.beat)" }.joined(separator: ","))] \(ook ? "OOK" : (unres ? "UNRES" : "LEAP")) bar \(b.index) beat \(n.beat) \(n.midi) \(n.kind) chord \(bc.chord.symbol) key \(b.keyName) | \(ctx)")
        }
    }
    // voices too
    var vo = 0
    for b in bars { for n in b.notes where n.voice != .melody {
        let bc = b.chord(at: n.beat); let pc = n.midi % 12
        if !bc.chord.pcs.contains(pc) && !bc.scale.pcs.contains(pc) && !bc.key.contains(pc) { vo += 1; if vo < 5 { print("OOK voice \(n.voice) \(n.kind) bar \(b.index) \(n.beat) \(n.midi) \(bc.chord.symbol)") } }
    }}
    exit(0)
}

let bank = try SampleBank.loadBundled()
let sr = SynthCore.internalSampleRate

struct AudioStats { var rms, peak, p10, p50, p90: Double; var clicks: Int; var amFreq, amProm: Double; var cpu: Double; var limiter: Float; var maxVoices: Int; var steals: Int; var nonFinite: Bool }

func renderStats(style: CompositionStyle?, mode: FocusMode, seconds: Double, seed: UInt64 = 3, am: Bool = true,
                 switchTo: FocusMode? = nil, switchAt: Double = 0) -> (AudioStats, [Float]) {
    var p = EngineParams(); p.mode = mode; p.style = style; p.rateHz = mode.defaultRate; p.amEnabled = am
    p.rampInSeconds = 0.01; p.intensity = 1.0
    let core = SynthCore(bank: bank, seed: seed, style: style, mode: mode)
    core.setParams(p); core.startSession(fadeInSeconds: 0.2)
    var maxV = 0, minLim: Float = 1
    let t0 = Date()
    var switched = false
    let out = core.renderOffline(seconds: seconds) { pos in
        if pos % 4096 == 0 { let m = core.meters; maxV = max(maxV, m.activeVoices); minLim = min(minLim, m.limiterGain) }
        if let s = switchTo, !switched, Double(pos) / sr >= switchAt {
            switched = true
            var q = p; q.mode = s; q.rateHz = s.defaultRate; core.setParams(q)
        }
    }
    let cpu = Date().timeIntervalSince(t0) / seconds
    let x = Array(out.left[Int(sr * 6)...])
    let st = AudioAnalysis.shortTermDB(x, sampleRate: sr)
    let env = AudioAnalysis.envelope(x, sampleRate: sr)
    let r = mode.defaultRate
    let pk = AudioAnalysis.envelopePeak(env, envRate: 500, band: (r * 0.6)...(r * 1.5), step: r < 5 ? 0.02 : 0.05)
    let clicks = AudioAnalysis.clickCount(x)
    return (AudioStats(rms: AudioAnalysis.db(AudioAnalysis.rms(x)), peak: AudioAnalysis.db(AudioAnalysis.peak(x)),
                       p10: AudioAnalysis.percentile(st, 0.1), p50: AudioAnalysis.percentile(st, 0.5), p90: AudioAnalysis.percentile(st, 0.9),
                       clicks: clicks.count, amFreq: pk.freq, amProm: pk.prominence, cpu: cpu, limiter: minLim, maxVoices: maxV,
                       steals: core.debugSteals, nonFinite: AudioAnalysis.hasNonFinite(out.left)), out.left)
}

if cmd == "renders" {
    let dir = args.count > 2 ? args[2] : "renders"
    let secs = args.count > 3 ? Double(args[3]) ?? 90 : 90
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for style in CompositionStyle.allCases {
        for mode in [FocusMode.focus, .sleep] {
            var p = EngineParams(); p.mode = mode; p.style = style; p.rateHz = mode.defaultRate; p.rampInSeconds = 15
            let core = SynthCore(bank: bank, seed: 11, style: style, mode: mode)
            core.setParams(p); core.startSession(fadeInSeconds: 1)
            let o = core.renderOffline(seconds: secs)
            let url = URL(fileURLWithPath: "\(dir)/\(style.rawValue)-\(mode.rawValue).wav")
            try WAV.write(left: o.left, right: o.right, sampleRate: Int(sr), to: url)
            print("wrote \(url.path)")
        }
    }
    exit(0)
}

// report
let seconds = args.count > 2 ? Double(args[2]) ?? 90 : 90
var md = "# Cadence offline analysis\n\nGenerated by `cadence-analyze report \(Int(seconds))`. Internal rate 48 kHz. Modulation at full intensity, no ramp.\n\n"
md += "## Audio (per style × mode, \(Int(seconds)) s each, first 6 s skipped)\n\n"
md += "| Style | Mode | RMS dBFS | Peak | Short-term p10/p50/p90 | Clicks | AM peak (Hz) | Prominence | Max voices | Limiter min gain | CPU (×RT) |\n|---|---|---|---|---|---|---|---|---|---|---|\n"
var worstClicks = 0
for style in CompositionStyle.allCases {
    for mode in FocusMode.allCases {
        let (s, _) = renderStats(style: style, mode: mode, seconds: seconds)
        worstClicks = max(worstClicks, s.clicks)
        let row = "| \(style.title) | \(mode.title) | \(f1(s.rms)) | \(f1(s.peak)) | \(f1(s.p10))/\(f1(s.p50))/\(f1(s.p90)) | \(s.clicks) | \(f2(s.amFreq)) | ×\(Int(s.amProm)) | \(s.maxVoices) | \(f2(Double(s.limiter))) | \(String(format: "%.3f", s.cpu))\(s.nonFinite ? " NaN!" : "") |"
        print(row); md += row + "\n"
    }
}
// AM on vs off at the target rate (Focus)
let (onS, onX) = renderStats(style: .romantic, mode: .focus, seconds: seconds)
let (_, offX) = renderStats(style: .romantic, mode: .focus, seconds: seconds, am: false)
let eOn = AudioAnalysis.envelope(onX, sampleRate: sr), eOff = AudioAnalysis.envelope(offX, sampleRate: sr)
let mOn = AudioAnalysis.envelopeMagnitude(eOn, envRate: 500, at: 16), mOff = AudioAnalysis.envelopeMagnitude(eOff, envRate: 500, at: 16)
md += "\nAM on/off at 16 Hz (Romantic, Focus): envelope magnitude ratio ×\(Int(mOn / max(mOff, 1e-12))); AM-off clicks \(AudioAnalysis.clickCount(offX).count); peak bin \(f2(onS.amFreq)) Hz.\n"

// mode transition
let (tr, trX) = renderStats(style: .romantic, mode: .focus, seconds: 75, switchTo: .sleep, switchAt: 35)
let st = AudioAnalysis.shortTermDB(trX, sampleRate: sr)   // starts at 6 s; switch at index (35-6)/0.1
let si = Int((35.0 - 6) / 0.1)
let before = AudioAnalysis.percentile(Array(st[(si - 60)..<si]), 0.5)
let during = Array(st[si..<min(st.count, si + 60)]).min() ?? 0
let tail = Array(trX[Int(sr * (75 - 6 - 20))...])
let tailEnv = AudioAnalysis.envelope(tail, sampleRate: sr)
let tailPk = AudioAnalysis.envelopePeak(tailEnv, envRate: 500, band: 1.5...4, step: 0.02)
md += "\n## Mode transition (Focus → Sleep at 35 s, Romantic)\n\nMedian level before \(f1(before)) dBFS; lowest 0.4 s window in the 6 s after the switch \(f1(during)) dBFS (music continues, no gap); clicks over the whole render \(tr.clicks); modulation peak (1.5–4 Hz) in the last 20 s \(f2(tailPk.freq)) Hz (×\(Int(tailPk.prominence))). In Sleep the music's own beat (~1 Hz) shares this band, so the AM on/off ratio is the meaningful measure (tested ≥ 4×).\n"

// composition
md += "\n## Composition (Composer only, ~60 min per style, seed 5)\n\n| Style | Bars | Min | Notes/bar (mel/ctr/bass/inner) | Out-of-key | Chromatic % | Melody NCT % | Unresolved | Outer ∥5/8 | Mean |interval| | Leaps>6th | Static runs | Key changes | Distinct chords | Unique 4-bar windows | Tempo | Velocity |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
for style in CompositionStyle.allCases {
    let c = Composer(mode: .focus, style: style, seed: 5)
    var bars: [Bar] = []
    var mins = 0.0
    while mins < 60 { let b = c.nextBar(); bars.append(b); mins += Double(b.beats) / b.tempo }
    let r = CompositionAnalysis.analyze(bars)
    let npb = [VoiceRole.melody, .counter, .bass, .inner].map { f1(r.notesPerBar[$0] ?? 0) }.joined(separator: "/")
    let row = "| \(style.title) | \(r.bars) | \(Int(r.minutes)) | \(npb) | \(r.outOfKey) | \(f1(100 * Double(r.chromatic) / Double(r.notes))) | \(f1(100 * Double(r.melodyNonChordTones) / Double(max(1, r.melodyNotes)))) | \(r.unresolvedDissonances) | \(r.outerParallels)/\(r.chordChanges) | \(f2(r.meanAbsMelodicInterval)) | \(r.melodicLeapsOverSixth) | \(r.staticRepeats) | \(r.keyChanges) | \(r.distinctChordSymbols) | \(f2(r.uniqueFourBarWindows)) | \(Int(r.tempoRange.lowerBound))–\(Int(r.tempoRange.upperBound)) | \(r.velocityRange.lowerBound)–\(r.velocityRange.upperBound) |"
    print(row); md += row + "\n"
}
md += "\n### Salience (events likely to grab attention; 3 × 60 min per style)\n\n" + salienceHeader
for style in CompositionStyle.allCases {
    var bars: [Bar] = []
    for sd in 0..<3 { bars += composeMinutes(style, seed: UInt64(5 + sd * 17)) }
    md += salienceRow(style, CompositionAnalysis.analyze(bars)) + "\n"
}
if let i = args.firstIndex(of: "--long"), i + 1 < args.count, let mins = Double(args[i + 1]) {
    var p = EngineParams(); p.style = nil
    let core = SynthCore(bank: bank, seed: 21, style: nil, mode: .focus)
    core.setParams(p); core.startSession(fadeInSeconds: 1)
    var levels: [Double] = []
    var maxV = 0
    var bad = false
    let t0 = Date()
    for _ in 0..<Int(mins) {
        let o = core.renderOffline(seconds: 60)
        bad = bad || AudioAnalysis.hasNonFinite(o.left)
        levels.append(AudioAnalysis.db(AudioAnalysis.rms(o.left)))
        maxV = max(maxV, core.meters.activeVoices)
    }
    let el = Date().timeIntervalSince(t0)
    md += "\n## Long session (\(Int(mins)) min, varied styles)\n\nPer-minute RMS range \(f1(levels.min()!))…\(f1(levels.max()!)) dBFS; non-finite samples: \(bad ? "YES" : "none"); voices at end \(maxV); render speed \(f1(mins * 60 / el))× real time; styles visited: \(core.currentStatus.movement + 1) movements.\n"
}
try? FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
try md.write(toFile: "docs/ANALYSIS.md", atomically: true, encoding: .utf8)
print("\nwrote docs/ANALYSIS.md; worst clicks \(worstClicks)")
