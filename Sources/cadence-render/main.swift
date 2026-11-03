import Foundation
import CadenceCore

// Usage: cadence-render [--mode focus|relax|sleep] [--seconds N] [--no-am] [--noise] [--seed N] [--rate HZ] out.wav
var args = Array(CommandLine.arguments.dropFirst())
var p = EngineParams()
var seconds = 60.0
var seed: UInt64 = 1
var out = "cadence.wav"
func take(_ k: String) -> String? { if let i = args.firstIndex(of: k), i + 1 < args.count { let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v }; return nil }
if let m = take("--mode"), let mode = FocusMode(rawValue: m) { p.mode = mode; p.rateHz = mode.defaultRate }
if let s = take("--seconds"), let d = Double(s) { seconds = d }
if let s = take("--seed"), let d = UInt64(s) { seed = d }
if let s = take("--rate"), let d = Double(s) { p.rateHz = d }
if let i = args.firstIndex(of: "--no-am") { p.amEnabled = false; args.remove(at: i) }
if let i = args.firstIndex(of: "--noise") { p.noiseEnabled = true; args.remove(at: i) }
if let f = args.first { out = f }
let sr = 44100.0
let core = SynthCore(bank: try SampleBank.loadBundled(), sampleRate: sr, seed: seed)
core.setParams(p)
core.startSession(fadeInSeconds: 1)
let (l, r) = core.renderOffline(seconds: seconds)
try WAV.write(left: l, right: r, sampleRate: Int(sr), to: URL(fileURLWithPath: out))
print("Wrote \(out): \(seconds)s, mode \(p.mode.rawValue), AM \(p.amEnabled ? "\(p.rateHz) Hz" : "off"), key \(core.currentKeyName)")
