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
            save(MainView(player: p), size: CGSize(width: 420, height: 640), to: "\(dir)/main-\(name).png")
            save(MenuBarView(player: p).background(.background), size: CGSize(width: 300, height: 330), to: "\(dir)/menubar-\(name).png")
            save(SettingsView(player: p), size: CGSize(width: 500, height: 600), to: "\(dir)/settings-\(name).png")
            if let piece = p.piece {
                save(Image(nsImage: Artwork.image(for: piece)), size: CGSize(width: 600, height: 600), to: "\(dir)/artwork-\(name).png")
            }
            save(OnboardingView(player: p).background(.background), size: CGSize(width: 440, height: 300), to: "\(dir)/onboarding-\(name).png")
        }
        var sheet: [PieceIdentity] = []
        for (i, st) in CompositionStyle.allCases.enumerated() { for (j, m) in FocusMode.allCases.enumerated() {
            sheet.append(PieceIdentity(movement: i * 3 + j, keyName: ["E♭ major", "A minor", "D dorian", "F♯ minor"][i], style: st, mode: m, salt: 42))
        }}
        let grid = VStack(spacing: 6) { ForEach(0..<4, id: \.self) { r in HStack(spacing: 6) { ForEach(0..<3, id: \.self) { c in
            let pc = sheet[r * 3 + c]
            VStack(spacing: 2) {
                Image(nsImage: Artwork.image(for: pc, size: 200)).resizable().frame(width: 150, height: 150)
                Text(pc.name).font(.caption.bold()); Text(pc.subtitle).font(.caption2)
            }
        }}}}
        save(grid.padding(6).background(.background), size: CGSize(width: 480, height: 780), to: "\(dir)/artwork-sheet.png")
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
