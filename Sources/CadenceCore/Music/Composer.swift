import Foundation

public struct GeneratedNote: Sendable, Equatable {
    public var beat: Double
    public var durBeats: Double
    public var midi: Int
    public var velocity: Int
    public var voice: VoiceRole
    public var kind: NoteKind
    public enum Hand: Sendable { case left, right }
    public var hand: Hand { voice == .melody || voice == .counter ? .right : .left }
}

public struct PedalEvent: Sendable, Equatable {
    public var beat: Double
    public var down: Bool
}

public struct BarChord: Sendable {
    public var beat: Double
    public var length: Double
    public var chord: Chord
    public var key: Key
    public var scale: Scale
}

public struct Bar: Sendable {
    public var index: Int
    public var tempo: Double
    public var beats: Int
    public var key: Key
    public var chords: [BarChord]
    public var notes: [GeneratedNote]
    public var pedal: [PedalEvent]
    public var style: CompositionStyle
    public var section: String
    public var movement: Int
    public var phraseEnd: Bool
    public var cadence: Cadence?
    public var keyName: String { key.name }
    public func chord(at beat: Double) -> BarChord { chords.last { $0.beat <= beat + 1e-9 } ?? chords[0] }
}

/// Hierarchical composer: movement → sections (A, varied A, bridge, B, retransition, A′, codetta)
/// → periods (antecedent / consequent) → phrases → harmonic slots → voiced notes.
/// Emits one bar at a time, forever, never repeating.
public final class Composer {
    let dice: Dice
    public private(set) var mode: FocusMode
    public private(set) var stylePreference: CompositionStyle?
    public private(set) var style: CompositionStyle
    private var profile: StyleProfile
    public private(set) var currentKey: Key
    private var home: Key
    public private(set) var movement = 0
    private var meter = 4
    private var motif: Motif
    private var motifB: Motif
    private var figA: Figuration
    private var figB: Figuration
    private var ostinatoA: [Int] = [0, 3]
    private var ostinatoB: [Int] = [0, 5, 3, 4]
    private var themes: [String: [(plan: PhrasePlan, melody: [MelNote])]] = [:]
    private var lastVoicing: Voicing?
    private var lastChord: Chord?
    private var lastMelody = 72
    /// Last few melody pitches heard (oldest first), so phrase joins can be smoothed.
    private var melHistory: [Int] = []
    private var lastMelVel: Double?
    private var lastMelodyNeedsStep = false
    private var lastBass: Int?
    private var lastBarNotes: Int?
    private var tempoNow: Double
    private var tempoDrift = 0.0
    private var barIndex = 0
    private var cellCounter = 0
    private var queue: [Bar] = []
    private var jobs: [Job] = []
    private var styleChangePending = false
    /// Session arc (ease-in / sustain / ease-out); nil = full strength, as without an arc.
    private var arc: ArcState?
    private let planner: HarmonicPlanner
    private let leader = VoiceLeader()
    private let melodist: MelodyComposer

    enum Job {
        case theme(label: String, role: PhraseRole, key: Key, recall: Bool, fig: Figuration, display: String)
        case bridge(to: Key)
        case codetta
        case cadentialExtension
    }

    public init(mode: FocusMode, style: CompositionStyle? = nil, seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        dice = Dice(seed: seed)
        self.mode = mode
        stylePreference = style
        let st = style ?? dice.pick([.romantic, .impressionist, .minimalist, .baroque])
        self.style = st
        profile = st.profile
        let m = dice.pick(st.profile.modes)
        home = Key(tonic: dice.pick([0, 2, 3, 5, 7, 8, 9, 10, 4]), mode: m)
        currentKey = home
        planner = HarmonicPlanner(dice: dice)
        melodist = MelodyComposer(dice: dice)
        meter = dice.pick(st.profile.beatsPerBar)
        motif = Motif.make(profile: st.profile, beats: meter, dice: dice)
        motifB = motif
        figA = st.profile.figurations[0]
        figB = figA
        let mp = mode.profile
        tempoNow = mp.tempoRange.lowerBound + st.profile.tempoBias * (mp.tempoRange.upperBound - mp.tempoRange.lowerBound)
    }

    // MARK: control

    /// Focus/relax/sleep: tempo and dynamics glide over the next bars; density changes at the next phrase.
    public func setMode(_ m: FocusMode) { mode = m }

    /// Current point in the session arc: calmer, sparser music while settling in; fewer key excursions
    /// and style changes once settled. Applied from the next bar (tempo, dynamics) or phrase (density).
    public func setArc(_ a: ArcState?) { arc = a }
    private var novelty: Double { arc?.novelty ?? 1 }

    /// nil = vary styles between movements. A change takes effect at the next phrase boundary
    /// through a short codetta and modulation, so the music never stops.
    public func setStyle(_ s: CompositionStyle?) {
        guard s != stylePreference else { return }
        stylePreference = s
        if let s, s != style { styleChangePending = true }
    }

    // MARK: output

    public func nextBar() -> Bar {
        while queue.isEmpty { renderNextJob() }
        return queue.removeFirst()
    }

    // MARK: form

    private func relatedKeys(of k: Key, modes: [ScaleMode]) -> [(Key, Double)] {
        var out: [(Key, Double)] = []
        for m in modes {
            for (off, w) in [(7, 3.0), (5, 2.5), (k.mode.isMinorish ? 3 : 9, 2.0), (0, 0.8)] {
                let c = Key(tonic: k.tonic + off, mode: m)
                if c == k { continue }
                if off == 0 && c.mode == k.mode { continue }
                if off == 3 && !(k.mode.isMinorish && !m.isMinorish) { continue }
                if off == 9 && !(m.isMinorish && !k.mode.isMinorish) { continue }
                if Harmony.pivots(from: k, to: c).isEmpty { continue }
                if out.contains(where: { $0.0 == c }) { continue }
                out.append((c, w))
            }
        }
        if out.isEmpty { out = [(Key(tonic: k.tonic + 7, mode: modes[0]), 1)] }
        return out
    }

    private func planMovement() {
        if styleChangePending || (stylePreference == nil && movement > 0 && dice.chance(0.5 * novelty)) {
            let next = stylePreference ?? dice.pick(CompositionStyle.allCases.filter { $0 != style })
            style = next
            profile = next.profile
            styleChangePending = false
        }
        if !profile.modes.contains(home.mode) {
            home = Key(tonic: home.tonic, mode: profile.modes[0])
        }
        meter = dice.pick(profile.beatsPerBar)
        if style == .minimalist && meter == 3 { figA = .gymnopedie; figB = .ostinato }
        else if style == .minimalist { figA = .ostinato; figB = .ostinato }
        else {
            let f = dice.shuffled(profile.figurations)
            figA = f[0]; figB = f.count > 1 ? f[1] : f[0]
        }
        motif = movement == 0 ? Motif.make(profile: profile, beats: meter, dice: dice) : motif.developed(profile: profile, beats: meter, dice: dice)
        motifB = motif.developed(profile: profile, beats: meter, dice: dice)
        ostinatoA = dice.pick(HarmonicPlanner.ostinati)
        ostinatoB = dice.pick(HarmonicPlanner.ostinati.filter { $0 != ostinatoA })
        themes = [:]
        let A = "A", B = "B"
        // contrasting key area
        var bKey = home
        // the contrasting section stays home sometimes, so key changes stay unhurried
        if dice.chance((style == .baroque ? 1 : (style == .minimalist ? 0.4 : 0.65)) * novelty) {
            let rel = relatedKeys(of: home, modes: profile.modes).filter { $0.0.tonic != home.tonic }
            if !rel.isEmpty { bKey = dice.weighted(rel) }
        }
        var j: [Job] = [
            .theme(label: A, role: .antecedent, key: home, recall: false, fig: figA, display: "Theme"),
            .theme(label: A, role: .consequent, key: home, recall: false, fig: figA, display: "Theme"),
        ]
        if dice.chance(0.75) {
            j += [.theme(label: A, role: .antecedent, key: home, recall: true, fig: figB, display: "Theme, varied"),
                  .theme(label: A, role: .consequent, key: home, recall: true, fig: figB, display: "Theme, varied")]
        }
        if bKey != home { j.append(.bridge(to: bKey)) }
        j += [.theme(label: B, role: .antecedent, key: bKey, recall: false, fig: figB, display: "Contrast"),
              .theme(label: B, role: .consequent, key: bKey, recall: false, fig: figB, display: "Contrast")]
        if bKey != home { j.append(.bridge(to: home)) }
        j += [.theme(label: A, role: .antecedent, key: home, recall: true, fig: figA, display: "Return"),
              .theme(label: A, role: .consequent, key: home, recall: true, fig: figA, display: "Return"),
              .codetta]
        let nextStyleModes = (stylePreference ?? style).profile.modes
        let next = dice.weighted(relatedKeys(of: home, modes: nextStyleModes))
        j.append(.bridge(to: next))
        jobs = j
    }

    private func renderNextJob() {
        if styleChangePending {
            // finish gracefully: short codetta, then a fresh movement in the new style
            jobs = [.codetta]
            styleChangePending = true
            let job = jobs.removeFirst()
            render(job)
            jobs = []
            movement += 1
            planMovement()
            return
        }
        if jobs.isEmpty {
            if barIndex > 0 { movement += 1 }
            planMovement()
        }
        render(jobs.removeFirst())
    }

    // MARK: phrase rendering

    private var density: Double { mode.profile.density * (arc?.density ?? 1) }
    private var melodyRange: ClosedRange<Int> {
        let r = profile.melodyRange
        return mode == .sleep ? r.lowerBound...(r.upperBound - 3) : r
    }

    private func voice(_ plan: PhrasePlan) -> [Voicing] {
        var out: [Voicing] = []
        for (i, s) in plan.slots.enumerated() {
            let cadential = (i == plan.slots.count - 1 && (plan.cadence == .authentic || plan.cadence == .plagal))
                || (i == plan.slots.count - 2 && plan.cadence == .authentic && s.chord.spec.degree == 4)
            let v = leader.voice(s.chord, previous: lastVoicing, previousChord: lastChord, rootPosition: cadential, dice: dice)
            out.append(v)
            lastVoicing = v
            lastChord = s.chord
        }
        return out
    }

    private func render(_ job: Job) {
        let B = meter
        var plan: PhrasePlan
        var melody: [MelNote]
        var fig = figA
        var section = ""
        var role: PhraseRole = .antecedent
        switch job {
        case let .theme(label, r, key, recall, f, display):
            role = r
            fig = f
            section = display
            let idx = r == .antecedent ? 0 : 1
            if recall, let stored = themes[label], stored.count > idx {
                plan = stored[idx].plan
                let voicings = voice(plan)
                melody = octaveFit(melodist.vary(stored[idx].melody, plan: plan))
                let r = melodyRange
                melodist.fixParallels(&melody, plan: plan, voicings: voicings, range: r)
                melodist.resolveDissonances(&melody, plan: plan, range: (r.lowerBound - 2)...(r.upperBound + 2))
                emit(plan: plan, voicings: voicings, melody: melody, fig: fig, section: section, role: role)
                if plan.cadence == .deceptive { emitExtension(key: key, fig: fig, section: section) }
                return
            }
            let isB = label == "B"
            var cadence: Cadence
            if style == .minimalist {
                cadence = r == .antecedent ? .open : (dice.chance(profile.plagalProb) ? .plagal : .authentic)
            } else if r == .antecedent {
                cadence = .half
            } else {
                cadence = dice.chance(profile.deceptiveProb) ? .deceptive : (dice.chance(profile.plagalProb) ? .plagal : .authentic)
            }
            let ost = style == .minimalist ? (isB ? ostinatoB : ostinatoA) : nil
            var prefixSpecs: [ChordSpec] = []
            var prefixMel: [MelNote] = []
            var prefixBeats = 0.0
            let ante = r == .consequent && style != .minimalist ? themes[label]?.first : nil
            if let ante {
                let half = ante.plan.totalBeats / 2
                prefixSpecs = ante.plan.slots.filter { $0.end <= half + 1e-9 }.map { $0.chord.spec }
            }
            plan = planner.plan(key: key, profile: profile, bars: profile.phraseBars, beats: B, cadence: cadence,
                                prefix: prefixSpecs, ostinato: ost)
            if let ante, plan.prefixKept > 0 {
                // copy exactly as much melody as the harmony that was actually kept
                prefixBeats = plan.slots[plan.prefixKept - 1].end
                prefixMel = octaveFit(ante.melody.filter { $0.beat < prefixBeats - 1e-9 }.map {
                    var n = $0; n.dur = min(n.dur, prefixBeats - n.beat); return n
                })
            }
            let voicings = voice(plan)
            melody = melodist.compose(plan: plan, voicings: voicings, motif: isB ? motifB : motif, profile: profile,
                                      density: density, role: r, range: melodyRange, startPitch: lastMelody,
                                      prefix: prefixMel, prefixBeats: prefixBeats)
            themes[label, default: []].append((plan, melody))
            emit(plan: plan, voicings: voicings, melody: melody, fig: fig, section: section, role: role)
            if cadence == .deceptive { emitExtension(key: key, fig: fig, section: section) }
            return
        case .bridge(let to):
            role = .bridge
            section = "Transition"
            let bars = profile.phraseBars >= 8 ? 4 : 2
            plan = planner.bridge(from: currentKey, to: to, profile: profile, bars: bars, beats: B)
            if to == home || jobs.isEmpty { home = to }
        case .codetta:
            role = .codetta
            section = "Codetta"
            let k = currentKey
            let pd: ChordSpec = k.mode.isMinorish ? ChordSpec(3) : (dice.chance(0.4) ? ChordSpec(3, .borrowed) : ChordSpec(1, seventh: true))
            let barsEach = profile.phraseBars >= 8 ? 2 : 1
            let len = Double(B * barsEach)
            plan = PhrasePlan(bars: 2 * barsEach, beatsPerBar: B, slots: [
                HarmonySlot(start: 0, length: len, key: k, chord: Harmony.realize(pd, in: k)),
                HarmonySlot(start: len, length: len, key: k, chord: Harmony.realize(ChordSpec(0, added9: style == .impressionist), in: k)),
            ], cadence: .plagal)
        case .cadentialExtension:
            return
        }
        let voicings = voice(plan)
        melody = melodist.compose(plan: plan, voicings: voicings, motif: motif, profile: profile, density: density,
                                  role: role, range: melodyRange, startPitch: lastMelody)
        emit(plan: plan, voicings: voicings, melody: melody, fig: fig, section: section, role: role)
    }

    /// Restated material (a consequent's opening, a recalled theme) may begin far from where the previous
    /// phrase ended; move it by an octave when that is closer and still fits the range.
    private func octaveFit(_ notes: [MelNote]) -> [MelNote] {
        guard let first = notes.first, abs(first.midi - lastMelody) > 9 else { return notes }
        let r = melodyRange
        let lo = notes.map { $0.midi }.min()!, hi = notes.map { $0.midi }.max()!
        for shift in [first.midi > lastMelody ? -12 : 12] {
            if lo + shift >= r.lowerBound - 2 && hi + shift <= r.upperBound + 2 && abs(first.midi + shift - lastMelody) < abs(first.midi - lastMelody) {
                return notes.map { var n = $0; n.midi += shift; return n }
            }
        }
        return notes
    }

    /// A deceptive cadence demands a short cadential extension that closes properly.
    private func emitExtension(key: Key, fig: Figuration, section: String) {
        let ext = planner.plan(key: key, profile: profile, bars: 2, beats: meter, cadence: .authentic)
        let v2 = voice(ext)
        let m2 = melodist.compose(plan: ext, voicings: v2, motif: motif, profile: profile, density: density,
                                  role: .cadentialExtension, range: melodyRange, startPitch: lastMelody)
        emit(plan: ext, voicings: v2, melody: m2, fig: fig, section: section, role: .cadentialExtension)
    }

    private func emit(plan: PhrasePlan, voicings: [Voicing], melody rawMelody: [MelNote], fig: Figuration, section: String, role: PhraseRole) {
        var melody = rawMelody
        let mr = melodyRange
        let wide = (mr.lowerBound - 2)...(mr.upperBound + 2)
        if let pb = lastBass, let pm = melHistory.last {
            melodist.fixJoinParallel(&melody, plan: plan, voicings: voicings, prevMelody: pm, prevBass: pb,
                                     needsStep: lastMelodyNeedsStep, range: mr)
        }
        melodist.polish(&melody, plan: plan, history: melHistory, historyNeedsStep: lastMelodyNeedsStep, range: wide)
        melodist.fixParallels(&melody, plan: plan, voicings: voicings, range: mr)
        melodist.resolveDissonances(&melody, plan: plan, range: wide)
        var all: [(MelNote, VoiceRole)] = melody.map { ($0, .melody) }
        if fig == .walking {
            all += melodist.walkingBass(plan: plan, voicings: voicings, density: density).map { ($0, .bass) }
        } else {
            all += Texture.accompany(plan: plan, voicings: voicings, figuration: fig, density: density, cellCounter: &cellCounter)
        }
        if fig == .walking || (density >= 0.8 && dice.chance(profile.counterVoiceProb)) {
            all += melodist.counterVoice(plan: plan, voicings: voicings, melody: melody, density: density, range: 55...71).map { ($0, .counter) }
        }
        // warmth: lyrical styles sometimes double a long melody note a third or sixth below
        if style == .romantic || style == .impressionist {
            for n in melody where n.structural && n.kind == .chordTone && n.dur >= 1.5 && dice.chance(0.3) {
                let chord = plan.slot(at: n.beat).chord
                let taken = Set(all.filter { $0.0.beat < n.end - 1e-9 && $0.0.end > n.beat + 1e-9 }.map { $0.0.midi })
                if let d = [n.midi - 3, n.midi - 4, n.midi - 8, n.midi - 9].first(where: { chord.pcs.contains(mod12($0)) && !taken.contains($0) && $0 >= 57 }) {
                    all.append((MelNote(beat: n.beat, dur: n.dur, midi: d, kind: .chordTone, structural: false), .counter))
                }
            }
        }
        let pedal = Texture.pedal(plan: plan, style: profile.pedal, dice: dice)
        if let last = melody.last { lastMelody = last.midi }
        melHistory = Array((melHistory + melody.map { $0.midi }).suffix(3))
        lastBass = voicings.last?.bass
        lastMelodyNeedsStep = melody.last.map { $0.kind.isDissonantByDesign || $0.kind == .suspension } ?? false
        currentKey = plan.endKey

        // tempo: glide toward a slowly drifting target inside the mode's range
        let tr = mode.profile.tempoRange
        tempoDrift = max(-3, min(3, tempoDrift + dice.gauss() * 1.2))
        var target = min(max(tr.lowerBound + profile.tempoBias * (tr.upperBound - tr.lowerBound) + tempoDrift, tr.lowerBound), tr.upperBound)
        if let a = arc, a.tempoBlend < 1 {
            // ease in from a calmer tempo
            let start = SessionArc.startTempo(for: mode)
            target = start + (target - start) * a.tempoBlend
        }
        let arcSoft = (1 - (arc?.energy ?? 1)) * 0.08
        // large-scale dynamics: the contrasting section and codetta a little softer, the return a little fuller
        let sectionLift: Double = ["Contrast": -1.5, "Transition": -1, "Return": 1, "Codetta": -2.5, "Theme, varied": 0.5][section] ?? 0

        let vr = mode.profile.velocityRange
        let lo = Double(vr.lowerBound), span = Double(vr.upperBound - vr.lowerBound)
        let total = plan.totalBeats
        let B = Double(plan.beatsPerBar)
        for bar in 0..<plan.bars {
            let b0 = Double(bar) * B, b1 = b0 + B
            let step = target - tempoNow
            tempoNow += max(-1.2, min(1.2, step))
            var tempo = tempoNow
            if bar == plan.bars - 1 { tempo *= profile.ritardando }
            else { tempo = min(tr.upperBound, tempo * (1 + 0.012 * sin(.pi * Double(bar) / Double(plan.bars)))) }   // gentle phrase rubato
            tempo = min(80, max(55, tempo))
            var notes: [GeneratedNote] = []
            for (n, role) in all where n.beat >= b0 - 1e-9 && n.beat < b1 - 1e-9 {
                let p = n.beat / total
                let arch = sin(.pi * p)
                var base: Double
                switch role { case .melody: base = 0.6; case .counter: base = 0.42; case .bass: base = 0.42; case .inner: base = 0.27 }
                var v = lo + span * (base + 0.12 * arch - arcSoft)
                switch n.kind {
                case .ornament: v -= 3
                case .resolution: v -= 2
                case .appoggiatura, .suspension: v += 1.5
                default: break
                }
                if role == .melody && n.structural { v += 1.5 }
                if abs(n.beat - b0) < 1e-6 && role != .melody { v += 1 }
                if bar == plan.bars - 1 && n.beat >= total - B { v -= 2 }
                v += dice.gauss() * 1.2 + sectionLift
                if role == .melody {
                    // no sudden accents: each melody note within ±6 of the one before
                    if let lv = lastMelVel { v = min(lv + 6, max(lv - 6, v)) }
                    lastMelVel = v
                }
                let vel = min(vr.upperBound, max(vr.lowerBound, Int(v.rounded())))
                notes.append(GeneratedNote(beat: n.beat - b0, durBeats: n.dur, midi: n.midi, velocity: vel, voice: role, kind: n.kind))
            }
            // texture density changes gradually: the first bar of a phrase meets the previous bar halfway
            if bar == 0, let last = lastBarNotes {
                let hiLimit = max(Int(Double(last) * 1.6), last + 4)
                if notes.count > hiLimit {
                    var drop = notes.count - hiLimit
                    for idx in notes.indices.reversed() where drop > 0 {
                        if (notes[idx].voice == .inner || notes[idx].voice == .counter) && notes[idx].beat > 1e-6 {
                            notes[idx].midi = -1; drop -= 1
                        }
                    }
                    notes.removeAll { $0.midi < 0 }
                }
                let loLimit = min(Int(Double(last) / 1.6), last - 4)
                if notes.count < loLimit, let v = voicings.first {
                    // fill empty beats with a soft inner chord tone
                    for beat in 0..<plan.beatsPerBar where notes.count < loLimit {
                        let t = Double(beat)
                        if notes.contains(where: { abs($0.beat - t) < 1e-6 }) { continue }
                        let p = v.upper[0]
                        notes.append(GeneratedNote(beat: t, durBeats: 1, midi: p, velocity: max(vr.lowerBound, Int(lo + span * 0.25)), voice: .inner, kind: .accompaniment))
                    }
                }
            }
            lastBarNotes = notes.count
            let chords = plan.slots.filter { $0.start < b1 - 1e-9 && $0.end > b0 + 1e-9 }.map {
                BarChord(beat: max(0, $0.start - b0), length: $0.length, chord: $0.chord, key: $0.key, scale: $0.scale)
            }
            let ped = pedal.filter { $0.beat >= b0 && $0.beat < b1 }.map { PedalEvent(beat: $0.beat - b0, down: $0.down) }
            let isEnd = bar == plan.bars - 1
            queue.append(Bar(index: barIndex, tempo: tempo, beats: plan.beatsPerBar, key: plan.slot(at: b0).key,
                             chords: chords, notes: notes.sorted { $0.beat < $1.beat }, pedal: ped,
                             style: style, section: section, movement: movement, phraseEnd: isEnd,
                             cadence: isEnd ? plan.cadence : nil))
            barIndex += 1
        }
    }
}
