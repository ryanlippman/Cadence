import Foundation

/// Turns voiced harmony into idiomatic piano accompaniment figures.
enum Texture {
    static func accompany(plan: PhrasePlan, voicings: [Voicing], figuration: Figuration, density: Double,
                          cellCounter: inout Int) -> [(MelNote, VoiceRole)] {
        var out: [(MelNote, VoiceRole)] = []
        let B = Double(plan.beatsPerBar)
        func add(_ beat: Double, _ dur: Double, _ midi: Int, _ role: VoiceRole, slotEnd: Double) {
            guard beat < slotEnd - 1e-9 else { return }
            out.append((MelNote(beat: beat, dur: max(0.1, min(dur, slotEnd - beat + 0.5)), midi: midi, kind: .accompaniment, structural: false), role))
        }
        for (si, slot) in plan.slots.enumerated() {
            let v = voicings[si]
            let b = v.bass, t = v.upper[0], a = v.upper[1], s = v.upper[2]
            let end = slot.end
            switch figuration {
            case .gymnopedie:
                var bar = (slot.start / B).rounded(.down) * B
                if bar < slot.start { bar += B }
                var first = true
                var x = slot.start
                while x < end - 1e-9 {
                    add(x, first ? slot.length : B, b, .bass, slotEnd: end)
                    for p in [t, a, s] { add(x + 1, B - 1, p, .inner, slotEnd: end) }
                    first = false
                    x += B
                }
            case .ostinato:
                add(slot.start, slot.length, b, .bass, slotEnd: end)
                let cell = [a, s, t]
                let step = density >= 0.8 ? 0.5 : 1.0
                var x = slot.start
                while x < end - 1e-9 {
                    add(x, step * 1.5, cell[cellCounter % 3], .inner, slotEnd: end)
                    cellCounter += 1
                    x += step
                }
            case .rolled:
                let chord = [b - 12 >= 31 ? b - 12 : b, b, t, a, s]
                var seen = Set<Int>()
                var k = 0
                for p in chord where !seen.contains(p) {
                    seen.insert(p)
                    add(slot.start + Double(k) * 0.08, slot.length, p, k < 2 ? .bass : .inner, slotEnd: end)
                    k += 1
                }
                if slot.length >= 4 {
                    add(slot.start + slot.length / 2, slot.length / 2, a, .inner, slotEnd: end)
                    add(slot.start + slot.length / 2 + 0.5, slot.length / 2 - 0.5, s, .inner, slotEnd: end)
                }
            case .nocturne:
                let x = (b + 7...b + 12).first { slot.chord.pcs.contains(mod12($0)) } ?? b + 12
                let ups = [t, a].map { $0 <= x ? $0 + 12 : $0 }
                let fig: [Int] = density >= 0.85 ? [b, x, ups[0], ups[1], ups[0], x] : [b, x, ups[0], ups[1]]
                let d = 2.0 / Double(fig.count)
                var u = slot.start
                while u < end - 1e-9 {
                    for (k, p) in fig.enumerated() {
                        add(u + Double(k) * d, k == 0 ? 2 : d * 2.5, p, k == 0 ? .bass : .inner, slotEnd: end)
                    }
                    u += 2
                }
            case .alberti:
                add(slot.start, slot.length, b, .bass, slotEnd: end)
                let fig = density >= 0.85 ? [t, s, a, s] : [t, s]
                let d = 2.0 / Double(fig.count)
                var u = slot.start
                while u < end - 1e-9 {
                    for (k, p) in fig.enumerated() { add(u + Double(k) * d, d * 1.5, p, .inner, slotEnd: end) }
                    u += 2
                }
            case .prelude:
                var u = slot.start
                while u < end - 1e-9 {
                    add(u, 2, b, .bass, slotEnd: end)
                    if density >= 0.85 {
                        add(u + 0.5, 1.5, t, .inner, slotEnd: end)
                        add(u + 1.0, 0.5, a, .inner, slotEnd: end)
                        add(u + 1.5, 0.5, s, .inner, slotEnd: end)
                    } else {
                        add(u + 1.0, 1.0, a, .inner, slotEnd: end)
                    }
                    u += 2
                }
            case .walking:
                break // bass line and counter-voice are composed separately
            }
        }
        return out
    }

    /// Legato pedalling: lift just after each new harmony is struck, catch it again a moment later.
    static func pedal(plan: PhrasePlan, style: StyleProfile.PedalStyle, dice: Dice) -> [PedalEvent] {
        guard style != .none else { return [] }
        var ev: [PedalEvent] = []
        for (i, slot) in plan.slots.enumerated() {
            if style == .long, i > 0, dice.chance(0.25),
               plan.slots[i - 1].chord.pcs.intersection(slot.chord.pcs).count >= 2 { continue }   // let it blur
            ev.append(PedalEvent(beat: slot.start + 0.04, down: false))
            ev.append(PedalEvent(beat: slot.start + 0.22, down: true))
        }
        return ev
    }
}
