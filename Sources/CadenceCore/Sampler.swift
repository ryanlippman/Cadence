import Foundation

public struct NoteEvent {
    public var startSample: Int64
    public var holdSamples: Int
    public var midi: Int
    public var velocity: Int
    public init(startSample: Int64, holdSamples: Int, midi: Int, velocity: Int) {
        self.startSample = startSample; self.holdSamples = holdSamples
        self.midi = midi; self.velocity = velocity
    }
}

struct Voice {
    var active = false
    var delay = 0
    var lo = 0, hi = 0
    var gLo: Float = 0, gHi: Float = 0
    var pos: Double = 0
    var rate: Double = 1
    var hold = 0
    var releasing = false
    var env: Float = 1
    var age = 0
}

/// Polyphonic sample player with velocity-layer crossfade and pitch shifting
/// (4-point Hermite interpolation). Renders into caller-owned float buffers.
public final class Sampler {
    let bank: SampleBank
    let sampleRate: Double
    var voices: [Voice]
    let releaseCoef: Float
    public static let maxVoices = 64

    public init(bank: SampleBank, sampleRate: Double) {
        self.bank = bank
        self.sampleRate = sampleRate
        self.voices = Array(repeating: Voice(), count: Sampler.maxVoices)
        // ~0.2 s time constant release
        self.releaseCoef = Float(exp(-1.0 / (sampleRate * 0.2)))
    }

    public var activeVoiceCount: Int { voices.reduce(0) { $0 + ($1.active ? 1 : 0) } }

    /// Starts a note `delay` frames from the start of the next rendered block.
    public func noteOn(midi: Int, velocity: Int, holdSamples: Int, delay: Int) {
        guard let sel = bank.select(midi: midi, velocity: velocity) else { return }
        let zLo = bank.zones[sel.lo]
        // Amplitude: target loudness A(v) grows smoothly with velocity; each layer is normalised by
        // its measured attack RMS, then the two bracketing layers are crossfaded.
        let target = 0.05 * powf(Float(velocity) / 40, 1.3)
        let gLo = (1 - sel.wHi) * target / zLo.attackRMS
        let gHi = sel.wHi * target / bank.zones[sel.hi].attackRMS
        var slot = voices.firstIndex { !$0.active }
        if slot == nil {
            slot = voices.indices.max { voices[$0].age < voices[$1].age } // steal oldest
        }
        guard let s = slot else { return }
        voices[s] = Voice(active: true, delay: delay, lo: sel.lo, hi: sel.hi, gLo: gLo, gHi: gHi,
                          pos: 0,
                          rate: pow(2.0, Double(midi - sel.center) / 12.0) * (zLo.sampleRate / sampleRate),
                          hold: max(1, holdSamples), releasing: false, env: 1, age: 0)
    }

    public func allNotesOff() {
        for i in voices.indices where voices[i].active { voices[i].releasing = true; voices[i].hold = 0 }
    }

    @inline(__always)
    private func hermite(_ p: UnsafeMutablePointer<Int16>, _ frames: Int, _ pos: Double) -> Float {
        let i = Int(pos)
        let t = Float(pos - Double(i))
        @inline(__always) func s(_ k: Int) -> Float {
            (k >= 0 && k < frames) ? Float(p[k]) * (1.0 / 32768.0) : 0
        }
        let y0 = s(i - 1), y1 = s(i), y2 = s(i + 1), y3 = s(i + 2)
        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + c0
    }

    /// Adds the voices' output into `outL`/`outR` (which must be zeroed by the caller).
    public func render(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        for vi in voices.indices where voices[vi].active {
            var v = voices[vi]
            let zLo = bank.zones[v.lo]
            let zHi = bank.zones[v.hi]
            let useHi = v.hi != v.lo && v.gHi > 0
            var f = 0
            if v.delay > 0 {
                if v.delay >= frames { v.delay -= frames; voices[vi] = v; continue }
                f = v.delay; v.delay = 0
            }
            while f < frames {
                if v.pos >= Double(zLo.frames - 2) { v.active = false; break }
                var l = hermite(zLo.left, zLo.frames, v.pos)
                var r = hermite(zLo.right, zLo.frames, v.pos)
                l *= v.gLo; r *= v.gLo
                if useHi {
                    l += hermite(zHi.left, zHi.frames, v.pos) * v.gHi
                    r += hermite(zHi.right, zHi.frames, v.pos) * v.gHi
                }
                l *= v.env; r *= v.env
                outL[f] += l; outR[f] += r
                v.pos += v.rate
                v.age += 1
                if v.releasing {
                    v.env *= releaseCoef
                    if v.env < 1e-4 { v.active = false; break }
                } else {
                    v.hold -= 1
                    if v.hold <= 0 { v.releasing = true }
                }
                f += 1
            }
            voices[vi] = v
        }
    }
}
