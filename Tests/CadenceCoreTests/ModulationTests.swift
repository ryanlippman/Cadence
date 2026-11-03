import XCTest
@testable import CadenceCore

/// Envelope spectrum helpers (plain DFT at chosen frequencies; no dependencies).
enum Spectrum {
    /// RMS envelope sampled at `envRate` Hz.
    static func envelope(_ x: [Float], sampleRate: Double, envRate: Double = 500) -> [Double] {
        let hop = Int(sampleRate / envRate)
        var env: [Double] = []
        var i = 0
        while i + hop <= x.count {
            var acc = 0.0
            for k in i..<(i + hop) { acc += Double(x[k]) * Double(x[k]) }
            env.append((acc / Double(hop)).squareRoot())
            i += hop
        }
        return env
    }

    /// Hann-windowed DFT magnitude at frequency `f` (after removing the mean).
    static func magnitude(_ e: [Double], envRate: Double, at f: Double) -> Double {
        let n = e.count
        let mean = e.reduce(0, +) / Double(n)
        var re = 0.0, im = 0.0, wsum = 0.0
        for k in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * .pi * Double(k) / Double(n - 1))
            let v = (e[k] - mean) * w
            let a = 2 * Double.pi * f * Double(k) / envRate
            re += v * cos(a); im -= v * sin(a); wsum += w
        }
        return (re * re + im * im).squareRoot() * 2 / wsum
    }

    static func peak(_ e: [Double], envRate: Double, in band: ClosedRange<Double>, step: Double = 0.05) -> (freq: Double, mag: Double, median: Double) {
        var best = (0.0, -1.0)
        var mags: [Double] = []
        var f = band.lowerBound
        while f <= band.upperBound {
            let m = magnitude(e, envRate: envRate, at: f)
            mags.append(m)
            if m > best.1 { best = (f, m) }
            f += step
        }
        let median = mags.sorted()[mags.count / 2]
        return (best.0, best.1, median)
    }
}

final class ModulationTests: XCTestCase {
    static let bank: SampleBank = { try! SampleBank.loadBundled() }()
    let sr = 44100.0

    /// Pure stage test: steady noise-like tone in, expect a single clean peak at the LFO rate.
    func testStageProducesPeakAtConfiguredRate() {
        for rate in [2.5, 9.0, 16.0] {
            let n = Int(sr * 30)
            var l = (0..<n).map { Float(sin(2 * .pi * 220 * Double($0) / sr)) * 0.3 }
            var r = l
            let am = ModulationStage(sampleRate: sr, initialRate: rate)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                am.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: n, rate: rate, depth: 0.4,
                           waveform: .sine, ramp: { _ in 1 })
            }}
            let env = Spectrum.envelope(l, sampleRate: sr)
            let pk = Spectrum.peak(env, envRate: 500, in: 0.5...40)
            XCTAssertEqual(pk.freq, rate, accuracy: 0.1, "rate \(rate)")
            XCTAssertGreaterThan(pk.mag / max(pk.median, 1e-9), 50, "peak not clear for \(rate) Hz")
        }
    }

    func testNoClicks_gainIsContinuousAndBounded() {
        let n = Int(sr * 5)
        var l = [Float](repeating: 1, count: n), r = l
        let am = ModulationStage(sampleRate: sr)
        // Sweep parameters mid-stream to prove smooth transitions.
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            for k in 0..<5 {
                am.process(left: lp.baseAddress! + k * Int(sr), right: rp.baseAddress! + k * Int(sr), frames: Int(sr),
                           rate: k % 2 == 0 ? 16 : 9, depth: k % 2 == 0 ? 0.5 : 0.2, waveform: k < 3 ? .sine : .rounded,
                           ramp: { _ in 1 })
            }
        }}
        var maxStep: Float = 0
        for i in 1..<n { maxStep = max(maxStep, abs(l[i] - l[i - 1])) }
        XCTAssertLessThan(maxStep, 0.01, "per-sample gain step must be tiny (no clicks)")
        XCTAssertGreaterThan(l.min()!, 0.4)
        XCTAssertLessThan(l.max()!, 2.0)
    }

    func renderMusic(mode: FocusMode, am: Bool, rate: Double? = nil, seconds: Double = 60) -> [Float] {
        var p = EngineParams()
        p.mode = mode; p.rateHz = rate ?? mode.defaultRate; p.amEnabled = am
        p.depth = 0.45; p.intensity = 1; p.rampInSeconds = 0.01
        let core = SynthCore(bank: ModulationTests.bank, sampleRate: sr, seed: 7)
        core.setParams(p)
        core.startSession(fadeInSeconds: 0.01)
        let out = core.renderOffline(seconds: seconds)
        return Array(out.left[Int(sr * 8)...])   // skip startup
    }

    /// Full pipeline: generated piano → reverb → AM. The envelope spectrum must show a clear
    /// peak at the configured rate, and that peak must be absent without AM.
    func testFullPipelineEnvelopePeak_Focus16Hz() {
        let on = Spectrum.envelope(renderMusic(mode: .focus, am: true), sampleRate: sr)
        let off = Spectrum.envelope(renderMusic(mode: .focus, am: false), sampleRate: sr)
        let pk = Spectrum.peak(on, envRate: 500, in: 8...30)
        XCTAssertEqual(pk.freq, 16, accuracy: 0.15)
        XCTAssertGreaterThan(pk.mag / pk.median, 8, "clear peak vs. band median")
        let base = Spectrum.magnitude(off, envRate: 500, at: pk.freq)
        XCTAssertGreaterThan(pk.mag / max(base, 1e-9), 10, "AM adds the peak (vs. AM off)")
        print("FOCUS 16Hz peak:", pk, "AM-off magnitude at same bin:", base)
    }

    func testFullPipelineEnvelopePeak_Relax9Hz() {
        let on = Spectrum.envelope(renderMusic(mode: .relax, am: true), sampleRate: sr)
        let off = Spectrum.envelope(renderMusic(mode: .relax, am: false), sampleRate: sr)
        let pk = Spectrum.peak(on, envRate: 500, in: 5...14)
        XCTAssertEqual(pk.freq, 9, accuracy: 0.15)
        let base = Spectrum.magnitude(off, envRate: 500, at: pk.freq)
        XCTAssertGreaterThan(pk.mag / max(base, 1e-9), 8)
        print("RELAX 9Hz peak:", pk, "AM-off:", base)
    }

    func testFullPipelineEnvelopePeak_Sleep2p5Hz() {
        let on = Spectrum.envelope(renderMusic(mode: .sleep, am: true, seconds: 90), sampleRate: sr)
        let off = Spectrum.envelope(renderMusic(mode: .sleep, am: false, seconds: 90), sampleRate: sr)
        let mOn = Spectrum.magnitude(on, envRate: 500, at: 2.5)
        let mOff = Spectrum.magnitude(off, envRate: 500, at: 2.5)
        XCTAssertGreaterThan(mOn / max(mOff, 1e-9), 3, "AM energy at 2.5 Hz well above the natural envelope")
        print("SLEEP 2.5Hz on/off:", mOn, mOff)
    }

    func testConfigurableRateMovesPeak() {
        let env = Spectrum.envelope(renderMusic(mode: .focus, am: true, rate: 14, seconds: 45), sampleRate: sr)
        let pk = Spectrum.peak(env, envRate: 500, in: 8...30)
        XCTAssertEqual(pk.freq, 14, accuracy: 0.2)
    }

    func testDepthControlsPeakStrength() {
        func mag(_ intensity: Double) -> Double {
            var p = EngineParams(); p.intensity = intensity; p.rampInSeconds = 0.01
            let core = SynthCore(bank: ModulationTests.bank, sampleRate: sr, seed: 7)
            core.setParams(p); core.startSession(fadeInSeconds: 0.01)
            let x = Array(core.renderOffline(seconds: 40).left[Int(sr * 6)...])
            return Spectrum.magnitude(Spectrum.envelope(x, sampleRate: sr), envRate: 500, at: 16)
        }
        let lo = mag(0.3), hi = mag(1.0)
        XCTAssertGreaterThan(hi, lo * 1.8)
    }

    func testRampInStartsWithoutModulation() {
        var p = EngineParams(); p.rampInSeconds = 20; p.intensity = 1
        let core = SynthCore(bank: ModulationTests.bank, sampleRate: sr, seed: 3)
        core.setParams(p); core.startSession(fadeInSeconds: 0.01)
        let x = core.renderOffline(seconds: 32).left
        let early = Array(x[Int(sr * 2)..<Int(sr * 6)]), late = Array(x[Int(sr * 24)..<Int(sr * 32)])
        let me = Spectrum.magnitude(Spectrum.envelope(early, sampleRate: sr), envRate: 500, at: 16)
        let ml = Spectrum.magnitude(Spectrum.envelope(late, sampleRate: sr), envRate: 500, at: 16)
        XCTAssertGreaterThan(ml, me * 3)
    }

    func testFadeOutReachesSilenceAndOutputIsBounded() {
        let core = SynthCore(bank: ModulationTests.bank, sampleRate: sr, seed: 5)
        core.setParams(EngineParams()); core.startSession(fadeInSeconds: 0.5)
        _ = core.renderOffline(seconds: 5)
        core.beginFadeOut(seconds: 2)
        let tail = core.renderOffline(seconds: 3).left
        XCTAssertLessThan(tail.suffix(Int(sr)).map(abs).max()!, 1e-6)
        XCTAssertTrue(core.fadeFinished)
        XCTAssertLessThanOrEqual(tail.map(abs).max()!, 1.0)
    }

    func testPinkNoiseToggle() {
        func rms(_ noise: Bool) -> Float {
            var p = EngineParams(); p.noiseEnabled = noise; p.volume = 0.8
            let core = SynthCore(bank: ModulationTests.bank, sampleRate: sr, seed: 5)
            core.setParams(p); core.startSession(fadeInSeconds: 0.01)
            // before any music starts, only the noise bed contributes
            let x = Array(core.renderOffline(seconds: 0.04 + 2).left[Int(sr * 1.5)...Int(sr * 1.9)])
            return (x.map { $0 * $0 }.reduce(0, +) / Float(x.count)).squareRoot()
        }
        XCTAssertGreaterThan(rms(true), rms(false))
    }
}
