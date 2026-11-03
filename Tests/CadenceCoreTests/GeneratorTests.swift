import XCTest
@testable import CadenceCore

final class GeneratorTests: XCTestCase {
    /// ~40 minutes of music per mode and seed.
    func bars(_ mode: FocusMode, seed: UInt64, count: Int = 900) -> [Bar] {
        let g = MusicGenerator(mode: mode, seed: seed)
        return (0..<count).map { _ in g.nextBar() }
    }

    func testNotesStayInKey() {
        for mode in FocusMode.allCases { for seed in 1...6 as ClosedRange<UInt64> {
            for b in bars(mode, seed: seed) {
                XCTAssertFalse(b.notes.isEmpty)
                for n in b.notes {
                    XCTAssertTrue(b.allowedPCs.contains(n.midi % 12),
                                  "\(mode) seed \(seed) bar \(b.index): \(n.midi) not in \(b.keyName)\(b.borrowed ? " +borrowed" : "")")
                    if !b.borrowed { XCTAssertTrue(b.scalePCs.contains(n.midi % 12)) }
                }
            }
        }}
    }

    func testRegisterIsPianistic() {
        for b in bars(.focus, seed: 3) { for n in b.notes {
            switch n.hand {
            case .left: XCTAssertTrue((36...72).contains(n.midi), "LH \(n.midi)")
            case .right: XCTAssertTrue((64...81).contains(n.midi), "RH \(n.midi)")
            }
            XCTAssertGreaterThanOrEqual(n.beat, 0)
            XCTAssertLessThan(n.beat, Double(b.beats))
        }}
    }

    func testTempoAndDynamicsInRange() {
        for mode in FocusMode.allCases {
            let p = mode.profile
            var vmin = 127, vmax = 0
            for b in bars(mode, seed: 9) {
                XCTAssertTrue((55.0...80.0).contains(b.tempo), "tempo \(b.tempo)")
                XCTAssertTrue(p.tempoRange.contains(b.tempo), "\(mode) tempo \(b.tempo)")
                for n in b.notes {
                    XCTAssertTrue(p.velocityRange.contains(n.velocity), "\(mode) vel \(n.velocity)")
                    vmin = min(vmin, n.velocity); vmax = max(vmax, n.velocity)
                }
            }
            XCTAssertLessThanOrEqual(vmax, 70, "no loud notes")
            XCTAssertLessThanOrEqual(vmax - vmin, 40, "narrow dynamic range")
        }
    }

    func testTempoChangesAreGradual() {
        let b = bars(.focus, seed: 4)
        for i in 1..<b.count { XCTAssertLessThan(abs(b[i].tempo - b[i - 1].tempo), 4) }
    }

    func testModulatesGraduallyAndNeverRepeatsExactly() {
        let b = bars(.focus, seed: 5, count: 1200)
        let keys = Set(b.map { $0.keyName })
        XCTAssertGreaterThan(keys.count, 2, "should modulate over ~50 minutes")
        let mods = b.filter { $0.modulatedHere }.count
        XCTAssertLessThan(mods, 30)
        // first 100 bars unique-ish: no two 8-bar windows identical
        func sig(_ x: ArraySlice<Bar>) -> [Int] { x.flatMap { $0.notes.map { $0.midi } } }
        var seen = Set<[Int]>()
        for s in stride(from: 0, to: 800, by: 8) { XCTAssertTrue(seen.insert(sig(b[s..<(s + 8)])).inserted) }
    }

    func testModulationUsesPivotChord() {
        let b = bars(.relax, seed: 11, count: 1200)
        for i in 1..<b.count where b[i].modulatedHere {
            XCTAssertTrue(b[i - 1].pivot, "bar before a key change must be a pivot chord")
        }
    }

    func testDensityIsSparse() {
        let b = bars(.sleep, seed: 2)
        let rh = b.map { $0.notes.filter { $0.hand == .right }.count }
        XCTAssertLessThan(Double(rh.reduce(0, +)) / Double(b.count), 2.0)
    }
}
