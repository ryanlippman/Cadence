import SwiftUI
import CadenceCore

@main
struct CadenceApp: App {
    @StateObject private var player = PlayerController.shared

    init() {
        // Test hook:  Cadence --selftest <seconds>  starts playback, reports the peak level, exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            Task { @MainActor in await CadenceApp.selfTest(seconds: secs) }
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
        .windowResizability(.contentMinSize)
        .defaultSize(width: 440, height: 780)

        MenuBarExtra("Cadence", systemImage: player.isPlaying ? "waveform.circle.fill" : "waveform.circle") {
            MenuBarView(player: player)
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor static func selfTest(seconds: Double) async {
        let p = PlayerController.shared
        while p.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        p.start()
        print("SELFTEST started, playing=\(p.isPlaying) error=\(p.errorMessage ?? "none")")
        for s in 1...Int(seconds) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            print("SELFTEST t=\(s)s peak=\(p.level) maxPeak=\(p.peakSeen) \(p.nowPlayingText)")
            fflush(stdout)
        }
        let ok = p.isPlaying && p.peakSeen > 0.001
        print("SELFTEST RESULT \(ok ? "PASS" : "FAIL") maxPeak=\(p.peakSeen)")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }
}
