import SwiftUI
import CadenceCore

struct SettingsView: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        TabView {
            soundTab.tabItem { Label("Modulation", systemImage: "waveform.path") }
            sessionTab.tabItem { Label("Session", systemImage: "timer") }
            AboutContent().padding(20).tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 540)
        .tint(player.settings.mode.tint)
    }

    private var soundTab: some View {
        Form {
            Section {
                Toggle("Rhythmic amplitude modulation", isOn: $player.settings.amEnabled)
                Text("A smooth, fast rise and fall in loudness applied to the whole mix. It works on speakers and headphones. Turn it off to hear only the piano.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rate per mode") {
                ForEach(FocusMode.allCases) { m in
                    LabeledSlider(title: m.title, systemImage: m.symbol,
                                  value: Binding(get: { player.settings.rate(for: m) }, set: { player.settings.rates[m.rawValue] = $0 }),
                                  range: m.rateRange, display: { String(format: "%.1f Hz", $0) })
                }
                Button("Restore default rates") { player.settings.rates = [:] }
            }
            .disabled(!player.settings.amEnabled)
            Section("Shape") {
                LabeledSlider(title: "Depth", systemImage: "arrow.up.and.down", value: $player.settings.depth, range: 0.1...0.7)
                LabeledSlider(title: "Ramp-in", systemImage: "chart.line.uptrend.xyaxis", value: $player.settings.rampInSeconds,
                              range: 0...120, display: { "\(Int($0)) s" })
                Picker("Waveform", selection: $player.settings.waveform) {
                    Text("Smooth (sine)").tag(ModWaveform.sine)
                    Text("Rounded").tag(ModWaveform.rounded)
                }
            }
            .disabled(!player.settings.amEnabled)
        }
        .formStyle(.grouped)
    }

    private var sessionTab: some View {
        Form {
            Section("Timer") {
                Picker("Default length", selection: $player.settings.timerMinutes) {
                    Text("25 minutes").tag(25); Text("50 minutes").tag(50); Text("90 minutes").tag(90); Text("No timer").tag(0)
                }
                LabeledSlider(title: "Fade-out", systemImage: "speaker.wave.1", value: $player.settings.fadeOutSeconds,
                              range: 5...90, display: { "\(Int($0)) s" })
            }
            Section("Pink-noise bed") {
                Toggle("Play a soft noise bed under the piano", isOn: $player.settings.noiseEnabled)
                LabeledSlider(title: "Level", systemImage: "cloud", value: $player.settings.noiseLevel)
                    .disabled(!player.settings.noiseEnabled)
            }
            Section {
                Text("While Cadence plays, your Mac won't go to sleep on its own; the display can still sleep. Media keys and Control Centre's Now Playing control playback.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show the introduction again") { player.settings.onboarded = false }
            }
        }
        .formStyle(.grouped)
    }
}
