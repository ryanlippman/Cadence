import SwiftUI
import CadenceCore

@main
struct CadenceApp: App {
    @StateObject private var player = PlayerController.shared

    init() {
        // Test hooks:  --selftest <seconds> [--style S] [--mode M]   plays, reports levels, exits.
        //              --autostart                                   starts playing at launch.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            Task { @MainActor in await CadenceApp.selfTest(seconds: secs, args: args) }
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = args[i + 1]
            Task { @MainActor in await Snapshot.run(dir: dir) }
        } else if args.contains("--autostart") {
            Task { @MainActor in
                while PlayerController.shared.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
                PlayerController.shared.start()
            }
        }
    }

    var body: some Scene {
        Window("Cadence", id: "main") {
            MainView(player: player)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { PlaybackCommands(player: player) }

        Settings { SettingsView(player: player) }

        MenuBarExtra {
            MenuBarView(player: player)
        } label: {
            Image(systemName: player.isPlaying ? "waveform.circle.fill" : "waveform.circle")
                .accessibilityLabel("Cadence")
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor static func selfTest(seconds: Double, args: [String]) async {
        let p = PlayerController.shared
        while p.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        p.settings.onboarded = true
        if let i = args.firstIndex(of: "--style"), i + 1 < args.count { p.settings.styleRaw = args[i + 1] }
        if let i = args.firstIndex(of: "--mode"), i + 1 < args.count, let m = FocusMode(rawValue: args[i + 1]) { p.selectMode(m) }
        p.start()
        print("SELFTEST started playing=\(p.isPlaying) error=\(p.errorMessage ?? "none")")
        var peaks: [Float] = []
        for s in 1...Int(seconds) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let m = p.meters()
            peaks.append(m?.peak ?? 0)
            print(String(format: "SELFTEST t=%ds peak=%.3f voices=%d %@", s, m?.peak ?? 0, m?.activeVoices ?? 0,
                         "\(p.status.style.title) · \(p.status.keyName) · \(p.status.section)"))
            fflush(stdout)
        }
        let ok = p.isPlaying && p.maxPeakSeen > 0.001
        print("SELFTEST RESULT \(ok ? "PASS" : "FAIL") maxPeak=\(p.maxPeakSeen)")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }
}

struct PlaybackCommands: Commands {
    @ObservedObject var player: PlayerController
    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Stop" : "Start") { player.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            Divider()
            ForEach(Array(FocusMode.allCases.enumerated()), id: \.offset) { i, m in
                Button(m.title) { player.selectMode(m) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Menu("Style") {
                ForEach(CompositionStyle.allCases) { s in Button(s.title) { player.selectStyle(s) } }
                Button("Varied") { player.selectStyle(nil) }
            }
            Menu("Session") {
                Button("25 minutes") { player.settings.timerMinutes = 25 }
                Button("50 minutes") { player.settings.timerMinutes = 50 }
                Button("90 minutes") { player.settings.timerMinutes = 90 }
                Button("No timer") { player.settings.timerMinutes = 0 }
            }
        }
    }
}
