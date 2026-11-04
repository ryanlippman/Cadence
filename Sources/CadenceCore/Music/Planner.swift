import Foundation

public enum Cadence: String, Sendable { case authentic, half, plagal, deceptive, open }

public struct HarmonySlot: Sendable {
    public var start: Double
    public var length: Double
    public var key: Key
    public var chord: Chord
    public var scale: Scale
    public var end: Double { start + length }
    init(start: Double, length: Double, key: Key, chord: Chord) {
        self.start = start; self.length = length; self.key = key; self.chord = chord
        self.scale = Scale.local(for: chord, in: key)
    }
}

public struct PhrasePlan: Sendable {
    public var bars: Int
    public var beatsPerBar: Int
    public var slots: [HarmonySlot]
    public var cadence: Cadence
    /// How many leading slots were copied verbatim from a prefix (parallel period).
    public var prefixKept = 0
    public var totalBeats: Double { Double(bars * beatsPerBar) }
    public var endKey: Key { slots[slots.count - 1].key }
    public func slotIndex(at beat: Double) -> Int {
        var i = 0
        for (k, s) in slots.enumerated() where s.start <= beat + 1e-9 { i = k }
        return i
    }
    public func slot(at beat: Double) -> HarmonySlot { slots[slotIndex(at: beat)] }
}

/// Plans the harmony of a phrase: opening tonic, functional middle (T → PD → D), cadence formula,
/// secondary dominants, borrowed colour, descending-fifth sequences and minimalist ostinati.
final class HarmonicPlanner {
    let dice: Dice
    init(dice: Dice) { self.dice = dice }

    static let ostinati: [[Int]] = [[0, 3], [0, 5, 3, 4], [0, 2, 3, 0], [5, 3, 0, 4], [0, 6, 5, 6], [0, 3, 5, 4], [0, 1, 0, 3]]

    func slotLengths(bars: Int, beats: Int, profile: StyleProfile, cadence: Cadence) -> [Double] {
        let total = Double(bars * beats)
        let B = Double(beats)
        if bars <= 2 && (cadence == .authentic || cadence == .deceptive) && profile.chordsPerBar <= 1 {
            return bars == 1 ? [B / 3, B / 3, B / 3] : [B / 2, B / 2] + [B * Double(bars - 1)]
        }
        let n = max(2, Int((Double(bars) * profile.chordsPerBar).rounded()))
        var lens = [Double](repeating: total / Double(n), count: n)
        // cadential acceleration: penultimate bar carries PD + D in one-chord-per-bar styles
        if profile.chordsPerBar == 1, bars >= 3, cadence == .authentic || cadence == .deceptive, beats == 4 {
            lens = [Double](repeating: Double(beats), count: bars - 2) + [Double(beats) / 2, Double(beats) / 2, Double(beats)]
        }
        return lens
    }

    private func choose(_ f: HarmonicFunction, key: Key, profile: StyleProfile, avoid: ChordSpec?) -> ChordSpec {
        let minor = key.mode.isMinorish
        var opts: [(ChordSpec, Double)]
        switch f {
        case .tonic:
            opts = [(ChordSpec(0), 3), (ChordSpec(5), 2), (ChordSpec(2), profile.style == .impressionist ? 1.2 : 0.5)]
        case .predominant:
            opts = [(ChordSpec(3), 3), (ChordSpec(1, seventh: minor), 2.5), (ChordSpec(5), 0.6)]
            if profile.borrowedProb > 0 {
                let b = minor ? [ChordSpec(3, .borrowed)] : [ChordSpec(3, .borrowed), ChordSpec(5, .borrowed)]
                for s in b { opts.append((s, 4 * profile.borrowedProb)) }
            }
        case .dominant:
            opts = [(ChordSpec(4), 4), (ChordSpec(6, seventh: true), profile.style == .baroque || profile.style == .romantic ? 0.8 : 0)]
            if profile.style == .impressionist && !minor { opts.append((ChordSpec(6, .borrowed), 1.5)) } // ♭VII
        }
        if minor { opts = opts.filter { !($0.0.kind == .diatonic && $0.0.degree == 6 && !$0.0.seventh) } }
        if let a = avoid { opts = opts.map { ($0.0.degree == a.degree && $0.0.kind == a.kind ? ($0.0, $0.1 * 0.03) : $0) } }
        return dice.weighted(opts)
    }

    private func nextFunction(_ f: HarmonicFunction) -> HarmonicFunction {
        switch f {
        case .tonic: return dice.weighted([(.tonic, 0.25), (.predominant, 0.55), (.dominant, 0.2)])
        case .predominant: return dice.weighted([(.predominant, 0.3), (.dominant, 0.62), (.tonic, 0.08)])
        case .dominant: return dice.weighted([(.tonic, 0.8), (.dominant, 0.15), (.predominant, 0.05)])
        }
    }

    private func colour(_ s: ChordSpec, key: Key, profile: StyleProfile, isFinal: Bool) -> ChordSpec {
        var c = s
        guard c.kind == .diatonic || c.kind == .borrowed, !c.cadential64 else { return c }
        if isFinal {
            if profile.style == .impressionist || profile.style == .minimalist { c.seventh = dice.chance(0.3); c.added9 = !c.seventh && dice.chance(0.3) }
            return c
        }
        if !c.seventh { c.seventh = dice.chance(profile.seventhProb * (c.degree == 4 ? 1.4 : 1)) }
        if !c.seventh, c.kind == .diatonic { c.added9 = dice.chance(profile.added9Prob) }
        return c
    }

    /// Plans a phrase in one key.
    func plan(key: Key, profile: StyleProfile, bars: Int, beats: Int, cadence: Cadence,
              prefix: [ChordSpec] = [], ostinato: [Int]? = nil) -> PhrasePlan {
        let lens = slotLengths(bars: bars, beats: beats, profile: profile, cadence: cadence)
        let n = lens.count
        var specs = [ChordSpec?](repeating: nil, count: n)
        var locked = [Bool](repeating: false, count: n)     // prefix: must stay identical
        var isTail = [Bool](repeating: false, count: n)
        let minor = key.mode.isMinorish

        // Cadence formula
        var tail: [ChordSpec] = []
        switch cadence {
        case .authentic:
            let v = ChordSpec(4, seventh: dice.chance(0.6))
            if profile.cadential64Prob > 0, n >= 4, dice.chance(profile.cadential64Prob) {
                tail = [choose(.predominant, key: key, profile: profile, avoid: nil), ChordSpec(0, cadential64: true), v, ChordSpec(0)]
            } else {
                tail = [choose(.predominant, key: key, profile: profile, avoid: nil), v, ChordSpec(0)]
            }
        case .half: tail = [choose(.predominant, key: key, profile: profile, avoid: nil), ChordSpec(4)]
        case .plagal: tail = [dice.chance(0.3) && !minor ? ChordSpec(3, .borrowed) : ChordSpec(3, added9: profile.style == .impressionist), ChordSpec(0)]
        case .deceptive: tail = [choose(.predominant, key: key, profile: profile, avoid: nil), ChordSpec(4, seventh: true), ChordSpec(5)]
        case .open: tail = []
        }
        if n - tail.count < 1 { tail = Array(tail.suffix(n - 1)) }
        for (i, s) in tail.enumerated() { specs[n - tail.count + i] = s; isTail[n - tail.count + i] = true }

        // Prefix (parallel period: consequent repeats the antecedent's opening harmony)
        let kept = prefix.prefix(n - tail.count)
        for (i, s) in kept.enumerated() { specs[i] = s; locked[i] = true }

        if let ost = ostinato {
            for i in 0..<n where specs[i] == nil { specs[i] = ChordSpec(ost[i % ost.count], seventh: dice.chance(profile.seventhProb * 0.5)) }
        } else {
            if specs[0] == nil { specs[0] = ChordSpec(0) }
            let freeIdx = (0..<n).filter { specs[$0] == nil }
            // descending-fifth sequence leading into the cadence
            if freeIdx.count >= 3, freeIdx.last! + 1 < n, dice.chance(profile.sequenceProb), let anchor = specs[freeIdx.last! + 1] {
                var d = anchor.degree
                for i in freeIdx.reversed() {
                    d = mod7(d + 4)
                    if minor && d == 1 { specs[i] = ChordSpec(1, seventh: true) }
                    else { specs[i] = ChordSpec(d, seventh: profile.style == .baroque || dice.chance(0.4)) }
                }
            } else {
                var f = specs[(freeIdx.first ?? 1) - 1]?.function ?? .tonic
                for i in freeIdx {
                    f = nextFunction(f)
                    specs[i] = choose(f, key: key, profile: profile, avoid: specs[i - 1] ?? nil)
                }
            }
        }

        // Secondary dominants tonicising ii, IV, V, vi
        if profile.secondaryDominantProb > 0 {
            for i in stride(from: n - 1, through: 2, by: -1) {
                guard let t = specs[i], t.kind == .diatonic, !t.cadential64, [1, 3, 4, 5].contains(t.degree), !locked[i - 1],
                      let prev = specs[i - 1], !prev.cadential64, prev.kind == .diatonic,
                      !isTail[i - 1] || prev.function == .predominant else { continue }
                let targetChord = Harmony.realize(ChordSpec(t.degree), in: key)
                guard targetChord.intervals[1] != 3 || targetChord.intervals[2] == 7 else { continue }  // not diminished
                guard targetChord.intervals[2] == 7 else { continue }
                if dice.chance(profile.secondaryDominantProb) {
                    specs[i - 1] = profile.style == .romantic && dice.chance(0.3)
                        ? ChordSpec(t.degree, .appliedDiminished(target: t.degree))
                        : ChordSpec(t.degree, .appliedDominant(target: t.degree), seventh: dice.chance(0.75))
                    isTail[i - 1] = true
                }
            }
        }

        var slots: [HarmonySlot] = []
        var start = 0.0
        for i in 0..<n {
            var s = specs[i] ?? ChordSpec(0)
            if !locked[i] { s = colour(s, key: key, profile: profile, isFinal: i == n - 1) }
            slots.append(HarmonySlot(start: start, length: lens[i], key: key, chord: Harmony.realize(s, in: key)))
            start += lens[i]
        }
        var plan = PhrasePlan(bars: bars, beatsPerBar: beats, slots: slots, cadence: cadence)
        plan.prefixKept = kept.count
        return plan
    }

    /// A short modulating phrase: pivot chord(s) in the old key, then pre-dominant and V7 of the new key.
    func bridge(from: Key, to: Key, profile: StyleProfile, bars: Int, beats: Int) -> PhrasePlan {
        let total = Double(bars * beats)
        let n = max(2, min(4, Int((Double(bars) * max(1, profile.chordsPerBar)).rounded())))
        let len = total / Double(n)
        var pivots = Harmony.pivots(from: from, to: to)
        if pivots.isEmpty { pivots = [ChordSpec(0)] }
        var slots: [HarmonySlot] = []
        let pivot = dice.pick(pivots)
        slots.append(HarmonySlot(start: 0, length: len, key: from, chord: Harmony.realize(pivot, in: from)))
        if n >= 3 {
            // the pivot re-read in the new key leads to its pre-dominant
            let pd = dice.chance(0.5) ? ChordSpec(1, seventh: true) : ChordSpec(3)
            slots.append(HarmonySlot(start: len, length: len, key: to, chord: Harmony.realize(pd, in: to)))
        }
        if n >= 4 {
            slots.append(HarmonySlot(start: 2 * len, length: len, key: to, chord: Harmony.realize(ChordSpec(0, cadential64: true), in: to)))
        }
        slots.append(HarmonySlot(start: Double(slots.count) * len, length: total - Double(slots.count) * len, key: to,
                                 chord: Harmony.realize(ChordSpec(0, .appliedDominant(target: 0), seventh: true), in: to)))
        return PhrasePlan(bars: bars, beatsPerBar: beats, slots: slots, cadence: .half)
    }
}
