import XCTest
@testable import CadenceCore

final class SamplerTests: XCTestCase {
    static let bank: SampleBank = { try! SampleBank.loadBundled() }()
    let sr = SynthCore.internalSampleRate

    func render(_ s: Sampler, _ frames: Int) -> [Float] {
        var l = [Float](repeating: 0, count: frames), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            s.render(outL: lp.baseAddress!, outR: rp.baseAddress!, frames: frames) }}
        return l
    }

    func testBankLoadsLosslessSubset() {
        let b = SamplerTests.bank
        XCTAssertEqual(b.zones.count, 88, "22 pitches × 4 velocity layers")
        XCTAssertEqual(b.releaseZones.count, 22)
        XCTAssertEqual(b.centers.first, 33)
        XCTAssertEqual(b.centers.last, 96)
        XCTAssertLessThan(b.residentBytes, 150_000_000)
    }

    func testRawSamplesHaveNoCodecSpikes() {
        // the previous AAC encode produced isolated spikes in attacks; ALAC must be clean
        for z in SamplerTests.bank.zones {
            let n = min(z.frames, Int(z.sampleRate * 0.5))
            let x = (0..<n).map { Float(z.left[$0]) / 32768 }
            XCTAssertEqual(AudioAnalysis.clickCount(x).count, 0, "zone \(z.centerMidi) v\(z.layerVelocity)")
        }
    }

    func testPitchAccuracyIncludingShiftedNotes() {
        for (midi, freq) in [(57, 220.0), (59, 246.94), (70, 466.16), (40, 82.41)] {
            let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
            s.noteOn(midi: midi, velocity: 50, holdSamples: Int(sr))
            let l = render(s, Int(sr * 0.6))
            XCTAssertGreaterThan(l.map(abs).max()!, 0.01)
            let seg = Array(l[Int(sr * 0.1)..<(Int(sr * 0.1) + 8192)])
            var best = 0, bestV: Float = -1
            for lag in Int(sr / (freq * 1.2))...Int(sr / (freq * 0.8)) {
                var acc: Float = 0
                for i in 0..<(seg.count - lag) { acc += seg[i] * seg[i + lag] }
                if acc > bestV { bestV = acc; best = lag }
            }
            XCTAssertEqual(sr / Double(best), freq, accuracy: freq * 0.015, "midi \(midi)")
        }
    }

    func testVelocityIsMonotonicAcrossLayers() {
        func level(_ vel: Int) -> Double {
            let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
            s.noteOn(midi: 60, velocity: vel, holdSamples: 30000)
            return AudioAnalysis.rms(render(s, 14400))
        }
        let v = [26, 36, 40, 45, 50, 54, 60, 68, 75].map(level)
        for i in 1..<v.count { XCTAssertGreaterThan(v[i], v[i - 1] * 0.97, "velocity step \(i)") }
        XCTAssertGreaterThan(v.last!, v.first! * 2.5)
    }

    func testPedalSustainsAndDampersStop() {
        func tailEnergy(pedal: Bool) -> Double {
            let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
            if pedal { s.setPedal(true) }
            s.noteOn(midi: 55, velocity: 50, holdSamples: Int(sr * 0.2))
            _ = render(s, Int(sr * 0.5))
            return AudioAnalysis.rms(render(s, Int(sr * 0.5)))
        }
        let held = tailEnergy(pedal: true), damped = tailEnergy(pedal: false)
        XCTAssertGreaterThan(held, damped * 20, "pedal must keep the string ringing after key release")
    }

    func testPedalLiftDampsAndRepedalCatches() {
        let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
        s.setPedal(true)
        s.noteOn(midi: 60, velocity: 50, holdSamples: 100)
        _ = render(s, Int(sr * 0.3))
        s.setPedal(false)
        _ = render(s, Int(sr * 0.02))
        s.setPedal(true)                // caught within 80 ms
        let caught = AudioAnalysis.rms(render(s, Int(sr * 0.3)))
        XCTAssertGreaterThan(caught, 1e-3)
        s.setPedal(false)
        _ = render(s, Int(sr * 0.6))
        XCTAssertLessThan(AudioAnalysis.rms(render(s, Int(sr * 0.2))), 1e-4)
    }

    func testRestrikeDoesNotStackVoices() {
        let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
        s.setPedal(true)
        for _ in 0..<12 { s.noteOn(midi: 64, velocity: 50, holdSamples: 4000); _ = render(s, 4800) }
        XCTAssertLessThanOrEqual(s.activeVoiceCount, 4, "old vibrations fade on re-strike")
    }

    func testDampingProducesNoClicks() {
        let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
        for m in [48, 52, 55, 60, 64] { s.noteOn(midi: m, velocity: 55, holdSamples: Int(sr * 0.3)) }
        let x = render(s, Int(sr * 2))
        XCTAssertEqual(AudioAnalysis.clickCount(x).count, 0)
    }
}
