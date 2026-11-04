import SwiftUI
import CadenceCore

struct MainView: View {
    @ObservedObject var player: PlayerController
    @Environment(\.openSettings) private var openSettings
    @State private var showAbout = false
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 18)
            hero.frame(height: 250)
            VStack(spacing: 18) {
                modePicker
                stylePicker
                VStack(spacing: 10) {
                    LabeledSlider(title: "Intensity", systemImage: "waveform.path", value: $player.settings.intensity)
                    LabeledSlider(title: "Volume", systemImage: "speaker.wave.2", value: $player.settings.volume)
                }
                sessionRow
            }
            .padding(.horizontal, 26)
            Spacer(minLength: 12)
            footer.padding(.bottom, 14)
        }
        .frame(width: 420, height: 604)
        .background(.background)
        .tint(player.settings.mode.tint)
        .animation(.easeInOut(duration: 0.35), value: player.settings.mode)
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showOnboarding) { OnboardingView(player: player) }
        .onAppear { if !player.settings.onboarded { showOnboarding = true } }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Cadence").font(.system(size: 24, weight: .medium, design: .serif))
            Text(statusLine)
                .font(.callout).foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: statusLine)
                .accessibilityLabel("Now playing: \(statusLine)")
        }
    }

    private var statusLine: String {
        if let e = player.errorMessage { return e }
        switch player.state {
        case .loading: return "Tuning the piano…"
        case .idle: return "Original piano music, composed as you listen"
        case .stopping: return "Fading out…"
        case .playing:
            let s = player.status
            return s.keyName.isEmpty ? "Beginning…" : "\(s.style.title) · \(s.keyName) · \(s.section)"
        }
    }

    private var hero: some View {
        ZStack {
            Visualizer(player: player)
            if player.remaining != nil {
                Circle().trim(from: 0, to: player.sessionProgress)
                    .stroke(player.settings.mode.tint.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 214, height: 214)
                    .accessibilityHidden(true)
            }
            Button(action: player.toggle) {
                ZStack {
                    Circle().fill(player.settings.mode.tint.gradient)
                        .shadow(color: player.settings.mode.tint.opacity(player.isPlaying ? 0.45 : 0.2), radius: player.isPlaying ? 16 : 6)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                        .offset(x: player.isPlaying ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 92, height: 92)
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying ? "Stop" : "Start")
            .accessibilityHint("Space bar also starts and stops")
            if let r = player.remaining, player.isPlaying {
                Text(formatTime(r)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .offset(y: 72).accessibilityLabel("\(formatTime(r)) remaining")
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(FocusMode.allCases) { m in
                let selected = player.settings.mode == m
                Button { player.selectMode(m) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: m.symbol).font(.system(size: 15)).frame(height: 18)
                        Text(m.title).font(.callout.weight(.medium))
                        Text(player.settings.amEnabled ? rateText(player.settings.rate(for: m)) : "No modulation")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? m.tint.opacity(0.18) : Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? m.tint.opacity(0.7) : .clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.blurb)
                .accessibilityLabel("\(m.title) mode")
                .accessibilityValue(selected ? "Selected" : "")
                .accessibilityHint(m.blurb)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var stylePicker: some View {
        HStack {
            Image(systemName: "music.quarternote.3").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text("Style").frame(width: 74, alignment: .leading)
            Picker("Style", selection: Binding(get: { player.settings.styleRaw }, set: { player.settings.styleRaw = $0 })) {
                ForEach(CompositionStyle.allCases) { s in
                    Text(s.title).tag(s.rawValue)
                }
                Divider()
                Text("Varied").tag("varied")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(player.settings.style?.blurb ?? "Changes style between pieces")
            Spacer()
            Text(player.settings.style?.blurb ?? "Changes between pieces")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .font(.callout)
    }

    private var sessionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer").foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text("Session").frame(width: 74, alignment: .leading)
            Picker("Session length", selection: $player.settings.timerMinutes) {
                Text("25m").tag(25); Text("50m").tag(50); Text("90m").tag(90); Text("∞").tag(0)
            }
            .pickerStyle(.segmented).labelsHidden()
            Toggle(isOn: $player.settings.noiseEnabled) { Label("Noise", systemImage: "cloud").labelStyle(.iconOnly) }
                .toggleStyle(.button)
                .help("Soft pink-noise bed")
                .accessibilityLabel("Pink-noise bed")
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Button { showAbout = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help("About & attribution").accessibilityLabel("About and attribution")
            Spacer()
            Text("Effects vary between people · not a medical device")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings (⌘,)").accessibilityLabel("Settings")
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.secondary)
    }
}
