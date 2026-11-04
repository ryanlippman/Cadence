import XCTest
@testable import CadenceCore

final class EngineTests: XCTestCase {
    static let bank: SampleBank = { try! SampleBank.loadBundled() }()
    let sr = SynthCore.internalSampleRate

    func testOutputIsCleanBoundedAndClickFree() {
        for style in CompositionStyle.allCases { for mode in FocusMode.allCases {
            let core = SynthCore(bank: EngineTests.bank, seed: 2, style: style, mode: mode)
            var p = EngineParams(); p.style = style; p.mode = mode; p.rateHz = mode.defaultRate
            p.volume = 1; p.intensity = 1; p.rampInSeconds = 0.01
            core.setParams(p); core.startSession(fadeInSeconds: 0.5)
            let x = core.renderOffline(seconds: 45).left
            XCTAssertFalse(AudioAnalysis.hasNonFinite(x))
            XCTAssertLessThanOrEqual(AudioAnalysis.peak(x), 0.996)
            XCTAssertEqual(AudioAnalysis.clickCount(Array(x[Int(sr)...])).count, 0, "\(style) \(mode)")
            XCTAssertEqual(core.debugSteals, 0, "\(style) never needs hard voice stealing")
        }}
    }

    func testAllNewOptionsTogetherAreCleanAndTogglingNeverClicks() {
        let core = SynthCore(bank: EngineTests.bank, seed: 6, style: .romantic, mode: .focus)
        var p = EngineParams(); p.volume = 1; p.intensity = 1; p.rampInSeconds = 0.01
        p.strength = .strong; p.waveform = .ramp; p.stereo = .alternating; p.band = .upper
        p.spatial = true; p.slowVariation = true
        core.setParams(p); core.startSession(fadeInSeconds: 0.5)
        var o = core.renderOffline(seconds: 20)
        // toggle everything mid-stream
        p.spatial = false; p.stereo = .together; p.band = .full; p.waveform = .pulse; p.strength = .gentle
        core.setParams(p)
        let o2 = core.renderOffline(seconds: 10)
        o.left += o2.left; o.right += o2.right
        for x in [o.left, o.right] {
            XCTAssertFalse(AudioAnalysis.hasNonFinite(x))
            XCTAssertLessThanOrEqual(AudioAnalysis.peak(x), 0.996)
            XCTAssertEqual(AudioAnalysis.clickCount(Array(x[Int(sr)...])).count, 0)
        }
        // Strong at 16 Hz is clearly present in the envelope
        let env = AudioAnalysis.envelope(Array(o.left[Int(sr * 5)..<Int(sr * 20)]), sampleRate: sr)
        let pk = AudioAnalysis.envelopePeak(env, envRate: 500, band: 10...22)
        XCTAssertEqual(pk.freq, 16, accuracy: 1.2)
    }

    func testModeSwitchKeepsMusicPlaying() {
        let core = SynthCore(bank: EngineTests.bank, seed: 4, style: .romantic)
        var p = EngineParams(); p.rampInSeconds = 0.01
        core.setParams(p); core.startSession(fadeInSeconds: 0.01)
        var x = core.renderOffline(seconds: 25).left
        p.mode = .sleep; p.rateHz = FocusMode.sleep.defaultRate
        core.setParams(p)
        x += core.renderOffline(seconds: 25).left
        let st = AudioAnalysis.shortTermDB(Array(x[Int(sr * 10)...]), sampleRate: sr, window: 1.0, hop: 0.25)
        XCTAssertGreaterThan(st.min()!, AudioAnalysis.percentile(st, 0.5) - 18, "no silence gap at the switch")
        XCTAssertEqual(AudioAnalysis.clickCount(Array(x[Int(sr * 20)..<Int(sr * 32)])).count, 0)
    }

    func testAfterSwitchingToSleepTheModulationRunsAtTheSleepRate() {
        func tail(am: Bool) -> [Double] {
            let core = SynthCore(bank: EngineTests.bank, seed: 4, style: .romantic)
            var p = EngineParams(); p.rampInSeconds = 0.01; p.intensity = 1; p.amEnabled = am
            core.setParams(p); core.startSession(fadeInSeconds: 0.01)
            _ = core.renderOffline(seconds: 20)
            p.mode = .sleep; p.rateHz = FocusMode.sleep.defaultRate
            core.setParams(p)
            let x = core.renderOffline(seconds: 40).left
            return AudioAnalysis.envelope(Array(x[Int(sr * 10)...]), sampleRate: sr)
        }
        let on = tail(am: true), off = tail(am: false)
        let at25 = AudioAnalysis.envelopeMagnitude(on, envRate: 500, at: 2.5) / AudioAnalysis.envelopeMagnitude(off, envRate: 500, at: 2.5)
        let at16 = AudioAnalysis.envelopeMagnitude(on, envRate: 500, at: 16) / AudioAnalysis.envelopeMagnitude(off, envRate: 500, at: 16)
        XCTAssertGreaterThan(at25, 4, "modulation energy now at 2.5 Hz")
        XCTAssertLessThan(at16, 1.5, "and no longer at the Focus rate")
    }

    func testFadeOutAndResume() {
        let core = SynthCore(bank: EngineTests.bank, seed: 5)
        core.setParams(EngineParams()); core.startSession(fadeInSeconds: 0.5)
        _ = core.renderOffline(seconds: 4)
        core.beginFadeOut(seconds: 2)
        let tail = core.renderOffline(seconds: 3).left
        XCTAssertLessThan(AudioAnalysis.peak(Array(tail.suffix(Int(sr)))), 1e-6)
        XCTAssertTrue(core.fadeFinished)
        core.resume(fadeInSeconds: 1)
        XCTAssertGreaterThan(AudioAnalysis.rms(Array(core.renderOffline(seconds: 4).left.suffix(Int(sr * 2)))), 1e-3)
    }

    func testResetSilencesWithoutTouchingSamplerFromCallerThread() {
        let core = SynthCore(bank: EngineTests.bank, seed: 6)
        core.setParams(EngineParams()); core.startSession(fadeInSeconds: 0.01)
        _ = core.renderOffline(seconds: 5)
        XCTAssertGreaterThan(core.meters.activeVoices, 0)
        core.resetPlayback()
        // render directly (no further scheduling): ringing notes fade out, nothing new starts
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<60 {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                core.render(left: lp.baseAddress!, right: rp.baseAddress!, frames: 512) }}
        }
        XCTAssertEqual(core.meters.activeVoices, 0, "ringing notes fade; only the reverb tail remains")
    }

    /// Scheduling and control run on other threads while the "audio thread" renders.
    func testConcurrentControlAndRenderingIsSafe() {
        let core = SynthCore(bank: EngineTests.bank, seed: 8)
        core.setParams(EngineParams()); core.startSession(fadeInSeconds: 0.01)
        let done = expectation(description: "render")
        var produced = 0.0
        DispatchQueue.global(qos: .userInteractive).async {
            var l = [Float](repeating: 0, count: 256), r = l
            for _ in 0..<(Int(self.sr * 20) / 256) {
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                    core.render(left: lp.baseAddress!, right: rp.baseAddress!, frames: 256) }}
                produced += AudioAnalysis.rms(l)
            }
            done.fulfill()
        }
        let stop = Date().addingTimeInterval(1.5)
        var i = 0
        while Date() < stop {
            core.topUp()
            var p = EngineParams(); p.mode = FocusMode.allCases[i % 3]; p.style = CompositionStyle.allCases[i % 4]
            p.intensity = Double(i % 10) / 10
            core.setParams(p)
            _ = core.currentStatus; _ = core.meters
            i += 1
        }
        wait(for: [done], timeout: 60)
        XCTAssertGreaterThan(produced, 0)
    }

    func testLongSessionIsStable() {
        // 20 minutes, varied styles, mode changes: no NaN, bounded voices, level stays in a sane band
        let core = SynthCore(bank: EngineTests.bank, seed: 9, style: nil)
        var p = EngineParams(); p.style = nil
        core.setParams(p); core.startSession(fadeInSeconds: 1)
        var levels: [Double] = []
        for minute in 0..<20 {
            if minute == 7 { p.mode = .relax; core.setParams(p) }
            if minute == 14 { p.mode = .focus; core.setParams(p) }
            let x = core.renderOffline(seconds: 60).left
            XCTAssertFalse(AudioAnalysis.hasNonFinite(x))
            levels.append(AudioAnalysis.db(AudioAnalysis.rms(x)))
            XCTAssertLessThan(core.meters.activeVoices, Sampler.maxVoices)
        }
        XCTAssertLessThan(levels.max()! - levels.min()!, 12, "consistent loudness over time: \(levels)")
        XCTAssertGreaterThan(core.currentStatus.movement, 3)
    }
}
