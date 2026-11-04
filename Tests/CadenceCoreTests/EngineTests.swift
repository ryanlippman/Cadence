import XCTest
@testable import CadenceCore

final class EngineTests: XCTestCase {
    static let bank: SampleBank = { try! SampleBank.loadBundled() }()
    let sr = SynthCore.internalSampleRate

    func testOutputIsCleanBoundedAndClickFree() {
        for style in CompositionStyle.allCases {
            let core = SynthCore(bank: EngineTests.bank, seed: 2, style: style)
            var p = EngineParams(); p.style = style; p.volume = 1; p.amEnabled = false
            core.setParams(p); core.startSession(fadeInSeconds: 0.5)
            let x = core.renderOffline(seconds: 40).left
            XCTAssertFalse(AudioAnalysis.hasNonFinite(x))
            XCTAssertLessThanOrEqual(AudioAnalysis.peak(x), 0.996)
            XCTAssertEqual(AudioAnalysis.clickCount(Array(x[Int(sr)...])).count, 0, "\(style)")
            XCTAssertEqual(core.debugSteals, 0, "\(style) never needs hard voice stealing")
        }
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
