import Foundation

public enum FocusMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case focus, relax, sleep
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// Default amplitude-modulation rate in Hz.
    public var defaultRate: Double {
        switch self { case .focus: return 16; case .relax: return 9; case .sleep: return 2.5 }
    }
    /// Allowed range for user adjustment of the modulation rate.
    public var rateRange: ClosedRange<Double> {
        switch self { case .focus: return 12...20; case .relax: return 6...12; case .sleep: return 1...4 }
    }
    /// How strongly this mode scales the modulation depth.
    public var depthScale: Double {
        switch self { case .focus: return 1.0; case .relax: return 0.9; case .sleep: return 0.7 }
    }
    public var profile: MusicProfile {
        switch self {
        case .focus:
            return MusicProfile(tempoRange: 64...78, velocityRange: 38...66, melodyDensity: 0.55,
                                modulationSeconds: 300, barsPerChord: 1, reverbWet: 0.16)
        case .relax:
            return MusicProfile(tempoRange: 58...70, velocityRange: 34...60, melodyDensity: 0.5,
                                modulationSeconds: 330, barsPerChord: 1, reverbWet: 0.2)
        case .sleep:
            return MusicProfile(tempoRange: 55...60, velocityRange: 26...46, melodyDensity: 0.35,
                                modulationSeconds: 420, barsPerChord: 2, reverbWet: 0.24)
        }
    }
}

public struct MusicProfile: Sendable {
    public var tempoRange: ClosedRange<Double>
    public var velocityRange: ClosedRange<Int>
    public var melodyDensity: Double
    public var modulationSeconds: Double
    public var barsPerChord: Int
    public var reverbWet: Float
}

public struct ScaleMode: Sendable, Equatable {
    public let name: String
    public let intervals: [Int]
    public static let ionian = ScaleMode(name: "major", intervals: [0, 2, 4, 5, 7, 9, 11])
    public static let aeolian = ScaleMode(name: "minor", intervals: [0, 2, 3, 5, 7, 8, 10])
    public static let dorian = ScaleMode(name: "dorian", intervals: [0, 2, 3, 5, 7, 9, 10])
    public static let lydian = ScaleMode(name: "lydian", intervals: [0, 2, 4, 6, 7, 9, 11])
    public static let mixolydian = ScaleMode(name: "mixolydian", intervals: [0, 2, 4, 5, 7, 9, 10])
    public var isMinorish: Bool { intervals[2] == 3 }
}

public let pitchClassNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

public struct Chord: Sendable, Equatable {
    public var rootPC: Int
    /// Semitone offsets from the root (triad first; optional colour tone appended).
    public var intervals: [Int]
    public var degree: Int?          // diatonic degree 0...6, nil if borrowed
    public var pcs: Set<Int> { Set(intervals.map { (rootPC + $0) % 12 }) }
}

public struct GeneratedNote: Sendable, Equatable {
    public enum Hand: Sendable { case left, right }
    public var beat: Double
    public var durBeats: Double
    public var midi: Int
    public var velocity: Int
    public var hand: Hand
}

public struct Bar: Sendable {
    public var index: Int
    public var tempo: Double
    public var beats: Int
    public var keyTonic: Int
    public var scale: ScaleMode
    public var chord: Chord
    public var borrowed: Bool
    public var pivot: Bool
    public var modulatedHere: Bool
    public var notes: [GeneratedNote]
    public var scalePCs: Set<Int> { Set(scale.intervals.map { (keyTonic + $0) % 12 }) }
    /// Pitch classes any note in this bar may use.
    public var allowedPCs: Set<Int> { borrowed ? scalePCs.union(chord.pcs) : scalePCs }
    public var keyName: String { "\(pitchClassNames[keyTonic]) \(scale.name)" }
}

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
