import SwiftUI
import CadenceCore

extension FocusMode {
    var symbol: String {
        switch self { case .focus: return "scope"; case .relax: return "leaf"; case .sleep: return "moon.stars" }
    }
    var blurb: String {
        switch self { case .focus: return "Brisk rhythm for deep work"; case .relax: return "Softer, unhurried"; case .sleep: return "Slowest and quietest" }
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.up)); let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

struct MainView: View {
    @ObservedObject var player: PlayerController
    @State private var showAdvanced = false
    @State private var showAbout = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                playButton
                modePicker
                controls
                timerSection
                DisclosureGroup(isExpanded: $showAdvanced) { advanced.padding(.top, 8) } label: {
                    Label("Modulation settings", systemImage: "slider.horizontal.3").font(.subheadline)
                }
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 400, idealWidth: 440, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAbout) { AttributionView() }
    }

    var header: some View {
        VStack(spacing: 4) {
            Text("Cadence").font(.system(size: 28, weight: .semibold, design: .serif))
            Text(player.isPlaying ? (player.nowPlayingText.isEmpty ? "Starting…" : player.nowPlayingText) : "Generative piano with a rhythmic amplitude layer")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    var playButton: some View {
        VStack(spacing: 8) {
            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.indigo, .purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: .indigo.opacity(0.4), radius: player.isPlaying ? 18 : 8)
                    Circle().stroke(.white.opacity(0.25 + Double(player.level)), lineWidth: 2).padding(-6)
                    Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                        .offset(x: player.isPlaying ? 0 : 3)
                }
                .frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Stop" : "Start")
            Text(player.isLoading ? "Loading piano…" : (player.isPlaying ? "Playing" : "Ready"))
                .font(.caption).foregroundStyle(.secondary)
            if let e = player.errorMessage { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(FocusMode.allCases) { m in
                let selected = player.settings.mode == m
                Button { player.selectMode(m) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: m.symbol).font(.title3)
                        Text(m.title).font(.subheadline.weight(.medium))
                        Text(player.settings.amEnabled ? "\(rateText(player.settings.rate(for: m))) Hz" : "AM off")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(m.blurb)
            }
        }
    }

    func rateText(_ r: Double) -> String { r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r) }

    var controls: some View {
        VStack(spacing: 14) {
            SliderRow(title: "Intensity", icon: "waveform.path", value: $player.settings.intensity, range: 0...1,
                      label: "\(Int(player.settings.intensity * 100))%")
            SliderRow(title: "Volume", icon: "speaker.wave.2", value: $player.settings.volume, range: 0...1,
                      label: "\(Int(player.settings.volume * 100))%")
            Toggle(isOn: $player.settings.noiseEnabled) {
                Label("Soft pink-noise bed", systemImage: "cloud")
            }
            if player.settings.noiseEnabled {
                SliderRow(title: "Noise", icon: "dial.low", value: $player.settings.noiseLevel, range: 0...1,
                          label: "\(Int(player.settings.noiseLevel * 100))%")
            }
        }
    }

    var timerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Session timer", systemImage: "timer")
                Spacer()
                if let r = player.remaining, player.isPlaying { Text(formatTime(r)).monospacedDigit().foregroundStyle(.secondary) }
            }
            Picker("", selection: $player.settings.timerMinutes) {
                Text("25 min").tag(25); Text("50 min").tag(50); Text("90 min").tag(90); Text("∞").tag(0)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("Fades out gently over the last 25 seconds.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var advanced: some View {
        let mode = player.settings.mode
        return VStack(spacing: 12) {
            Toggle("Amplitude modulation", isOn: $player.settings.amEnabled)
            SliderRow(title: "\(mode.title) rate", icon: "metronome",
                      value: Binding(get: { player.settings.rate(for: mode) },
                                     set: { player.settings.rates[mode.rawValue] = $0 }),
                      range: mode.rateRange, label: String(format: "%.1f Hz", player.settings.rate(for: mode)))
            SliderRow(title: "Depth", icon: "arrow.up.and.down", value: $player.settings.depth, range: 0.1...0.7,
                      label: "\(Int(player.settings.depth * 100))%")
            SliderRow(title: "Ramp-in", icon: "chart.line.uptrend.xyaxis",
                      value: $player.settings.rampInSeconds, range: 0...120, label: "\(Int(player.settings.rampInSeconds)) s")
            Picker("Waveform", selection: $player.settings.waveform) {
                ForEach(ModWaveform.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            Button("Reset rate to default") { player.settings.rates[mode.rawValue] = nil }.font(.caption)
        }
        .disabled(false)
    }

    var footer: some View {
        VStack(spacing: 6) {
            Text("Inspired by published research on rhythmic auditory stimulation. Effects vary between people; this is not a medical device.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("About & Attribution") { showAbout = true }.buttonStyle(.link).font(.caption)
        }
    }
}

struct SliderRow: View {
    let title: String
    let icon: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon).frame(width: 130, alignment: .leading).lineLimit(1)
            Slider(value: $value, in: range)
            Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var player: PlayerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { player.toggle() } label: {
                    Label(player.isPlaying ? "Stop" : "Start", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                }.disabled(player.isLoading)
                Spacer()
                if let r = player.remaining, player.isPlaying { Text(formatTime(r)).monospacedDigit().foregroundStyle(.secondary) }
            }
            Picker("Mode", selection: Binding(get: { player.settings.mode }, set: { player.selectMode($0) })) {
                ForEach(FocusMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            HStack { Image(systemName: "speaker.fill"); Slider(value: $player.settings.volume, in: 0...1) }
            HStack { Image(systemName: "waveform.path"); Slider(value: $player.settings.intensity, in: 0...1) }
            Picker("Timer", selection: $player.settings.timerMinutes) {
                Text("25m").tag(25); Text("50m").tag(50); Text("90m").tag(90); Text("∞").tag(0)
            }.pickerStyle(.segmented).labelsHidden()
            Divider()
            HStack {
                Button("Open Cadence") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14).frame(width: 280)
    }
}

struct AttributionView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About & Attribution").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Piano samples").font(.headline)
                    Text("Salamander Grand Piano V3 (Yamaha C5) recorded by Alexander Holm, distributed by the FreePats project, licensed under Creative Commons Attribution 3.0 (CC BY 3.0). Cadence uses a subset of notes and velocity layers, which were trimmed, faded and compressed to AAC; pitches between recorded notes are produced by pitch-shifting.")
                    HStack {
                        Link("CC BY 3.0 license", destination: URL(string: "https://creativecommons.org/licenses/by/3.0/")!)
                        Link("FreePats", destination: URL(string: "https://freepats.zenvoid.org/Piano/acoustic-grand-piano.html")!)
                    }
                    Text("About the sound layer").font(.headline)
                    Text("Cadence applies a smooth low-frequency amplitude modulation to the piano (≈16 Hz for Focus, ≈9 Hz for Relax, ≈1–4 Hz for Sleep). It is inspired by published research on rhythmic auditory stimulation. Effects on concentration and sleep vary between people, and Cadence makes no medical claims. It is not a medical device and not a treatment for any condition.")
                    Text("All music is generated on your Mac in real time; nothing is streamed or uploaded.")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 460, height: 420)
    }
}
