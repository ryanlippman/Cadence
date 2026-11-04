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
    // Large rate changes (e.g. Focus → Sleep) dip the modulation out, switch rate, then bring it
    // back, instead of audibly sweeping through every rate in between.
    private var rateTarget: Double
    private var pendingRate: Double?
    private var transition = 1.0
    private var recovering = false
    private let dipStep: Double
    private let recoverStep: Double
    public var transitionLevel: Double { transition }
    // pulse-lock: phase corrections are spread over many samples (a tiny, smooth frequency deviation)
    private var nudgeLeft = 0
    private var nudgePerSample = 0.0

    /// Shift the LFO phase by `radians`, spread evenly over `seconds`.
    public func nudgePhase(by radians: Double, over seconds: Double) {
        nudgeLeft = max(1, Int(seconds * sampleRate))
        nudgePerSample = radians / Double(nudgeLeft)
    }

    public init(sampleRate: Double, initialRate: Double = 16) {
        self.sampleRate = sampleRate
        rateS = initialRate
        rateTarget = initialRate
        rateCoef = 1 - exp(-1 / (sampleRate * 0.6))
        depthCoef = 1 - exp(-1 / (sampleRate * 0.05))
        dipStep = 1 / (sampleRate * 1.2)
        recoverStep = 1 / (sampleRate * 3.0)
    }

    public var currentPhase: Double { phase }
    public var currentRate: Double { rateS }

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
                        rate: Double, depth: Double, waveform: ModWaveform, immediateRate: Bool = false,
                        ramp: (Int) -> Double) {
        let twoPi = 2 * Double.pi
        if abs(rate - rateTarget) / max(rateTarget, 0.1) > 0.2 {
            pendingRate = rate; recovering = false
        }
        rateTarget = rate
        for i in 0..<frames {
            if let p = pendingRate {
                transition -= dipStep
                if transition <= 0 { transition = 0; rateS = p; pendingRate = nil; recovering = true }
            } else if immediateRate {
                rateS = rateTarget
                if recovering { transition += recoverStep; if transition >= 1 { transition = 1; recovering = false } }
            } else {
                rateS += (rateTarget - rateS) * rateCoef
                if recovering { transition += recoverStep; if transition >= 1 { transition = 1; recovering = false } }
            }
            let tg = transition * transition * (3 - 2 * transition)
            depthS += (depth * ramp(i) * tg - depthS) * depthCoef
            shapeS += ((waveform == .rounded ? 1.0 : 0.0) - shapeS) * depthCoef * 0.2
            let l = (1 - shapeS) * ModulationStage.lfo(phase, .sine) + shapeS * ModulationStage.lfo(phase, .rounded)
            // makeup keeps the average level constant as depth changes
            let g = Float((1 - depthS * l) / (1 - depthS * 0.5))
            left[i] *= g; right[i] *= g
            phase += twoPi * rateS / sampleRate
            if nudgeLeft > 0 { phase += nudgePerSample; nudgeLeft -= 1; if phase < 0 { phase += twoPi } }
            if phase >= twoPi { phase -= twoPi }
        }
    }
}

/// Pink noise (Paul Kellet's refined filter) from a fast xorshift white source.
struct PinkNoise {
    private var s: UInt32
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    init(seed: UInt32) { s = seed | 1 }
    private var hp: Float = 0, hpPrev: Float = 0, lpS: Float = 0
    /// Pink noise, high-passed (~30 Hz, no rumble) and gently low-passed (~5 kHz, soft).
    mutating func next() -> Float {
        let x = rawNext()
        hp = 0.996 * (hp + x - hpPrev); hpPrev = x
        lpS += (hp - lpS) * 0.48
        return lpS
    }
    mutating func rawNext() -> Float {
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
