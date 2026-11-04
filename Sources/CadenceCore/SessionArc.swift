import Foundation

/// Where a listening session is in its arc.
public enum ArcPhase: UInt8, Sendable, CaseIterable {
    case settling, deepening, sustaining, windingDown

    public func title(for mode: FocusMode) -> String {
        switch (self, mode) {
        case (.settling, _): return "Settling in"
        case (.deepening, .focus): return "Deepening focus"
        case (.deepening, .relax): return "Unwinding"
        case (.deepening, .sleep): return "Drifting down"
        case (.sustaining, .focus): return "Sustained focus"
        case (.sustaining, .relax): return "Deep rest"
        case (.sustaining, .sleep): return "Deep calm"
        case (.windingDown, _): return "Winding down"
        }
    }
}

/// Everything the arc modulates at one moment of a session.
public struct ArcState: Sendable, Equatable {
    public var phase: ArcPhase
    /// 0 = just started, 1 = fully settled.
    public var energy: Double
    /// Multiplies the modulation depth.
    public var depthScale: Double
    /// Modulation rate (Hz) before any pulse-locking.
    public var rate: Double
    /// Multiplies musical density (notes per bar).
    public var density: Double
    /// 0 = calm starting tempo, 1 = the mode's normal tempo.
    public var tempoBlend: Double
    /// Multiplies the chance of attention-grabbing events (key excursions, style changes).
    public var novelty: Double
    /// Amount of the slow breathing-paced swell (0…1).
    public var swell: Double
}

/// The session arc: instead of starting at full strength, a session eases in over several minutes —
/// lower modulation depth, a slower starting rate that glides to the target, calmer and sparser music —
/// then holds steady with fewer surprises, and (for timed sessions) eases back down at the end.
///
/// This shapes the listening experience gradually; it is not a claim that a particular mental state is
/// induced. Effects vary between people.
public enum SessionArc {
    /// Modulation rate a session starts from before gliding to the mode's target.
    public static func startRate(for mode: FocusMode) -> Double {
        switch mode { case .focus: return 10; case .relax: return 11; case .sleep: return 6 }
    }
    /// Tempo (BPM) the music starts from during the ease-in.
    public static func startTempo(for mode: FocusMode) -> Double {
        switch mode { case .focus: return 60; case .relax: return 66; case .sleep: return 60 }
    }

    @inline(__always) static func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    /// - Parameters:
    ///   - elapsed: seconds since the session started
    ///   - inductionMinutes: ease-in length; 0 disables the arc entirely (always full strength)
    ///   - sessionSeconds: total length of a timed session, or nil/0 for open-ended
    public static func state(elapsed t: Double, inductionMinutes: Double, sessionSeconds: Double?,
                             mode: FocusMode, targetRate: Double) -> ArcState {
        let ind = max(0, inductionMinutes) * 60
        let on = ind > 0
        var e = on ? smooth(t / ind) : 1
        var phase: ArcPhase = !on || t >= ind ? .sustaining : (t < ind * 0.3 ? .settling : .deepening)
        if let s = sessionSeconds, s > 0 {
            let cool = min(180, s / 6)
            if t > s - cool {
                let x = smooth((t - (s - cool)) / cool)
                e *= 1 - 0.6 * x
                phase = .windingDown
            }
        }
        let start = startRate(for: mode)
        return ArcState(
            phase: phase,
            energy: e,
            depthScale: 0.2 + 0.8 * e,
            rate: start + (targetRate - start) * e,
            density: 0.7 + 0.3 * e,
            tempoBlend: e,
            novelty: on ? 1 - 0.45 * e : 1,
            swell: on ? max(0, 1 - e * 1.4) : 0)
    }
}
