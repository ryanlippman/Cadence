import Foundation

/// Objective checks on generated music (used by tests and `cadence-analyze`).
public struct CompositionReport: Sendable {
    public var bars = 0
    public var minutes = 0.0
    public var notes = 0
    public var notesPerBar: [VoiceRole: Double] = [:]
    /// Notes outside key ∪ sounding chord ∪ local scale: should be zero.
    public var outOfKey = 0
    /// Notes not in the key (legitimate chromatic chord tones of applied/borrowed chords).
    public var chromatic = 0
    public var melodyNotes = 0
    public var melodyNonChordTones = 0
    /// Melody non-chord tones not followed by a step (should be zero).
    public var unresolvedDissonances = 0
    public var outerParallels = 0
    public var chordChanges = 0
    public var maxMelodicLeap = 0
    public var melodicLeapsOverSixth = 0
    public var meanAbsMelodicInterval = 0.0
    public var staticRepeats = 0
    public var cadences: [String: Int] = [:]
    public var keyChanges = 0
    public var distinctChordSymbols = 0
    public var tempoRange: ClosedRange<Double> = 0...0
    public var velocityRange: ClosedRange<Int> = 0...0
    public var uniqueFourBarWindows = 0.0
    public var styles: Set<CompositionStyle> = []
}

public enum CompositionAnalysis {
    public static func analyze(_ bars: [Bar]) -> CompositionReport {
        var r = CompositionReport()
        r.bars = bars.count
        var seconds = 0.0
        var counts: [VoiceRole: Int] = [:]
        var tmin = Double.infinity, tmax = -Double.infinity, vmin = 127, vmax = 0
        var symbols = Set<String>()
        // absolute melody list and chord-change list
        struct M { var t: Double; var midi: Int; var nct: Bool }
        var melody: [M] = []
        var changes: [(t: Double, bass: Int?, mel: Int?)] = []
        var beatOffset = 0.0
        var lastKey: Key? = nil
        var windows: [[Int]] = []
        var cur: [Int] = []
        for b in bars {
            r.styles.insert(b.style)
            seconds += Double(b.beats) * 60 / b.tempo
            tmin = min(tmin, b.tempo); tmax = max(tmax, b.tempo)
            if let lk = lastKey, lk != b.key { r.keyChanges += 1 }
            lastKey = b.key
            if let c = b.cadence { r.cadences[c.rawValue, default: 0] += 1 }
            for c in b.chords { symbols.insert(c.chord.symbol) }
            for n in b.notes {
                r.notes += 1
                counts[n.voice, default: 0] += 1
                vmin = min(vmin, n.velocity); vmax = max(vmax, n.velocity)
                let bc = b.chord(at: n.beat)
                let pc = mod12(n.midi)
                let inChord = bc.chord.pcs.contains(pc)
                if !inChord && !bc.scale.pcs.contains(pc) && !bc.key.contains(pc) { r.outOfKey += 1 }
                if !bc.key.contains(pc) { r.chromatic += 1 }
                if n.voice == .melody {
                    melody.append(M(t: beatOffset + n.beat, midi: n.midi, nct: !inChord))
                    cur.append(n.midi)
                }
            }
            for c in b.chords where c.beat >= 0 {
                let t = beatOffset + c.beat
                let bass = b.notes.filter { $0.voice == .bass && abs($0.beat - c.beat) < 0.15 }.map { $0.midi }.min()
                changes.append((t, bass, nil))
            }
            if (b.index + 1) % 4 == 0 { windows.append(cur); cur = [] }
            beatOffset += Double(b.beats)
        }
        r.minutes = seconds / 60
        for (k, v) in counts { r.notesPerBar[k] = Double(v) / Double(max(1, bars.count)) }
        r.tempoRange = tmin...max(tmin, tmax)
        r.velocityRange = vmin...max(vmin, vmax)
        r.distinctChordSymbols = symbols.count
        r.melodyNotes = melody.count
        var sumInt = 0
        var run = 0
        for i in melody.indices {
            if melody[i].nct {
                r.melodyNonChordTones += 1
                // (the final note of an excerpt resolves beyond it, so it isn't counted)
                if i + 1 < melody.count && abs(melody[i + 1].midi - melody[i].midi) > 2 { r.unresolvedDissonances += 1 }
            }
            if i > 0 {
                let d = abs(melody[i].midi - melody[i - 1].midi)
                sumInt += d
                r.maxMelodicLeap = max(r.maxMelodicLeap, d)
                if d > 9 { r.melodicLeapsOverSixth += 1 }
                run = d == 0 ? run + 1 : 0
                if run == 2 { r.staticRepeats += 1 }
            }
        }
        r.meanAbsMelodicInterval = melody.count > 1 ? Double(sumInt) / Double(melody.count - 1) : 0
        // outer-voice parallels at chord changes
        var mi = 0
        var prev: (Int, Int)? = nil
        for c in changes {
            while mi + 1 < melody.count && melody[mi + 1].t <= c.t + 0.3 { mi += 1 }
            guard let bass = c.bass, !melody.isEmpty else { prev = nil; continue }
            let mel = melody[mi].midi
            if let (pm, pb) = prev, pm != mel, pb != bass {
                let a = mod12(pm - pb), b2 = mod12(mel - bass)
                if a == b2 && (a == 0 || a == 7) && (mel - pm).signum() == (bass - pb).signum() { r.outerParallels += 1 }
            }
            r.chordChanges += 1
            prev = (mel, bass)
        }
        let nonEmpty = windows.filter { !$0.isEmpty }
        r.uniqueFourBarWindows = nonEmpty.isEmpty ? 1 : Double(Set(nonEmpty).count) / Double(nonEmpty.count)
        return r
    }
}
