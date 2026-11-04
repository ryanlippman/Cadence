import Foundation

public enum ModWaveform: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Raised-cosine: smooth, no harmonics in the gain curve.
    case sine
    /// Slightly flattened peaks/troughs (tanh-shaped sine): a touch more pronounced, still click-free.
    case rounded
    /// Short dips between longer plateaus: the music stays full most of the time.
    case pulse
    /// Quick (but smooth) rise and slower fall, like a soft note onset each cycle; the most "pulsed" feel.
    case ramp
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sine: return "Smooth"
        case .rounded: return "Rounded"
        case .pulse: return "Pulse"
        case .ramp: return "Onset"
        }
    }
    public var blurb: String {
        switch self {
        case .sine: return "Even rise and fall"
        case .rounded: return "Fuller peaks and troughs"
        case .pulse: return "Brief dips, steady in between"
        case .ramp: return "Quick rise, slow fall"
        }
    }
    /// Mean of the 0...1 LFO, for level make-up.
    var meanLevel: Double { self == .pulse ? 0.375 : 0.5 }
    var index: Int { ModWaveform.allCases.firstIndex(of: self)! }
}

/// How the modulation is placed between the ears.
public enum ModStereo: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Both channels rise and fall together.
    case together
    /// Left and right alternate (half a cycle apart), so the sound gently moves between the ears.
    case alternating
    public var id: String { rawValue }
    public var title: String { self == .together ? "Together" : "Alternating" }
}

/// Which part of the spectrum is modulated.
public enum ModBand: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The whole mix.
    case full
    /// Mostly above the bass (≈ 220 Hz): the low end stays steady, which many people find less tiring.
    case upper
    public var id: String { rawValue }
    public var title: String { self == .full ? "Whole mix" : "Above the bass" }
}

/// Overall strength preset (multiplies depth). Responses to modulation vary between people; some find the
/// standard setting too subtle and prefer stronger modulation.
public enum ModStrength: String, CaseIterable, Codable, Sendable, Identifiable {
    case gentle, standard, strong
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var depthFactor: Double {
        switch self { case .gentle: return 0.65; case .standard: return 1.0; case .strong: return 1.6 }
    }
}

/// Sample-accurate amplitude modulation: an LFO drives gain between (1 - depth) and 1.
/// Phase is accumulated in Double and rate, depth, waveform, stereo spread and band are all smoothed
/// per sample, so changing settings (or switching modes) never produces a phase jump or a click.
public final class ModulationStage {
    private let sampleRate: Double
    private var phase = 0.0
    private var rateS: Double
    private var depthS = 0.0
    /// Per-waveform weights, each glides toward 0 or 1 so switching waveform cross-fades.
    private var shapeW: [Double] = [1, 0, 0, 0]
    private var spreadS = 0.0      // 0 = together, 1 = right channel half a cycle behind
    private var lowAmtS = 1.0      // how much of the low band is modulated (1 = all)
    private var lowL = 0.0, lowR = 0.0
    private let lowCoef: Double
    private let rateCoef: Double
    private let depthCoef: Double
    private let slowCoef: Double
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
        slowCoef = 1 - exp(-1 / (sampleRate * 0.4))
        lowCoef = 1 - exp(-2 * Double.pi * 220 / sampleRate)
        dipStep = 1 / (sampleRate * 1.2)
        recoverStep = 1 / (sampleRate * 3.0)
    }

    public var currentPhase: Double { phase }
    public var currentRate: Double { rateS }

    /// LFO value 0...1 for a phase in radians (1 = deepest point of the dip); gain = 1 - depth * lfo.
    /// Every shape is at least C1-continuous, so the gain curve has no corners (no clicks or buzz).
    @inline(__always)
    static func lfo(_ phase: Double, _ w: ModWaveform) -> Double {
        switch w {
        case .sine: return 0.5 * (1 - cos(phase))
        case .rounded:
            let k = 1.8
            return 0.5 * (1 + tanh(-k * cos(phase)) / tanh(k)) // same orientation as .sine
        case .pulse:
            let s = 0.5 * (1 - cos(phase))
            return s * s
        case .ramp:
            // phase warp: the trough→peak half takes 25 % of the cycle, peak→trough the other 75 %
            let x = phase / (2 * Double.pi)
            let a = 0.25
            let u = x < a ? 0.5 * x / a : 0.5 + 0.5 * (x - a) / (1 - a)
            return 0.5 * (1 + cos(2 * Double.pi * u))
        }
    }

    /// `depth` is the target depth 0...1; `ramp(i)` supplies a 0...1 ramp-in multiplier per sample.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                        rate: Double, depth: Double, waveform: ModWaveform, stereo: ModStereo = .together,
                        band: ModBand = .full, immediateRate: Bool = false, ramp: (Int) -> Double) {
        let twoPi = 2 * Double.pi
        if abs(rate - rateTarget) / max(rateTarget, 0.1) > 0.2 {
            pendingRate = rate; recovering = false
        }
        rateTarget = rate
        let wi = waveform.index
        let spreadT = stereo == .alternating ? 1.0 : 0.0
        let lowT = band == .upper ? 0.25 : 1.0
        let shapes = ModWaveform.allCases
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
            spreadS += (spreadT - spreadS) * slowCoef
            lowAmtS += (lowT - lowAmtS) * slowCoef
            var lL = 0.0, lR = 0.0, mean = 0.0
            let phR = phase - Double.pi * spreadS
            for k in 0..<4 {
                shapeW[k] += ((k == wi ? 1.0 : 0.0) - shapeW[k]) * slowCoef
                let w = shapeW[k]
                if w < 1e-5 { continue }
                lL += w * ModulationStage.lfo(phase, shapes[k])
                lR += w * ModulationStage.lfo(phR < 0 ? phR + twoPi : phR, shapes[k])
                mean += w * shapes[k].meanLevel
            }
            // makeup keeps the average level constant as depth and shape change
            let mk = 1 / (1 - depthS * mean)
            let gL = (1 - depthS * lL) * mk, gR = (1 - depthS * lR) * mk
            let xl = Double(left[i]), xr = Double(right[i])
            lowL += (xl - lowL) * lowCoef
            lowR += (xr - lowR) * lowCoef
            // low band gets only `lowAmtS` of the modulation (with its own makeup)
            let glL = 1 + (gL - 1) * lowAmtS, glR = 1 + (gR - 1) * lowAmtS
            left[i] = Float((xl - lowL) * gL + lowL * glL)
            right[i] = Float((xr - lowR) * gR + lowR * glR)
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
