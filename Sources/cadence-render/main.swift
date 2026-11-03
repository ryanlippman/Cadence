import Foundation
import CadenceCore

// Stage 1 smoke tool: renders a short arpeggio through sampler + reverb to a WAV file.
let out = CommandLine.arguments.dropFirst().first ?? "stage1.wav"
let sr = 44100.0
let bank = try SampleBank.loadBundled()
print("Loaded \(bank.zones.count) sample zones, centers \(bank.centers.first!)…\(bank.centers.last!)")
let sampler = Sampler(bank: bank, sampleRate: sr)
let reverb = Reverb(sampleRate: sr)
let total = Int(sr * 10)
var L = [Float](repeating: 0, count: total), R = L
let notes = [48, 55, 60, 64, 67, 64, 60, 55]
var pending: [(Int, Int)] = notes.enumerated().map { (Int(Double($0.offset) * 0.5 * sr), $0.element) }
let block = 512
var pos = 0
L.withUnsafeMutableBufferPointer { lp in R.withUnsafeMutableBufferPointer { rp in
    while pos < total {
        let n = min(block, total - pos)
        while let f = pending.first, f.0 < pos + n {
            sampler.noteOn(midi: f.1, velocity: 50, holdSamples: Int(sr * 3), delay: f.0 - pos)
            pending.removeFirst()
        }
        sampler.render(outL: lp.baseAddress! + pos, outR: rp.baseAddress! + pos, frames: n)
        reverb.process(left: lp.baseAddress! + pos, right: rp.baseAddress! + pos, frames: n, wet: 0.2)
        pos += n
    }
}}
try WAV.write(left: L, right: R, sampleRate: Int(sr), to: URL(fileURLWithPath: out))
print("Wrote \(out); peak \(max(L.map(abs).max()!, R.map(abs).max()!))")
