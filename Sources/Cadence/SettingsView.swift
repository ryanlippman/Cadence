import SwiftUI
import CadenceCore

struct SettingsView: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        TabView {
            flowTab.tabItem { Label("Flow", systemImage: "chart.line.uptrend.xyaxis") }
            soundTab.tabItem { Label("Modulation", systemImage: "waveform.path") }
            sessionTab.tabItem { Label("Session", systemImage: "timer") }
            AboutContent().padding(20).tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 600)
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
            Section {
                Picker("Strength", selection: $player.settings.strength) {
                    ForEach(ModStrength.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("If the effect feels too subtle, try Strong. In published research, stronger modulation helped most for listeners who report more attention difficulties; others may find it distracting. Choose what feels best.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Strength") }
            .disabled(!player.settings.amEnabled)
            Section("Shape") {
                LabeledSlider(title: "Depth", systemImage: "arrow.up.and.down", value: $player.settings.depth, range: 0.1...0.7)
                LabeledSlider(title: "Ramp-in", systemImage: "chart.line.uptrend.xyaxis", value: $player.settings.rampInSeconds,
                              range: 0...120, display: { "\(Int($0)) s" })
                Picker("Waveform", selection: $player.settings.waveform) {
                    ForEach(ModWaveform.allCases) { w in Text("\(w.title) — \(w.blurb)").tag(w) }
                }
                Picker("Stereo", selection: $player.settings.stereo) {
                    ForEach(ModStereo.allCases) { Text($0.title).tag($0) }
                }
                Picker("Applies to", selection: $player.settings.band) {
                    ForEach(ModBand.allCases) { Text($0.title).tag($0) }
                }
                Text("Alternating moves the pulse gently between your ears (best on headphones). “Above the bass” keeps the low notes steady, which some people find less tiring.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!player.settings.amEnabled)
        }
        .formStyle(.grouped)
    }

    private var flowTab: some View {
        Form {
            Section {
                Picker("Ease in over", selection: $player.settings.inductionMinutes) {
                    Text("Off").tag(0.0); Text("5 minutes").tag(5.0); Text("10 minutes").tag(10.0); Text("15 minutes").tag(15.0)
                }
                Text("Sessions start gently and deepen gradually: the modulation begins shallow and slower (about 10 Hz for Focus) and glides to its target, while the music starts calmer and sparser. Timed sessions also ease out over their last few minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Session arc") }
            Section {
                Toggle("Lock the modulation to the music's pulse", isOn: $player.settings.tempoLock)
                Text("Snaps the modulation rate to a whole multiple of the beat (within 10 % of the chosen rate) and keeps it aligned to each bar, so the effect moves with the music rather than against it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Slow, breathing-paced swells while settling in", isOn: $player.settings.breathSwell)
                Text("A very gentle rise and fall about six times a minute, like slow breathing, that fades away as the session deepens.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep the modulation subtly alive", isOn: $player.settings.slowVariation)
                Text("The strength wanders very slowly (about ±12 % over several minutes) so it never becomes a perfectly constant signal your ear tunes out completely.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Place the sound in front of you (headphones)", isOn: $player.settings.spatial)
                Text("Crossfeed and soft early reflections move the piano out of your head and into the room ahead, as if from speakers on your desk.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Techniques") }
            Section {
                Text("Cadence also reduces surprises throughout: no sudden accents, gaps, jumps in texture or shrill high notes, and once settled, fewer changes of key and style. These choices are inspired by research on rhythm, arousal and attention; how they feel varies from person to person.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
