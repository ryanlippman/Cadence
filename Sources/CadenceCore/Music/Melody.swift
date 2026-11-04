import Foundation

public enum NoteKind: String, Sendable {
    case chordTone, passing, neighbor, suspension, resolution, appoggiatura, ornament, anticipation, accompaniment
    public var isDissonantByDesign: Bool { [.passing, .neighbor, .appoggiatura, .ornament, .anticipation].contains(self) }
}

public enum VoiceRole: String, Sendable { case melody, counter, bass, inner }

struct MelNote: Sendable {
    var beat: Double
    var dur: Double
    var midi: Int
    var kind: NoteKind
    var structural: Bool
    var end: Double { beat + dur }
}

/// A short rhythmic-melodic idea that a movement develops.
public struct Motif: Sendable {
    var rhythm: [(Double, Double)]
    /// Melodic direction of each onset relative to the previous structural tone (−1, 0, +1).
    var directions: [Int]
    var beats: Int

    static func make(profile: StyleProfile, beats: Int, dice: Dice) -> Motif {
        let vocab = beats == 3 ? profile.rhythms3 : profile.rhythms4
        let r = dice.pick(vocab.filter { $0.count >= 2 }.isEmpty ? vocab : vocab.filter { $0.count >= 2 })
        var dirs: [Int] = []
        for i in 0..<max(r.count, 2) {
            dirs.append(i == 0 ? 0 : dice.weighted([(1, 0.45), (-1, 0.4), (0, 0.15)]))
        }
        return Motif(rhythm: r, directions: dirs, beats: beats)
    }

    /// Develop an existing motif for a new movement: inversion, retrograde, or a fresh variant.
    func developed(profile: StyleProfile, beats: Int, dice: Dice) -> Motif {
        guard beats == self.beats else { return Motif.make(profile: profile, beats: beats, dice: dice) }
        switch dice.int(0...3) {
        case 0: return Motif(rhythm: rhythm, directions: directions.map { -$0 }, beats: beats)   // inversion
        case 1: return Motif(rhythm: rhythm, directions: [0] + directions.dropFirst().reversed(), beats: beats)
        case 2:
            var m = Motif.make(profile: profile, beats: beats, dice: dice)
            m.directions = directions
            return m
        default: return Motif.make(profile: profile, beats: beats, dice: dice)
        }
    }
}

enum PhraseRole { case antecedent, consequent, bridge, codetta, cadentialExtension }

final class MelodyComposer {
    let dice: Dice
    init(dice: Dice) { self.dice = dice }

    // MARK: rhythm

    private func rhythm(plan: PhrasePlan, motif: Motif, profile: StyleProfile, density: Double, role: PhraseRole,
                        fromBeat: Double) -> [(Double, Double)] {
        let B = plan.beatsPerBar
        let vocab = B == 3 ? profile.rhythms3 : profile.rhythms4
        let cad = B == 3 ? profile.cadenceRhythms3 : profile.cadenceRhythms4
        let motifPat = motif.beats == B ? motif.rhythm : dice.pick(vocab)
        let sparsest = vocab.min { $0.count < $1.count } ?? motifPat
        func response() -> [(Double, Double)] {
            let c = vocab.filter { $0.count <= motifPat.count && !($0.map { $0.0 } == motifPat.map { $0.0 }) }
            return c.isEmpty ? sparsest : dice.pick(c)
        }
        func variant() -> [(Double, Double)] {
            var p = motifPat
            if dice.chance(0.5), let i = p.firstIndex(where: { $0.1 >= 2 }) {
                let (o, d) = p[i]; p[i] = (o, d / 2); p.insert((o + d / 2, d / 2), at: i + 1)
            }
            return p
        }
        func head() -> [(Double, Double)] {
            let half = Double(B) / 2
            var h = motifPat.filter { $0.0 < half }.map { ($0.0, min($0.1, half - $0.0)) }
            if h.isEmpty { h = [(0, half)] }
            h.append((half, half))
            return h
        }
        var out: [(Double, Double)] = []
        let resp = response()
        for bar in 0..<plan.bars {
            let start = Double(bar * B)
            if start < fromBeat - 1e-9 { continue }
            let last = bar == plan.bars - 1
            var pat: [(Double, Double)]
            if last { pat = dice.pick(cad) }
            else if role == .bridge || role == .codetta { pat = bar == 0 ? head() : dice.pick(vocab) }
            else if plan.bars <= 4 { pat = [motifPat, resp, variant(), resp][bar % 4] }
            else { pat = [motifPat, resp, motifPat, response(), head(), head(), dice.pick(vocab), resp][bar % 8] }
            if !last, dice.chance((1 - density) * 0.8) { pat = sparsest }
            if profile.style == .minimalist, !last, bar % 2 == 1, dice.chance(0.3) { pat = [] }
            out += pat.map { (start + $0.0, $0.1) }
        }
        return out
    }

    // MARK: main entry

    func compose(plan: PhrasePlan, voicings: [Voicing], motif: Motif, profile: StyleProfile, density: Double,
                 role: PhraseRole, range: ClosedRange<Int>, startPitch: Int, prefix: [MelNote] = [], prefixBeats: Double = 0) -> [MelNote] {
        let rh = rhythm(plan: plan, motif: motif, profile: profile, density: density, role: role, fromBeat: prefixBeats)
        let B = plan.beatsPerBar
        let total = plan.totalBeats
        let slotStarts = Set(plan.slots.map { $0.start })
        var notes: [MelNote] = prefix
        for (i, (b, d)) in rh.enumerated() {
            let inBar = b.truncatingRemainder(dividingBy: Double(B))
            let integral = abs(b - b.rounded()) < 1e-9
            var structural = integral && (d >= 1 || inBar == 0 || (B == 4 && inBar == 2) || slotStarts.contains(b))
            if i == 0 || i == rh.count - 1 { structural = true }
            notes.append(MelNote(beat: b, dur: d, midi: 0, kind: .chordTone, structural: structural))
        }
        guard notes.count > prefix.count else { return notes }

        // contour
        let lo = range.lowerBound, hi = range.upperBound
        // continuity with the previous phrase, pulled back toward a comfortable singing register
        let home = Double(lo) + Double(hi - lo) * 0.35
        let startReg = min(max(0.5 * Double(startPitch) + 0.5 * home, Double(lo + 2)), Double(hi - 7))
        let span = Double(dice.int(profile.climaxSpan)) * (role == .bridge || role == .codetta ? 0.5 : 1)
        let climax = min(Double(hi - 1), startReg + span)
        let climaxPos = dice.range(0.5...0.72)
        let endReg = startReg - Double(dice.int(1...5))
        func target(_ beat: Double) -> Double {
            let p = beat / total
            if p < climaxPos { return startReg + (climax - startReg) * sin(.pi / 2 * p / climaxPos) }
            return climax + (endReg - climax) * (1 - cos(.pi / 2 * (p - climaxPos) / (1 - climaxPos)))
        }

        // structural tones
        let structIdx = notes.indices.filter { $0 >= prefix.count && notes[$0].structural }
        let lastStruct = structIdx.last
        let finalKey = plan.endKey
        var prev = prefix.last?.midi ?? startPitch
        var prevInterval = 0
        var prevBass: Int? = nil
        var motifCounter = 0
        var repeats = 0
        var openingPitch: Int? = prefix.first?.midi
        var slotPitch: [Int: Int] = [:]   // melody pitch at each harmony change, for outer-voice checks
        let motifBars: Set<Int> = plan.bars <= 4 ? [0, 2] : [0, 2]
        for (k, i) in structIdx.enumerated() {
            let n = notes[i]
            let si = plan.slotIndex(at: n.beat)
            let slot = plan.slots[si]
            let chord = slot.chord
            let bass = voicings[si].bass
            let isFinal = i == lastStruct
            let isPenult = k == structIdx.count - 2
            var cands = (lo...hi).filter { chord.pcs.contains(mod12($0)) }
            if isPenult && plan.cadence == .authentic && chord.function == .dominant {
                let f = cands.filter { [finalKey.pc(1), finalKey.pc(6)].contains(mod12($0)) }   // 2̂ or 7̂ → 1̂
                if !f.isEmpty { cands = f }
            }
            if isFinal {
                switch plan.cadence {
                case .authentic, .plagal, .deceptive:
                    let want = role == .antecedent && dice.chance(0.25) ? finalKey.pc(2) : finalKey.tonic
                    let f = cands.filter { mod12($0) == want }
                    if !f.isEmpty { cands = f } else { cands = cands.filter { mod12($0) == finalKey.tonic }.isEmpty ? cands : cands.filter { mod12($0) == finalKey.tonic } }
                case .half:
                    let pref = Set([finalKey.pc(1), finalKey.pc(6), finalKey.pc(4)])
                    let f = cands.filter { pref.contains(mod12($0)) }
                    if !f.isEmpty { cands = f }
                case .open: break
                }
            }
            let bar = Int(n.beat) / B
            let dirWanted: Int? = motifBars.contains(bar % 8) && role != .bridge ? motif.directions[motifCounter % motif.directions.count] : nil
            if dirWanted != nil { motifCounter += 1 }
            var best = cands.first ?? prev, bestCost = Double.infinity
            for m in cands {
                var c = abs(Double(m) - target(n.beat)) * 0.32
                let d = abs(m - prev)
                let table: [Double] = [profile.style == .minimalist ? 0.4 : 1.1, 0.05, 0.0, 0.35, 0.45, 1.1, 6, 1.8, 3.0, 3.5, 6, 7, 5]
                c += d <= 12 ? table[d] : 9
                if d == 0 { c += Double(repeats) * 2.0 }   // no static note-repetition
                if let w = dirWanted, w != 0, (m - prev).signum() != w { c += 1.6 }
                if abs(prevInterval) >= 5, (m - prev).signum() == prevInterval.signum() { c += 2.2 }   // recover leaps
                if let pb = prevBass, pb != bass {
                    let a = mod12(prev - pb), b2 = mod12(m - bass)
                    if a == b2 && (a == 0 || a == 7) && (m - prev).signum() == (bass - pb).signum() { c += 9 }
                }
                if abs(n.beat - slot.start) < 1e-6, si > 0, let pm = slotPitch[si - 1] {
                    let pb = voicings[si - 1].bass
                    let a = mod12(pm - pb), b2 = mod12(m - bass)
                    if pm != m && pb != bass && a == b2 && (a == 0 || a == 7) && (m - pm).signum() == (bass - pb).signum() { c += 12 }
                }
                // an antecedent's cadence stays near its opening register, so the restatement flows on
                if isFinal && role == .antecedent, let o = openingPitch { c += Double(max(0, abs(m - o) - 7)) * 0.9 }
                if isPenult && plan.cadence == .authentic {
                    let pc = mod12(m)
                    if pc == finalKey.pc(1) || pc == finalKey.pc(6) { c -= 1.2 }
                }
                c += dice.gauss() * 0.25
                if c < bestCost { bestCost = c; best = m }
            }
            prevInterval = best - prev
            repeats = best == prev ? repeats + 1 : 0
            prev = best
            if abs(n.beat - slot.start) < 1e-6 || slotPitch[si] == nil { slotPitch[si] = best }
            if openingPitch == nil { openingPitch = best }
            prevBass = bass
            notes[i].midi = best
        }

        // weak tones between structural tones
        var i = prefix.count
        while i < notes.count {
            if notes[i].structural { i += 1; continue }
            var j = i
            while j < notes.count && !notes[j].structural { j += 1 }
            let a = i > 0 ? notes[i - 1].midi : startPitch
            let b = j < notes.count ? notes[j].midi : a
            let k = j - i
            let scale = plan.slot(at: notes[i].beat).scale
            let s = scale.steps(from: a, to: b)
            var pitches: [Int] = []
            if abs(s) == k + 1 {
                pitches = (1...k).map { scale.step(from: a, by: s.signum() * $0) }
            } else if s == 0 && k == 1 {
                pitches = [scale.step(from: a, by: dice.chance(0.6) ? 1 : -1)]
            } else {
                for r in 0..<k {
                    let isLastWeak = r == k - 1
                    let chord = plan.slot(at: notes[i + r].beat).chord
                    if isLastWeak && s != 0 {
                        pitches.append(dice.chance(0.25) && k == 1 && abs(s) == 1 ? b : scale.step(from: b, by: -s.signum()))
                    } else {
                        let interp = Double(a) + Double(b - a) * Double(r + 1) / Double(k + 1)
                        let last = pitches.last ?? a
                        let ct = (lo...hi).filter { chord.pcs.contains(mod12($0)) && $0 != last }
                            .min { abs(Double($0) - interp) < abs(Double($1) - interp) } ?? last
                        pitches.append(ct)
                    }
                }
            }
            for r in 0..<k {
                let idx = i + r
                let p = min(max(pitches[r], lo - 2), hi + 2)
                notes[idx].midi = p
                let chord = plan.slot(at: notes[idx].beat).chord
                if chord.pcs.contains(mod12(p)) { notes[idx].kind = .chordTone }
                else if p == b { notes[idx].kind = .anticipation }
                else { notes[idx].kind = abs(s) >= 2 ? .passing : .neighbor }
            }
            i = j
        }
        resolveDissonances(&notes, plan: plan, range: (lo - 2)...(hi + 2), from: prefix.count)

        // suspensions at chord changes (prepare – suspend – resolve down by step)
        if profile.suspensionProb > 0 {
            for j in max(1, prefix.count)..<notes.count {
                let n = notes[j], p = notes[j - 1]
                guard n.structural, slotStarts.contains(n.beat), n.dur >= 1, abs(p.end - n.beat) < 1e-6,
                      p.kind == .chordTone, dice.chance(profile.suspensionProb) else { continue }
                let slot = plan.slot(at: n.beat)
                guard !slot.chord.pcs.contains(mod12(p.midi)) else { continue }
                let r = slot.scale.step(from: p.midi, by: -1)
                guard slot.chord.pcs.contains(mod12(r)), p.midi - r <= 2 else { continue }
                let sus = n.dur >= 2 ? 1.0 : 0.5
                notes[j - 1].dur += sus
                notes[j - 1].kind = .suspension
                notes[j] = MelNote(beat: n.beat + sus, dur: n.dur - sus, midi: r, kind: .resolution, structural: true)
            }
        }
        // appoggiaturas on long notes
        if profile.appoggiaturaProb > 0 {
            var out: [MelNote] = []
            for (idx, n) in notes.enumerated() {
                if idx >= max(1, prefix.count), n.structural, n.kind == .chordTone, n.dur >= 2, dice.chance(profile.appoggiaturaProb) {
                    let slot = plan.slot(at: n.beat)
                    let u = slot.scale.step(from: n.midi, by: 1)
                    if !slot.chord.pcs.contains(mod12(u)), u <= hi + 1, abs(u - (out.last?.midi ?? u)) <= 7 {
                        out.append(MelNote(beat: n.beat, dur: n.dur / 2, midi: u, kind: .appoggiatura, structural: true))
                        out.append(MelNote(beat: n.beat + n.dur / 2, dur: n.dur / 2, midi: n.midi, kind: .resolution, structural: true))
                        continue
                    }
                }
                out.append(n)
            }
            notes = out
        }
        // turns leading into long notes
        if profile.ornamentProb > 0 {
            var out: [MelNote] = []
            for (idx, n) in notes.enumerated() {
                if idx >= max(1, prefix.count), var p = out.last, n.structural, n.dur >= 1.5, p.dur >= 1, abs(p.end - n.beat) < 1e-6,
                   p.kind == .chordTone, dice.chance(profile.ornamentProb) {
                    let scale = plan.slot(at: n.beat).scale
                    let t0 = n.beat - 0.5
                    let before = plan.slot(at: t0)
                    p.dur -= 0.5
                    out[out.count - 1] = p
                    let up = scale.step(from: n.midi, by: 1), dn = scale.step(from: n.midi, by: -1)
                    let ok = [up, n.midi, dn].allSatisfy { before.scale.contains($0) && scale.contains($0) }
                    if abs(up - p.midi) <= 4 && ok {
                        out.append(MelNote(beat: t0, dur: 1.0 / 6, midi: up, kind: .ornament, structural: false))
                        out.append(MelNote(beat: t0 + 1.0 / 6, dur: 1.0 / 6, midi: n.midi, kind: .ornament, structural: false))
                        out.append(MelNote(beat: t0 + 2.0 / 6, dur: 1.0 / 6, midi: dn, kind: .ornament, structural: false))
                    } else {
                        p.dur += 0.5; out[out.count - 1] = p
                    }
                }
                out.append(n)
            }
            notes = out
        }
        fixParallels(&notes, plan: plan, voicings: voicings, range: lo...hi)
        // final guarantee after all embellishment (including the copied prefix's last note, which now
        // leads into newly composed material): every dissonance resolves by step
        resolveDissonances(&notes, plan: plan, range: (lo - 2)...(hi + 2), from: 0)
        return notes
    }

    /// Any note that is not a chord tone at its onset must move by step (≤ 2 semitones) to the next
    /// note and belong to the local scale; otherwise it is replaced by the nearest chord tone.
    func resolveDissonances(_ notes: inout [MelNote], plan: PhrasePlan, range: ClosedRange<Int>, from: Int = 0) {
        guard !notes.isEmpty else { return }
        for i in stride(from: notes.count - 1, through: from, by: -1) {
            let slot = plan.slot(at: notes[i].beat)
            let pc = mod12(notes[i].midi)
            if slot.chord.pcs.contains(pc) {
                if notes[i].kind != .suspension && notes[i].kind != .ornament { notes[i].kind = notes[i].kind == .resolution ? .resolution : .chordTone }
                continue
            }
            let nextOK = i + 1 < notes.count && abs(notes[i + 1].midi - notes[i].midi) <= 2
            if nextOK && slot.scale.pcs.contains(pc) {
                if notes[i].kind == .chordTone || notes[i].kind == .resolution {
                    notes[i].kind = abs(notes[i + 1].midi - notes[i].midi) == 0 ? .anticipation : .passing
                }
                continue
            }
            let ref = i > 0 ? notes[i - 1].midi : notes[i].midi
            let ct = range.filter { slot.chord.pcs.contains(mod12($0)) }.min { abs($0 - ref) < abs($1 - ref) } ?? notes[i].midi
            notes[i].midi = ct
            notes[i].kind = .chordTone
        }
    }

    /// Repairs parallel fifths/octaves between melody and bass at harmony changes by moving the
    /// melody's chord tone to the nearest alternative that keeps every dissonance resolved.
    func fixParallels(_ notes: inout [MelNote], plan: PhrasePlan, voicings: [Voicing], range: ClosedRange<Int>) {
        guard plan.slots.count > 1, !notes.isEmpty else { return }
        func sounding(at t: Double) -> Int? { notes.lastIndex { $0.beat <= t + 0.3 } }
        for si in 1..<min(plan.slots.count, voicings.count) {
            guard let i0 = sounding(at: plan.slots[si - 1].start), let i1 = sounding(at: plan.slots[si].start), i0 != i1 else { continue }
            let pm = notes[i0].midi, m = notes[i1].midi, pb = voicings[si - 1].bass, b = voicings[si].bass
            guard pm != m, pb != b else { continue }
            let a = mod12(pm - pb)
            guard a == mod12(m - b), a == 0 || a == 7, (m - pm).signum() == (b - pb).signum() else { continue }
            guard notes[i1].kind == .chordTone else { continue }
            let chord = plan.slot(at: notes[i1].beat).chord
            let prev: MelNote? = i1 > 0 ? notes[i1 - 1] : nil
            let prevNCT = prev.map { !plan.slot(at: $0.beat).chord.pcs.contains(mod12($0.midi)) } ?? false
            let opts = range.filter { x in
                chord.pcs.contains(mod12(x)) && x != m && abs(x - m) <= 5
                    && !(mod12(x - b) == a && (x - pm).signum() == (b - pb).signum())
                    && (!prevNCT || abs(x - prev!.midi) <= 2)
            }.sorted { abs($0 - m) < abs($1 - m) }
            if let x = opts.first { notes[i1].midi = x }
        }
    }

    /// Light variation for recalled phrases: added passing tones between structural thirds.
    func vary(_ notes: [MelNote], plan: PhrasePlan) -> [MelNote] {
        var out: [MelNote] = []
        var added = 0
        for (i, n) in notes.enumerated() {
            if added < 3, i + 1 < notes.count, n.kind == .chordTone, n.dur >= 1, abs(n.end - notes[i + 1].beat) < 1e-6, dice.chance(0.7) {
                let scale = plan.slot(at: n.beat + n.dur / 2).scale
                let nx = notes[i + 1].midi
                if abs(scale.steps(from: n.midi, to: nx)) == 2 {
                    let mid = scale.step(from: n.midi, by: (nx - n.midi).signum())
                    out.append(MelNote(beat: n.beat, dur: n.dur / 2, midi: n.midi, kind: .chordTone, structural: n.structural))
                    let chord = plan.slot(at: n.beat + n.dur / 2).chord
                    out.append(MelNote(beat: n.beat + n.dur / 2, dur: n.dur / 2, midi: mid,
                                       kind: chord.pcs.contains(mod12(mid)) ? .chordTone : .passing, structural: false))
                    added += 1
                    continue
                }
            }
            out.append(n)
        }
        let lo = (out.map { $0.midi }.min() ?? 60) - 2, hi = (out.map { $0.midi }.max() ?? 84) + 2
        resolveDissonances(&out, plan: plan, range: lo...hi)
        return out
    }

    // MARK: independent voices

    /// An inner counter-melody that moves when the melody rests and holds when it moves.
    func counterVoice(plan: PhrasePlan, voicings: [Voicing], melody: [MelNote], density: Double, range: ClosedRange<Int>) -> [MelNote] {
        var notes: [MelNote] = []
        let melodyOnsets = Set(melody.map { ($0.beat * 1000).rounded() })
        func melodyPitch(at b: Double) -> Int? { melody.last { $0.beat <= b + 1e-9 && $0.end > b + 1e-9 }?.midi }
        for (si, slot) in plan.slots.enumerated() {
            var anchor = voicings[si].upper[1]
            while anchor < range.lowerBound { anchor += 12 }
            while anchor > range.upperBound { anchor -= 12 }
            let nextAnchor: Int = {
                guard si + 1 < voicings.count else { return anchor }
                var a = voicings[si + 1].upper[1]
                while a < range.lowerBound { a += 12 }
                while a > range.upperBound { a -= 12 }
                return a
            }()
            let step = density >= 0.85 ? 1.0 : 2.0
            var onsets: [Double] = []
            var t = slot.start
            while t < slot.end - 1e-9 {
                let mel = melodyOnsets.contains((t * 1000).rounded())
                if t == slot.start || !mel || dice.chance(0.3) { onsets.append(t) }
                t += step
            }
            var cur = anchor
            for (k, o) in onsets.enumerated() {
                var p: Int
                if k == 0 { p = anchor }
                else {
                    let remaining = onsets.count - k
                    let s = slot.scale.steps(from: cur, to: nextAnchor)
                    if abs(s) >= 1 && abs(s) <= remaining + 1 { p = slot.scale.step(from: cur, by: s.signum()) }
                    else {
                        p = range.filter { slot.chord.pcs.contains(mod12($0)) && $0 != cur && abs($0 - cur) <= 5 }
                            .min { abs($0 - cur) < abs($1 - cur) } ?? cur
                    }
                }
                if let m = melodyPitch(at: o), p >= m - 2 {
                    p = range.filter { slot.chord.pcs.contains(mod12($0)) && $0 < m - 2 }.max() ?? (p - 12)
                }
                let end = k + 1 < onsets.count ? onsets[k + 1] : slot.end
                notes.append(MelNote(beat: o, dur: end - o, midi: p,
                                     kind: slot.chord.pcs.contains(mod12(p)) ? .chordTone : .passing, structural: k == 0))
                cur = p
            }
        }
        resolveDissonances(&notes, plan: plan, range: range)
        // keep below the melody after resolution
        for i in notes.indices {
            if let m = melodyPitch(at: notes[i].beat), notes[i].midi >= m - 1 {
                let slot = plan.slot(at: notes[i].beat)
                if let c = range.filter({ slot.chord.pcs.contains(mod12($0)) && $0 < m - 2 }).max() { notes[i].midi = c; notes[i].kind = .chordTone }
            }
        }
        return notes
    }

    /// Stepwise quarter-note bass line connecting the voiced bass notes (baroque).
    func walkingBass(plan: PhrasePlan, voicings: [Voicing], density: Double) -> [MelNote] {
        var notes: [MelNote] = []
        let range = 31...55
        let step = density >= 0.8 ? 1.0 : 2.0
        for (si, slot) in plan.slots.enumerated() {
            let b0 = voicings[si].bass
            let next = si + 1 < voicings.count ? voicings[si + 1].bass : b0
            var onsets: [Double] = []
            var t = slot.start
            while t < slot.end - 1e-9 { onsets.append(t); t += step }
            var cur = b0
            for (k, o) in onsets.enumerated() {
                var p = b0
                if k > 0 {
                    let remaining = onsets.count - k
                    let s = slot.scale.steps(from: cur, to: next)
                    if abs(s) >= 1 && abs(s) <= remaining + 1 && abs(next - cur) <= 7 { p = slot.scale.step(from: cur, by: s.signum()) }
                    else {
                        let opts = range.filter { slot.chord.pcs.contains(mod12($0)) && $0 != cur && abs($0 - cur) <= 12 }
                        p = opts.min { abs($0 - (cur + next) / 2) < abs($1 - (cur + next) / 2) } ?? cur
                    }
                }
                let end = k + 1 < onsets.count ? onsets[k + 1] : slot.end
                notes.append(MelNote(beat: o, dur: end - o, midi: p,
                                     kind: slot.chord.pcs.contains(mod12(p)) ? .chordTone : .passing, structural: k == 0))
                cur = p
            }
        }
        resolveDissonances(&notes, plan: plan, range: range)
        return notes
    }
}
