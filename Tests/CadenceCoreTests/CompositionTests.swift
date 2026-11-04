import XCTest
@testable import CadenceCore

final class CompositionTests: XCTestCase {
    func bars(_ style: CompositionStyle?, _ mode: FocusMode = .focus, seed: UInt64, minutes: Double = 30) -> [Bar] {
        let c = Composer(mode: mode, style: style, seed: seed)
        var out: [Bar] = []
        var m = 0.0
        while m < minutes { let b = c.nextBar(); out.append(b); m += Double(b.beats) / b.tempo }
        return out
    }

    func testEveryNoteBelongsToKeyChordOrLocalScale() {
        for style in CompositionStyle.allCases { for seed: UInt64 in [1, 2, 3] {
            let r = CompositionAnalysis.analyze(bars(style, seed: seed))
            XCTAssertEqual(r.outOfKey, 0, "\(style) seed \(seed)")
            XCTAssertLessThan(Double(r.chromatic) / Double(r.notes), 0.12, "chromaticism stays occasional")
        }}
    }

    func testMelodicDissonancesResolveByStep() {
        for style in CompositionStyle.allCases { for seed: UInt64 in [4, 5] {
            let r = CompositionAnalysis.analyze(bars(style, seed: seed))
            XCTAssertEqual(r.unresolvedDissonances, 0, "\(style) seed \(seed)")
            XCTAssertGreaterThan(r.melodyNonChordTones, 0, "\(style) uses passing tones/suspensions")
        }}
    }

    func testOuterVoicesRarelyMoveInParallelFifthsOrOctaves() {
        for style in CompositionStyle.allCases {
            let r = CompositionAnalysis.analyze(bars(style, seed: 6))
            XCTAssertLessThan(Double(r.outerParallels) / Double(r.chordChanges), 0.03, "\(style)")
        }
    }

    func testMelodyIsSingableAndNotStatic() {
        for style in CompositionStyle.allCases {
            let r = CompositionAnalysis.analyze(bars(style, seed: 7))
            XCTAssertLessThan(r.meanAbsMelodicInterval, 3.0, "\(style) mostly stepwise")
            XCTAssertLessThan(Double(r.melodicLeapsOverSixth) / Double(r.melodyNotes), 0.01, "\(style)")
            XCTAssertLessThanOrEqual(r.maxMelodicLeap, 12, "\(style)")
        }
    }

    func testTempoAndDynamicsStayInRange() {
        for mode in FocusMode.allCases { for style in CompositionStyle.allCases {
            let b = bars(style, mode, seed: 8, minutes: 15)
            let p = mode.profile
            for x in b {
                XCTAssertTrue((55.0...80.0).contains(x.tempo), "\(mode) \(style) tempo \(x.tempo)")
                if !x.phraseEnd { XCTAssertTrue(p.tempoRange.contains(x.tempo), "\(mode) \(style) tempo \(x.tempo)") }
                for n in x.notes { XCTAssertTrue(p.velocityRange.contains(n.velocity), "\(mode) vel \(n.velocity)") }
            }
            for i in 1..<b.count { XCTAssertLessThan(abs(b[i].tempo - b[i - 1].tempo), 6, "gradual tempo") }
        }}
    }

    func testPhrasesEndWithProperCadences() {
        for style in [CompositionStyle.romantic, .baroque, .impressionist] {
            for b in bars(style, seed: 9) where b.phraseEnd {
                guard let cad = b.cadence, let last = b.chords.last else { continue }
                switch cad {
                case .authentic, .plagal:
                    XCTAssertEqual(last.chord.rootPC, last.key.tonic, "\(style) \(cad) ends on I (\(last.chord.symbol))")
                case .half:
                    XCTAssertEqual(last.chord.function, .dominant, "\(style) half cadence ends on a dominant (\(last.chord.symbol))")
                case .deceptive:
                    XCTAssertEqual(last.chord.spec.degree, 5)
                case .open: break
                }
            }
        }
    }

    func testKeyChangesGoThroughTransitionsAndArePaced() {
        let b = bars(.romantic, seed: 10, minutes: 40)
        for i in 1..<b.count where b[i].key != b[i - 1].key {
            XCTAssertTrue(b[i].section == "Transition" || b[i - 1].section == "Transition",
                          "modulation at bar \(i) happens inside a transition (\(b[i - 1].section) → \(b[i].section))")
        }
        let r = CompositionAnalysis.analyze(b)
        XCTAssertLessThan(Double(r.keyChanges) / r.minutes, 2.0, "no more than ~1 key change per 30 s on average")
        XCTAssertGreaterThan(Set(b.map { $0.key }).count, 3, "long-term harmonic development")
    }

    func testThemesReturn() {
        // the "Return" section restates the theme: its melodic contour matches the first statement
        let b = bars(.romantic, seed: 11, minutes: 10)
        func mel(_ section: String, movement: Int) -> [Int] {
            b.filter { $0.section == section && $0.movement == movement }.prefix(4)
                .flatMap { $0.notes.filter { $0.voice == .melody && $0.kind == .chordTone }.map { $0.midi } }
        }
        let theme = mel("Theme", movement: 0), ret = mel("Return", movement: 0)
        XCTAssertFalse(theme.isEmpty); XCTAssertFalse(ret.isEmpty)
        let common = Set(theme).intersection(Set(ret)).count
        XCTAssertGreaterThan(Double(common) / Double(Set(theme).count), 0.6)
    }

    func testStylesAreDistinct() {
        var density: [CompositionStyle: Double] = [:]
        var harmonicRhythm: [CompositionStyle: Double] = [:]
        for s in CompositionStyle.allCases {
            let b = bars(s, seed: 12, minutes: 15)
            let r = CompositionAnalysis.analyze(b)
            density[s] = Double(r.notes) / Double(r.bars)
            harmonicRhythm[s] = Double(b.reduce(0) { $0 + $1.chords.filter { $0.beat > 0 || true }.count }) / Double(b.count)
            XCTAssertEqual(r.styles, [s])
        }
        XCTAssertGreaterThan(harmonicRhythm[.baroque]!, harmonicRhythm[.romantic]!)
        XCTAssertGreaterThan(harmonicRhythm[.romantic]!, harmonicRhythm[.minimalist]!)
        XCTAssertLessThan(density[.minimalist]!, density[.romantic]!)
        // baroque carries independent voices (counter-melody + walking bass)
        let baroque = CompositionAnalysis.analyze(bars(.baroque, seed: 12, minutes: 10))
        XCTAssertGreaterThan(baroque.notesPerBar[.counter] ?? 0, 1.5)
    }

    func testNeverRepeatsVerbatim() {
        let r = CompositionAnalysis.analyze(bars(nil, seed: 13, minutes: 60))
        XCTAssertGreaterThan(r.uniqueFourBarWindows, 0.75, "themes recur by design, but most material is new")
        XCTAssertGreaterThan(r.styles.count, 1, "varied mode visits several styles")
    }

    func testDeterministicForSeed() {
        let a = bars(.impressionist, seed: 14, minutes: 3).flatMap { $0.notes.map { $0.midi } }
        let b = bars(.impressionist, seed: 14, minutes: 3).flatMap { $0.notes.map { $0.midi } }
        XCTAssertEqual(a, b)
    }

    func testStyleChangeIsGracefulAndPrompt() {
        let c = Composer(mode: .focus, style: .romantic, seed: 15)
        for _ in 0..<10 { _ = c.nextBar() }
        c.setStyle(.minimalist)
        var reached = -1
        for i in 0..<40 { if c.nextBar().style == .minimalist { reached = i; break } }
        XCTAssertTrue((0..<24).contains(reached), "new style within a phrase + codetta (\(reached) bars)")
    }

    func testThreeHourRunIsStable() {
        let c = Composer(mode: .focus, style: nil, seed: 16)
        var m = 0.0, bars = 0
        while m < 180 { let b = c.nextBar(); m += Double(b.beats) / b.tempo; bars += 1
            XCTAssertFalse(b.notes.isEmpty && b.chords.isEmpty) }
        XCTAssertGreaterThan(bars, 2500)
    }
}
