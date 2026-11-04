import Foundation

public struct NoteEvent: Sendable {
    public enum Kind: UInt8, Sendable { case note, pedalDown, pedalUp }
    public var startSample: Int64
    public var kind: Kind
    public var holdSamples: Int
    public var midi: Int
    public var velocity: Int
    public init(startSample: Int64, holdSamples: Int, midi: Int, velocity: Int) {
        self.startSample = startSample; self.kind = .note; self.holdSamples = holdSamples
        self.midi = midi; self.velocity = velocity
    }
    public init(pedalDown: Bool, at s: Int64) {
        startSample = s; kind = pedalDown ? .pedalDown : .pedalUp; holdSamples = 0; midi = 0; velocity = 0
    }
}

struct Voice {
    enum State: UInt8 { case free, held, sustained, damping, fading }
    var state: State = .free
    var midi = 0
    var lo: ZoneData? = nil
    var hi: ZoneData? = nil
    var gLo: Float = 0, gHi: Float = 0
    var pos: Double = 0
    var rate: Double = 1
    var hold = 0
    var env: Float = 1
    var dampAge = 0
    var fastCoef: Float = 0.999
    var slowCoef: Float = 0.9999
    var fadeCoef: Float = 0.99
    var age = 0
    var isRelease = false
    /// Samples of fade-in remaining (voices start just before the attack, where the waveform is not
    /// exactly zero; a 1 ms ramp prevents a tiny step).
    var fadeIn = 0
}

/// Polyphonic piano sample player.
///
/// * velocity layers crossfaded and loudness-normalised; Hermite pitch-shifting between recorded notes
/// * key state + sustain pedal: released keys are held by the pedal, and dampers fall when it lifts,
///   with a two-stage (fast, then slow) damping curve; legato re-pedalling "catches" just-released notes
/// * top octave and a half has no dampers, as on a real grand
/// * re-struck notes fade the previous vibration quickly instead of stacking
/// * pseudo round-robin (alternating neighbouring sample on repeated notes) and micro-variation
/// * release (damper/hammer) noise at −37 dB, as in the original SFZ
/// No allocation happens on the audio thread.
public final class Sampler {
    let bank: SampleBank
    let sampleRate: Double
    var voices: [Voice]
    public static let maxVoices = 96
    static let softLimit = 80
    public private(set) var pedalDown = false
    public var stealCount = 0
    private var lastStrike = [Int](repeating: -1_000_000, count: 128)
    private var useAlt = [Bool](repeating: false, count: 128)
    private var clock = 0
    private var rng: UInt32 = 0x9E3779B9
    var releaseNoiseLevel: Float = 0.014   // −37 dB
    static let undampedFrom = 89
    private var fadeInLength: Int { Int(sampleRate * 0.001) }

    public init(bank: SampleBank, sampleRate: Double) {
        self.bank = bank
        self.sampleRate = sampleRate
        self.voices = Array(repeating: Voice(), count: Sampler.maxVoices)
    }

    public var activeVoiceCount: Int { voices.reduce(0) { $0 + ($1.state != .free ? 1 : 0) } }

    @inline(__always) private func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng) / Float(UInt32.max)
    }
    @inline(__always) private func coef(_ seconds: Double) -> Float { Float(exp(-1 / (sampleRate * seconds))) }

    private func freeSlot() -> Int? {
        var active = 0
        var free: Int? = nil
        for i in voices.indices { if voices[i].state == .free { if free == nil { free = i } } else { active += 1 } }
        if active >= Sampler.softLimit {
            // gently retire the quietest released voices to keep headroom
            var q = -1; var qe: Float = .infinity
            for i in voices.indices where voices[i].state == .damping || voices[i].state == .sustained || voices[i].isRelease {
                if voices[i].env < qe { qe = voices[i].env; q = i }
            }
            if q >= 0 { voices[q].state = .fading; voices[q].fadeCoef = coef(0.015) }
        }
        if let f = free { return f }
        stealCount += 1
        return voices.indices.max { voices[$0].age < voices[$1].age }
    }

    public func noteOn(midi: Int, velocity: Int, holdSamples: Int) {
        guard (0..<128).contains(midi), !bank.centers.isEmpty else { return }
        // re-strike: the previous vibration of this string fades quickly
        for i in voices.indices where voices[i].state != .free && voices[i].midi == midi && !voices[i].isRelease {
            voices[i].state = .fading; voices[i].fadeCoef = coef(0.04)
        }
        var center = bank.nearest[midi]
        if clock - lastStrike[midi] < Int(sampleRate * 3), bank.alternate[midi] >= 0 {
            useAlt[midi].toggle()
            if useAlt[midi] { center = bank.alternate[midi] }
        } else { useAlt[midi] = false }
        lastStrike[midi] = clock
        let nLayers = bank.layerCount[center]
        guard nLayers > 0 else { return }
        // Nearest recorded layer (layers are not cross-faded: two different strikes summed partially
        // phase-cancel); loudness follows velocity continuously through the normalised gain.
        var loIdx = bank.layerTable[center * SampleBank.maxLayers]
        var bestD = Int.max
        for k in 0..<nLayers {
            let zi = bank.layerTable[center * SampleBank.maxLayers + k]
            let d = abs(bank.zones[zi].layerVelocity - velocity)
            if d < bestD { bestD = d; loIdx = zi }
        }
        let hiIdx = loIdx
        let w: Float = 0
        let zLo = bank.zones[loIdx], zHi = bank.zones[hiIdx]
        let target = 0.05 * powf(Float(velocity) / 40, 1.3) * (1 + (rand() - 0.5) * 0.09)  // ±0.4 dB
        let detuneCents = Double(rand() - 0.5) * 3
        guard let s = freeSlot() else { return }
        let damp = 1.0 + Double(max(0, 60 - midi)) / 30   // bass dampers are slower
        voices[s] = Voice(state: .held, midi: midi, lo: zLo, hi: hiIdx != loIdx ? zHi : nil,
                          gLo: (1 - w) * target / zLo.attackRMS, gHi: w * target / zHi.attackRMS,
                          pos: Double(zLo.startOffset), rate: pow(2.0, (Double(midi - center) + detuneCents / 100) / 12.0) * (zLo.sampleRate / sampleRate),
                          hold: max(1, holdSamples), env: 1, dampAge: 0,
                          fastCoef: coef(0.03 * damp), slowCoef: coef(0.22 * damp), fadeCoef: 1, age: 0, isRelease: false,
                          fadeIn: fadeInLength)
        lastVelocity[midi] = Float(velocity)
    }
    private var lastVelocity = [Float](repeating: 40, count: 128)

    private func releaseNoise(midi: Int, level: Float) {
        guard level > 0.05, bank.releaseTable[midi] >= 0 else { return }
        let z = bank.releaseZones[bank.releaseTable[midi]]
        guard let s = voices.firstIndex(where: { $0.state == .free }) else { return }
        let ref = bank.zones[bank.layerTable[bank.nearest[midi] * SampleBank.maxLayers]].attackRMS
        let g = releaseNoiseLevel * 0.05 * powf(lastVelocity[midi] / 40, 1.3) / ref * level
        voices[s] = Voice(state: .held, midi: midi, lo: z, hi: nil, gLo: g, gHi: 0, pos: 0, rate: z.sampleRate / sampleRate,
                          hold: Int.max / 2, env: 1, fadeCoef: 1, age: 0, isRelease: true, fadeIn: fadeInLength)
    }

    private func startDamping(_ i: Int) {
        guard voices[i].midi < Sampler.undampedFrom else { return }
        voices[i].state = .damping
        voices[i].dampAge = 0
        releaseNoise(midi: voices[i].midi, level: voices[i].env)
    }

    public func setPedal(_ down: Bool) {
        guard down != pedalDown else { return }
        pedalDown = down
        if down {
            // catch strings whose dampers only just fell (legato pedalling)
            for i in voices.indices where voices[i].state == .damping && voices[i].dampAge < Int(sampleRate * 0.08) {
                voices[i].state = .sustained
            }
        } else {
            for i in voices.indices where voices[i].state == .sustained { startDamping(i) }
        }
    }

    public func reset() {
        for i in voices.indices { voices[i].state = .free }
        pedalDown = false
    }

    public func allNotesOff() {
        for i in voices.indices where voices[i].state != .free { voices[i].state = .fading; voices[i].fadeCoef = coef(0.05) }
        pedalDown = false
    }

    @inline(__always)
    private func hermite(_ p: UnsafeMutablePointer<Int16>, _ frames: Int, _ pos: Double) -> Float {
        let i = Int(pos)
        let t = Float(pos - Double(i))
        let y0 = i > 0 ? Float(p[i - 1]) : 0
        let y1 = Float(p[i]), y2 = Float(p[i + 1]), y3 = Float(p[i + 2])
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return (((c3 * t + c2) * t + c1) * t + y1) * (1.0 / 32768.0)
    }

    /// Adds the voices' output into `outL`/`outR`.
    public func render(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        clock += frames
        for vi in voices.indices where voices[vi].state != .free {
            var v = voices[vi]
            guard let zLo = v.lo else { voices[vi].state = .free; continue }
            let zHi = v.hi
            let limit = Double(zLo.frames - 2)
            for f in 0..<frames {
                if v.pos >= limit { v.state = .free; break }
                var l = hermite(zLo.left, zLo.frames, v.pos) * v.gLo
                var r = hermite(zLo.right, zLo.frames, v.pos) * v.gLo
                if let h = zHi, v.pos < Double(h.frames - 2) {
                    l += hermite(h.left, h.frames, v.pos) * v.gHi
                    r += hermite(h.right, h.frames, v.pos) * v.gHi
                }
                var e = v.env
                if v.fadeIn > 0 {
                    let n = Float(fadeInLength)
                    e *= (n - Float(v.fadeIn)) / n
                    v.fadeIn -= 1
                }
                outL[f] += l * e; outR[f] += r * e
                v.pos += v.rate
                switch v.state {
                case .held:
                    v.hold -= 1
                    if v.hold <= 0 && !v.isRelease {
                        if pedalDown || v.midi >= Sampler.undampedFrom { v.state = .sustained }
                        else { voices[vi] = v; startDamping(vi); v = voices[vi] }
                    }
                case .damping:
                    v.env *= v.env > 0.12 ? v.fastCoef : v.slowCoef
                    v.dampAge += 1
                    if v.env < 1e-4 { v.state = .free }
                case .fading:
                    v.env *= v.fadeCoef
                    if v.env < 1e-4 { v.state = .free }
                default: break
                }
                if v.state == .free { break }
            }
            v.age += frames
            voices[vi] = v
        }
    }
}
