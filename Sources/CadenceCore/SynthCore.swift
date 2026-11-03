import Foundation

public struct EngineParams: Equatable, Sendable {
    public var mode: FocusMode = .focus
    public var amEnabled = true
    public var rateHz: Double = FocusMode.focus.defaultRate
    /// Depth at full intensity (0...1). Default 0.45.
    public var depth: Double = 0.45
    /// Overall strength of the effect (0...1). Effective depth = depth * intensity * mode scale.
    public var intensity: Double = 0.8
    public var waveform: ModWaveform = .sine
    public var rampInSeconds: Double = 30
    public var noiseEnabled = false
    public var noiseLevel: Double = 0.5
    public var volume: Double = 0.7
    public init() {}

    public var effectiveDepth: Double {
        guard amEnabled else { return 0 }
        return min(0.9, max(0, depth * intensity * mode.depthScale))
    }
}

/// The complete audio signal chain, independent of any audio hardware so it can be rendered
/// offline in tests:  generator → sampler → reverb → AM (LFO) → pink-noise bed → master → soft clip.
public final class SynthCore {
    public let sampleRate: Double
    private let sampler: Sampler
    private let reverb: Reverb
    private let am: ModulationStage
    private let generator: MusicGenerator
    private var noiseL = PinkNoise(seed: 0x1234567), noiseR = PinkNoise(seed: 0x7654321)

    private let lock = NSLock()
    private var params = EngineParams()
    private var audioParams = EngineParams()
    private var pending: [NoteEvent] = []
    private var nextBarStart: Int64 = 0
    private var rng = SeededRNG(seed: 42)

    // audio-thread state
    private var position: Int64 = 0
    private var shadowPosition: Int64 = 0
    private var amElapsed = 0.0
    private var fadeLevel: Double = 0
    private var fadeTarget: Double = 0
    private var fadeSeconds = 2.0
    private var volumeS = 0.7
    private var noiseGain = 0.0
    private var wetS: Float
    private var dryL: UnsafeMutablePointer<Float>
    private var dryR: UnsafeMutablePointer<Float>
    private static let maxBlock = 1024

    public private(set) var outputPeak: Float = 0
    public var debugSteals: Int { sampler.stealCount }
    public var debugVoices: Int { sampler.activeVoiceCount }
    public private(set) var fadeFinished = false
    public private(set) var currentKeyName = ""
    public private(set) var currentTempo = 0.0

    public init(bank: SampleBank, sampleRate: Double, seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.sampleRate = sampleRate
        sampler = Sampler(bank: bank, sampleRate: sampleRate)
        reverb = Reverb(sampleRate: sampleRate)
        am = ModulationStage(sampleRate: sampleRate)
        generator = MusicGenerator(mode: .focus, seed: seed)
        rng = SeededRNG(seed: seed ^ 0xABCDEF)
        wetS = FocusMode.focus.profile.reverbWet
        dryL = .allocate(capacity: SynthCore.maxBlock)
        dryR = .allocate(capacity: SynthCore.maxBlock)
    }

    deinit { dryL.deallocate(); dryR.deallocate() }

    // MARK: control (any thread)

    public func setParams(_ p: EngineParams) {
        lock.lock(); defer { lock.unlock() }
        if p.mode != params.mode { generator.setMode(p.mode) }
        params = p
    }

    /// Begin a session: silent start, gentle fade-in, AM ramp-in restarts.
    public func startSession(fadeInSeconds: Double = 2) {
        lock.lock(); defer { lock.unlock() }
        amElapsed = 0
        fadeSeconds = max(0.01, fadeInSeconds)
        fadeTarget = 1
        fadeFinished = false
        if nextBarStart < shadowPosition { nextBarStart = shadowPosition }
    }

    public func beginFadeOut(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        fadeSeconds = max(0.01, seconds)
        fadeTarget = 0
        fadeFinished = false
    }

    /// Silence immediately and forget scheduled music (call once fully faded out).
    public func resetPlayback() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll()
        sampler.allNotesOff()
        nextBarStart = shadowPosition
    }

    /// Generate and schedule upcoming bars. Cheap; call from a timer a few times per second.
    public func topUp(aheadSeconds: Double = 6) {
        lock.lock(); defer { lock.unlock() }
        let horizon = shadowPosition + Int64(aheadSeconds * sampleRate)
        if nextBarStart < shadowPosition { nextBarStart = shadowPosition + Int64(0.05 * sampleRate) }
        while nextBarStart < horizon {
            let bar = generator.nextBar()
            let beat = 60.0 / bar.tempo * sampleRate
            for n in bar.notes {
                let jitter = gauss() * 0.007 * sampleRate + (n.hand == .right ? 0.010 * sampleRate : 0)
                var start = nextBarStart + Int64(n.beat * beat + jitter)
                if start < nextBarStart { start = nextBarStart }
                pending.append(NoteEvent(startSample: start, holdSamples: Int(n.durBeats * beat),
                                         midi: n.midi, velocity: n.velocity))
            }
            nextBarStart += Int64(Double(bar.beats) * beat)
            currentKeyName = bar.keyName
            currentTempo = bar.tempo
        }
        pending.sort { $0.startSample < $1.startSample }
    }

    private func gauss() -> Double {
        let u1 = Double.random(in: 1e-9..<1, using: &rng), u2 = Double.random(in: 0..<1, using: &rng)
        return max(-2.5, min(2.5, (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)))
    }

    // MARK: audio thread

    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(SynthCore.maxBlock, frames - done)
            renderChunk(left + done, right + done, n)
            done += n
        }
    }

    private func renderChunk(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ n: Int) {
        if lock.try() {
            audioParams = params
            // Session state is mutated by control calls under the same lock; mirror position back.
            shadowPosition = position
            let end = position + Int64(n)
            var taken = 0
            while taken < pending.count, pending[taken].startSample < end {
                let e = pending[taken]
                sampler.noteOn(midi: e.midi, velocity: e.velocity, holdSamples: e.holdSamples,
                               delay: max(0, Int(e.startSample - position)))
                taken += 1
            }
            if taken > 0 { pending.removeFirst(taken) }
            lock.unlock()
        }
        let p = audioParams

        for i in 0..<n { dryL[i] = 0; dryR[i] = 0 }
        sampler.render(outL: dryL, outR: dryR, frames: n)
        let targetWet = p.mode.profile.reverbWet
        wetS += (targetWet - wetS) * 0.01
        reverb.process(left: dryL, right: dryR, frames: n, wet: wetS)

        let startElapsed = amElapsed
        let invRamp = 1 / max(0.001, p.rampInSeconds)
        let sr = sampleRate
        am.process(left: dryL, right: dryR, frames: n, rate: p.rateHz, depth: p.effectiveDepth,
                   waveform: p.waveform) { i in
            let x = min(1, (startElapsed + Double(i) / sr) * invRamp)
            return x * x * (3 - 2 * x)
        }
        amElapsed += Double(n) / sr

        let fadeStep = 1 / (fadeSeconds * sr)
        let noiseTarget = p.noiseEnabled ? p.noiseLevel * 0.2 : 0
        var peak: Float = 0
        for i in 0..<n {
            volumeS += (p.volume - volumeS) * 0.002
            noiseGain += (noiseTarget - noiseGain) * 0.0002
            if fadeLevel < fadeTarget { fadeLevel = min(fadeTarget, fadeLevel + fadeStep) }
            else if fadeLevel > fadeTarget { fadeLevel = max(fadeTarget, fadeLevel - fadeStep) }
            let g = Float(volumeS * fadeLevel * fadeLevel) * 2.5   // output trim (piano samples are quiet)
            let ng = Float(noiseGain)
            let l = (dryL[i] + noiseL.next() * ng) * g
            let r = (dryR[i] + noiseR.next() * ng) * g
            let cl = tanhf(l), cr = tanhf(r)
            outL[i] = cl; outR[i] = cr
            peak = max(peak, abs(cl), abs(cr))
        }
        outputPeak = peak
        if fadeTarget == 0 && fadeLevel == 0 { fadeFinished = true }
        position += Int64(n)
    }

    /// Convenience for offline rendering/testing.
    public func renderOffline(seconds: Double, block: Int = 512) -> (left: [Float], right: [Float]) {
        let total = Int(seconds * sampleRate)
        var l = [Float](repeating: 0, count: total), r = l
        var pos = 0
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            while pos < total {
                topUp()
                let n = min(block, total - pos)
                render(left: lp.baseAddress! + pos, right: rp.baseAddress! + pos, frames: n)
                pos += n
            }
        }}
        return (l, r)
    }
}
