import Foundation
import os

public struct EngineParams: Equatable, Sendable {
    public var mode: FocusMode = .focus
    /// nil = vary between styles from movement to movement.
    public var style: CompositionStyle? = .romantic
    public var amEnabled = true
    public var rateHz: Double = FocusMode.focus.defaultRate
    /// Depth at full intensity (0...1).
    public var depth: Double = 0.45
    /// Overall strength of the effect (0...1). Effective depth = depth × intensity × mode scale.
    public var intensity: Double = 0.8
    public var waveform: ModWaveform = .sine
    public var rampInSeconds: Double = 30
    public var noiseEnabled = false
    public var noiseLevel: Double = 0.5
    public var volume: Double = 0.7
    /// Ease-in length in minutes (0 = start at full strength). See `SessionArc`.
    public var inductionMinutes: Double = 0
    /// Length of a timed session in seconds measured from `startSession` (0 = open-ended); used to ease out.
    public var sessionSeconds: Double = 0
    /// Snap the modulation rate to a whole multiple of the music's beat and keep it phase-aligned to bars.
    public var tempoLock = false
    /// Slow (0.1 Hz) breathing-paced swell while settling in.
    public var breathSwell = false
    public init() {}

    public var effectiveDepth: Double {
        guard amEnabled else { return 0 }
        return min(0.9, max(0, depth * intensity * mode.depthScale))
    }
}

/// What is playing now (for the UI). Read from any thread.
public struct EngineStatus: Sendable, Equatable {
    public var keyName = ""
    public var tempo = 0.0
    public var style: CompositionStyle = .romantic
    public var section = ""
    public var chordSymbol = ""
    public var movement = 0
    public init() {}
    public init(keyName: String, tempo: Double, style: CompositionStyle, section: String, chordSymbol: String, movement: Int) {
        self.keyName = keyName; self.tempo = tempo; self.style = style; self.section = section
        self.chordSymbol = chordSymbol; self.movement = movement
    }
}

/// Audio-thread → UI meters.
public struct EngineMeters: Sendable {
    public var peak: Float = 0
    public var rms: Float = 0
    public var amPhase: Double = 0
    public var amDepth: Double = 0
    public var fadeLevel: Double = 0
    public var fadeFinished = false
    public var activeVoices = 0
    public var limiterGain: Float = 1
    public var arcPhase: ArcPhase = .sustaining
    public var arcEnergy: Double = 1
    /// Modulation rate actually in use (after the arc and pulse-locking).
    public var modRate: Double = 0
    public var pulseLocked = false
    /// Beat frequency (Hz) of the bar currently playing.
    public var beatHz: Double = 0
    public init() {}
    init(peak: Float, rms: Float, amPhase: Double, amDepth: Double, fadeLevel: Double, fadeFinished: Bool, activeVoices: Int, limiterGain: Float) {
        self.peak = peak; self.rms = rms; self.amPhase = amPhase; self.amDepth = amDepth; self.fadeLevel = fadeLevel
        self.fadeFinished = fadeFinished; self.activeVoices = activeVoices; self.limiterGain = limiterGain
    }
}

/// The complete signal chain, independent of audio hardware so it can be rendered offline:
///
///   Composer → events → Sampler (+pedal) → sympathetic resonance → FDN reverb
///   → amplitude modulation (LFO) → pink-noise bed → master volume/fade → limiter
///
/// Threading: `topUp`, `setParams`, `startSession`, `beginFadeOut`, `resetPlayback` may be called from
/// any non-audio thread. `render` is the audio callback: it never blocks (try-lock only) and never
/// allocates; control changes reach it as values copied at block boundaries.
public final class SynthCore {
    public static let internalSampleRate = 48_000.0
    public let sampleRate: Double
    private let sampler: Sampler
    private let resonance: SympatheticResonance
    private let reverb: FDNReverb
    private let am: ModulationStage
    private let limiter: Limiter
    private let composer: Composer
    private var noiseL = PinkNoise(seed: 0x1234567), noiseR = PinkNoise(seed: 0x7654321)

    // --- shared state, guarded by `queueLock` (audio thread only ever try-locks) ---
    private var queueLock = os_unfair_lock()
    private var pending: [NoteEvent] = []
    private var params = EngineParams()
    private struct Control { var fadeTarget = 0.0; var fadeSeconds = 2.0; var session = 0; var reset = 0 }
    private var control = Control()
    private var publishedPosition: Int64 = 0
    private var publishedMeters = EngineMeters()

    private var sessionStartPosition: Int64 = 0

    // --- composer side, guarded by `composerLock` (never touched by the audio thread) ---
    private let composerLock = NSLock()
    private var nextBarStart: Int64 = 0
    private var status = EngineStatus()
    private var jitter = SeededRNG(seed: 99)

    // --- audio-thread-only state ---
    private var position: Int64 = 0
    private var audioParams = EngineParams()
    private var audioControl = Control()
    private var seenSession = 0, seenReset = 0
    private var amElapsed = 0.0
    private var fadeLevel = 0.0
    private var volumeS = 0.7
    private var noiseGain = 0.0
    private var wetS: Float = 0.2
    private var lockBeatHz = 0.0
    private var lastArc = ArcState(phase: .sustaining, energy: 1, depthScale: 1, rate: 16, density: 1, tempoBlend: 1, novelty: 1, swell: 0)
    private var swellGain: Float = 1
    private var usedRate = 0.0
    private var locked = false
    /// Phase error (radians) measured at recent bar starts — for tests of the pulse lock.
    public private(set) var debugLockErrors: [Double] = Array(repeating: .nan, count: 64)
    private var lockErrorIdx = 0
    private let dryL: UnsafeMutablePointer<Float>
    private let dryR: UnsafeMutablePointer<Float>
    private let due: UnsafeMutablePointer<NoteEvent>
    private static let maxBlock = 1024
    private static let maxDue = 1024
    /// Output trim so that typical material sits around −20 dBFS RMS at full volume.
    public var outputTrim: Float = 2.0

    public init(bank: SampleBank, sampleRate: Double = SynthCore.internalSampleRate, seed: UInt64 = UInt64.random(in: 0...UInt64.max),
                style: CompositionStyle? = .romantic, mode: FocusMode = .focus) {
        self.sampleRate = sampleRate
        sampler = Sampler(bank: bank, sampleRate: sampleRate)
        resonance = SympatheticResonance(sampleRate: sampleRate)
        reverb = FDNReverb(sampleRate: sampleRate, t60: mode.profile.reverbTime)
        am = ModulationStage(sampleRate: sampleRate, initialRate: mode.defaultRate)
        limiter = Limiter(sampleRate: sampleRate)
        composer = Composer(mode: mode, style: style, seed: seed)
        jitter = SeededRNG(seed: seed ^ 0x5EED)
        params.mode = mode; params.style = style; params.rateHz = mode.defaultRate
        audioParams = params
        wetS = mode.profile.reverbWet
        dryL = allocZeroed(SynthCore.maxBlock)
        dryR = allocZeroed(SynthCore.maxBlock)
        due = .allocate(capacity: SynthCore.maxDue)
        pending.reserveCapacity(8192)
    }

    deinit { dryL.deallocate(); dryR.deallocate(); due.deallocate() }

    // MARK: control (any non-audio thread)

    @inline(__always) private func withQueue<T>(_ f: () -> T) -> T {
        os_unfair_lock_lock(&queueLock); defer { os_unfair_lock_unlock(&queueLock) }
        return f()
    }

    public func setParams(_ p: EngineParams) {
        composerLock.lock()
        composer.setMode(p.mode)
        composer.setStyle(p.style)
        composerLock.unlock()
        withQueue { params = p }
    }

    /// Begin a session: gentle fade-in and AM ramp-in from zero.
    public func startSession(fadeInSeconds: Double = 2) {
        withQueue {
            control.fadeTarget = 1
            control.fadeSeconds = max(0.01, fadeInSeconds)
            control.session += 1
            sessionStartPosition = publishedPosition
        }
    }

    /// Fade to silence (resume with `resume(fadeInSeconds:)` without restarting the AM ramp).
    public func beginFadeOut(seconds: Double) {
        withQueue { control.fadeTarget = 0; control.fadeSeconds = max(0.01, seconds) }
    }

    public func resume(fadeInSeconds: Double) {
        withQueue { control.fadeTarget = 1; control.fadeSeconds = max(0.01, fadeInSeconds) }
    }

    /// Forget scheduled music and silence ringing notes (applied by the audio thread at the next block).
    public func resetPlayback() {
        let pos = withQueue { () -> Int64 in pending.removeAll(keepingCapacity: true); control.reset += 1; return publishedPosition }
        composerLock.lock(); nextBarStart = pos; composerLock.unlock()
    }

    public var meters: EngineMeters { withQueue { publishedMeters } }
    public var currentStatus: EngineStatus { composerLock.lock(); defer { composerLock.unlock() }; return status }
    public var fadeFinished: Bool { meters.fadeFinished }
    public var outputPeak: Float { meters.peak }
    public var currentKeyName: String { currentStatus.keyName }
    public var currentTempo: Double { currentStatus.tempo }

    /// Compose and schedule upcoming bars. Cheap; call from a timer a few times per second.
    public func topUp(aheadSeconds: Double = 4) {
        let (pos, sessionStart, p) = withQueue { (publishedPosition, sessionStartPosition, params) }
        composerLock.lock()
        let horizon = pos + Int64(aheadSeconds * sampleRate)
        if nextBarStart < pos { nextBarStart = pos + Int64(0.05 * sampleRate) }
        var fresh: [NoteEvent] = []
        while nextBarStart < horizon {
            let t = Double(nextBarStart - sessionStart) / sampleRate
            composer.setArc(SessionArc.state(elapsed: max(0, t), inductionMinutes: p.inductionMinutes,
                                             sessionSeconds: p.sessionSeconds, mode: p.mode, targetRate: p.rateHz))
            let bar = composer.nextBar()
            let beat = 60.0 / bar.tempo * sampleRate
            let barStart = nextBarStart
            for n in bar.notes {
                var j = gauss() * 0.004
                if n.voice == .melody { j += 0.008 }
                var start = barStart + Int64(n.beat * beat + j * sampleRate)
                if start < barStart { start = barStart }
                fresh.append(NoteEvent(startSample: start, holdSamples: Int(n.durBeats * beat), midi: n.midi, velocity: n.velocity))
            }
            for pe in bar.pedal { fresh.append(NoteEvent(pedalDown: pe.down, at: barStart + Int64(pe.beat * beat))) }
            fresh.append(NoteEvent(tempoBeatHz: bar.tempo / 60, barSamples: Int(Double(bar.beats) * beat), at: barStart))
            nextBarStart += Int64(Double(bar.beats) * beat)
            status = EngineStatus(keyName: bar.keyName, tempo: bar.tempo, style: bar.style, section: bar.section,
                                  chordSymbol: bar.chords.first?.chord.symbol ?? "", movement: bar.movement)
        }
        composerLock.unlock()
        guard !fresh.isEmpty else { return }
        withQueue {
            pending.append(contentsOf: fresh)
            pending.sort { $0.startSample < $1.startSample || ($0.startSample == $1.startSample && $0.kind.rawValue > $1.kind.rawValue) }
        }
    }

    private func gauss() -> Double {
        let u1 = max(1e-12, Double.random(in: 0..<1, using: &jitter)), u2 = Double.random(in: 0..<1, using: &jitter)
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
        var dueCount = 0
        if os_unfair_lock_trylock(&queueLock) {
            audioParams = params
            audioControl = control
            publishedPosition = position
            let end = position + Int64(n)
            var taken = 0
            while taken < pending.count, pending[taken].startSample < end, dueCount < SynthCore.maxDue {
                due[dueCount] = pending[taken]; dueCount += 1; taken += 1
            }
            if taken > 0 { pending.removeFirst(taken) }
            os_unfair_lock_unlock(&queueLock)
        }
        let p = audioParams
        if audioControl.reset != seenReset { seenReset = audioControl.reset; sampler.allNotesOff() }
        if audioControl.session != seenSession { seenSession = audioControl.session; amElapsed = 0 }

        for i in 0..<n { dryL[i] = 0; dryR[i] = 0 }
        // sample-accurate event dispatch: render up to each event, apply it, continue
        var cursor = 0
        for k in 0..<dueCount {
            let e = due[k]
            let off = max(cursor, min(n - 1, Int(e.startSample - position)))
            if off > cursor { sampler.render(outL: dryL + cursor, outR: dryR + cursor, frames: off - cursor); cursor = off }
            switch e.kind {
            case .note: sampler.noteOn(midi: e.midi, velocity: e.velocity, holdSamples: e.holdSamples)
            case .pedalDown: sampler.setPedal(true)
            case .pedalUp: sampler.setPedal(false)
            case .tempo:
                lockBeatHz = e.value
                // phase-lock: steer the LFO so it is at phase 0 at bar starts (corrected over the bar)
                let predicted = am.currentPhase + 2 * .pi * am.currentRate * Double(off) / sampleRate
                var err = predicted.truncatingRemainder(dividingBy: 2 * .pi)
                if err > .pi { err -= 2 * .pi }
                if locked {
                    debugLockErrors[lockErrorIdx] = err
                    lockErrorIdx = (lockErrorIdx + 1) % debugLockErrors.count
                }
                let barSeconds = Double(max(1, e.holdSamples)) / sampleRate
                if audioParams.tempoLock { am.nudgePhase(by: -err, over: min(0.5, barSeconds / 4)) }
            }
        }
        if cursor < n { sampler.render(outL: dryL + cursor, outR: dryR + cursor, frames: n - cursor) }

        resonance.process(left: dryL, right: dryR, frames: n, pedalDown: sampler.pedalDown)
        let prof = p.mode.profile
        reverb.setDecay(prof.reverbTime)
        wetS += (prof.reverbWet - wetS) * 0.02
        reverb.process(left: dryL, right: dryR, frames: n, wet: wetS)

        let startElapsed = amElapsed
        let invRamp = 1 / max(0.001, p.rampInSeconds)
        let sr = sampleRate
        let arc = SessionArc.state(elapsed: amElapsed, inductionMinutes: p.inductionMinutes,
                                   sessionSeconds: p.sessionSeconds, mode: p.mode, targetRate: p.rateHz)
        lastArc = arc
        var rate = arc.rate
        locked = false
        if p.tempoLock && lockBeatHz > 0.2 {
            let k = max(1, (rate / lockBeatHz).rounded())
            let snapped = k * lockBeatHz
            if abs(snapped - rate) / rate <= 0.1 { rate = snapped; locked = true }
        }
        usedRate = rate
        am.process(left: dryL, right: dryR, frames: n, rate: rate, depth: p.effectiveDepth * arc.depthScale, waveform: p.waveform,
                   immediateRate: locked) { i in
            let x = min(1, (startElapsed + Double(i) / sr) * invRamp)
            return x * x * (3 - 2 * x)
        }
        amElapsed += Double(n) / sr

        // breathing-paced swell (±1.5 dB at 0.1 Hz) while settling, interpolated across the block
        let swellTarget: Float = p.breathSwell && arc.swell > 0
            ? Float(pow(10, 1.5 * arc.swell * sin(2 * .pi * 0.1 * amElapsed) / 20)) : 1
        let swellStart = swellGain
        let swellStep = (swellTarget - swellStart) / Float(n)
        swellGain = swellTarget
        let fadeStep = 1 / (audioControl.fadeSeconds * sr)
        let target = audioControl.fadeTarget
        let noiseTarget = p.noiseEnabled ? p.noiseLevel * 0.12 : 0
        let volCoef = 1 - exp(-1 / (sr * 0.05))
        let noiseCoef = 1 - exp(-1 / (sr * 0.5))
        for i in 0..<n {
            volumeS += (p.volume - volumeS) * volCoef
            noiseGain += (noiseTarget - noiseGain) * noiseCoef
            if fadeLevel < target { fadeLevel = min(target, fadeLevel + fadeStep) }
            else if fadeLevel > target { fadeLevel = max(target, fadeLevel - fadeStep) }
            // perceptual (squared) fade curve and squared volume taper
            let g = Float(volumeS * volumeS * fadeLevel * fadeLevel) * outputTrim * (swellStart + swellStep * Float(i))
            let ng = Float(noiseGain)
            outL[i] = (dryL[i] + noiseL.next() * ng) * g
            outR[i] = (dryR[i] + noiseR.next() * ng) * g
        }
        limiter.process(left: outL, right: outR, frames: n)
        var peak: Float = 0, acc: Float = 0
        for i in 0..<n { peak = max(peak, abs(outL[i]), abs(outR[i])); acc += outL[i] * outL[i] }
        position += Int64(n)
        if os_unfair_lock_trylock(&queueLock) {
            publishedMeters = EngineMeters(peak: peak, rms: (acc / Float(n)).squareRoot(), amPhase: am.currentPhase,
                                           amDepth: p.effectiveDepth * am.transitionLevel, fadeLevel: fadeLevel,
                                           fadeFinished: target == 0 && fadeLevel == 0, activeVoices: sampler.activeVoiceCount,
                                           limiterGain: limiter.minGain)
            publishedMeters.arcPhase = lastArc.phase
            publishedMeters.arcEnergy = lastArc.energy
            publishedMeters.modRate = usedRate
            publishedMeters.pulseLocked = locked
            publishedMeters.beatHz = lockBeatHz
            publishedPosition = position
            os_unfair_lock_unlock(&queueLock)
        }
    }

    // MARK: offline

    public var debugSteals: Int { sampler.stealCount }
    public var debugVoices: Int { sampler.activeVoiceCount }

    /// Render offline (tests/analysis). Calls `topUp` between blocks exactly as the app's timer would.
    public func renderOffline(seconds: Double, block: Int = 512, onBlock: ((Int) -> Void)? = nil) -> (left: [Float], right: [Float]) {
        let total = Int(seconds * sampleRate)
        var l = [Float](repeating: 0, count: total), r = l
        var pos = 0
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            while pos < total {
                if pos % (block * 8) == 0 { topUp() }
                let n = min(block, total - pos)
                render(left: lp.baseAddress! + pos, right: rp.baseAddress! + pos, frames: n)
                pos += n
                onBlock?(pos)
            }
        }}
        return (l, r)
    }
}
