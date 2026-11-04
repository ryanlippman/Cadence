import Foundation

public enum HarmonicFunction: String, Sendable { case tonic, predominant, dominant }

/// Abstract, key-relative chord description (what a composer would write as a Roman numeral).
public struct ChordSpec: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case diatonic
        /// Taken from the parallel major/minor.
        case borrowed
        /// Secondary dominant (V or V7) of the diatonic degree `target`.
        case appliedDominant(target: Int)
        /// Secondary leading-tone diminished seventh of `target`.
        case appliedDiminished(target: Int)
    }
    public var degree: Int
    public var kind: Kind = .diatonic
    public var seventh = false
    public var added9 = false
    /// Cadential 6/4: tonic triad over the dominant bass, functioning as a dominant.
    public var cadential64 = false

    public init(_ degree: Int, _ kind: Kind = .diatonic, seventh: Bool = false, added9: Bool = false, cadential64: Bool = false) {
        self.degree = mod7(degree); self.kind = kind; self.seventh = seventh; self.added9 = added9
        self.cadential64 = cadential64
    }

    public var function: HarmonicFunction {
        if cadential64 { return .dominant }
        switch kind {
        case .appliedDominant, .appliedDiminished: return .dominant
        case .borrowed: return degree == 6 || degree == 4 ? .dominant : .predominant
        case .diatonic:
            switch degree { case 0, 2: return .tonic; case 5: return .tonic; case 1, 3: return .predominant; default: return .dominant }
        }
    }
}

/// A concrete chord: pitch classes plus metadata for voice leading.
public struct Chord: Sendable, Equatable {
    public var rootPC: Int
    /// Root-position stack in semitones above the root: [0, third, fifth, (seventh), (ninth)].
    public var intervals: [Int]
    public var symbol: String
    public var function: HarmonicFunction
    public var spec: ChordSpec
    /// Required bass pitch class (cadential 6/4, pedal points), if any.
    public var forcedBassPC: Int?

    public var pcs: Set<Int> { Set(intervals.map { mod12(rootPC + $0) }) }
    public var thirdPC: Int { mod12(rootPC + intervals[1]) }
    public var fifthPC: Int { mod12(rootPC + intervals[2]) }
    public var seventhPC: Int? { intervals.count > 3 && intervals[3] >= 9 && intervals[3] <= 11 ? mod12(rootPC + intervals[3]) : nil }
    /// The note that wants to rise by semitone (dominant-function chords only).
    public var leadingTonePC: Int? {
        guard function == .dominant, !spec.cadential64 else { return nil }
        if intervals[1] == 3 && intervals[2] == 6 { return rootPC }        // diminished: root is the leading tone
        if intervals[1] == 4 { return thirdPC }                              // major/dominant: third
        return nil
    }
    /// Pitch classes that are allowed as bass notes in order of preference.
    public var bassOptions: [Int] {
        if let f = forcedBassPC { return [f] }
        var o = [rootPC, thirdPC]
        if let s = seventhPC { o.append(s) }
        return o
    }
}

public enum Harmony {
    static let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]

    static func stack(_ key: Key, _ d: Int, seventh: Bool, ninth: Bool) -> (Int, [Int]) {
        let root = key.pc(d)
        var iv = [0, mod12(key.pc(d + 2) - root), mod12(key.pc(d + 4) - root)]
        if seventh { iv.append(mod12(key.pc(d + 6) - root)) }
        if ninth { iv.append(mod12(key.pc(d + 1) - root) + 12) }
        return (root, iv)
    }

    static func quality(_ iv: [Int]) -> String {
        switch (iv[1], iv[2]) {
        case (4, 7): return "maj"
        case (3, 7): return "min"
        case (3, 6): return "dim"
        case (4, 8): return "aug"
        default: return "maj"
        }
    }

    static func name(degree: Int, root: Int, key: Key, iv: [Int], seventh: Bool, ninth: Bool) -> String {
        let q = quality(iv)
        var n = numerals[degree]
        if q == "min" || q == "dim" { n = n.lowercased() }
        let expected = key.pc(degree)
        let accidental = root == expected ? "" : (mod12(root - expected) == 11 ? "♭" : "♯")
        var s = accidental + n + (q == "dim" ? "°" : "")
        if seventh, iv.count > 3 {
            if iv[3] == 11 { s += "maj7" } else if q == "dim" && iv[3] == 9 { s += "7" } else if q == "dim" { s = s.replacingOccurrences(of: "°", with: "ø") + "7" } else { s += "7" }
        }
        if ninth { s += "add9" }
        return s
    }

    public static func realize(_ spec: ChordSpec, in key: Key) -> Chord {
        switch spec.kind {
        case .diatonic:
            var (root, iv) = stack(key, spec.degree, seventh: spec.seventh, ninth: spec.added9)
            // Minor-mode dominant uses the raised leading tone (harmonic minor), as in common practice.
            if key.mode.isMinorish && spec.degree == 4 {
                iv[1] = 4
                if spec.seventh { iv[3] = 10 }
            }
            if spec.cadential64 {
                let (r, t) = stack(key, 0, seventh: false, ninth: false)
                return Chord(rootPC: r, intervals: t, symbol: "I⁶₄", function: .dominant, spec: spec, forcedBassPC: key.pc(4))
            }
            return Chord(rootPC: root, intervals: iv,
                         symbol: name(degree: spec.degree, root: root, key: key, iv: iv, seventh: spec.seventh, ninth: spec.added9),
                         function: spec.function, spec: spec, forcedBassPC: nil)
        case .borrowed:
            let par = key.parallel
            let (root, iv) = stack(par, spec.degree, seventh: spec.seventh, ninth: spec.added9)
            return Chord(rootPC: root, intervals: iv,
                         symbol: name(degree: spec.degree, root: root, key: key, iv: iv, seventh: spec.seventh, ninth: spec.added9),
                         function: spec.function, spec: spec, forcedBassPC: nil)
        case .appliedDominant(let t):
            let root = mod12(key.pc(t) + 7)
            let iv = spec.seventh ? [0, 4, 7, 10] : [0, 4, 7]
            let sym = t == 0 ? "V\(spec.seventh ? "7" : "")" : "V\(spec.seventh ? "7" : "")/\(targetName(t, key))"
            return Chord(rootPC: root, intervals: iv, symbol: sym,
                         function: .dominant, spec: spec, forcedBassPC: nil)
        case .appliedDiminished(let t):
            let root = mod12(key.pc(t) - 1)
            return Chord(rootPC: root, intervals: [0, 3, 6, 9], symbol: "vii°7/\(targetName(t, key))",
                         function: .dominant, spec: spec, forcedBassPC: nil)
        }
    }

    static func targetName(_ t: Int, _ key: Key) -> String {
        let (_, iv) = stack(key, t, seventh: false, ninth: false)
        var n = numerals[mod7(t)]
        if quality(iv) != "maj" { n = n.lowercased() }
        if key.mode.isMinorish && mod7(t) == 4 { n = "V" }
        return n
    }

    /// Diatonic chords of `from` whose pitch classes all belong to `to` (pivot candidates).
    public static func pivots(from: Key, to: Key) -> [ChordSpec] {
        [1, 3, 5, 2, 0, 4].map { ChordSpec($0) }.filter {
            let c = realize($0, in: from)
            return c.intervals[2] == 7 && c.pcs.isSubset(of: to.pcs)     // consonant (major/minor) pivots only
        }
    }
}
