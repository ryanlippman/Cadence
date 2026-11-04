import Foundation

// MARK: - Listening modes (orthogonal to compositional style)

public enum FocusMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case focus, relax, sleep
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// Default amplitude-modulation rate in Hz.
    public var defaultRate: Double {
        switch self { case .focus: return 16; case .relax: return 9; case .sleep: return 2.5 }
    }
    public var rateRange: ClosedRange<Double> {
        switch self { case .focus: return 12...20; case .relax: return 6...12; case .sleep: return 1...4 }
    }
    public var depthScale: Double {
        switch self { case .focus: return 1.0; case .relax: return 0.9; case .sleep: return 0.7 }
    }
    public var profile: MusicProfile {
        switch self {
        case .focus:
            return MusicProfile(tempoRange: 64...76, velocityRange: 34...66, density: 1.0, reverbWet: 0.20, reverbTime: 2.1)
        case .relax:
            return MusicProfile(tempoRange: 58...68, velocityRange: 30...60, density: 0.85, reverbWet: 0.26, reverbTime: 2.6)
        case .sleep:
            return MusicProfile(tempoRange: 55...60, velocityRange: 24...46, density: 0.6, reverbWet: 0.32, reverbTime: 3.2)
        }
    }
}

public struct MusicProfile: Sendable, Equatable {
    public var tempoRange: ClosedRange<Double>
    public var velocityRange: ClosedRange<Int>
    /// Multiplies figuration/melody density (sleep plays fewer notes).
    public var density: Double
    public var reverbWet: Float
    public var reverbTime: Double
}

// MARK: - Scales & keys

public struct ScaleMode: Sendable, Equatable, Hashable {
    public let name: String
    public let intervals: [Int]
    public static let ionian = ScaleMode(name: "major", intervals: [0, 2, 4, 5, 7, 9, 11])
    public static let aeolian = ScaleMode(name: "minor", intervals: [0, 2, 3, 5, 7, 8, 10])
    public static let dorian = ScaleMode(name: "dorian", intervals: [0, 2, 3, 5, 7, 9, 10])
    public static let lydian = ScaleMode(name: "lydian", intervals: [0, 2, 4, 6, 7, 9, 11])
    public static let mixolydian = ScaleMode(name: "mixolydian", intervals: [0, 2, 4, 5, 7, 9, 10])
    public var isMinorish: Bool { intervals[2] == 3 }
}

public let pitchClassNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

@inline(__always) func mod12(_ x: Int) -> Int { ((x % 12) + 12) % 12 }
@inline(__always) func mod7(_ x: Int) -> Int { ((x % 7) + 7) % 7 }

public struct Key: Sendable, Equatable, Hashable {
    public var tonic: Int
    public var mode: ScaleMode
    public init(tonic: Int, mode: ScaleMode) { self.tonic = mod12(tonic); self.mode = mode }

    /// Pitch class of scale degree `d` (0-based, any integer; wraps by octave).
    public func pc(_ d: Int) -> Int { mod12(tonic + mode.intervals[mod7(d)]) }
    public var pcs: Set<Int> { Set(mode.intervals.map { mod12(tonic + $0) }) }
    public func contains(_ pc: Int) -> Bool { mode.intervals.contains(mod12(pc - tonic)) }
    public func degree(of pc: Int) -> Int? { mode.intervals.firstIndex(of: mod12(pc - tonic)) }
    public var name: String { "\(tonicName) \(mode.name)" }
    /// Conventional spelling: sharps for C♯/F♯/G♯ minor-type keys, flats for D♭/A♭/E♭/B♭ majors.
    public var tonicName: String {
        if mode.isMinorish {
            return ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "G♯", "A", "B♭", "B"][tonic]
        }
        return ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][tonic]
    }

    /// MIDI pitch of diatonic index `i` (octave*7 + degree) with C-based octave anchoring.
    public func midi(diatonic i: Int, baseOctave: Int = 0) -> Int {
        let oct = Int(floor(Double(i) / 7.0))
        return tonic + mode.intervals[mod7(i)] + 12 * (oct + baseOctave)
    }
    /// Diatonic index of a MIDI pitch that belongs to the key (nil if chromatic).
    public func diatonicIndex(of midi: Int) -> Int? {
        let rel = midi - tonic
        let oct = Int(floor(Double(rel) / 12.0))
        guard let d = mode.intervals.firstIndex(of: rel - oct * 12) else { return nil }
        return oct * 7 + d
    }
    /// Nearest diatonic pitch strictly above / below `midi`.
    public func step(from midi: Int, by steps: Int) -> Int {
        var m = midi, s = steps
        while s != 0 {
            m += s > 0 ? 1 : -1
            if contains(m) { s += s > 0 ? -1 : 1 }
        }
        return m
    }

    public var parallel: Key { Key(tonic: tonic, mode: mode.isMinorish ? .ionian : .aeolian) }
    public var relative: Key {
        mode.isMinorish ? Key(tonic: tonic + 3, mode: .ionian) : Key(tonic: tonic + 9, mode: .aeolian)
    }
    public var dominantKey: Key { Key(tonic: tonic + 7, mode: mode.isMinorish ? .aeolian : mode) }
    public var subdominantKey: Key { Key(tonic: tonic + 5, mode: mode.isMinorish ? .aeolian : mode) }
}

// MARK: - Deterministic randomness

public struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Reference-type RNG with musical helpers, shared by the composition subsystems.
public final class Dice {
    var rng: SeededRNG
    public init(seed: UInt64) { rng = SeededRNG(seed: seed) }
    func unit() -> Double { Double.random(in: 0..<1, using: &rng) }
    func chance(_ p: Double) -> Bool { unit() < p }
    func range(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &rng) }
    func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
    func gauss() -> Double {
        let u1 = max(1e-12, unit()), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &rng)] }
    func weighted<T>(_ items: [(T, Double)]) -> T {
        let total = items.reduce(0) { $0 + max(0, $1.1) }
        guard total > 0 else { return items[0].0 }
        var r = unit() * total
        for (v, w) in items where w > 0 { if r < w { return v }; r -= w }
        return items[items.count - 1].0
    }
    func shuffled<T>(_ a: [T]) -> [T] { a.shuffled(using: &rng) }
}
