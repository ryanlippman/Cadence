import SwiftUI
import CadenceCore

/// A quiet, living ring: it breathes with the music's loudness, and its fine ripple count mirrors the
/// modulation rate (drawn slowly — the real 16 Hz would flicker). Static when Reduce Motion is on.
struct Visualizer: View {
    @ObservedObject var player: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Smoothing state lives in a reference so per-frame updates don't invalidate the view.
    private final class Smooth { var level = 0.0; var depth = 0.0 }
    @State private var smooth = Smooth()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || reduceMotion)) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let m = player.meters()
                let mode = player.settings.mode
                let target = player.isPlaying ? min(1, Double(m?.rms ?? 0) * 7) : 0
                smooth.level += (target - smooth.level) * 0.12
                smooth.depth += ((player.isPlaying ? (m?.amDepth ?? 0) : 0) - smooth.depth) * 0.05
                let lvl = smooth.level, dep = smooth.depth
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) * 0.36
                let lobes = Double(max(3, min(20, Int(player.settings.rate(for: mode).rounded()))))
                let rot = reduceMotion ? 0 : t * 0.15
                for layer in 0..<3 {
                    var path = Path()
                    let k = Double(layer)
                    for i in 0...240 {
                        let a = Double(i) / 240 * 2 * .pi
                        let ripple = player.settings.amEnabled ? dep * 5 * sin(lobes * a + rot * (1 + k * 0.3) + k) : 0
                        let r = base + k * 7 + lvl * 9 * (1 - k * 0.25) + ripple
                        let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                    let opacity = player.isPlaying ? (0.55 - k * 0.17) : 0.18 - k * 0.05
                    g.stroke(path, with: .color(mode.tint.opacity(opacity)), lineWidth: layer == 0 ? 2 : 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
