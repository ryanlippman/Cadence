import XCTest
@testable import CadenceCore

final class SessionArcTests: XCTestCase {
    static let bank: SampleBank = { try! SampleBank.loadBundled() }()
    let sr = SynthCore.internalSampleRate

    func testArcStartsGentleAndDeepensSmoothly() {
        let s0 = SessionArc.state(elapsed: 0, inductionMinutes: 10, sessionSeconds: nil, mode: .focus, targetRate: 16)
        XCTAssertEqual(s0.phase, .settling)
        XCTAssertEqual(s0.depthScale, 0.2, accuracy: 1e-9)
        XCTAssertEqual(s0.rate, 10, accuracy: 1e-9)
        XCTAssertLessThan(s0.density, 0.75)
        XCTAssertEqual(SessionArc.state(elapsed: 240, inductionMinutes: 10, sessionSeconds: nil, mode: .focus, targetRate: 16).phase, .deepening)
        let end = SessionArc.state(elapsed: 600, inductionMinutes: 10, sessionSeconds: nil, mode: .focus, targetRate: 16)
        XCTAssertEqual(end.phase, .sustaining)
        XCTAssertEqual(end.rate, 16, accuracy: 1e-9)
        XCTAssertEqual(end.depthScale, 1, accuracy: 1e-9)
        XCTAssertLessThan(end.novelty, 0.6, "fewer surprises once settled")
        XCTAssertEqual(end.swell, 0)
        // monotonic, no jumps
        var prev = s0
        for t in stride(from: 1.0, through: 600, by: 1) {
            let s = SessionArc.state(elapsed: t, inductionMinutes: 10, sessionSeconds: nil, mode: .focus, targetRate: 16)
            XCTAssertGreaterThanOrEqual(s.depthScale, prev.depthScale)
            XCTAssertLessThan(abs(s.rate - prev.rate), 0.05)
            prev = s
        }
    }

    func testSleepArcDescends() {
        let a = SessionArc.state(elapsed: 0, inductionMinutes: 15, sessionSeconds: nil, mode: .sleep, targetRate: 2.5)
        let b = SessionArc.state(elapsed: 900, inductionMinutes: 15, sessionSeconds: nil, mode: .sleep, targetRate: 2.5)
        XCTAssertGreaterThan(a.rate, b.rate)
        XCTAssertEqual(b.rate, 2.5, accuracy: 1e-9)
    }

    func testTimedSessionEasesOut() {
        let s = SessionArc.state(elapsed: 25 * 60 - 10, inductionMinutes: 5, sessionSeconds: 25 * 60, mode: .focus, targetRate: 16)
        XCTAssertEqual(s.phase, .windingDown)
        XCTAssertLessThan(s.depthScale, 0.7)
        XCTAssertLessThan(s.rate, 14)
    }

    func testDisabledArcIsFullStrength() {
        let s = SessionArc.state(elapsed: 0, inductionMinutes: 0, sessionSeconds: nil, mode: .focus, targetRate: 16)
        XCTAssertEqual(s, ArcState(phase: .sustaining, energy: 1, depthScale: 1, rate: 16, density: 1, tempoBlend: 1, novelty: 1, swell: 0))
    }

    /// Rendered audio: early in an ease-in the modulation is weaker and slower; later it is at full rate.
    func testEngineEasesIntoTheModulation() {
        var p = EngineParams(); p.inductionMinutes = 2; p.intensity = 1; p.rampInSeconds = 0.01
        let core = SynthCore(bank: SessionArcTests.bank, seed: 3, style: .romantic)
        core.setParams(p); core.startSession(fadeInSeconds: 0.01)
        let x = core.renderOffline(seconds: 150).left
        let early = AudioAnalysis.envelope(Array(x[Int(sr * 4)..<Int(sr * 24)]), sampleRate: sr)
        let late = AudioAnalysis.envelope(Array(x[Int(sr * 125)..<Int(sr * 150)]), sampleRate: sr)
        let pe = AudioAnalysis.envelopePeak(early, envRate: 500, band: 8...20)
        let pl = AudioAnalysis.envelopePeak(late, envRate: 500, band: 8...20)
        XCTAssertLessThan(pe.freq, 12.5, "starts slower (≈10 Hz)")
        XCTAssertEqual(pl.freq, 16, accuracy: 0.15, "arrives at the target")
        XCTAssertGreaterThan(pl.magnitude, pe.magnitude * 2.5, "and deeper")
        XCTAssertEqual(core.meters.arcPhase, .sustaining)
    }

    func testComposerStartsCalmerAndSparser() {
        func stats(energy: Double) -> (tempo: Double, notes: Double) {
            let c = Composer(mode: .focus, style: .romantic, seed: 4)
            c.setArc(ArcState(phase: .settling, energy: energy, depthScale: 1, rate: 16, density: 0.7 + 0.3 * energy,
                              tempoBlend: energy, novelty: 1, swell: 0))
            var t = 0.0, n = 0
            for _ in 0..<64 { let b = c.nextBar(); t += b.tempo; n += b.notes.count }
            return (t / 64, Double(n) / 64)
        }
        let start = stats(energy: 0), settled = stats(energy: 1)
        XCTAssertLessThan(start.tempo, settled.tempo - 3)
        XCTAssertLessThan(start.notes, settled.notes)
    }

    func testPulseLockSnapsToBeatAndStaysPhaseAligned() {
        var p = EngineParams(); p.tempoLock = true; p.intensity = 1; p.rampInSeconds = 0.01
        let core = SynthCore(bank: SessionArcTests.bank, seed: 5, style: .baroque)
        core.setParams(p); core.startSession(fadeInSeconds: 0.01)
        let x = core.renderOffline(seconds: 70).left
        let m = core.meters
        XCTAssertTrue(m.pulseLocked)
        XCTAssertEqual(m.modRate, 16, accuracy: 1.6)
        let tempoHz = m.beatHz
        let k = (m.modRate / tempoHz).rounded()
        XCTAssertEqual(m.modRate, k * tempoHz, accuracy: 0.05, "a whole multiple of the beat")
        let errs = core.debugLockErrors.filter { !$0.isNaN }.suffix(20)
        XCTAssertGreaterThan(errs.count, 10)
        XCTAssertLessThan(errs.map(abs).reduce(0, +) / Double(errs.count), 0.25, "phase-aligned at bar starts")
        // still a clear modulation peak near the target
        let pk = AudioAnalysis.envelopePeak(AudioAnalysis.envelope(Array(x[Int(sr * 20)...]), sampleRate: sr), envRate: 500, band: 12...20)
        XCTAssertGreaterThan(pk.prominence, 10)
        XCTAssertEqual(AudioAnalysis.clickCount(Array(x[Int(sr)...])).count, 0)
    }

    func testBreathSwellAddsSlowSwellOnlyWhileSettling() {
        func swellEnergy(_ on: Bool) -> Double {
            var p = EngineParams(); p.inductionMinutes = 10; p.breathSwell = on; p.amEnabled = false
            let core = SynthCore(bank: SessionArcTests.bank, seed: 6, style: .minimalist)
            core.setParams(p); core.startSession(fadeInSeconds: 0.01)
            let x = Array(core.renderOffline(seconds: 70).left[Int(sr * 5)...])
            return AudioAnalysis.envelopeMagnitude(AudioAnalysis.envelope(x, sampleRate: sr, envRate: 50), envRate: 50, at: 0.1)
        }
        XCTAssertGreaterThan(swellEnergy(true), swellEnergy(false))
    }
}
