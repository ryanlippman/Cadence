import XCTest
@testable import CadenceCore

final class SamplerTests: XCTestCase {
    static var bank: SampleBank = { try! SampleBank.loadBundled() }()

    func testBankLoadsAndCoversRange() {
        let b = SamplerTests.bank
        XCTAssertEqual(b.zones.count, 66)
        XCTAssertEqual(b.centers.first, 33)
        XCTAssertEqual(b.centers.last, 96)
    }

    func testNoteIsAudibleAndPitchedCorrectly() {
        // Play A3 (220 Hz) from a C3-shifted... A3 is a recorded centre; also test a shifted note (B3 ~ 246.94 Hz).
        for (midi, freq) in [(57, 220.0), (59, 246.94), (70, 466.16)] {
            let sr = 44100.0
            let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
            s.noteOn(midi: midi, velocity: 50, holdSamples: Int(sr), delay: 0)
            let n = 22050
            var l = [Float](repeating: 0, count: n), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                s.render(outL: lp.baseAddress!, outR: rp.baseAddress!, frames: n)
            }}
            XCTAssertGreaterThan(l.map(abs).max()!, 0.01, "silent for midi \(midi)")
            // Estimate fundamental via autocorrelation on 0.1..0.4 s
            let seg = Array(l[4410..<(4410 + 8192)])
            var best = 0, bestV: Float = -1
            let lo = Int(sr / (freq * 1.2)), hi = Int(sr / (freq * 0.8))
            for lag in lo...hi {
                var acc: Float = 0
                for i in 0..<(seg.count - lag) { acc += seg[i] * seg[i + lag] }
                if acc > bestV { bestV = acc; best = lag }
            }
            let est = sr / Double(best)
            XCTAssertEqual(est, freq, accuracy: freq * 0.02, "pitch off for midi \(midi): \(est)")
        }
    }

    func testVelocityMonotonic() {
        func peak(_ vel: Int) -> Float {
            let sr = 44100.0
            let s = Sampler(bank: SamplerTests.bank, sampleRate: sr)
            s.noteOn(midi: 60, velocity: vel, holdSamples: 20000, delay: 0)
            var l = [Float](repeating: 0, count: 20000), r = l
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                s.render(outL: lp.baseAddress!, outR: rp.baseAddress!, frames: 20000) }}
            return l.map(abs).max()!
        }
        let p = [30, 40, 47, 53, 65, 76, 90].map(peak)
        for i in 1..<p.count { XCTAssertGreaterThan(p[i], p[i - 1] * 0.95) }; XCTAssertGreaterThan(p.last!, p.first! * 3)
    }
}
