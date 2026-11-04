import Foundation

/// Broad compositional traditions. Each one is a set of tendencies, not an imitation of any piece.
public enum CompositionStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case minimalist, impressionist, romantic, baroque
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var blurb: String {
        switch self {
        case .minimalist: return "Spacious, slowly turning patterns"
        case .impressionist: return "Colourful, pedalled, atmospheric"
        case .romantic: return "Lyrical melody over flowing arpeggios"
        case .baroque: return "Gentle counterpoint and sequences"
        }
    }
    public var profile: StyleProfile { StyleProfile.for(self) }
}

public enum Figuration: Sendable, Equatable {
    case gymnopedie      // bass on 1, soft chord on 2 (3/4)
    case ostinato        // rotating 3-note cell in eighths over a held bass
    case rolled          // rolled wide chord, gentle echo halfway through
    case nocturne        // sweeping triplet arpeggio over a held bass
    case alberti         // bass-top-middle-top
    case prelude         // held bass+tenor, broken upper voices (prelude-like)
    case walking         // baroque: stepwise quarter-note bass + independent inner voice
}

public struct StyleProfile: Sendable {
    public var style: CompositionStyle
    public var beatsPerBar: [Int]               // allowed meters
    public var phraseBars: Int
    public var chordsPerBar: Double             // harmonic rhythm
    public var figurations: [Figuration]
    public var modes: [ScaleMode]
    public var melodyRange: ClosedRange<Int>
    public var climaxSpan: ClosedRange<Int>     // semitones above the phrase's starting register
    public var secondaryDominantProb: Double
    public var borrowedProb: Double
    public var seventhProb: Double
    public var added9Prob: Double
    public var sequenceProb: Double
    public var suspensionProb: Double
    public var appoggiaturaProb: Double
    public var ornamentProb: Double
    public var counterVoiceProb: Double         // probability a phrase carries an independent inner voice
    public var cadential64Prob: Double
    public var plagalProb: Double
    public var deceptiveProb: Double
    public var pedal: PedalStyle
    public var ritardando: Double               // tempo factor in phrase-final bars
    public var tempoBias: Double                // 0 = low end of mode tempo range, 1 = high end
    public var rhythms4: [[(Double, Double)]]   // melody rhythm vocabulary (onset, duration) per 4/4 bar
    public var rhythms3: [[(Double, Double)]]
    public var cadenceRhythms4: [[(Double, Double)]]
    public var cadenceRhythms3: [[(Double, Double)]]

    public enum PedalStyle: Sendable { case none, perChord, long }

    static func `for`(_ s: CompositionStyle) -> StyleProfile {
        switch s {
        case .minimalist:
            return StyleProfile(
                style: s, beatsPerBar: [3, 4], phraseBars: 8, chordsPerBar: 0.5,
                figurations: [.gymnopedie, .ostinato], modes: [.ionian, .dorian, .aeolian, .lydian],
                melodyRange: 64...81, climaxSpan: 3...6,
                secondaryDominantProb: 0, borrowedProb: 0.05, seventhProb: 0.45, added9Prob: 0.2,
                sequenceProb: 0, suspensionProb: 0.25, appoggiaturaProb: 0.0, ornamentProb: 0,
                counterVoiceProb: 0.0, cadential64Prob: 0, plagalProb: 0.6, deceptiveProb: 0,
                pedal: .long, ritardando: 0.97, tempoBias: 0.2,
                rhythms4: [[(0, 4)], [(0, 3), (3, 1)], [(0, 2), (2, 2)], [(1, 3)], [(0, 1.5), (1.5, 2.5)], [(2, 2)]],
                rhythms3: [[(0, 3)], [(0, 2), (2, 1)], [(1, 2)], [(0, 1), (1, 2)], [(1, 1), (2, 1)]],
                cadenceRhythms4: [[(0, 4)], [(0, 2), (2, 2)]],
                cadenceRhythms3: [[(0, 3)], [(1, 2)]])
        case .impressionist:
            return StyleProfile(
                style: s, beatsPerBar: [4], phraseBars: 4, chordsPerBar: 1,
                figurations: [.rolled, .nocturne], modes: [.lydian, .ionian, .mixolydian, .dorian],
                melodyRange: 65...84, climaxSpan: 4...8,
                secondaryDominantProb: 0.05, borrowedProb: 0.25, seventhProb: 0.75, added9Prob: 0.35,
                sequenceProb: 0.2, suspensionProb: 0.25, appoggiaturaProb: 0.15, ornamentProb: 0.05,
                counterVoiceProb: 0.15, cadential64Prob: 0, plagalProb: 0.55, deceptiveProb: 0.15,
                pedal: .long, ritardando: 0.95, tempoBias: 0.35,
                rhythms4: [[(0, 1.5), (1.5, 0.5), (2, 2)], [(0, 3), (3, 1)], [(0.5, 1.5), (2, 1), (3, 1)],
                           [(0, 2), (2, 1), (3, 1)], [(0, 4)], [(1, 1), (2, 2)]],
                rhythms3: [[(0, 3)], [(0, 1.5), (1.5, 1.5)]],
                cadenceRhythms4: [[(0, 4)], [(0, 1), (1, 3)], [(0, 2), (2, 2)]],
                cadenceRhythms3: [[(0, 3)]])
        case .romantic:
            return StyleProfile(
                style: s, beatsPerBar: [4], phraseBars: 4, chordsPerBar: 1,
                figurations: [.nocturne, .alberti], modes: [.ionian, .aeolian, .ionian],
                melodyRange: 65...84, climaxSpan: 5...9,
                secondaryDominantProb: 0.3, borrowedProb: 0.15, seventhProb: 0.35, added9Prob: 0.05,
                sequenceProb: 0.15, suspensionProb: 0.35, appoggiaturaProb: 0.25, ornamentProb: 0.12,
                counterVoiceProb: 0.35, cadential64Prob: 0.5, plagalProb: 0.1, deceptiveProb: 0.15,
                pedal: .perChord, ritardando: 0.94, tempoBias: 0.45,
                rhythms4: [[(0, 1.5), (1.5, 0.5), (2, 1), (3, 1)], [(0, 2), (2, 1), (3, 1)], [(0, 3), (3, 0.5), (3.5, 0.5)],
                           [(0, 1), (1, 1), (2, 2)], [(0, 2.5), (2.5, 0.5), (3, 1)], [(0, 2), (2, 2)]],
                rhythms3: [[(0, 2), (2, 1)], [(0, 1.5), (1.5, 0.5), (2, 1)]],
                cadenceRhythms4: [[(0, 2), (2, 2)], [(0, 1), (1, 3)], [(0, 4)]],
                cadenceRhythms3: [[(0, 3)], [(0, 2), (2, 1)]])
        case .baroque:
            return StyleProfile(
                style: s, beatsPerBar: [4], phraseBars: 4, chordsPerBar: 2,
                figurations: [.prelude, .walking], modes: [.ionian, .aeolian, .dorian],
                melodyRange: 64...81, climaxSpan: 4...7,
                secondaryDominantProb: 0.3, borrowedProb: 0.0, seventhProb: 0.3, added9Prob: 0,
                sequenceProb: 0.4, suspensionProb: 0.45, appoggiaturaProb: 0.05, ornamentProb: 0.04,
                counterVoiceProb: 1.0, cadential64Prob: 0.25, plagalProb: 0.05, deceptiveProb: 0.15,
                pedal: .none, ritardando: 0.97, tempoBias: 0.55,
                rhythms4: [[(0, 1), (1, 0.5), (1.5, 0.5), (2, 1), (3, 1)], [(0, 1), (1, 1), (2, 1), (3, 1)],
                           [(0, 0.5), (0.5, 0.5), (1, 1), (2, 0.5), (2.5, 0.5), (3, 1)], [(0, 1.5), (1.5, 0.5), (2, 1), (3, 1)],
                           [(0, 2), (2, 1), (3, 1)]],
                rhythms3: [[(0, 1), (1, 1), (2, 1)]],
                cadenceRhythms4: [[(0, 2), (2, 2)], [(0, 1), (1, 1), (2, 2)], [(0, 4)]],
                cadenceRhythms3: [[(0, 2), (2, 1)]])
        }
    }
}
