import XCTest
@testable import CadenceCore

final class ModulationTests: XCTestCase {
    static let bank: SampleBank = { try! SampleBank.loadBundled() }()
    let sr = SynthCore.internalSampleRate

    func testStageProducesPeakAtConfiguredRate() {
        for rate in [2.5, 9.0, 16.0, 18.5] {
            let n = Int(sr * 30)
            var l = (0..<n).map { Float(sin(2 * .pi * 220 * Double($0) / sr)) * 0.3 }
            var r = l
            let am = ModulationStage(sampleRate: sr, initialRate: rate)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                am.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: n, rate: rate, depth: 0.4, waveform: .sine, ramp: { _ in 1 })
            }}
            let pk = AudioAnalysis.envelopePeak(AudioAnalysis.envelope(l, sampleRate: sr), envRate: 500, band: 0.5...40)
            XCTAssertEqual(pk.freq, rate, accuracy: 0.06, "rate \(rate)")
            XCTAssertGreaterThan(pk.prominence, 50)
        }
    }

    func testRateIsSampleAccurateOverLongDurations() {
        // phase after exactly 10 minutes at 16 Hz must still be ~0 (no accumulated drift)
        let am = ModulationStage(sampleRate: sr, initialRate: 16)
        let block = 4800
        var l = [Float](repeating: 1, count: block), r = l
        for _ in 0..<(Int(sr * 600) / block) {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                am.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: block, rate: 16, depth: 0.3, waveform: .sine, ramp: { _ in 1 })
            }}
        }
        let wrapped = min(am.currentPhase, 2 * .pi - am.currentPhase)
        XCTAssertLessThan(wrapped, 1e-6)
    }

    func testNoClicksWhenChangingEverything() {
        let n = Int(sr * 12)
        var l = [Float](repeating: 1, count: n), r = l
        let am = ModulationStage(sampleRate: sr)
        let sec = Int(sr)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            for k in 0..<12 {
                am.process(left: lp.baseAddress! + k * sec, right: rp.baseAddress! + k * sec, frames: sec,
                           rate: [16, 9, 2.5, 18][k % 4], depth: [0.5, 0.2, 0.7, 0.3][k % 4], waveform: k % 3 == 0 ? .rounded : .sine,
                           ramp: { _ in 1 })
            }
        }}
        var maxStep: Float = 0
        for i in 1..<n { maxStep = max(maxStep, abs(l[i] - l[i - 1])) }
        XCTAssertLessThan(maxStep, 0.006, "per-sample gain step must be tiny")
    }

    func testLargeRateChangeDipsInsteadOfSweeping() {
        let am = ModulationStage(sampleRate: sr, initialRate: 16)
        let n = Int(sr * 0.6)
        var l = [Float](repeating: 1, count: n), r = l
        func run(_ rate: Double) {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                am.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: n, rate: rate, depth: 0.4, waveform: .sine, ramp: { _ in 1 })
            }}
        }
        run(16); run(2.5); run(2.5)   // 1.2 s: fully dipped, rate switched
        XCTAssertLessThan(am.transitionLevel, 0.2)
        for _ in 0..<8 { run(2.5) }   // recovered
        XCTAssertEqual(am.transitionLevel, 1, accuracy: 1e-9)
    }

    func renderMusic(style: CompositionStyle = .romantic, mode: FocusMode, am: Bool, rate: Double? = nil, seconds: Double = 50,
                     intensity: Double = 1) -> [Float] {
        var p = EngineParams()
        p.mode = mode; p.style = style; p.rateHz = rate ?? mode.defaultRate; p.amEnabled = am
        p.depth = 0.45; p.intensity = intensity; p.rampInSeconds = 0.01
        let core = SynthCore(bank: ModulationTests.bank, seed: 7, style: style, mode: mode)
        core.setParams(p)
        core.startSession(fadeInSeconds: 0.01)
        return Array(core.renderOffline(seconds: seconds).left[Int(sr * 6)...])
    }

    /// Full pipeline (composer → sampler → resonance → reverb → AM → limiter): clear envelope peak at
    /// the configured rate, absent with AM off, for every style.
    func testFullPipelinePeakAtFocusRateForEveryStyle() {
        for style in CompositionStyle.allCases {
            let on = AudioAnalysis.envelope(renderMusic(style: style, mode: .focus, am: true), sampleRate: sr)
            let off = AudioAnalysis.envelope(renderMusic(style: style, mode: .focus, am: false), sampleRate: sr)
            let pk = AudioAnalysis.envelopePeak(on, envRate: 500, band: 8...30)
            XCTAssertEqual(pk.freq, 16, accuracy: 0.1, "\(style)")
            XCTAssertGreaterThan(pk.prominence, 15, "\(style)")
            XCTAssertGreaterThan(pk.magnitude / AudioAnalysis.envelopeMagnitude(off, envRate: 500, at: 16), 15, "\(style)")
        }
    }

    func testFullPipelineRelaxAndSleep() {
        let relax = AudioAnalysis.envelope(renderMusic(mode: .relax, am: true), sampleRate: sr)
        let pk = AudioAnalysis.envelopePeak(relax, envRate: 500, band: 6...14)
        XCTAssertEqual(pk.freq, 9, accuracy: 0.1)
        let on = AudioAnalysis.envelope(renderMusic(mode: .sleep, am: true, seconds: 80), sampleRate: sr)
        let off = AudioAnalysis.envelope(renderMusic(mode: .sleep, am: false, seconds: 80), sampleRate: sr)
        XCTAssertGreaterThan(AudioAnalysis.envelopeMagnitude(on, envRate: 500, at: 2.5) /
                             AudioAnalysis.envelopeMagnitude(off, envRate: 500, at: 2.5), 4)
    }

    func testIntensityScalesModulation() {
        func mag(_ i: Double) -> Double {
            AudioAnalysis.envelopeMagnitude(AudioAnalysis.envelope(renderMusic(mode: .focus, am: true, seconds: 35, intensity: i), sampleRate: sr), envRate: 500, at: 16)
        }
        XCTAssertGreaterThan(mag(1.0), mag(0.3) * 2)
    }

    func testRampIn() {
        var p = EngineParams(); p.rampInSeconds = 20; p.intensity = 1
        let core = SynthCore(bank: ModulationTests.bank, seed: 3, style: .romantic)
        core.setParams(p); core.startSession(fadeInSeconds: 0.01)
        let x = core.renderOffline(seconds: 32).left
        let early = Array(x[Int(sr * 2)..<Int(sr * 6)]), late = Array(x[Int(sr * 24)..<Int(sr * 32)])
        XCTAssertGreaterThan(AudioAnalysis.envelopeMagnitude(AudioAnalysis.envelope(late, sampleRate: sr), envRate: 500, at: 16),
                             AudioAnalysis.envelopeMagnitude(AudioAnalysis.envelope(early, sampleRate: sr), envRate: 500, at: 16) * 3)
    }

    func testPinkNoiseBedIsSoftAndToggleable() {
        func render(_ noise: Bool) -> [Float] {
            var p = EngineParams(); p.noiseEnabled = noise; p.volume = 0.8
            let core = SynthCore(bank: ModulationTests.bank, seed: 5)
            core.setParams(p); core.startSession(fadeInSeconds: 0.01)
            return Array(core.renderOffline(seconds: 6).left[Int(sr * 3)...])
        }
        let with = render(true), without = render(false)
        let noise = AudioAnalysis.rms(zip(with, without).map { $0 - $1 })
        let music = AudioAnalysis.rms(without)
        XCTAssertGreaterThan(noise, 1e-3, "noise bed present")
        let rel = AudioAnalysis.db(noise) - AudioAnalysis.db(music)
        XCTAssertTrue((-30.0)...(-10.0) ~= rel, "noise sits well below the music (\(rel) dB)")
    }
}
