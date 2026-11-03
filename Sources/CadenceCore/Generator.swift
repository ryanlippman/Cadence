import Foundation

/// Rules-based generator of slow, calm, tonal piano music. Emits one bar at a time, forever.
public final class MusicGenerator {
    public enum Texture: CaseIterable { case alberti, rolling, gymnopedie, lullaby }

    private var rng: SeededRNG
    public private(set) var mode: FocusMode
    private var profile: MusicProfile

    public private(set) var tonic: Int
    public private(set) var scale: ScaleMode
    public private(set) var texture: Texture
    private var degree = 0
    private var barsInChord = 0
    private var currentChord: Chord
    private var currentBorrowed = false
    private var tempo: Double
    private var barIndex = 0
    private var elapsedSeconds = 0.0
    private var nextModulationAt: Double
    private var pendingModulation: (tonic: Int, scale: ScaleMode)?
    private var melodyPitch = 72
    private var lastPattern = -1
    private var restStreak = 0
    private var dynPhase: Double

    private static let transitions: [[(Int, Double)]] = [
        [(3, 3), (5, 3), (1, 2), (4, 2), (2, 1)],
        [(4, 3), (3, 2), (0, 1), (5, 1)],
        [(5, 3), (3, 2), (1, 1)],
        [(0, 2), (4, 2), (1, 2), (5, 1)],
        [(0, 4), (5, 2), (3, 1)],
        [(3, 3), (1, 2), (4, 1), (0, 1)],
        [(0, 3), (2, 1), (5, 1)],
    ]

    public init(mode: FocusMode, seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        rng = SeededRNG(seed: seed)
        self.mode = mode
        profile = mode.profile
        let scales: [ScaleMode]
        switch mode {
        case .focus: scales = [.ionian, .mixolydian, .dorian, .aeolian, .ionian]
        case .relax: scales = [.ionian, .lydian, .aeolian, .dorian]
        case .sleep: scales = [.ionian, .lydian, .ionian]
        }
        scale = scales.randomElement(using: &rng)!
        // favour comfortable piano keys
        tonic = [0, 2, 3, 5, 7, 9, 10, 4, 8].randomElement(using: &rng)!
        texture = Texture.allCases.randomElement(using: &rng)!
        tempo = Double.random(in: mode.profile.tempoRange, using: &rng)
        nextModulationAt = mode.profile.modulationSeconds * Double.random(in: 0.8...1.2, using: &rng)
        dynPhase = Double.random(in: 0...(2 * .pi), using: &rng)
        currentChord = Chord(rootPC: tonic, intervals: [0, 4, 7], degree: 0)
        currentChord = MusicGenerator.diatonic(0, tonic: tonic, scale: scale, colour: nil)
    }

    /// Switches focus/relax/sleep behaviour; takes effect at the next bar without changing key.
    public func setMode(_ m: FocusMode) {
        guard m != mode else { return }
        mode = m
        profile = m.profile
        tempo = min(max(tempo, profile.tempoRange.lowerBound), profile.tempoRange.upperBound)
    }

    // MARK: chords

    static func diatonic(_ d: Int, tonic: Int, scale: ScaleMode, colour: Int?) -> Chord {
        func pc(_ i: Int) -> Int { (tonic + scale.intervals[i % 7]) % 12 }
        let root = pc(d)
        var iv = [0, (pc(d + 2) - root + 12) % 12, (pc(d + 4) - root + 12) % 12]
        if let c = colour { iv.append((pc(d + c) - root + 12) % 12) }
        return Chord(rootPC: root, intervals: iv, degree: d)
    }

    private func borrowedChord() -> Chord {
        // Chords from the parallel mode, expressed relative to the tonic.
        let options: [(Int, [Int])] = scale.isMinorish
            ? [(5, [0, 4, 7]), (7, [0, 4, 7])]                 // IV, V (major)
            : [(8, [0, 4, 7]), (10, [0, 4, 7]), (5, [0, 3, 7])] // ♭VI, ♭VII, iv
        let o = options.randomElement(using: &rng)!
        return Chord(rootPC: (tonic + o.0) % 12, intervals: o.1, degree: nil)
    }

    private func nextDegree(from d: Int) -> Int {
        let row = MusicGenerator.transitions[d]
        let total = row.reduce(0) { $0 + $1.1 }
        var r = Double.random(in: 0..<total, using: &rng)
        for (to, w) in row { if r < w { return to }; r -= w }
        return 0
    }

    // MARK: modulation

    private func planModulation() -> (Int, ScaleMode, Chord)? {
        var candidates: [(Int, ScaleMode)] = []
        if scale.isMinorish {
            candidates = [((tonic + 3) % 12, .ionian), ((tonic + 7) % 12, .aeolian), ((tonic + 5) % 12, .aeolian)]
        } else {
            candidates = [((tonic + 7) % 12, scale), ((tonic + 5) % 12, scale), ((tonic + 9) % 12, .aeolian)]
        }
        candidates.shuffle(using: &rng)
        for (t, s) in candidates {
            let target = Set(s.intervals.map { (t + $0) % 12 })
            for d in [1, 3, 5, 4, 2] { // pivot chord diatonic to both keys
                let c = MusicGenerator.diatonic(d, tonic: tonic, scale: scale, colour: nil)
                if c.pcs.isSubset(of: target) { pendingModulation = (t, s); return (t, s, c) }
            }
        }
        return nil
    }

    // MARK: bar generation

    public func nextBar() -> Bar {
        let beats = texture == .gymnopedie ? 3 : 4
        // slow tempo drift (rubato-like) bounded by the profile
        let mid = (profile.tempoRange.lowerBound + profile.tempoRange.upperBound) / 2
        tempo += gauss() * 0.7 + (mid - tempo) * 0.05
        tempo = min(max(tempo, profile.tempoRange.lowerBound), profile.tempoRange.upperBound)

        var pivot = false
        var modulatedHere = false

        if let pm = pendingModulation {
            // switch key now; begin on the new dominant
            tonic = pm.tonic; scale = pm.scale
            pendingModulation = nil
            degree = 4
            currentChord = MusicGenerator.diatonic(4, tonic: tonic, scale: scale, colour: nil)
            currentBorrowed = false
            barsInChord = 0
            modulatedHere = true
            nextModulationAt = elapsedSeconds + profile.modulationSeconds * Double.random(in: 0.8...1.25, using: &rng)
            if Double.random(in: 0..<1, using: &rng) < 0.3 { texture = Texture.allCases.randomElement(using: &rng)! }
        } else if barsInChord >= profile.barsPerChord || barIndex == 0 {
            if barIndex > 0 {
                if elapsedSeconds >= nextModulationAt, let plan = planModulation() {
                    currentChord = plan.2
                    degree = plan.2.degree ?? 0
                    currentBorrowed = false
                    pivot = true
                } else {
                    degree = nextDegree(from: degree)
                    if Double.random(in: 0..<1, using: &rng) < 0.1, degree != 0 {
                        currentChord = borrowedChord(); currentBorrowed = true
                    } else {
                        let r = Double.random(in: 0..<1, using: &rng)
                        let colour: Int? = r < 0.25 ? 6 : (r < 0.4 ? 8 : nil)  // 7th or 9th, diatonic
                        currentChord = MusicGenerator.diatonic(degree, tonic: tonic, scale: scale, colour: colour)
                        currentBorrowed = false
                    }
                }
            }
            barsInChord = 0
        }
        barsInChord += 1

        // breathing dynamics: slow sine inside a narrow band
        dynPhase += 0.35
        let vr = profile.velocityRange
        let span = Double(vr.upperBound - vr.lowerBound)
        let base = Double(vr.lowerBound) + span * (0.45 + 0.25 * sin(dynPhase))

        var notes = leftHand(beats: beats, base: base)
        notes += rightHand(beats: beats, base: base + span * 0.12)

        let bar = Bar(index: barIndex, tempo: tempo, beats: beats, keyTonic: tonic, scale: scale,
                      chord: currentChord, borrowed: currentBorrowed, pivot: pivot,
                      modulatedHere: modulatedHere, notes: notes)
        barIndex += 1
        elapsedSeconds += Double(beats) * 60 / tempo
        return bar
    }

    private func gauss() -> Double {
        let u1 = Double.random(in: 1e-9..<1, using: &rng), u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    private func vel(_ base: Double) -> Int {
        let v = Int((base + gauss() * 2.5).rounded())
        return min(max(v, profile.velocityRange.lowerBound), profile.velocityRange.upperBound)
    }

    private static func placeAbove(_ pc: Int, _ lower: Int) -> Int {
        var m = lower + 1
        while ((m % 12) + 12) % 12 != pc { m += 1 }
        return m
    }

    // MARK: left hand

    private func leftHand(beats: Int, base: Double) -> [GeneratedNote] {
        let c = currentChord
        let third = (c.rootPC + c.intervals[1]) % 12
        let fifth = (c.rootPC + c.intervals[2]) % 12
        var bass = 36 + ((c.rootPC - 36) % 12 + 12) % 12
        if bass > 47 { bass -= 12 }
        let mid = MusicGenerator.placeAbove(fifth, bass)
        let top = MusicGenerator.placeAbove(third, mid)
        let oct = bass + 12
        let lhBase = base - 5
        var seq: [(Double, Int, Double)] = []   // beat, midi, accent
        switch texture {
        case .alberti:
            let p = [bass, top, mid, top, bass, top, mid, top]
            for i in 0..<min(8, beats * 2) { seq.append((Double(i) * 0.5, p[i], i == 0 ? 1 : 0)) }
        case .rolling:
            let p = [bass, mid, top, oct + (top - oct >= 12 ? 0 : 0), top, mid, bass, mid]
            for i in 0..<min(8, beats * 2) { seq.append((Double(i) * 0.5, p[i], i == 0 ? 1 : 0)) }
        case .gymnopedie:
            seq = [(0, bass, 1), (1, mid, 0), (1, top, 0), (2, mid, -1), (2, top, -1)]
        case .lullaby:
            // slow quarter-note broken chord
            let p = [bass, mid, top, mid]
            for i in 0..<beats { seq.append((Double(i), p[i % 4], i == 0 ? 1 : 0)) }
        }
        return seq.map { (b, m, acc) in
            GeneratedNote(beat: b, durBeats: Double(beats) - b + 0.25, midi: m,
                          velocity: vel(lhBase + acc * 3), hand: .left)
        }
    }

    // MARK: right hand

    private static let patterns4: [[(Double, Double)]] = [
        [(0, 2), (2, 2)], [(0, 4)], [(0, 1.5), (1.5, 0.5), (2, 2)], [(2, 2)],
        [(0, 1), (1, 1), (2, 2)], [(0, 3), (3, 1)], [(0.5, 1.5), (2, 2)], [(1, 1), (2, 2)],
    ]
    private static let patterns3: [[(Double, Double)]] = [
        [(0, 3)], [(0, 1.5), (1.5, 1.5)], [(1, 2)], [(0, 1), (1, 1), (2, 1)], [(2, 1)],
    ]

    private func rightHand(beats: Int, base: Double) -> [GeneratedNote] {
        let wantMelody = Double.random(in: 0..<1, using: &rng) < profile.melodyDensity || restStreak >= 2
        guard wantMelody else { restStreak += 1; return [] }
        restStreak = 0
        let pats = beats == 3 ? MusicGenerator.patterns3 : MusicGenerator.patterns4
        var pi = Int.random(in: 0..<pats.count, using: &rng)
        if pi == lastPattern { pi = (pi + 1) % pats.count }   // no repeated rhythmic hook
        lastPattern = pi

        let scalePCs = Set(scale.intervals.map { (tonic + $0) % 12 })
        let allowed = currentBorrowed ? scalePCs.union(currentChord.pcs) : scalePCs
        let chordPCs = currentChord.pcs
        var out: [GeneratedNote] = []
        for (start, dur) in pats[pi] {
            let strong = start == 0 || start == 2
            let pool = strong ? chordPCs : allowed
            var cands: [(Int, Double)] = []
            for m in 64...81 where pool.contains(m % 12) {
                let d = abs(m - melodyPitch)
                if d > 7 { continue }
                var w = exp(-Double(d) / 2.2) * exp(-Double(abs(m - 72)) / 14)
                if d == 0 { w *= 0.4 }
                cands.append((m, w))
            }
            if cands.isEmpty { // fall back: nearest allowed pitch in range
                if let m = (64...81).filter({ allowed.contains($0 % 12) }).min(by: { abs($0 - melodyPitch) < abs($1 - melodyPitch) }) {
                    cands = [(m, 1)]
                } else { continue }
            }
            let total = cands.reduce(0) { $0 + $1.1 }
            var r = Double.random(in: 0..<total, using: &rng)
            var chosen = cands[0].0
            for (m, w) in cands { if r < w { chosen = m; break }; r -= w }
            melodyPitch = chosen
            out.append(GeneratedNote(beat: start, durBeats: min(dur, Double(beats) - start) + 0.5,
                                     midi: chosen, velocity: vel(base + (strong ? 2 : 0)), hand: .right))
        }
        return out
    }
}
