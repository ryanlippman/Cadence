import SwiftUI
import AppKit
import CadenceCore

/// Development aid: `Cadence --snapshot <dir>` renders the main views off-screen in light and dark
/// appearance to PNG files (used to review the UI where screen capture isn't available).
@MainActor
enum Snapshot {
    static func run(dir: String) async {
        let p = PlayerController.shared
        while p.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        p.settings.onboarded = true
        p.start()
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            save(MainView(player: p), size: CGSize(width: 420, height: 604), to: "\(dir)/main-\(name).png")
            save(MenuBarView(player: p).background(.background), size: CGSize(width: 300, height: 330), to: "\(dir)/menubar-\(name).png")
            save(SettingsView(player: p), size: CGSize(width: 480, height: 540), to: "\(dir)/settings-\(name).png")
            save(OnboardingView(player: p).background(.background), size: CGSize(width: 440, height: 300), to: "\(dir)/onboarding-\(name).png")
        }
        print("SNAPSHOT done → \(dir)")
        exit(0)
    }

    static func save<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSApp.appearance
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
