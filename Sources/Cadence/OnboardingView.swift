import SwiftUI
import CadenceCore

struct OnboardingView: View {
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        VStack(spacing: 20) {
            Group {
                switch page {
                case 0:
                    panel("pianokeys", "Music composed as you listen",
                          "Cadence writes calm, original piano music in real time: never looping, never quite the same, and quiet enough to stay in the background.")
                case 1:
                    panel("waveform.path", "A gentle rhythmic layer",
                          "An optional fast, smooth rise and fall in loudness, inspired by research on rhythmic auditory stimulation. It works on speakers or headphones. Effects vary from person to person; adjust Intensity, or switch it off in Settings.")
                default:
                    VStack(spacing: 14) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 38)).foregroundStyle(.tint)
                        Text("Choose how you'd like to listen").font(.title3.weight(.semibold))
                        HStack(spacing: 10) {
                            ForEach(FocusMode.allCases) { m in
                                Button { player.selectMode(m) } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: m.symbol)
                                        Text(m.title).font(.callout.weight(.medium))
                                        Text(m.blurb).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    }
                                    .frame(width: 118, height: 86)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(player.settings.mode == m ? m.tint.opacity(0.18) : Color.primary.opacity(0.05)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(player.settings.mode == m ? .isSelected : [])
                            }
                        }
                    }
                }
            }
            .frame(height: 200)
            .transition(.opacity)
            HStack {
                ForEach(0..<3) { i in Circle().fill(i == page ? player.settings.mode.tint : Color.secondary.opacity(0.3)).frame(width: 6, height: 6) }
                    .accessibilityHidden(true)
                Spacer()
                if page > 0 { Button("Back") { withAnimation { page -= 1 } } }
                Button(page < 2 ? "Continue" : "Start listening") {
                    if page < 2 { withAnimation { page += 1 } }
                    else {
                        player.settings.onboarded = true
                        dismiss()
                        player.start()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 440)
        .tint(player.settings.mode.tint)
    }

    private func panel(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
