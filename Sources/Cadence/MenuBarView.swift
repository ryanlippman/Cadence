import SwiftUI
import CadenceCore

struct MenuBarView: View {
    @ObservedObject var player: PlayerController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if player.isPlaying, let piece = player.piece {
                    Image(nsImage: Artwork.image(for: piece, size: 160)).resizable().frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous)).accessibilityHidden(true)
                }
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(player.settings.mode.tint.gradient))
                }
                .buttonStyle(.plain).disabled(player.isLoading)
                .accessibilityLabel(player.isPlaying ? "Stop" : "Start")
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.isPlaying ? (player.piece?.name ?? "\(player.settings.mode.title) · \(player.status.style.title)") : "Cadence")
                        .font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            Picker("Mode", selection: Binding(get: { player.settings.mode }, set: { player.selectMode($0) })) {
                ForEach(FocusMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker("Style", selection: Binding(get: { player.settings.styleRaw }, set: { player.settings.styleRaw = $0 })) {
                ForEach(CompositionStyle.allCases) { Text($0.title).tag($0.rawValue) }
                Divider()
                Text("Varied").tag("varied")
            }
            HStack { Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $player.settings.volume).accessibilityLabel("Volume") }
            HStack { Image(systemName: "waveform.path").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $player.settings.intensity).accessibilityLabel("Intensity") }
            Picker("Timer", selection: $player.settings.timerMinutes) {
                Text("25m").tag(25); Text("50m").tag(50); Text("90m").tag(90); Text("∞").tag(0)
            }
            .pickerStyle(.segmented).labelsHidden()
            Divider()
            HStack(spacing: 14) {
                Button("Open Cadence") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Button("Settings…") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
        .tint(player.settings.mode.tint)
    }

    private var subtitle: String {
        if player.isLoading { return "Tuning the piano…" }
        if player.isPlaying {
            let k = player.settings.inductionMinutes > 0 ? player.arcPhase.title(for: player.settings.mode) : player.status.keyName
            if let r = player.remaining { return "\(k) · \(formatTime(r)) left" }
            return k.isEmpty ? "Beginning…" : k
        }
        return "Ready"
    }
}
