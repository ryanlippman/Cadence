import Foundation
import CadenceCore

/// Persisted user settings. Decoding is tolerant: missing or unknown fields fall back to defaults,
/// so adding a setting in a future version never resets someone's preferences.
struct UserSettings: Codable, Equatable {
    var mode: FocusMode = .focus
    /// "varied" or a CompositionStyle raw value.
    var styleRaw: String = CompositionStyle.romantic.rawValue
    var rates: [String: Double] = [:]
    var amEnabled = true
    var depth = 0.45
    var intensity = 0.8
    var waveform: ModWaveform = .sine
    var rampInSeconds = 30.0
    var noiseEnabled = false
    var noiseLevel = 0.5
    var volume = 0.8
    /// 0 = no timer
    var timerMinutes = 0
    var fadeOutSeconds = 25.0
    var onboarded = false
    /// Ease-in length in minutes (0 = start at full strength).
    var inductionMinutes = 10.0
    var tempoLock = true
    var breathSwell = true
    var strength: ModStrength = .standard
    var stereo: ModStereo = .together
    var band: ModBand = .full
    var spatial = false
    var slowVariation = true

    var style: CompositionStyle? {
        get { CompositionStyle(rawValue: styleRaw) }
        set { styleRaw = newValue?.rawValue ?? "varied" }
    }

    func rate(for mode: FocusMode) -> Double {
        let r = rates[mode.rawValue] ?? mode.defaultRate
        return min(max(r, mode.rateRange.lowerBound), mode.rateRange.upperBound)
    }

    var engineParams: EngineParams {
        var p = EngineParams()
        p.mode = mode
        p.style = style
        p.amEnabled = amEnabled
        p.rateHz = rate(for: mode)
        p.depth = depth
        p.intensity = intensity
        p.waveform = waveform
        p.rampInSeconds = rampInSeconds
        p.noiseEnabled = noiseEnabled
        p.noiseLevel = noiseLevel
        p.volume = volume
        p.inductionMinutes = inductionMinutes
        p.tempoLock = tempoLock
        p.breathSwell = breathSwell
        p.strength = strength
        p.stereo = stereo
        p.band = band
        p.spatial = spatial
        p.slowVariation = slowVariation
        return p
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        mode = v(.mode, d.mode)
        styleRaw = v(.styleRaw, d.styleRaw)
        rates = v(.rates, d.rates)
        amEnabled = v(.amEnabled, d.amEnabled)
        depth = v(.depth, d.depth)
        intensity = v(.intensity, d.intensity)
        waveform = v(.waveform, d.waveform)
        rampInSeconds = v(.rampInSeconds, d.rampInSeconds)
        noiseEnabled = v(.noiseEnabled, d.noiseEnabled)
        noiseLevel = v(.noiseLevel, d.noiseLevel)
        volume = v(.volume, d.volume)
        timerMinutes = v(.timerMinutes, d.timerMinutes)
        fadeOutSeconds = v(.fadeOutSeconds, d.fadeOutSeconds)
        onboarded = v(.onboarded, d.onboarded)
        inductionMinutes = v(.inductionMinutes, d.inductionMinutes)
        tempoLock = v(.tempoLock, d.tempoLock)
        breathSwell = v(.breathSwell, d.breathSwell)
        strength = v(.strength, d.strength)
        stereo = v(.stereo, d.stereo)
        band = v(.band, d.band)
        spatial = v(.spatial, d.spatial)
        slowVariation = v(.slowVariation, d.slowVariation)
    }

    private static let key = "cadence.settings.v1"   // same key: v1 data migrates in place
    /// Test/diagnostic launches (--selftest, --snapshot) must not overwrite the user's preferences.
    static let persistenceEnabled = !CommandLine.arguments.contains { $0 == "--selftest" || $0 == "--snapshot" }
    static func load() -> UserSettings {
        guard persistenceEnabled else { return UserSettings() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(UserSettings.self, from: data) else { return UserSettings() }
        return s
    }
    func save() {
        guard UserSettings.persistenceEnabled else { return }
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: UserSettings.key) }
    }
}
