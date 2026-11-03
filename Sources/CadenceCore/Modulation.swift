import Foundation

public enum ModWaveform: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Raised-cosine: smooth, no harmonics in the gain curve.
    case sine
    /// Slightly flattened peaks/troughs (tanh-shaped sine): a touch more pronounced, still click-free.
    case rounded
    public var id: String { rawValue }
}

/// Sample-accurate amplitude modulation: an LFO drives gain between (1 - depth) and 1.
/// Phase is accumulated in Double and the rate/depth are one-pole smoothed per sample, so changing
/// settings (or switching modes) never produces a phase jump or a click.
public final class ModulationStage {
    private let sampleRate: Double
    private var phase = 0.0
    private var rateS: Double
    private var depthS = 0.0
    private var shapeS = 0.0   // 0 = sine, 1 = rounded; cross-faded so switching never steps
    private let rateCoef: Double
    private let depthCoef: Double

    public init(sampleRate: Double, initialRate: Double = 16) {
        self.sampleRate = sampleRate
        rateS = initialRate
        rateCoef = 1 - exp(-1 / (sampleRate * 0.4))
        depthCoef = 1 - exp(-1 / (sampleRate * 0.05))
    }

    public var currentPhase: Double { phase }

    /// Gain for a single LFO phase in radians: 1 - depth * lfo, lfo in [0, 1].
    @inline(__always)
    static func lfo(_ phase: Double, _ w: ModWaveform) -> Double {
        switch w {
        case .sine: return 0.5 * (1 - cos(phase))
        case .rounded:
            let k = 1.8
            return 0.5 * (1 + tanh(-k * cos(phase)) / tanh(k)) // same orientation as .sine
        }
    }

    /// `depth` is the target depth 0...1; `ramp(i)` supplies a 0...1 ramp-in multiplier per sample.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                        rate: Double, depth: Double, waveform: ModWaveform,
                        ramp: (Int) -> Double) {
        let twoPi = 2 * Double.pi
        for i in 0..<frames {
            rateS += (rate - rateS) * rateCoef
            depthS += (depth * ramp(i) - depthS) * depthCoef
            shapeS += ((waveform == .rounded ? 1.0 : 0.0) - shapeS) * depthCoef * 0.2
            let l = (1 - shapeS) * ModulationStage.lfo(phase, .sine) + shapeS * ModulationStage.lfo(phase, .rounded)
            // makeup keeps the average level constant as depth changes
            let g = Float((1 - depthS * l) / (1 - depthS * 0.5))
            left[i] *= g; right[i] *= g
            phase += twoPi * rateS / sampleRate
            if phase >= twoPi { phase -= twoPi }
        }
    }
}

/// Pink noise (Paul Kellet's refined filter) from a fast xorshift white source.
struct PinkNoise {
    private var s: UInt32
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    init(seed: UInt32) { s = seed | 1 }
    mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        let white = Float(Int32(bitPattern: s)) / Float(Int32.max)
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return out * 0.11
    }
}
