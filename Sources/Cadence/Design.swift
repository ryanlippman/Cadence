import SwiftUI
import CadenceCore

extension FocusMode {
    var symbol: String {
        switch self { case .focus: return "scope"; case .relax: return "leaf"; case .sleep: return "moon.stars" }
    }
    var blurb: String {
        switch self {
        case .focus: return "Steady, unhurried, for deep work"
        case .relax: return "Softer and more spacious"
        case .sleep: return "Slowest, quietest, darkest"
        }
    }
    var tint: Color {
        switch self {
        case .focus: return Color(red: 0.42, green: 0.48, blue: 0.95)
        case .relax: return Color(red: 0.25, green: 0.70, blue: 0.62)
        case .sleep: return Color(red: 0.58, green: 0.45, blue: 0.85)
        }
    }
}

extension CompositionStyle {
    var symbol: String {
        switch self {
        case .minimalist: return "circle.dotted"
        case .impressionist: return "drop"
        case .romantic: return "moon"
        case .baroque: return "point.3.connected.trianglepath.dotted"
        }
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up)); let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func rateText(_ r: Double) -> String { r == r.rounded() ? "\(Int(r)) Hz" : String(format: "%.1f Hz", r) }

/// Compact labelled slider row with an accessible value.
struct LabeledSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var display: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 18)
                .accessibilityHidden(true)
            Text(title).frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(display(value))
            Text(display(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .font(.callout)
    }
}
