import Foundation
import CadenceCore

// Audit/analysis tool. Usage: cadence-analyze [seconds]
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let bank = try SampleBank.loadBundled()
let sr = 44100.0
for mode in FocusMode.allCases {
    var p = EngineParams(); p.mode = mode; p.rateHz = mode.defaultRate
    let core = SynthCore(bank: bank, sampleRate: sr, seed: 3)
    core.setParams(p); core.startSession(fadeInSeconds: 0.5)
    let t0 = Date()
    let out = core.renderOffline(seconds: seconds)
    let rt = Date().timeIntervalSince(t0) / seconds
    let x = Array(out.left[Int(sr * 5)...])
    let st = AudioAnalysis.shortTermDB(x, sampleRate: sr)
    let clicks = AudioAnalysis.clickCount(x)
    let env = AudioAnalysis.envelope(x, sampleRate: sr)
    let pk = AudioAnalysis.envelopePeak(env, envRate: 500, band: (mode.defaultRate * 0.5)...(mode.defaultRate * 1.6))
    print(String(format: "%@: RMS %.1f dBFS, peak %.1f dBFS, short-term p10/p50/p90 %.1f/%.1f/%.1f, clicks %d (worst %.1f), AM peak %.2f Hz x%.0f, CPU %.3f×RT",
                 mode.rawValue, AudioAnalysis.db(AudioAnalysis.rms(x)), AudioAnalysis.db(AudioAnalysis.peak(x)),
                 AudioAnalysis.percentile(st, 0.1), AudioAnalysis.percentile(st, 0.5), AudioAnalysis.percentile(st, 0.9),
                 clicks.count, clicks.worst, pk.freq, pk.prominence, rt))
}

if CommandLine.arguments.contains("--clicks") {
    var p = EngineParams(); p.amEnabled = false
    let core = SynthCore(bank: bank, sampleRate: sr, seed: 3)
    core.setParams(p); core.startSession(fadeInSeconds: 0.01)
    var maxV = 0
    var x: [Float] = []
    for _ in 0..<(90 * 10) { let o = core.renderOffline(seconds: 0.1); x += o.left; maxV = max(maxV, core.debugVoices) }
    print("AM off: clicks", AudioAnalysis.clickCount(x), "steals", core.debugSteals, "max voices", maxV)
    // locate
    var d2 = [Double](repeating: 0, count: x.count)
    for n in 2..<x.count { d2[n] = Double(x[n]) - 2 * Double(x[n-1]) + Double(x[n-2]) }
    let top = d2.indices.sorted { abs(d2[$0]) > abs(d2[$1]) }.prefix(5)
    for t in top { print(String(format: "t=%.4fs d2=%.4f x=%.4f", Double(t) / sr, d2[t], x[t])) }
}
if CommandLine.arguments.contains("--starts") {
    for z in bank.zones.prefix(4) {
        let v = (0..<12).map { String(format: "%.4f", Float(z.left[$0]) / 32768) }
        let firstBig = (0..<z.frames).first { abs(Int(z.left[$0])) > 300 } ?? -1
        print(z.centerMidi, z.layerVelocity, v.joined(separator: " "), "first>0.01 at", firstBig)
    }
}
if CommandLine.arguments.contains("--around") {
    var p = EngineParams(); p.amEnabled = false
    let core = SynthCore(bank: bank, sampleRate: sr, seed: 3)
    core.setParams(p); core.startSession(fadeInSeconds: 0.01)
    let x = core.renderOffline(seconds: 80).left
    let c = Int(79.3631 * sr)
    print((c-8...c+8).map { String(format: "%.4f", x[$0]) }.joined(separator: " "))
    // also dry sampler-only: count clicks before reverb not possible here; print local stats
    print("rms around", AudioAnalysis.rms(x[(c-96)...(c+96)]))
}
if CommandLine.arguments.contains("--zones") {
    var bad = 0
    for z in bank.zones {
        var l = [Float](repeating: 0, count: z.frames)
        for i in 0..<z.frames { l[i] = Float(z.left[i]) / 32768 }
        let c = AudioAnalysis.clickCount(l, ratio: 10, floor: 2e-3)
        if c.count > 0 {
            bad += 1
            // locate first
            var d2 = [Double](repeating: 0, count: l.count)
            for n in 2..<l.count { d2[n] = Double(l[n]) - 2 * Double(l[n-1]) + Double(l[n-2]) }
            let t = d2.indices.max { abs(d2[$0]) < abs(d2[$1]) }!
            print("zone", z.centerMidi, "v", z.layerVelocity, "clicks", c.count, String(format: "maxd2 at %.4fs (%d)", Double(t)/z.sampleRate, t))
        }
    }
    print("zones with spikes:", bad, "of", bank.zones.count)
}
