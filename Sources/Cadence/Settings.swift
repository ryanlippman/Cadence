import Foundation
import CadenceCore

struct UserSettings: Codable, Equatable {
    var mode: FocusMode = .focus
    var rates: [String: Double] = [:]
    var amEnabled = true
    var depth = 0.45
    var intensity = 0.8
    var waveform: ModWaveform = .sine
    var rampInSeconds = 30.0
    var noiseEnabled = false
    var noiseLevel = 0.5
    var volume = 0.7
    /// 0 = no timer
    var timerMinutes = 0

    func rate(for mode: FocusMode) -> Double { rates[mode.rawValue] ?? mode.defaultRate }

    var engineParams: EngineParams {
        var p = EngineParams()
        p.mode = mode
        p.amEnabled = amEnabled
        p.rateHz = rate(for: mode)
        p.depth = depth
        p.intensity = intensity
        p.waveform = waveform
        p.rampInSeconds = rampInSeconds
        p.noiseEnabled = noiseEnabled
        p.noiseLevel = noiseLevel
        p.volume = volume
        return p
    }

    private static let key = "cadence.settings.v1"
    static func load() -> UserSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(UserSettings.self, from: d) else { return UserSettings() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: UserSettings.key) }
    }
}
