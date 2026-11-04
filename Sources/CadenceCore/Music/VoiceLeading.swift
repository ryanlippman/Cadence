import Foundation

/// A pitch-class collection with diatonic stepping (used for non-chord tones over chromatic chords).
public struct Scale: Sendable, Equatable {
    public let pcs: Set<Int>
    public init(_ pcs: Set<Int>) { self.pcs = pcs }
    public func contains(_ midi: Int) -> Bool { pcs.contains(mod12(midi)) }
    public func step(from midi: Int, by steps: Int) -> Int {
        var m = midi, s = steps, guardCount = 0
        while s != 0 && guardCount < 48 {
            m += s > 0 ? 1 : -1
            if contains(m) { s += s > 0 ? -1 : 1 }
            guardCount += 1
        }
        return m
    }
    /// Signed number of scale steps from a to b (both should be scale members).
    public func steps(from a: Int, to b: Int) -> Int {
        if a == b { return 0 }
        let dir = b > a ? 1 : -1
        var n = 0, m = a
        while m != b { m += dir; if contains(m) { n += dir } }
        return n
    }

    /// The scale in force over `chord`: the key, with each chromatic chord tone replacing the
    /// diatonic note it alters (raised for applied dominants, lowered for borrowed chords).
    public static func local(for chord: Chord, in key: Key) -> Scale {
        var pcs = key.pcs
        let raised: Bool
        switch chord.spec.kind {
        case .borrowed: raised = false
        default: raised = true
        }
        func maxGap(_ set: Set<Int>) -> Int {
            let v = set.sorted()
            guard v.count > 1 else { return 12 }
            var g = v[0] + 12 - v[v.count - 1]
            for i in 1..<v.count { g = max(g, v[i] - v[i - 1]) }
            return g
        }
        for pc in chord.pcs.sorted() where !pcs.contains(pc) {
            // replace the neighbouring diatonic note it alters; prefer the choice that avoids
            // augmented seconds, then raised (applied) / lowered (borrowed) as tie-break
            var options: [Int] = []
            for n in [mod12(pc - 1), mod12(pc + 1)] where pcs.contains(n) && !chord.pcs.contains(n) { options.append(n) }
            if options.isEmpty { pcs.insert(pc); continue }
            let ranked = options.map { n -> (Int, Int, Int) in
                var t = pcs; t.remove(n); t.insert(pc)
                let pref = (n == mod12(pc - 1)) == raised ? 0 : 1
                return (n, maxGap(t), pref)
            }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            pcs.remove(ranked[0].0)
            pcs.insert(pc)
        }
        return Scale(pcs)
    }
}

public struct Voicing: Sendable, Equatable {
    public var bass: Int
    /// Three upper voices, ascending (tenor, alto, top of the accompaniment).
    public var upper: [Int]
    public var all: [Int] { [bass] + upper }
}

/// Chooses bass notes (inversions) and inner voices by minimising a classical voice-leading cost:
/// small motion, common tones held, complete chords, good doubling, resolved sevenths and leading
/// tones, and no parallel fifths or octaves.
final class VoiceLeader {
    var bassRange = 33...52
    var upperRanges = [47...64, 52...68, 56...72]

    func voice(_ chord: Chord, previous: Voicing?, previousChord: Chord?, rootPosition: Bool, dice: Dice) -> Voicing {
        // Bass candidates
        var bassCands: [(Int, Double)] = []
        let options = rootPosition && chord.forcedBassPC == nil ? [chord.rootPC] : chord.bassOptions
        for (rank, pc) in options.enumerated() {
            let pen = chord.forcedBassPC != nil ? 0 : [0.0, 1.4, 2.4][min(rank, 2)]
            for m in bassRange where mod12(m) == pc {
                var c = pen + Double(abs(m - 42)) * 0.04
                if let p = previous {
                    let d = abs(m - p.bass)
                    let table: [Double] = [0.9, 0.15, 0.15, 0.55, 0.55, 0.35, 3.5, 0.35, 1.4, 1.4, 2.0, 3.0, 1.1]
                    c += d <= 12 ? table[d] : 4 + Double(d - 12) * 0.3
                }
                bassCands.append((m, c))
            }
        }
        bassCands.sort { $0.1 < $1.1 }
        let pcs = chord.pcs.sorted()
        var cands: [[Int]] = upperRanges.map { r in r.filter { pcs.contains(mod12($0)) } }
        if cands.contains(where: { $0.isEmpty }) { cands = upperRanges.map { Array($0) } }

        var best: Voicing? = nil
        var bestCost = Double.infinity
        let third = chord.thirdPC, seventh = chord.seventhPC, lt = chord.leadingTonePC
        for (b, bc) in bassCands.prefix(4) {
            for x in cands[0] where x > b + 2 {
                for y in cands[1] where y > x && y - x <= 12 {
                    for z in cands[2] where z > y && z - y <= 12 {
                        var cost = bc
                        let v = [b, x, y, z]
                        let vp = v.map(mod12)
                        let set = Set(vp)
                        if !set.contains(third) { cost += 7 }
                        if let s = seventh, !set.contains(s) { cost += 4 }
                        if !set.contains(chord.rootPC) && chord.forcedBassPC == nil { cost += 3 }
                        if !set.contains(chord.fifthPC) { cost += 0.5 }
                        if chord.intervals.count == 4 && chord.intervals[3] == 9 && set.count < 4 { cost += 5 } // dim7 complete
                        var counts = [Int: Int]()
                        for p in vp { counts[p, default: 0] += 1 }
                        for (p, n) in counts.sorted(by: { $0.key < $1.key }) where n > 1 {
                            if p == lt { cost += 6 }
                            else if p == seventh { cost += 5 }
                            else if p == third { cost += chord.intervals[1] == 3 ? 0.4 : 1.2 }
                            else if p == chord.fifthPC { cost += 0.3 }
                            if n > 2 { cost += 2 }
                        }
                        if x - b > 24 { cost += 1.5 }
                        if let p = previous {
                            let pv = p.all
                            for i in 1..<4 {
                                let d = abs(v[i] - pv[i])
                                cost += Double(d) * 0.32
                                if d > 4 { cost += 1.0 }
                                if d == 0 { cost -= 0.25 }
                            }
                            // parallel perfect intervals between any pair of voices
                            for i in 0..<4 { for j in (i + 1)..<4 {
                                let a = mod12(pv[j] - pv[i]), c2 = mod12(v[j] - v[i])
                                if a == c2 && (a == 0 || a == 7) && v[i] != pv[i] && v[j] != pv[j] { cost += 9 }
                            }}
                            if let pc = previousChord {
                                for i in 1..<4 {
                                    if let s = pc.seventhPC, mod12(pv[i]) == s {
                                        let d = pv[i] - v[i]
                                        cost += (d == 1 || d == 2) ? -1.5 : 1.0
                                    }
                                    if let l = pc.leadingTonePC, mod12(pv[i]) == l, chord.pcs.contains(mod12(l + 1)) {
                                        cost += v[i] == pv[i] + 1 ? -1.5 : 0.8
                                    }
                                }
                            }
                        } else {
                            let centers = [55, 60, 65]
                            for i in 0..<3 { cost += Double(abs(v[i + 1] - centers[i])) * 0.1 }
                        }
                        cost += dice.unit() * 0.15
                        if cost < bestCost { bestCost = cost; best = Voicing(bass: b, upper: [x, y, z]) }
                    }
                }
            }
        }
        return best ?? Voicing(bass: bassCands.first?.0 ?? 40, upper: [55, 60, 64])
    }
}
